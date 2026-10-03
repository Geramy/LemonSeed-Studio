import Foundation
import Clibgit2

/// One line inside a file diff, addressed by hunk and line position.
public struct LineSelection: Sendable, Hashable, Codable {
    public var hunk: Int
    public var line: Int
    public init(hunk: Int, line: Int) {
        self.hunk = hunk
        self.line = line
    }
}

extension GitRepository {
    // MARK: Whole files

    /// Stages files (`git add`, and `git rm` for deleted files).
    public func stage(_ paths: [String]) throws {
        guard let workdir = workingDirectory else { throw GitError.invalid("bare repository", "stage") }
        let index = try openIndex()
        defer { git_index_free(index) }
        for path in paths {
            let exists = FileManager.default.fileExists(atPath: workdir.appending(path: path).path)
            if exists {
                try check(git_index_add_bypath(index, path), "git_index_add_bypath(\(path))")
            } else {
                let rc = git_index_remove_bypath(index, path)
                if rc != GIT_ENOTFOUND.rawValue { try check(rc, "git_index_remove_bypath(\(path))") }
            }
        }
        try check(git_index_write(index), "git_index_write")
    }

    /// Stages every change in the working tree (`git add -A`).
    ///
    /// Driven by status rather than `git_index_add_all`, which cannot stage
    /// submodule gitlinks.
    public func stageAll() throws {
        var options = StatusOptions()
        options.detectRenames = false
        let paths = try status(options).filter { $0.unstaged != nil && $0.unstaged != .ignored }.map(\.path)
        guard !paths.isEmpty else { return }
        try stage(paths)
    }

    /// Unstages files: their index entries go back to HEAD (`git reset -- paths`).
    public func unstage(_ paths: [String]) throws {
        var head: OpaquePointer?
        if git_repository_head_unborn(handle) != 1 {
            try check(git_revparse_single(&head, handle, "HEAD"), "git_revparse_single(HEAD)")
        }
        defer { git_object_free(head) }
        let spec = CStringArray(paths)
        defer { spec.free() }
        var array = spec.array
        try check(git_reset_default(handle, head, &array), "git_reset_default")
    }

    /// Throws away working-tree changes to `paths`; untracked files are deleted.
    public func discard(_ paths: [String]) throws {
        guard let workdir = workingDirectory else { throw GitError.invalid("bare repository", "discard") }
        let index = try openIndex()
        defer { git_index_free(index) }
        var tracked: [String] = []
        for path in paths {
            if git_index_get_bypath(index, path, 0) != nil {
                tracked.append(path)
            } else {
                try? FileManager.default.removeItem(at: workdir.appending(path: path))
            }
        }
        guard !tracked.isEmpty else { return }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
        let spec = CStringArray(tracked)
        defer { spec.free() }
        opts.paths = spec.array
        try check(git_checkout_index(handle, index, &opts), "git_checkout_index")
    }

    // MARK: Hunks and lines

    /// Stages whole hunks of the unstaged diff of `path`.
    public func stage(path: String, hunks: Set<Int>, contextLines: Int = 3) throws {
        try stage(path: path, selection: { h, _ in hunks.contains(h) }, contextLines: contextLines)
    }

    /// Stages individual added or removed lines of the unstaged diff of `path`.
    public func stage(path: String, lines: Set<LineSelection>, contextLines: Int = 3) throws {
        try stage(path: path, selection: { h, l in lines.contains(LineSelection(hunk: h, line: l)) }, contextLines: contextLines)
    }

    /// Unstages whole hunks of the staged diff of `path`.
    public func unstage(path: String, hunks: Set<Int>, contextLines: Int = 3) throws {
        try unstage(path: path, selection: { h, _ in hunks.contains(h) }, contextLines: contextLines)
    }

    /// Unstages individual lines of the staged diff of `path`.
    public func unstage(path: String, lines: Set<LineSelection>, contextLines: Int = 3) throws {
        try unstage(path: path, selection: { h, l in lines.contains(LineSelection(hunk: h, line: l)) }, contextLines: contextLines)
    }

    /// Reverts hunks of the unstaged diff in the working tree.
    public func discard(path: String, hunks: Set<Int>, contextLines: Int = 3) throws {
        try discard(path: path, selection: { h, _ in hunks.contains(h) }, contextLines: contextLines)
    }

    /// Reverts individual lines of the unstaged diff in the working tree.
    public func discard(path: String, lines: Set<LineSelection>, contextLines: Int = 3) throws {
        try discard(path: path, selection: { h, l in lines.contains(LineSelection(hunk: h, line: l)) }, contextLines: contextLines)
    }

    // The index blob is rewritten directly: the new index content is the old
    // index content with only the selected changes applied.
    private func stage(path: String, selection: (Int, Int) -> Bool, contextLines: Int) throws {
        guard let workdir = workingDirectory else { throw GitError.invalid("bare repository", "stage") }
        let raw = try rawHunks(path: path, target: .unstaged, contextLines: contextLines)
        guard let raw else { return }
        if raw.isBinary { throw GitError.invalid("binary files can only be staged as a whole", "stage") }
        let index = try openIndex()
        defer { git_index_free(index) }
        let existing = git_index_get_bypath(index, path, 0)
        let old = try existing.map { try blobData(ObjectID($0.pointee.id)) } ?? Data()
        let updated = Self.apply(raw.hunks, to: old, including: selection)
        var mode = existing?.pointee.mode ?? 0
        if mode == 0 {
            let attrs = try? FileManager.default.attributesOfItem(atPath: workdir.appending(path: path).path)
            let perms = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            mode = perms & 0o111 != 0 ? FileMode.blobExecutable.rawValue : FileMode.blob.rawValue
        }
        try writeIndexEntry(index, path: path, mode: mode, data: updated)
    }

    private func unstage(path: String, selection: (Int, Int) -> Bool, contextLines: Int) throws {
        let raw = try rawHunks(path: path, target: .staged, contextLines: contextLines)
        guard let raw else { return }
        if raw.isBinary { throw GitError.invalid("binary files can only be unstaged as a whole", "unstage") }
        let headData: Data
        let inHead: Bool
        do {
            headData = try fileContents(path, at: "HEAD")
            inHead = true
        } catch {
            headData = Data()
            inHead = false
        }
        // Keep every staged change except the selected ones.
        let updated = Self.apply(raw.hunks, to: headData, including: { !selection($0, $1) })
        let index = try openIndex()
        defer { git_index_free(index) }
        let mode = git_index_get_bypath(index, path, 0)?.pointee.mode ?? FileMode.blob.rawValue
        if !inHead && updated.isEmpty && raw.hunks.allSatisfy({ h in h.hunk.lines.allSatisfy { $0.kind != .addition || selection(h.hunk.id, $0.id) } }) {
            try check(git_index_remove_bypath(index, path), "git_index_remove_bypath")
            try check(git_index_write(index), "git_index_write")
            return
        }
        try writeIndexEntry(index, path: path, mode: mode, data: updated)
    }

    private func discard(path: String, selection: (Int, Int) -> Bool, contextLines: Int) throws {
        guard let workdir = workingDirectory else { throw GitError.invalid("bare repository", "discard") }
        let raw = try rawHunks(path: path, target: .unstaged, contextLines: contextLines)
        guard let raw else { return }
        if raw.isBinary { throw GitError.invalid("binary files can only be discarded as a whole", "discard") }
        let indexData = try indexContents(path) ?? Data()
        let updated = Self.apply(raw.hunks, to: indexData, including: { !selection($0, $1) })
        try updated.write(to: workdir.appending(path: path), options: .atomic)
    }

    private func writeIndexEntry(_ index: OpaquePointer, path: String, mode: UInt32, data: Data) throws {
        var entry = git_index_entry()
        entry.mode = mode
        try path.withCString { cPath in
            entry.path = cPath
            _ = try data.withUnsafeBytes { buffer in
                try check(git_index_add_from_buffer(index, &entry, buffer.baseAddress, buffer.count),
                          "git_index_add_from_buffer(\(path))")
            }
        }
        try check(git_index_write(index), "git_index_write")
    }

    struct RawFilePatch {
        var isBinary: Bool
        var hunks: [(hunk: DiffHunk, raw: [Data])]
    }

    func rawHunks(path: String, target: DiffTarget, contextLines: Int) throws -> RawFilePatch? {
        var options = DiffOptions()
        options.paths = [path]
        options.contextLines = contextLines
        options.detectRenames = false
        let diff = try makeDiff(target, options: options)
        defer { git_diff_free(diff) }
        guard git_diff_num_deltas(diff) > 0 else { return nil }
        var patch: OpaquePointer?
        try check(git_patch_from_diff(&patch, diff, 0), "git_patch_from_diff")
        defer { git_patch_free(patch) }
        guard let delta = git_diff_get_delta(diff, 0)?.pointee else { return nil }
        let binary = delta.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0
        guard let patch else { return RawFilePatch(isBinary: binary, hunks: []) }
        return RawFilePatch(isBinary: binary, hunks: try hunks(of: patch))
    }

    /// Applies the selected lines of `hunks` (a diff whose old side is `old`)
    /// and returns the resulting content. Unselected deletions are kept and
    /// unselected additions are dropped; context lines are always kept.
    static func apply(_ hunks: [(hunk: DiffHunk, raw: [Data])], to old: Data, including: (Int, Int) -> Bool) -> Data {
        let oldLines = splitLines(old)
        var out = Data()
        out.reserveCapacity(old.count + 256)
        var cursor = 0

        func append(_ line: Data) {
            if let last = out.last, last != UInt8(ascii: "\n") { out.append(UInt8(ascii: "\n")) }
            out.append(line)
        }

        for (hunk, raws) in hunks {
            let start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            while cursor < min(start, oldLines.count) {
                append(oldLines[cursor]); cursor += 1
            }
            for (line, raw) in zip(hunk.lines, raws) {
                switch line.kind {
                case .context:
                    if cursor < oldLines.count { append(oldLines[cursor]) }
                    cursor += 1
                case .deletion:
                    if !including(hunk.id, line.id), cursor < oldLines.count { append(oldLines[cursor]) }
                    cursor += 1
                case .addition:
                    if including(hunk.id, line.id) { append(raw) }
                }
            }
        }
        while cursor < oldLines.count {
            append(oldLines[cursor]); cursor += 1
        }
        return out
    }

    static func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        for i in data.indices where data[i] == UInt8(ascii: "\n") {
            lines.append(data[start...i])
            start = data.index(after: i)
        }
        if start < data.endIndex { lines.append(data[start..<data.endIndex]) }
        return lines.map { Data($0) }
    }
}
