public import Foundation
public import Observation
public import GitKit

/// State and actions of the Source Control panel for one repository.
@MainActor
@Observable
public final class SourceControlModel {
    public let repository: GitRepository
    public let services: GitServices

    public struct Selection: Hashable, Sendable {
        public var path: String
        public var staged: Bool
    }

    public enum SyncState: Equatable {
        case idle
        case running(TransferProgress)
    }

    public private(set) var staged: [StatusEntry] = []
    public private(set) var unstaged: [StatusEntry] = []
    public private(set) var conflicted: [StatusEntry] = []
    public private(set) var head: GitRepository.Head?
    public private(set) var currentBranch: Branch?
    public private(set) var branches: [Branch] = []
    public private(set) var state: RepositoryState = .none
    public private(set) var rebase: RebaseProgress?
    public private(set) var stashes: [StashEntry] = []
    public private(set) var remotes: [Remote] = []
    public var selection: Selection?
    public private(set) var selectedDiff: FileDiff?
    public var selectedLines: Set<LineSelection> = []
    public var commitMessage = ""
    public var amend = false
    public private(set) var sync: SyncState = .idle
    public var errorMessage: String?
    public private(set) var lastRefresh: Date?
    /// The last finished action, for a short confirmation line.
    public var notice: String?

    /// How to switch branches with uncommitted changes.
    public enum SwitchStrategy: Sendable, Equatable {
        /// Keep the changes in the working tree (Git's default; refused when
        /// a changed file differs between the branches).
        case carry
        /// Stash every change (untracked files too), then switch.
        case stash
    }

    public init(repository: GitRepository, services: GitServices) {
        self.repository = repository
        self.services = services
    }

    public var name: String { repository.workingDirectory?.lastPathComponent ?? "Repository" }
    public var ahead: Int { currentBranch?.ahead ?? 0 }
    public var behind: Int { currentBranch?.behind ?? 0 }
    public var hasChanges: Bool { !staged.isEmpty || !unstaged.isEmpty || !conflicted.isEmpty }
    public var canCommit: Bool {
        conflicted.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!staged.isEmpty || amend || state == .merge)
    }

    // MARK: Loading

    public func refresh() async {
        await run {
            let entries = try await repository.status()
            conflicted = entries.filter(\.isConflicted)
            staged = entries.filter { $0.staged != nil && !$0.isConflicted }
            unstaged = entries.filter { $0.unstaged != nil && !$0.isConflicted && $0.unstaged != .ignored }
            head = try await repository.head()
            currentBranch = try await repository.currentBranch()
            branches = try await repository.branches(.all)
            state = await repository.state()
            rebase = try await repository.rebaseProgress()
            stashes = try await repository.stashes()
            remotes = try await repository.remotes()
            if state.isInProgress, commitMessage.isEmpty, let prepared = await repository.preparedMessage() {
                commitMessage = prepared.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
            }
            lastRefresh = Date()
            try await reloadSelection()
        }
    }

    public func select(_ entry: StatusEntry, staged: Bool) async {
        selection = Selection(path: entry.path, staged: staged)
        selectedLines = []
        await run { try await reloadSelection() }
    }

    private func reloadSelection() async throws {
        guard let selection else { selectedDiff = nil; return }
        selectedDiff = try await repository.diff(file: selection.path, selection.staged ? .staged : .unstaged)
        if selectedDiff == nil {
            // The file moved to the other list (e.g. fully staged).
            let other = try await repository.diff(file: selection.path, selection.staged ? .unstaged : .staged)
            if other != nil {
                self.selection = Selection(path: selection.path, staged: !selection.staged)
                selectedDiff = other
            }
        }
    }

    // MARK: Staging

    public func stage(_ entries: [StatusEntry]) async {
        await mutate { try await repository.stage(entries.map(\.path)) }
    }

    public func unstage(_ entries: [StatusEntry]) async {
        await mutate { try await repository.unstage(entries.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }) }
    }

    public func stageAll() async { await mutate { try await repository.stageAll() } }
    public func unstageAll() async { await unstage(staged) }

    public func discard(_ entries: [StatusEntry]) async {
        await mutate { try await repository.discard(entries.map(\.path)) }
    }

    /// Stages (or, in the staged view, unstages) one hunk of the selection.
    public func toggleHunk(_ hunk: DiffHunk) async {
        guard let selection else { return }
        await mutate {
            if selection.staged {
                try await repository.unstage(path: selection.path, hunks: [hunk.id])
            } else {
                try await repository.stage(path: selection.path, hunks: [hunk.id])
            }
        }
    }

    public func discardHunk(_ hunk: DiffHunk) async {
        guard let selection, !selection.staged else { return }
        await mutate { try await repository.discard(path: selection.path, hunks: [hunk.id]) }
    }

    public func toggleLine(_ line: DiffLine, in hunk: DiffHunk) {
        guard line.kind != .context else { return }
        let id = LineSelection(hunk: hunk.id, line: line.id)
        if selectedLines.contains(id) { selectedLines.remove(id) } else { selectedLines.insert(id) }
    }

    /// Stages or unstages the selected lines.
    public func applySelectedLines() async {
        guard let selection, !selectedLines.isEmpty else { return }
        let lines = selectedLines
        selectedLines = []
        await mutate {
            if selection.staged {
                try await repository.unstage(path: selection.path, lines: lines)
            } else {
                try await repository.stage(path: selection.path, lines: lines)
            }
        }
    }

    // MARK: Commit

    public func commit() async {
        guard canCommit else { return }
        await mutate {
            guard let identity = await services.identity(for: repository) else {
                throw GitError(code: .invalidArgument, message: "Set your name and email in Settings before committing.")
            }
            let signer = await services.commitSigner()
            try await repository.commit(message: commitMessage, options: CommitOptions(author: identity, amend: amend, signer: signer))
            commitMessage = ""
            amend = false
            selection = nil
        }
    }

    // MARK: Branches

    public var localBranches: [Branch] { branches.filter { !$0.isRemote } }
    public var remoteBranches: [Branch] { branches.filter(\.isRemote) }

    /// Switches to `branch` (local, or remote-tracking: a local branch
    /// tracking it is created). With uncommitted changes, `strategy` says
    /// whether they come along or are stashed first.
    public func checkout(_ branch: Branch, strategy: SwitchStrategy = .carry) async {
        await mutate {
            switch strategy {
            case .carry:
                do {
                    try await repository.checkout(branch: branch.name)
                } catch let error as GitError where error.code == .conflict {
                    throw GitError(code: .conflict, message: "Switching to \(branch.name) would overwrite uncommitted changes (\(error.message)). "
                                   + "Stash them or commit them first.", operation: "checkout")
                }
            case .stash:
                let message = "Stashed before switching to \(branch.name)"
                guard try await repository.stash(StashOptions(message: message, includeUntracked: true)) != nil else {
                    try await repository.checkout(branch: branch.name)
                    return
                }
                do {
                    try await repository.checkout(branch: branch.name)
                } catch {
                    // Put the changes back where they were before reporting.
                    _ = try await repository.popStash(0)
                    throw error
                }
                notice = "Your changes are in the stash \"\(message)\"."
            }
        }
    }

    /// Creates a branch at `startPoint` (HEAD, a branch name or a commit)
    /// and optionally switches to it. Returns whether it was created.
    @discardableResult
    public func createBranch(_ name: String, from startPoint: String = "HEAD", checkout: Bool = true) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard GitRepository.isValidBranchName(trimmed) else {
            errorMessage = "\"\(trimmed)\" is not a valid branch name."
            return false
        }
        var created = false
        await mutate {
            try await repository.createBranch(trimmed, at: startPoint.isEmpty ? "HEAD" : startPoint, checkout: checkout)
            created = true
        }
        return created
    }

    public func createBranch(_ name: String) async {
        await createBranch(name, from: "HEAD", checkout: true)
    }

    public func renameBranch(_ branch: Branch, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard GitRepository.isValidBranchName(trimmed) else {
            errorMessage = "\"\(trimmed)\" is not a valid branch name."
            return
        }
        await mutate {
            try await repository.renameBranch(branch.name, to: trimmed)
            notice = "Renamed \(branch.name) to \(trimmed)."
        }
    }

    public func deleteBranch(_ branch: Branch, force: Bool = false) async {
        await mutate {
            if branch.isRemote {
                try await repository.deleteRemoteTrackingBranch(branch.name)
            } else {
                try await repository.deleteBranch(branch.name, force: force)
            }
        }
    }

    /// Deletes the branch on its remote: a remote-tracking branch's own
    /// remote, or a local branch's upstream.
    public func deleteRemoteBranch(_ branch: Branch) async {
        let remote: String
        let name: String
        if branch.isRemote, let r = branch.remoteName {
            remote = r
            name = branch.nameWithoutRemote
        } else if let (r, n) = Self.split(upstream: branch.upstream) {
            remote = r
            name = n
        } else {
            errorMessage = "\(branch.name) has no remote branch."
            return
        }
        await runNetwork { network in
            try await repository.deleteRemoteBranch(name, remote: remote, network: network)
            if (try? await repository.branch(named: "\(remote)/\(name)", remote: true)) != nil {
                try await repository.deleteRemoteTrackingBranch("\(remote)/\(name)")
            }
            notice = "Deleted \(name) on \(remote)."
        }
    }

    /// Sets (or with nil clears) a local branch's upstream, e.g. `origin/main`.
    public func setUpstream(_ branch: Branch, to upstream: String?) async {
        await mutate {
            try await repository.setUpstream(of: branch.name, to: upstream)
            notice = upstream.map { "\(branch.name) now tracks \($0)." } ?? "\(branch.name) no longer tracks a remote branch."
        }
    }

    /// Pushes a local branch to `remote` and makes it the upstream (`push -u`).
    public func publish(_ branch: Branch, to remote: String) async {
        await runNetwork { network in
            try await repository.push(branch: branch.name, options: PushOptions(remote: remote, setUpstream: true), network: network)
            notice = "Published \(branch.name) to \(remote)."
        }
    }

    /// Pushes a local branch to its upstream (which may have another name).
    public func push(_ branch: Branch) async {
        guard let (remote, name) = Self.split(upstream: branch.upstream) else {
            errorMessage = "\(branch.name) has no upstream. Publish it first."
            return
        }
        await runNetwork { network in
            try await repository.push(branch: branch.name, options: PushOptions(remote: remote, remoteBranch: name), network: network)
            notice = "Pushed \(branch.name) to \(remote)/\(name)."
        }
    }

    /// `origin/feature/x` → ("origin", "feature/x").
    static func split(upstream: String?) -> (String, String)? {
        guard let upstream, let slash = upstream.firstIndex(of: "/") else { return nil }
        return (String(upstream[..<slash]), String(upstream[upstream.index(after: slash)...]))
    }

    /// Pushes the current branch (publishing it first when it has no upstream).
    /// Returns whether the branch is on the remote afterwards.
    @discardableResult
    public func pushCurrentBranch(remote preferred: String? = nil) async -> Bool {
        guard let branch = currentBranch else {
            errorMessage = "Check out a branch first (HEAD is detached)."
            return false
        }
        var pushed = false
        await runNetwork { network in
            if let (remote, name) = Self.split(upstream: branch.upstream) {
                try await repository.push(branch: branch.name, options: PushOptions(remote: remote, remoteBranch: name), network: network)
            } else {
                guard let remote = preferred ?? remotes.first(where: { $0.name == "origin" })?.name ?? remotes.first?.name else {
                    throw GitError(code: .notFound, message: "This repository has no remote to push to.", operation: "push")
                }
                try await repository.push(branch: branch.name, options: PushOptions(remote: remote, setUpstream: true), network: network)
            }
            pushed = true
        }
        return pushed
    }

    public func merge(_ branch: Branch) async {
        await mutate {
            if case .conflicts(let paths) = try await repository.merge(branch.referenceName) {
                errorMessage = "Merge stopped with conflicts in \(paths.count) file\(paths.count == 1 ? "" : "s")."
            }
        }
    }

    public func stash() async {
        await mutate { try await repository.stash(StashOptions(includeUntracked: true)) }
    }

    public func popStash(_ entry: StashEntry) async {
        await mutate { _ = try await repository.popStash(entry.index) }
    }

    // MARK: Operations in progress

    public func abortOperation() async {
        await mutate {
            if [.rebase, .rebaseMerge, .rebaseInteractive].contains(state) {
                try await repository.abortRebase()
            } else {
                try await repository.abortMerge()
            }
            commitMessage = ""
        }
    }

    public func continueRebase() async {
        await mutate { _ = try await repository.continueRebase() }
    }

    public func resolve(_ path: String, with resolution: ConflictResolution) async {
        await mutate { try await repository.resolveConflict(path, with: resolution) }
    }

    // MARK: Sync

    /// Fetch, integrate the upstream, then push.
    public func synchronize() async {
        guard sync == .idle else { return }
        await runNetwork { network in
            if let branch = currentBranch, let (remote, name) = Self.split(upstream: branch.upstream) {
                switch try await repository.pull(strategy: .merge, network: network) {
                case .conflicts(let paths):
                    errorMessage = "Pull stopped with conflicts in \(paths.count) file\(paths.count == 1 ? "" : "s"). Resolve them, then commit."
                    return
                default: break
                }
                let aheadNow = try await repository.currentBranch()?.ahead ?? 0
                if aheadNow > 0 {
                    try await repository.push(branch: branch.name, options: PushOptions(remote: remote, remoteBranch: name), network: network)
                }
            } else if let branch = currentBranch {
                // Publish the branch.
                guard let remote = remotes.first(where: { $0.name == "origin" })?.name ?? remotes.first?.name else {
                    throw GitError(code: .notFound, message: "This repository has no remote to publish to.", operation: "push")
                }
                try await repository.push(branch: branch.name, options: PushOptions(remote: remote, setUpstream: true), network: network)
            }
        }
    }

    public func fetch() async {
        await runNetwork { network in _ = try await repository.fetch(FetchOptions(prune: true), network: network) }
    }

    // MARK: Helpers

    private func run(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            errorMessage = (error as? any LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func mutate(_ body: () async throws -> Void) async {
        await run(body)
        await refresh()
    }

    private func runNetwork(_ body: (NetworkContext) async throws -> Void) async {
        sync = .running(TransferProgress(phase: .connecting))
        let network = await services.network(for: repository) { [weak self] progress in
            Task { @MainActor in
                guard let self, case .running = self.sync else { return }
                self.sync = .running(progress)
            }
        }
        await run { try await body(network) }
        sync = .idle
        await refresh()
    }
}
