import Foundation

/// One file changed by an agent run, diffed against its checkpoint.
public struct FileChange: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case added, modified, deleted }

    public var id: String { path }
    public var path: String
    public var kind: Kind
    /// Text before the run (nil when added or not text).
    public var original: String?
    /// Text now (nil when deleted or not text).
    public var current: String?
    public var hunks: [LineDiff.Hunk]
    public var isBinary: Bool

    public var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }
}

/// The reviewable result of an agent run: every touched file with its hunks.
///
/// Review is non-destructive until applied: the working tree already holds
/// the agent's version; `apply` keeps accepted hunks and rewrites rejected
/// ones back to the checkpointed original.
public struct ChangeSet: Sendable, Hashable, Identifiable {
    public var id: String { checkpoint.id }
    public var checkpoint: Checkpoint
    public var files: [FileChange]

    public var isEmpty: Bool { files.isEmpty }
    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    public init(checkpoint: Checkpoint, files: [FileChange]) {
        self.checkpoint = checkpoint
        self.files = files
    }

    public static func build(checkpoint: Checkpoint, store: CheckpointStore,
                             fileSystem: WorkspaceFileSystem) -> ChangeSet {
        var files: [FileChange] = []
        for f in checkpoint.files {
            let url = fileSystem.root.appending(path: f.path)
            let before = store.originalData(checkpoint, path: f.path)
            let nowExists = fileSystem.exists(url) && !fileSystem.isDirectory(url)
            let after = nowExists ? (try? fileSystem.readData(url)) : nil
            if !f.existed && after == nil { continue }  // created then removed
            if before == after { continue }
            let kind: FileChange.Kind = !f.existed ? .added : (after == nil ? .deleted : .modified)
            let oldText = before.flatMap(Self.text)
            let newText = after.flatMap(Self.text)
            let binary = (before != nil && oldText == nil) || (after != nil && newText == nil)
            let hunks = binary ? [] : LineDiff.hunks(old: oldText ?? "", new: newText ?? "")
            files.append(FileChange(path: f.path, kind: kind, original: oldText, current: newText,
                                    hunks: hunks, isBinary: binary))
        }
        return ChangeSet(checkpoint: checkpoint, files: files.sorted { $0.path < $1.path })
    }

    static func text(_ data: Data) -> String? {
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Hunk decisions per file; a missing entry means accepted.
    public struct Decisions: Sendable, Hashable {
        public var rejected: [String: Set<Int>] = [:]
        public init() {}

        public func isAccepted(_ path: String, hunk: Int) -> Bool { !(rejected[path]?.contains(hunk) ?? false) }

        public mutating func set(_ path: String, hunk: Int, accepted: Bool) {
            if accepted { rejected[path]?.remove(hunk) } else { rejected[path, default: []].insert(hunk) }
        }

        public mutating func setAll(_ file: FileChange, accepted: Bool) {
            rejected[file.path] = accepted ? [] : Set(file.hunks.map(\.id))
        }
    }

    /// Writes the reviewed result into the workspace. Files whose hunks are
    /// all rejected are restored byte-for-byte from the checkpoint.
    public func apply(_ decisions: Decisions, store: CheckpointStore, fileSystem: WorkspaceFileSystem) throws {
        for file in files {
            let rejected = decisions.rejected[file.path] ?? []
            if rejected.isEmpty { continue }
            let allRejected = file.isBinary || rejected.isSuperset(of: file.hunks.map(\.id))
            if allRejected {
                try store.restore(checkpoint, paths: [file.path])
                continue
            }
            let merged = LineDiff.merge(old: file.original ?? "", new: file.current ?? "") {
                !rejected.contains($0)
            }
            try fileSystem.workspace.withSecurityScope {
                let url = fileSystem.root.appending(path: file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(merged.utf8).write(to: url, options: .atomic)
            }
        }
    }
}
