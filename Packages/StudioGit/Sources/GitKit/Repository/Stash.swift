import Foundation
import Clibgit2

public struct StashEntry: Sendable, Hashable, Identifiable, Codable {
    /// Position in the stash list (0 = most recent, `stash@{0}`).
    public var index: Int
    public var message: String
    public var commit: ObjectID
    public var id: ObjectID { commit }
}

public enum StashApplyResult: Sendable, Equatable {
    case applied
    /// Applied with conflicts in these paths; the stash entry is kept.
    case conflicts([String])
}

public struct StashOptions: Sendable {
    public var message: String?
    public var includeUntracked = false
    /// Leave staged changes in the index as well (`--keep-index`).
    public var keepIndex = false
    public var stasher: Signature?
    public init(message: String? = nil, includeUntracked: Bool = false, keepIndex: Bool = false, stasher: Signature? = nil) {
        self.message = message
        self.includeUntracked = includeUntracked
        self.keepIndex = keepIndex
        self.stasher = stasher
    }
}

extension GitRepository {
    public func stashes() throws -> [StashEntry] {
        final class Box { var entries: [StashEntry] = [] }
        let box = Box()
        try check(git_stash_foreach(handle, { index, message, oid, payload in
            let box = Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue()
            if let oid {
                box.entries.append(StashEntry(index: index, message: String(gitCString: message) ?? "", commit: ObjectID(oid)))
            }
            return 0
        }, Unmanaged.passUnretained(box).toOpaque()), "git_stash_foreach")
        return box.entries
    }

    /// Saves local changes and reverts the working tree. Returns nil when
    /// there was nothing to stash.
    @discardableResult
    public func stash(_ options: StashOptions = StashOptions()) throws -> ObjectID? {
        guard let who = try options.stasher ?? configuredIdentity() else {
            throw GitError.invalid("no identity: set user.name and user.email", "stash")
        }
        let sig = try who.makeGitSignature()
        defer { git_signature_free(sig) }
        var flags = GIT_STASH_DEFAULT.rawValue
        if options.includeUntracked { flags |= GIT_STASH_INCLUDE_UNTRACKED.rawValue }
        if options.keepIndex { flags |= GIT_STASH_KEEP_INDEX.rawValue }
        var oid = git_oid()
        let rc = git_stash_save(&oid, handle, sig, options.message, flags)
        if rc == GIT_ENOTFOUND.rawValue { git_error_clear(); return nil }
        try check(rc, "git_stash_save")
        return ObjectID(oid)
    }

    /// Applies a stash entry, keeping it in the list.
    public func applyStash(_ index: Int = 0, reinstateIndex: Bool = false) throws -> StashApplyResult {
        try applyStash(index, reinstateIndex: reinstateIndex, pop: false)
    }

    /// Applies a stash entry and drops it if it applied cleanly.
    public func popStash(_ index: Int = 0, reinstateIndex: Bool = false) throws -> StashApplyResult {
        try applyStash(index, reinstateIndex: reinstateIndex, pop: true)
    }

    public func dropStash(_ index: Int = 0) throws {
        try check(git_stash_drop(handle, index), "git_stash_drop(\(index))")
    }

    private func applyStash(_ index: Int, reinstateIndex: Bool, pop: Bool) throws -> StashApplyResult {
        var opts = git_stash_apply_options()
        git_stash_apply_options_init(&opts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))
        if reinstateIndex { opts.flags = GIT_STASH_APPLY_REINSTATE_INDEX.rawValue }
        opts.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        let rc = git_stash_apply(handle, index, &opts)
        if rc == GIT_EMERGECONFLICT.rawValue || rc == GIT_ECONFLICT.rawValue {
            let paths = try conflicts().map(\.path)
            if paths.isEmpty { try check(rc, "git_stash_apply") }
            return .conflicts(paths)
        }
        try check(rc, "git_stash_apply")
        let paths = try conflicts().map(\.path)
        if !paths.isEmpty { return .conflicts(paths) }
        if pop { try dropStash(index) }
        return .applied
    }
}
