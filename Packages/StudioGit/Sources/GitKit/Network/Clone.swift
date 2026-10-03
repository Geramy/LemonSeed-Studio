public import Foundation
import Clibgit2

public struct CloneOptions: Sendable, Codable, Equatable {
    public var url: String
    /// The new working directory (must not exist or be empty).
    public var destination: URL
    /// Branch to check out; nil uses the remote's default branch.
    public var branch: String?
    /// Shallow clone depth; nil clones the full history.
    public var depth: Int?
    public var recurseSubmodules = false
    /// Stage the clone so an interrupted clone can be resumed (see below).
    public var resumable = true
    /// Download Git LFS objects (one batch, before checkout).
    public var lfs = true
    public var remoteName = "origin"

    public init(url: String, destination: URL, branch: String? = nil, depth: Int? = nil, recurseSubmodules: Bool = false, resumable: Bool = true) {
        self.url = url
        self.destination = destination
        self.branch = branch
        self.depth = depth
        self.recurseSubmodules = recurseSubmodules
        self.resumable = resumable
    }
}

/// Where an interrupted clone stopped.
public struct PendingClone: Sendable, Codable, Equatable {
    public enum Stage: String, Sendable, Codable {
        case initialized
        /// A depth-1 base has been fetched; the rest of the history is next.
        case shallowBase
        case fetched
        case checkedOut
    }
    public var options: CloneOptions
    public var stage: Stage
    public var defaultBranch: String?
}

extension GitRepository {
    static let pendingCloneFile = "studio-clone.json"

    /// Clones a repository.
    ///
    /// The Git pack protocol cannot resume a half-received pack, so a
    /// resumable clone is staged instead: `init` and `remote add`, then a
    /// depth-1 fetch (small and quick), then the rest of the history (or the
    /// requested depth), then checkout and submodules. Each finished stage is
    /// recorded in `.git/studio-clone.json`; `resumeClone(at:)` continues
    /// from the last finished stage, and a re-run fetch only transfers what
    /// is still missing.
    public static func clone(_ options: CloneOptions, network: NetworkContext = NetworkContext()) async throws -> GitRepository {
        GitRuntime.ensureInitialized()
        let fm = FileManager.default
        if fm.fileExists(atPath: options.destination.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: options.destination.path)) ?? []
            if !contents.isEmpty {
                if pendingClone(at: options.destination) != nil {
                    return try await resumeClone(at: options.destination, network: network)
                }
                throw GitError(code: .exists, message: "\(options.destination.lastPathComponent) already exists and is not empty", operation: "clone")
            }
        }
        let repo = try GitRepository.create(at: options.destination, initialBranch: options.branch ?? "main")
        try await repo.addRemote(options.remoteName, url: options.url)
        var pending = PendingClone(options: options, stage: .initialized, defaultBranch: nil)
        try await repo.savePending(pending)
        return try await repo.continueClone(&pending, network: network)
    }

    /// The pending clone recorded at `url`, if a clone there was interrupted.
    public static func pendingClone(at url: URL) -> PendingClone? {
        let file = url.appending(path: ".git").appending(path: pendingCloneFile)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PendingClone.self, from: data)
    }

    /// Continues an interrupted clone from its last finished stage.
    public static func resumeClone(at url: URL, network: NetworkContext = NetworkContext()) async throws -> GitRepository {
        guard var pending = pendingClone(at: url) else {
            throw GitError(code: .notFound, message: "no interrupted clone at \(url.path)", operation: "resumeClone")
        }
        let repo = try GitRepository.open(at: url)
        return try await repo.continueClone(&pending, network: network)
    }

    private func savePending(_ pending: PendingClone?) throws {
        let file = gitDirectory.appending(path: Self.pendingCloneFile)
        if let pending {
            try JSONEncoder().encode(pending).write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func continueClone(_ pending: inout PendingClone, network: NetworkContext) async throws -> GitRepository {
        let options = pending.options
        let remote = options.remoteName
        func step(_ name: String) {
            network.progress?({ var p = TransferProgress(phase: .connecting); p.step = name; return p }())
        }

        if pending.stage == .initialized {
            if pending.defaultBranch == nil && options.branch == nil {
                step("Connecting")
                pending.defaultBranch = try await remoteDefaultBranch(remote, network: network)
                try savePending(pending)
            }
            // The local transport has no shallow support; local clones are fast anyway.
            let isLocal = options.url.hasPrefix("/") || options.url.hasPrefix("file://")
            let wantsShallowBase = options.resumable && !isLocal && (options.depth == nil || options.depth! > 1)
            var shallowDone = false
            if wantsShallowBase {
                step("Fetching latest snapshot")
                do {
                    try await fetch(FetchOptions(remote: remote, refspecs: branchRefspecs(pending), depth: 1), network: network)
                    pending.stage = .shallowBase
                    shallowDone = true
                } catch let error as GitError where error.code != .cancelled && error.code != .authentication && error.code != .certificate {
                    // Servers without shallow support (dumb HTTP): fall through to a full fetch.
                }
            }
            if !shallowDone {
                step("Fetching")
                try await fetch(FetchOptions(remote: remote, depth: options.depth), network: network)
                pending.stage = .fetched
            }
            try savePending(pending)
        }

        if pending.stage == .shallowBase {
            if let depth = options.depth {
                step("Fetching \(depth) commits")
                try await fetch(FetchOptions(remote: remote, depth: depth), network: network)
            } else {
                step("Fetching history")
                try await fetch(FetchOptions(remote: remote, unshallow: true), network: network)
            }
            pending.stage = .fetched
            try savePending(pending)
        }

        if pending.stage == .fetched {
            step("Checking out")
            let branch = options.branch ?? pending.defaultBranch ?? (try? findAnyRemoteBranch(remote)) ?? "main"
            if options.lfs { try await prefetchLFS(remote: remote, branch: branch, network: network) }
            try checkoutAfterClone(branch: branch, remote: remote, progress: network.progress)
            pending.stage = .checkedOut
            try savePending(pending)
        }

        if pending.stage == .checkedOut {
            if options.recurseSubmodules {
                step("Submodules")
                try await updateSubmodules(initialize: true, recursive: true, network: network)
            }
            try savePending(nil)
        }
        network.progress?(TransferProgress(phase: .done))
        return self
    }

    /// Downloads the LFS objects of the branch being checked out so the
    /// smudge filter finds them during checkout (no per-file round trips).
    private func prefetchLFS(remote: String, branch: String, network: NetworkContext) async throws {
        let revision = "refs/remotes/\(remote)/\(branch)"
        guard let files = try? lfsFiles(at: revision), !files.isEmpty else { return }
        guard let endpoint = try lfsEndpoint(remote: remote, revision: revision) else { return }
        network.progress?({ var p = TransferProgress(phase: .lfs); p.step = "Downloading LFS files"; p.total = files.count; return p }())
        let client = LFSClient(endpoint: endpoint, session: network.lfsSession, credentials: network.credentials)
        try await client.download(files.map(\.pointer), into: lfsStore, ref: "refs/heads/\(branch)")
    }

    private func branchRefspecs(_ pending: PendingClone) -> [String] {
        guard let branch = pending.options.branch ?? pending.defaultBranch else { return [] }
        let remote = pending.options.remoteName
        return ["+refs/heads/\(branch):refs/remotes/\(remote)/\(branch)"]
    }

    private func findAnyRemoteBranch(_ remote: String) throws -> String? {
        try branches(.remote).first { $0.remoteName == remote }?.nameWithoutRemote
    }

    private func checkoutAfterClone(branch: String, remote: String, progress: TransferProgressHandler?) throws {
        let remoteRef = "refs/remotes/\(remote)/\(branch)"
        guard let target = try? resolveCommit(remoteRef) else {
            // Empty remote: leave an unborn branch with the right name.
            try check(git_repository_set_head(handle, "refs/heads/\(branch)"), "git_repository_set_head")
            return
        }
        let commit = try lookupCommit(target)
        defer { git_commit_free(commit) }
        var ref: OpaquePointer?
        try check(git_branch_create(&ref, handle, branch, commit, 1), "git_branch_create(\(branch))")
        defer { git_reference_free(ref) }
        try check(git_branch_set_upstream(ref, "\(remote)/\(branch)"), "git_branch_set_upstream")
        try check(git_repository_set_head(handle, "refs/heads/\(branch)"), "git_repository_set_head")

        final class Progress { var handler: TransferProgressHandler? }
        let box = Progress()
        box.handler = progress
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        if progress != nil {
            opts.progress_payload = Unmanaged.passUnretained(box).toOpaque()
            opts.progress_cb = { _, completed, total, payload in
                let box = Unmanaged<Progress>.fromOpaque(payload!).takeUnretainedValue()
                guard completed % 64 == 0 || completed == total else { return }
                var p = TransferProgress(phase: .checkingOut)
                p.current = completed
                p.total = total
                box.handler?(p)
            }
        }
        try check(git_checkout_head(handle, &opts), "git_checkout_head")
        withExtendedLifetime(box) {}
    }
}
