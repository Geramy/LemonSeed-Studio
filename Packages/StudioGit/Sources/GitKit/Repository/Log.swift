import Foundation
import Clibgit2

public struct LogOptions: Sendable {
    /// Revisions to start from (`HEAD`, branch names, ids).
    public var include: [String] = ["HEAD"]
    /// Revisions whose history is excluded (`a..b` is include b, exclude a).
    public var exclude: [String] = []
    /// Include every local and remote branch and tag (for the history graph).
    public var allReferences = false
    public var skip = 0
    public var limit: Int? = 500
    /// Only commits that changed this path.
    public var path: String?
    /// Case-insensitive substring of the author name or email.
    public var author: String?
    public var firstParentOnly = false
    public init() {}
}

extension GitRepository {
    /// Commit history in topological, then time order.
    public func log(_ options: LogOptions = LogOptions()) throws -> [CommitInfo] {
        if git_repository_head_unborn(handle) == 1 && !options.allReferences && options.include == ["HEAD"] {
            return []
        }
        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, handle), "git_revwalk_new")
        defer { git_revwalk_free(walk) }
        try check(git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue), "git_revwalk_sorting")
        if options.firstParentOnly { try check(git_revwalk_simplify_first_parent(walk), "git_revwalk_simplify_first_parent") }
        if options.allReferences {
            try check(git_revwalk_push_glob(walk, "refs/heads/*"), "git_revwalk_push_glob")
            try check(git_revwalk_push_glob(walk, "refs/remotes/*"), "git_revwalk_push_glob")
            try check(git_revwalk_push_glob(walk, "refs/tags/*"), "git_revwalk_push_glob")
            if git_repository_head_unborn(handle) != 1 { try check(git_revwalk_push_head(walk), "git_revwalk_push_head") }
        }
        for rev in options.include where !(options.allReferences && rev == "HEAD") {
            let id = try resolveCommit(rev)
            var oid = id.oid
            try check(git_revwalk_push(walk, &oid), "git_revwalk_push(\(rev))")
        }
        for rev in options.exclude {
            let id = try resolveCommit(rev)
            var oid = id.oid
            try check(git_revwalk_hide(walk, &oid), "git_revwalk_hide(\(rev))")
        }

        let authorFilter = options.author?.lowercased()
        var result: [CommitInfo] = []
        var skipped = 0
        var oid = git_oid()
        while git_revwalk_next(&oid, walk) == 0 {
            if let limit = options.limit, result.count >= limit { break }
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, handle, &oid) == 0, let commit else { continue }
            defer { git_commit_free(commit) }
            if let path = options.path, try !commitTouches(commit, path: path) { continue }
            let info = Self.info(of: commit)
            if let authorFilter,
               !info.author.name.lowercased().contains(authorFilter),
               !info.author.email.lowercased().contains(authorFilter) { continue }
            if skipped < options.skip { skipped += 1; continue }
            result.append(info)
        }
        return result
    }

    /// Whether `commit` changed `path` relative to every parent (Git's
    /// default history simplification for a path).
    private func commitTouches(_ commit: OpaquePointer, path: String) throws -> Bool {
        func entryID(_ c: OpaquePointer) -> ObjectID? {
            var tree: OpaquePointer?
            guard git_commit_tree(&tree, c) == 0 else { return nil }
            defer { git_tree_free(tree) }
            var entry: OpaquePointer?
            guard git_tree_entry_bypath(&entry, tree, path) == 0 else { return nil }
            defer { git_tree_entry_free(entry) }
            return ObjectID(git_tree_entry_id(entry))
        }
        let mine = entryID(commit)
        let count = git_commit_parentcount(commit)
        if count == 0 { return mine != nil }
        for i in 0..<count {
            var parent: OpaquePointer?
            guard git_commit_parent(&parent, commit, i) == 0, let parent else { continue }
            defer { git_commit_free(parent) }
            if entryID(parent) == mine { return false }
        }
        return true
    }

    /// Commits reachable from `upstream` but not `local` and vice versa.
    public func aheadBehind(local: ObjectID, upstream: ObjectID) throws -> (ahead: Int, behind: Int) {
        var ahead = 0, behind = 0
        var l = local.oid, u = upstream.oid
        try check(git_graph_ahead_behind(&ahead, &behind, handle, &l, &u), "git_graph_ahead_behind")
        return (ahead, behind)
    }

    /// Whether `ancestor` is reachable from `descendant`.
    public func isAncestor(_ ancestor: ObjectID, of descendant: ObjectID) throws -> Bool {
        var a = ancestor.oid, d = descendant.oid
        let rc = git_graph_descendant_of(handle, &d, &a)
        try check(rc, "git_graph_descendant_of")
        return rc == 1
    }

    public func mergeBase(_ a: ObjectID, _ b: ObjectID) throws -> ObjectID? {
        var out = git_oid(), x = a.oid, y = b.oid
        let rc = git_merge_base(&out, handle, &x, &y)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc, "git_merge_base")
        return ObjectID(out)
    }
}
