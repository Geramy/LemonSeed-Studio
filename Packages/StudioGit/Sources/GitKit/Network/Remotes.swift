public import Foundation
import Clibgit2

public struct Remote: Sendable, Hashable, Identifiable, Codable {
    public var name: String
    public var url: String
    public var pushURL: String?
    public var fetchRefspecs: [String]
    public var id: String { name }
}

public struct FetchOptions: Sendable {
    public enum Tags: Sendable { case auto, all, none }
    public var remote = "origin"
    /// Empty uses the remote's configured refspecs.
    public var refspecs: [String] = []
    public var prune = false
    public var tags: Tags = .auto
    /// Shallow depth; nil keeps the current depth (full for full clones).
    public var depth: Int?
    /// Convert a shallow repository into a complete one.
    public var unshallow = false
    public init(remote: String = "origin", refspecs: [String] = [], prune: Bool = false, tags: Tags = .auto, depth: Int? = nil, unshallow: Bool = false) {
        self.remote = remote
        self.refspecs = refspecs
        self.prune = prune
        self.tags = tags
        self.depth = depth
        self.unshallow = unshallow
    }
}

public struct FetchSummary: Sendable, Equatable {
    public struct Update: Sendable, Equatable {
        public var reference: String
        public var old: ObjectID?
        public var new: ObjectID?
    }
    public var updates: [Update]
    public var receivedObjects: Int
    public var receivedBytes: Int
}

public struct PushOptions: Sendable {
    public var remote = "origin"
    /// Push `+src:dst` (non-fast-forward allowed).
    public var force = false
    /// After pushing a branch, make the remote branch its upstream.
    public var setUpstream = false
    /// Extra refspecs (for tags: `refs/tags/v1:refs/tags/v1`).
    public var extraRefspecs: [String] = []
    /// Upload Git LFS objects referenced by the pushed branch first.
    public var lfs = true
    /// The branch name on the remote; nil pushes to the same name.
    public var remoteBranch: String?
    public init(remote: String = "origin", force: Bool = false, setUpstream: Bool = false, extraRefspecs: [String] = [], lfs: Bool = true,
                remoteBranch: String? = nil) {
        self.remote = remote
        self.force = force
        self.setUpstream = setUpstream
        self.extraRefspecs = extraRefspecs
        self.lfs = lfs
        self.remoteBranch = remoteBranch
    }
}

public enum PullStrategy: Sendable {
    case merge
    case rebase
    case fastForwardOnly
}

public enum PullResult: Sendable, Equatable {
    case upToDate
    case fastForwarded(ObjectID)
    case merged(ObjectID)
    case rebased(ObjectID)
    case conflicts([String])
}

/// Everything a network operation needs besides its own options.
public struct NetworkContext: Sendable {
    public var credentials: any CredentialProvider
    public var trust: any HostTrustEvaluator
    public var progress: TransferProgressHandler?
    /// Session for Git LFS transfers (a background session in the app).
    public var lfsSession: URLSession

    public init(credentials: any CredentialProvider = NoCredentials(),
                trust: any HostTrustEvaluator = KnownHostsStore.shared,
                progress: TransferProgressHandler? = nil,
                lfsSession: URLSession = .shared) {
        self.credentials = credentials
        self.trust = trust
        self.progress = progress
        self.lfsSession = lfsSession
    }

    func makeTransferContext() -> TransferContext {
        TransferContext(credentials: credentials, trust: trust, progress: progress)
    }
}

extension GitRepository {
    // MARK: Remote configuration

    public func remotes() throws -> [Remote] {
        var names = git_strarray()
        try check(git_remote_list(&names, handle), "git_remote_list")
        defer { git_strarray_dispose(&names) }
        return try names.swiftStrings.map { try remote(named: $0) }
    }

    public func remote(named name: String) throws -> Remote {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, handle, name), "git_remote_lookup(\(name))")
        defer { git_remote_free(remote) }
        var specs = git_strarray()
        try check(git_remote_get_fetch_refspecs(&specs, remote), "git_remote_get_fetch_refspecs")
        defer { git_strarray_dispose(&specs) }
        return Remote(name: name,
                      url: String(gitCString: git_remote_url(remote)) ?? "",
                      pushURL: String(gitCString: git_remote_pushurl(remote)),
                      fetchRefspecs: specs.swiftStrings)
    }

    @discardableResult
    public func addRemote(_ name: String, url: String) throws -> Remote {
        var remote: OpaquePointer?
        try check(git_remote_create(&remote, handle, name, url), "git_remote_create(\(name))")
        git_remote_free(remote)
        return try self.remote(named: name)
    }

    public func removeRemote(_ name: String) throws {
        try check(git_remote_delete(handle, name), "git_remote_delete(\(name))")
    }

    public func renameRemote(_ name: String, to newName: String) throws {
        var problems = git_strarray()
        try check(git_remote_rename(&problems, handle, name, newName), "git_remote_rename")
        git_strarray_dispose(&problems)
    }

    public func setRemoteURL(_ name: String, url: String, push: Bool = false) throws {
        if push {
            try check(git_remote_set_pushurl(handle, name, url), "git_remote_set_pushurl")
        } else {
            try check(git_remote_set_url(handle, name, url), "git_remote_set_url")
        }
    }

    /// Whether the repository is shallow (has a `.git/shallow` file).
    public func isShallow() -> Bool {
        git_repository_is_shallow(handle) == 1
    }

    // MARK: Fetch / push / pull

    /// Fetches from a remote. Runs on the transfer queue with a separate
    /// repository handle; cancel the calling Task to cancel the fetch.
    @discardableResult
    public nonisolated func fetch(_ options: FetchOptions = FetchOptions(), network: NetworkContext = NetworkContext()) async throws -> FetchSummary {
        let path = gitDirectory.path
        let context = network.makeTransferContext()
        let summary = try await TransferQueue.run(context) {
            try GitRepository.withHandle(path) { repo in
                try Self.fetch(repo: repo, options: options, context: context)
            }
        }
        await reopen()
        return summary
    }

    /// Pushes a branch (default: the current one) to its remote.
    public nonisolated func push(branch: String? = nil, options: PushOptions = PushOptions(), network: NetworkContext = NetworkContext()) async throws {
        let branchName: String?
        if let branch {
            branchName = branch
        } else {
            branchName = try await head().branch
        }
        var refspecs = options.extraRefspecs
        if let branchName {
            refspecs.insert("\(options.force ? "+" : "")refs/heads/\(branchName):refs/heads/\(options.remoteBranch ?? branchName)", at: 0)
        }
        guard !refspecs.isEmpty else { throw GitError.invalid("nothing to push (detached HEAD)", "push") }
        if options.lfs, let branchName, try await !lfsFiles(at: "refs/heads/\(branchName)").isEmpty {
            try await lfsPush(remote: options.remote, revision: "refs/heads/\(branchName)", network: network)
        }
        let path = gitDirectory.path
        let context = network.makeTransferContext()
        let remoteName = options.remote
        let pushRefspecs = refspecs
        try await TransferQueue.run(context) {
            try GitRepository.withHandle(path) { repo in
                var remote: OpaquePointer?
                try check(git_remote_lookup(&remote, repo, remoteName), "git_remote_lookup(\(remoteName))")
                defer { git_remote_free(remote) }
                var opts = git_push_options()
                git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION))
                context.install(into: &opts.callbacks)
                let specs = CStringArray(pushRefspecs)
                defer { specs.free() }
                var array = specs.array
                let rc = git_remote_push(remote, &array, &opts)
                if rc < 0 { throw context.error(for: rc, operation: "git_remote_push") }
                if !context.pushRejections.isEmpty {
                    let detail = context.pushRejections.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
                    throw GitError(code: .pushRejected, message: "push rejected: \(detail)", operation: "git_remote_push")
                }
            }
        }
        context.report(force: true) { $0.phase = .done }
        await reopen()
        if options.setUpstream, let branchName {
            try await setUpstream(of: branchName, to: "\(remoteName)/\(options.remoteBranch ?? branchName)")
        }
    }

    /// Deletes a branch on the remote (`git push origin :branch`).
    public nonisolated func deleteRemoteBranch(_ branch: String, remote: String = "origin", network: NetworkContext = NetworkContext()) async throws {
        try await push(branch: nil, options: PushOptions(remote: remote, extraRefspecs: [":refs/heads/\(branch)"]), network: network)
    }

    /// Fetches the current branch's upstream and integrates it.
    public func pull(strategy: PullStrategy = .merge, network: NetworkContext = NetworkContext()) async throws -> PullResult {
        guard let branch = try currentBranch() else {
            throw GitError(code: .unbornBranch, message: "no current branch to pull into", operation: "pull")
        }
        guard let upstream = branch.upstream else {
            throw GitError.invalid("branch \(branch.name) has no upstream", "pull")
        }
        let remoteName = String(upstream.split(separator: "/", maxSplits: 1).first ?? "origin")
        try await fetch(FetchOptions(remote: remoteName), network: network)
        let upstreamRef = "refs/remotes/\(upstream)"
        switch strategy {
        case .rebase:
            switch try rebase(onto: upstreamRef) {
            case .upToDate: return .upToDate
            case .completed(let id): return .rebased(id)
            case .stopped(let progress): return .conflicts(progress.conflicts)
            }
        case .merge, .fastForwardOnly:
            let result = try merge(upstreamRef, options: MergeOptions(fastForward: strategy == .fastForwardOnly ? .only : .allowed))
            switch result {
            case .upToDate: return .upToDate
            case .fastForward(let id): return .fastForwarded(id)
            case .merged(let id): return .merged(id)
            case .conflicts(let paths): return .conflicts(paths)
            }
        }
    }

    /// Asks the remote for its default branch (`HEAD`), e.g. `main`.
    public nonisolated func remoteDefaultBranch(_ remoteName: String = "origin", network: NetworkContext = NetworkContext()) async throws -> String? {
        let path = gitDirectory.path
        let context = network.makeTransferContext()
        return try await TransferQueue.run(context) {
            try GitRepository.withHandle(path) { repo in
                var remote: OpaquePointer?
                try check(git_remote_lookup(&remote, repo, remoteName), "git_remote_lookup")
                defer { git_remote_free(remote) }
                var callbacks = git_remote_callbacks()
                git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
                context.install(into: &callbacks)
                let rc = git_remote_connect(remote, GIT_DIRECTION_FETCH, &callbacks, nil, nil)
                if rc < 0 { throw context.error(for: rc, operation: "git_remote_connect") }
                defer { git_remote_disconnect(remote) }
                var buf = git_buf()
                let drc = git_remote_default_branch(&buf, remote)
                if drc == GIT_ENOTFOUND.rawValue { return nil }
                try check(drc, "git_remote_default_branch")
                return buf.takeString().shortRefName
            }
        }
    }

    // MARK: Internals shared with clone

    /// Opens a private handle for work off the actor.
    static func withHandle<T>(_ path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var repo: OpaquePointer?
        try check(git_repository_open(&repo, path), "git_repository_open")
        defer { git_repository_free(repo) }
        return try body(repo!)
    }

    static func fetch(repo: OpaquePointer, options: FetchOptions, context: TransferContext) throws -> FetchSummary {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, repo, options.remote), "git_remote_lookup(\(options.remote))")
        defer { git_remote_free(remote) }
        var opts = git_fetch_options()
        git_fetch_options_init(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION))
        context.install(into: &opts.callbacks)
        opts.prune = options.prune ? GIT_FETCH_PRUNE : GIT_FETCH_PRUNE_UNSPECIFIED
        switch options.tags {
        case .auto: opts.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_AUTO
        case .all: opts.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_ALL
        case .none: opts.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE
        }
        if options.unshallow {
            opts.depth = Int32(GIT_FETCH_DEPTH_UNSHALLOW.rawValue)
        } else if let depth = options.depth {
            opts.depth = Int32(depth)
        }
        let specs = CStringArray(options.refspecs)
        defer { specs.free() }
        var array = specs.array
        let rc: Int32
        if options.refspecs.isEmpty {
            rc = git_remote_fetch(remote, nil, &opts, nil)
        } else {
            rc = git_remote_fetch(remote, &array, &opts, nil)
        }
        if rc < 0 { throw context.error(for: rc, operation: "git_remote_fetch") }
        let stats = git_remote_stats(remote)?.pointee
        context.report(force: true) { $0.phase = .done }
        return FetchSummary(
            updates: context.updatedReferences.map { FetchSummary.Update(reference: $0.name, old: $0.old, new: $0.new) },
            receivedObjects: Int(stats?.received_objects ?? 0),
            receivedBytes: stats?.received_bytes ?? 0)
    }
}
