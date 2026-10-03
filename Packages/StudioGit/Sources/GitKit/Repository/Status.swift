import Foundation
import Clibgit2

/// How a file differs in one place (index or working tree).
public enum FileChange: String, Sendable, Codable, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case typeChanged
    case untracked
    case ignored
    case conflicted
}

/// One path in `git status`.
public struct StatusEntry: Sendable, Hashable, Identifiable, Codable {
    /// Current path (the new path for renames).
    public var path: String
    /// The original path when the entry is a rename.
    public var oldPath: String?
    /// HEAD -> index ("staged") change.
    public var staged: FileChange?
    /// index -> working tree ("unstaged") change.
    public var unstaged: FileChange?
    public var isConflicted: Bool

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, staged: FileChange? = nil, unstaged: FileChange? = nil, isConflicted: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.staged = staged
        self.unstaged = unstaged
        self.isConflicted = isConflicted
    }
}

public struct StatusOptions: Sendable {
    public var includeUntracked = true
    public var recurseUntrackedDirectories = true
    public var includeIgnored = false
    public var detectRenames = true
    /// Limit status to these paths (pathspecs). Empty means the whole tree.
    /// The file watcher passes changed paths here for incremental status.
    public var paths: [String] = []
    public init() {}
}

extension GitRepository {
    public func status(_ options: StatusOptions = StatusOptions()) throws -> [StatusEntry] {
        var opts = git_status_options()
        git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        var flags: UInt32 = 0
        if options.includeUntracked { flags |= GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue }
        if options.recurseUntrackedDirectories { flags |= GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue }
        if options.includeIgnored { flags |= GIT_STATUS_OPT_INCLUDE_IGNORED.rawValue }
        if options.detectRenames {
            flags |= GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            flags |= GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR.rawValue
        }
        if !options.paths.isEmpty { flags |= GIT_STATUS_OPT_DISABLE_PATHSPEC_MATCH.rawValue }
        opts.flags = flags

        var list: OpaquePointer?
        let spec = CStringArray(options.paths)
        defer { spec.free() }
        if !spec.isEmpty { opts.pathspec = spec.array }
        try check(git_status_list_new(&list, handle, &opts), "git_status_list_new")
        defer { git_status_list_free(list) }

        var result: [StatusEntry] = []
        let count = git_status_list_entrycount(list)
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let entry = git_status_byindex(list, i)?.pointee else { continue }
            let s = entry.status.rawValue
            if s == GIT_STATUS_CURRENT.rawValue { continue }
            var e = StatusEntry(path: "")
            if s & GIT_STATUS_CONFLICTED.rawValue != 0 {
                e.isConflicted = true
            }
            if s & GIT_STATUS_INDEX_NEW.rawValue != 0 { e.staged = .added }
            else if s & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 { e.staged = .modified }
            else if s & GIT_STATUS_INDEX_DELETED.rawValue != 0 { e.staged = .deleted }
            else if s & GIT_STATUS_INDEX_RENAMED.rawValue != 0 { e.staged = .renamed }
            else if s & GIT_STATUS_INDEX_TYPECHANGE.rawValue != 0 { e.staged = .typeChanged }

            if s & GIT_STATUS_WT_NEW.rawValue != 0 { e.unstaged = .untracked }
            else if s & GIT_STATUS_WT_MODIFIED.rawValue != 0 { e.unstaged = .modified }
            else if s & GIT_STATUS_WT_DELETED.rawValue != 0 { e.unstaged = .deleted }
            else if s & GIT_STATUS_WT_RENAMED.rawValue != 0 { e.unstaged = .renamed }
            else if s & GIT_STATUS_WT_TYPECHANGE.rawValue != 0 { e.unstaged = .typeChanged }
            else if s & GIT_STATUS_IGNORED.rawValue != 0 { e.unstaged = .ignored }
            if e.isConflicted { e.unstaged = .conflicted; e.staged = nil }

            let delta = entry.index_to_workdir ?? entry.head_to_index
            if let delta {
                let newPath = String(gitCString: delta.pointee.new_file.path)
                let oldPath = String(gitCString: delta.pointee.old_file.path)
                e.path = newPath ?? oldPath ?? ""
                if let h2i = entry.head_to_index, s & GIT_STATUS_INDEX_RENAMED.rawValue != 0 {
                    e.oldPath = String(gitCString: h2i.pointee.old_file.path)
                    if entry.index_to_workdir == nil {
                        e.path = String(gitCString: h2i.pointee.new_file.path) ?? e.path
                    }
                } else if s & GIT_STATUS_WT_RENAMED.rawValue != 0 {
                    e.oldPath = oldPath
                }
            }
            result.append(e)
        }
        return result
    }

    /// Whether the working tree or index has any change (untracked included).
    public func isDirty(includeUntracked: Bool = true) throws -> Bool {
        var options = StatusOptions()
        options.includeUntracked = includeUntracked
        options.detectRenames = false
        return try !status(options).isEmpty
    }
}
