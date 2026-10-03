import Foundation
import Clibgit2

public enum DiffLineKind: String, Sendable, Codable, Hashable {
    case context
    case addition
    case deletion
}

public struct DiffLine: Sendable, Hashable, Identifiable, Codable {
    /// Position of the line within its hunk.
    public var id: Int
    public var kind: DiffLineKind
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    /// The text without its line terminator.
    public var text: String
    /// False for the last line of a file that has no trailing newline.
    public var hasNewline: Bool

    public init(id: Int, kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String, hasNewline: Bool = true) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
        self.hasNewline = hasNewline
    }
}

public struct DiffHunk: Sendable, Hashable, Identifiable, Codable {
    /// Position of the hunk within its file.
    public var id: Int
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(id: Int, header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct FileDiff: Sendable, Hashable, Identifiable, Codable {
    public var oldPath: String?
    public var newPath: String?
    public var change: FileChange
    public var isBinary: Bool
    public var oldMode: UInt32
    public var newMode: UInt32
    public var oldID: ObjectID?
    public var newID: ObjectID?
    public var hunks: [DiffHunk]

    public var path: String { newPath ?? oldPath ?? "" }
    public var id: String { path }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .addition } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deletion } } }
}

/// What a diff compares.
public enum DiffTarget: Sendable, Hashable {
    /// Index -> working tree: the unstaged changes.
    case unstaged
    /// HEAD -> index: the staged changes.
    case staged
    /// HEAD -> working tree (staged and unstaged together).
    case workingTreeToHead
    /// A commit against its first parent (or the empty tree for a root commit).
    case commit(ObjectID)
    /// Any two commits (`from` -> `to`).
    case commits(from: ObjectID, to: ObjectID)
}

public struct DiffOptions: Sendable {
    public var paths: [String] = []
    public var contextLines: Int = 3
    public var ignoreWhitespace = false
    /// Show untracked files as additions in working-tree diffs.
    public var includeUntracked = true
    public var detectRenames = true
    /// Maximum blob size to diff as text; larger files are reported as binary.
    public var maxSize: Int = 4 * 1024 * 1024
    public init() {}
}

extension GitRepository {
    public func diff(_ target: DiffTarget, options: DiffOptions = DiffOptions()) throws -> [FileDiff] {
        let diff = try makeDiff(target, options: options)
        defer { git_diff_free(diff) }
        return try fileDiffs(diff)
    }

    /// The diff of one file, or nil when it is unchanged.
    public func diff(file path: String, _ target: DiffTarget, contextLines: Int = 3) throws -> FileDiff? {
        var options = DiffOptions()
        options.paths = [path]
        options.contextLines = contextLines
        options.detectRenames = false
        return try diff(target, options: options).first { $0.path == path || $0.oldPath == path }
    }

    /// Short statistics: files changed, insertions, deletions.
    public func diffStats(_ target: DiffTarget) throws -> (files: Int, insertions: Int, deletions: Int) {
        let diff = try makeDiff(target, options: DiffOptions())
        defer { git_diff_free(diff) }
        var stats: OpaquePointer?
        try check(git_diff_get_stats(&stats, diff), "git_diff_get_stats")
        defer { git_diff_stats_free(stats) }
        return (git_diff_stats_files_changed(stats), git_diff_stats_insertions(stats), git_diff_stats_deletions(stats))
    }

    /// The diff as unified patch text (`git diff` output).
    public func patchText(_ target: DiffTarget, options: DiffOptions = DiffOptions()) throws -> String {
        let diff = try makeDiff(target, options: options)
        defer { git_diff_free(diff) }
        var buf = git_buf()
        try check(git_diff_to_buf(&buf, diff, GIT_DIFF_FORMAT_PATCH), "git_diff_to_buf")
        return buf.takeString()
    }

    // MARK: Internals

    func makeDiff(_ target: DiffTarget, options: DiffOptions) throws -> OpaquePointer {
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        opts.context_lines = UInt32(options.contextLines)
        opts.max_size = git_off_t(options.maxSize)
        var flags = GIT_DIFF_NORMAL.rawValue
        if options.ignoreWhitespace { flags |= GIT_DIFF_IGNORE_WHITESPACE.rawValue }
        if !options.paths.isEmpty { flags |= GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue }
        switch target {
        case .unstaged, .workingTreeToHead:
            if options.includeUntracked {
                flags |= GIT_DIFF_INCLUDE_UNTRACKED.rawValue
                flags |= GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
                flags |= GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
            }
        default: break
        }
        opts.flags = flags

        var diff: OpaquePointer?
        let spec = CStringArray(options.paths)
        defer { spec.free() }
        if !spec.isEmpty { opts.pathspec = spec.array }
        switch target {
        case .unstaged:
            try check(git_diff_index_to_workdir(&diff, handle, nil, &opts), "git_diff_index_to_workdir")
        case .staged:
            let tree = try headTree()
            defer { git_tree_free(tree) }
            try check(git_diff_tree_to_index(&diff, handle, tree, nil, &opts), "git_diff_tree_to_index")
        case .workingTreeToHead:
            let tree = try headTree()
            defer { git_tree_free(tree) }
            try check(git_diff_tree_to_workdir_with_index(&diff, handle, tree, &opts), "git_diff_tree_to_workdir_with_index")
        case .commit(let id):
            let newTree = try tree(ofCommit: id)
            defer { git_tree_free(newTree) }
            let parent = try commitInfo(id).parents.first
            let oldTree = try parent.map { try tree(ofCommit: $0) }
            defer { git_tree_free(oldTree) }
            try check(git_diff_tree_to_tree(&diff, handle, oldTree, newTree, &opts), "git_diff_tree_to_tree")
        case .commits(let from, let to):
            let oldTree = try tree(ofCommit: from)
            defer { git_tree_free(oldTree) }
            let newTree = try tree(ofCommit: to)
            defer { git_tree_free(newTree) }
            try check(git_diff_tree_to_tree(&diff, handle, oldTree, newTree, &opts), "git_diff_tree_to_tree")
        }
        if options.detectRenames, let diff {
            var find = git_diff_find_options()
            git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
            find.flags = GIT_DIFF_FIND_RENAMES.rawValue
            if case .unstaged = target { find.flags |= GIT_DIFF_FIND_FOR_UNTRACKED.rawValue }
            try check(git_diff_find_similar(diff, &find), "git_diff_find_similar")
        }
        return diff!
    }

    /// HEAD's tree, or nil when HEAD is unborn.
    func headTree() throws -> OpaquePointer? {
        if git_repository_head_unborn(handle) == 1 { return nil }
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, handle, "HEAD^{tree}"), "git_revparse_single(HEAD^{tree})")
        return obj
    }

    func tree(ofCommit id: ObjectID) throws -> OpaquePointer {
        try withCommit(id) { commit in
            var tree: OpaquePointer?
            try check(git_commit_tree(&tree, commit), "git_commit_tree")
            return tree!
        }
    }

    func fileDiffs(_ diff: OpaquePointer) throws -> [FileDiff] {
        var files: [FileDiff] = []
        let count = git_diff_num_deltas(diff)
        files.reserveCapacity(count)
        for i in 0..<count {
            guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }
            var patch: OpaquePointer?
            try check(git_patch_from_diff(&patch, diff, i), "git_patch_from_diff")
            defer { git_patch_free(patch) }
            var file = FileDiff(
                oldPath: String(gitCString: delta.old_file.path),
                newPath: String(gitCString: delta.new_file.path),
                change: FileChange(delta.status),
                isBinary: delta.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0,
                oldMode: UInt32(delta.old_file.mode),
                newMode: UInt32(delta.new_file.mode),
                oldID: delta.old_file.id.isZero ? nil : ObjectID(delta.old_file.id),
                newID: delta.new_file.id.isZero ? nil : ObjectID(delta.new_file.id),
                hunks: [])
            if file.change == .added || file.change == .untracked { file.oldPath = nil }
            if file.change == .deleted { file.newPath = nil }
            if let patch {
                file.hunks = try hunks(of: patch).map(\.hunk)
            }
            files.append(file)
        }
        return files
    }

    /// Hunks with the raw bytes of each line, used for line-level staging.
    func hunks(of patch: OpaquePointer) throws -> [(hunk: DiffHunk, raw: [Data])] {
        var result: [(DiffHunk, [Data])] = []
        let hunkCount = git_patch_num_hunks(patch)
        for h in 0..<hunkCount {
            var hunkPtr: UnsafePointer<git_diff_hunk>?
            var lineCount = 0
            try check(git_patch_get_hunk(&hunkPtr, &lineCount, patch, h), "git_patch_get_hunk")
            guard let gh = hunkPtr?.pointee else { continue }
            var header = withUnsafeBytes(of: gh.header) { raw in
                String(decoding: raw.prefix(Int(gh.header_len)), as: UTF8.self)
            }
            while header.hasSuffix("\n") { header.removeLast() }
            var lines: [DiffLine] = []
            var raws: [Data] = []
            for l in 0..<lineCount {
                var linePtr: UnsafePointer<git_diff_line>?
                try check(git_patch_get_line_in_hunk(&linePtr, patch, h, l), "git_patch_get_line_in_hunk")
                guard let line = linePtr?.pointee else { continue }
                let origin = UInt8(bitPattern: line.origin)
                let data = line.content.map { Data(bytes: $0, count: line.content_len) } ?? Data()
                switch origin {
                case UInt8(ascii: " "), UInt8(ascii: "+"), UInt8(ascii: "-"):
                    let kind: DiffLineKind = origin == UInt8(ascii: "+") ? .addition : origin == UInt8(ascii: "-") ? .deletion : .context
                    var text = String(decoding: data, as: UTF8.self)
                    let hasNewline = text.hasSuffix("\n")
                    if hasNewline { text.removeLast() }
                    if text.hasSuffix("\r") { text.removeLast() }
                    lines.append(DiffLine(id: lines.count, kind: kind,
                                          oldLineNumber: line.old_lineno > 0 ? Int(line.old_lineno) : nil,
                                          newLineNumber: line.new_lineno > 0 ? Int(line.new_lineno) : nil,
                                          text: text, hasNewline: hasNewline))
                    raws.append(data)
                case UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "<"):
                    // "\ No newline at end of file": the previous line lacks one.
                    if !lines.isEmpty { lines[lines.count - 1].hasNewline = false }
                default:
                    break
                }
            }
            let hunk = DiffHunk(id: Int(h), header: header,
                                oldStart: Int(gh.old_start), oldCount: Int(gh.old_lines),
                                newStart: Int(gh.new_start), newCount: Int(gh.new_lines),
                                lines: lines)
            result.append((hunk, raws))
        }
        return result
    }
}

extension git_oid {
    var isZero: Bool {
        var copy = self
        return git_oid_is_zero(&copy) == 1
    }
}

extension FileChange {
    init(_ delta: git_delta_t) {
        switch delta {
        case GIT_DELTA_ADDED: self = .added
        case GIT_DELTA_DELETED: self = .deleted
        case GIT_DELTA_RENAMED, GIT_DELTA_COPIED: self = .renamed
        case GIT_DELTA_TYPECHANGE: self = .typeChanged
        case GIT_DELTA_UNTRACKED: self = .untracked
        case GIT_DELTA_IGNORED: self = .ignored
        case GIT_DELTA_CONFLICTED: self = .conflicted
        default: self = .modified
        }
    }
}
