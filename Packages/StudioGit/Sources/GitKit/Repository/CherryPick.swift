import Foundation
import Clibgit2

public enum PickResult: Sendable, Equatable {
    /// The change applied cleanly and was committed.
    case committed(ObjectID)
    /// Conflicts in these paths. The repository is in the `.cherryPick` (or
    /// `.revert`) state: resolve, then `commit(message: preparedMessage())`,
    /// or `abortMerge()`.
    case conflicts([String])
}

extension GitRepository {
    /// Applies the change introduced by `commit` on top of HEAD
    /// (`git cherry-pick`). The original author is kept.
    public func cherryPick(_ commitID: ObjectID, mainline: Int = 0, committer: Signature? = nil) throws -> PickResult {
        let commit = try lookupCommit(commitID)
        defer { git_commit_free(commit) }
        var opts = git_cherrypick_options()
        git_cherrypick_options_init(&opts, UInt32(GIT_CHERRYPICK_OPTIONS_VERSION))
        opts.mainline = UInt32(mainline)
        opts.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        try check(git_cherrypick(handle, commit, &opts), "git_cherrypick")
        let paths = try conflicts().map(\.path)
        if !paths.isEmpty { return .conflicts(paths) }
        let info = Self.info(of: commit)
        let id = try self.commit(message: info.message,
                                 options: CommitOptions(author: info.author, committer: try committer ?? configuredIdentity(), allowEmpty: true))
        return .committed(id)
    }

    /// Creates a commit that undoes `commit` (`git revert`).
    public func revert(_ commitID: ObjectID, mainline: Int = 0, author: Signature? = nil) throws -> PickResult {
        let commit = try lookupCommit(commitID)
        defer { git_commit_free(commit) }
        var opts = git_revert_options()
        git_revert_options_init(&opts, UInt32(GIT_REVERT_OPTIONS_VERSION))
        opts.mainline = UInt32(mainline)
        opts.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        try check(git_revert(handle, commit, &opts), "git_revert")
        let paths = try conflicts().map(\.path)
        if !paths.isEmpty { return .conflicts(paths) }
        let info = Self.info(of: commit)
        let message = "Revert \"\(info.summary)\"\n\nThis reverts commit \(info.id.hex).\n"
        let id = try self.commit(message: message, options: CommitOptions(author: author, allowEmpty: true))
        return .committed(id)
    }
}
