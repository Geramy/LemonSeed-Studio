import Foundation
import Clibgit2

public struct RebaseProgress: Sendable, Equatable {
    /// 1-based position of the operation being applied.
    public var current: Int
    public var total: Int
    /// The original commit being replayed.
    public var commit: ObjectID?
    public var conflicts: [String]
}

public enum RebaseResult: Sendable, Equatable {
    /// Nothing to replay: the branch already contains `upstream`.
    case upToDate
    /// The rebase finished; HEAD is now at this commit.
    case completed(ObjectID)
    /// Stopped on a commit with conflicts. Resolve them (`resolveConflict`),
    /// then `continueRebase()`, `skipRebaseCommit()` or `abortRebase()`.
    case stopped(RebaseProgress)
}

extension GitRepository {
    /// Replays the current branch (or `branch`) on top of `upstream`
    /// (`git rebase upstream`).
    public func rebase(onto upstream: String, branch: String? = nil, committer: Signature? = nil) throws -> RebaseResult {
        let upstreamID = try resolveCommit(upstream)
        let branchID = try branch.map { try resolveCommit($0) } ?? head().commit
        guard let branchID else { throw GitError(code: .unbornBranch, message: "nothing to rebase", operation: "rebase") }
        if try upstreamID == branchID || isAncestor(upstreamID, of: branchID) {
            return .upToDate
        }

        var up: OpaquePointer?
        try check(git_annotated_commit_from_revspec(&up, handle, upstream), "git_annotated_commit_from_revspec(\(upstream))")
        defer { git_annotated_commit_free(up) }
        var br: OpaquePointer?
        if let branch {
            try check(git_annotated_commit_from_revspec(&br, handle, branch), "git_annotated_commit_from_revspec(\(branch))")
        }
        defer { git_annotated_commit_free(br) }

        var opts = rebaseOptions()
        var rebase: OpaquePointer?
        try check(git_rebase_init(&rebase, handle, br, up, nil, &opts), "git_rebase_init")
        defer { git_rebase_free(rebase) }
        return try runRebase(rebase!, committer: committer, commitCurrent: false)
    }

    /// Commits the resolved current operation and continues.
    public func continueRebase(committer: Signature? = nil) throws -> RebaseResult {
        let rebase = try openRebase()
        defer { git_rebase_free(rebase) }
        return try runRebase(rebase, committer: committer, commitCurrent: true)
    }

    /// Drops the current operation's changes and continues with the next one.
    public func skipRebaseCommit(committer: Signature? = nil) throws -> RebaseResult {
        let rebase = try openRebase()
        defer { git_rebase_free(rebase) }
        try reset(to: "HEAD", mode: .hard)
        return try runRebase(rebase, committer: committer, commitCurrent: false)
    }

    /// Stops the rebase and restores the branch to where it was.
    public func abortRebase() throws {
        let rebase = try openRebase()
        defer { git_rebase_free(rebase) }
        try check(git_rebase_abort(rebase), "git_rebase_abort")
    }

    /// Progress of an in-progress rebase, or nil.
    public func rebaseProgress() throws -> RebaseProgress? {
        guard [.rebase, .rebaseMerge, .rebaseInteractive].contains(state()) else { return nil }
        let rebase = try openRebase()
        defer { git_rebase_free(rebase) }
        return try progress(of: rebase)
    }

    private func openRebase() throws -> OpaquePointer {
        var opts = rebaseOptions()
        var rebase: OpaquePointer?
        try check(git_rebase_open(&rebase, handle, &opts), "git_rebase_open")
        return rebase!
    }

    private func rebaseOptions() -> git_rebase_options {
        var opts = git_rebase_options()
        git_rebase_options_init(&opts, UInt32(GIT_REBASE_OPTIONS_VERSION))
        opts.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        return opts
    }

    private func progress(of rebase: OpaquePointer) throws -> RebaseProgress {
        let total = git_rebase_operation_entrycount(rebase)
        let current = git_rebase_operation_current(rebase)
        var commit: ObjectID?
        var position = 0
        if current != Int(bitPattern: UInt(GIT_REBASE_NO_OPERATION)), let op = git_rebase_operation_byindex(rebase, current) {
            commit = ObjectID(op.pointee.id)
            position = current + 1
        }
        return RebaseProgress(current: position, total: total, commit: commit, conflicts: try conflicts().map(\.path))
    }

    private func runRebase(_ rebase: OpaquePointer, committer: Signature?, commitCurrent: Bool) throws -> RebaseResult {
        guard let committerSig = try committer ?? configuredIdentity() else {
            throw GitError.invalid("no committer: set user.name and user.email", "rebase")
        }
        let sig = try committerSig.makeGitSignature()
        defer { git_signature_free(sig) }

        func commitOperation() throws -> Bool {
            let pending = try conflicts()
            if !pending.isEmpty { return false }
            var oid = git_oid()
            let rc = git_rebase_commit(&oid, rebase, nil, sig, nil, nil)
            // GIT_EAPPLIED: the patch was already upstream; nothing to commit.
            if rc != GIT_EAPPLIED.rawValue { try check(rc, "git_rebase_commit") }
            git_error_clear()
            return true
        }

        if commitCurrent {
            guard try commitOperation() else { return .stopped(try progress(of: rebase)) }
        }
        var op: UnsafeMutablePointer<git_rebase_operation>?
        while true {
            let rc = git_rebase_next(&op, rebase)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc, "git_rebase_next")
            guard try commitOperation() else { return .stopped(try progress(of: rebase)) }
        }
        try check(git_rebase_finish(rebase, sig), "git_rebase_finish")
        guard let headID = try head().commit else { throw GitError.invalid("rebase left no HEAD", "rebase") }
        return .completed(headID)
    }
}
