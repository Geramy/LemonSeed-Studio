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
    public var selection: Selection?
    public private(set) var selectedDiff: FileDiff?
    public var selectedLines: Set<LineSelection> = []
    public var commitMessage = ""
    public var amend = false
    public private(set) var sync: SyncState = .idle
    public var errorMessage: String?
    public private(set) var lastRefresh: Date?

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

    public func checkout(_ branch: Branch) async {
        await mutate { try await repository.checkout(branch: branch.name) }
    }

    public func createBranch(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await mutate { try await repository.createBranch(trimmed, checkout: true) }
    }

    public func deleteBranch(_ branch: Branch, force: Bool = false) async {
        await mutate { try await repository.deleteBranch(branch.name, force: force) }
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
            if currentBranch?.upstream != nil {
                switch try await repository.pull(strategy: .merge, network: network) {
                case .conflicts(let paths):
                    errorMessage = "Pull stopped with conflicts in \(paths.count) file\(paths.count == 1 ? "" : "s")."
                    return
                default: break
                }
                let aheadNow = try await repository.currentBranch()?.ahead ?? 0
                if aheadNow > 0 {
                    try await repository.push(network: network)
                }
            } else if currentBranch != nil {
                // Publish the branch.
                try await repository.push(options: PushOptions(setUpstream: true), network: network)
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
