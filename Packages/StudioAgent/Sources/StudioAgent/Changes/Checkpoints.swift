import Foundation
import Synchronization

/// One file captured by a checkpoint.
public struct CheckpointFile: Codable, Sendable, Hashable {
    /// Workspace-relative path.
    public var path: String
    /// False when the file did not exist before the turn (rewind deletes it).
    public var existed: Bool
}

/// The original state of every file an agent run touched, taken just before
/// the first modification of each file.
public struct Checkpoint: Codable, Sendable, Hashable, Identifiable {
    public enum Storage: String, Codable, Sendable { case clone, memory }
    public var id: String
    public var createdAt: Date
    public var storage: Storage
    public var files: [CheckpointFile]

    /// Recorded in the session as a pi `custom` entry of this type.
    public static let sessionCustomType = "lemonseed.checkpoint"

    public var sessionData: JSONValue {
        ["id": .string(id), "storage": .string(storage.rawValue),
         "createdAt": .string(SessionTime.string(createdAt)),
         "files": .array(files.map { ["path": .string($0.path), "existed": .bool($0.existed)] })]
    }

    public init?(sessionData d: JSONValue) {
        guard let id = d["id"]?.stringValue else { return nil }
        self.id = id
        storage = Storage(rawValue: d["storage"]?.stringValue ?? "") ?? .clone
        createdAt = d["createdAt"]?.stringValue.flatMap(SessionTime.date) ?? .distantPast
        files = (d["files"]?.arrayValue ?? []).compactMap {
            guard let p = $0["path"]?.stringValue else { return nil }
            return CheckpointFile(path: p, existed: $0["existed"]?.boolValue ?? true)
        }
    }

    public init(id: String, createdAt: Date, storage: Storage, files: [CheckpointFile]) {
        self.id = id
        self.createdAt = createdAt
        self.storage = storage
        self.files = files
    }
}

/// Copy-on-write snapshots of files before the agent changes them.
///
/// With `.clone` storage each original is `clonefile(2)`d into
/// `<state>/checkpoints/<id>/files/`: on APFS that is a metadata-only copy,
/// so checkpointing a large file costs almost nothing until either copy
/// changes. Volumes without clone support fall back to a regular copy.
/// `.memory` keeps originals in RAM (tests, read-only state directories).
public final class CheckpointStore: FileMutationObserver, Sendable {
    public let directory: URL
    public let storage: Checkpoint.Storage
    private let workspace: any AgentWorkspace

    private struct State {
        var active: Checkpoint?
        var captured: Set<String> = []
        var memory: [String: [String: Data]] = [:]  // checkpoint id -> path -> original
        var known: [String: Checkpoint] = [:]
    }
    private let state = Mutex(State())

    public init(workspace: any AgentWorkspace, storage: Checkpoint.Storage = .clone, directory: URL? = nil) {
        self.workspace = workspace
        self.storage = storage
        self.directory = directory ?? workspace.stateDirectory.appending(path: "checkpoints", directoryHint: .isDirectory)
    }

    /// Starts capturing. Modifications before `end()` are snapshotted once each.
    @discardableResult
    public func begin(id: String = SessionIDs.short() + SessionIDs.short()) -> String {
        state.withLock {
            $0.active = Checkpoint(id: id, createdAt: Date(), storage: storage, files: [])
            $0.captured = []
        }
        return id
    }

    /// Stops capturing; returns the checkpoint if anything was captured.
    public func end() -> Checkpoint? {
        let cp: Checkpoint? = state.withLock { s in
            let active = s.active
            s.active = nil
            s.captured = []
            guard let cp = active, !cp.files.isEmpty else { return nil }
            s.known[cp.id] = cp
            return cp
        }
        if let cp, storage == .clone { try? writeManifest(cp) }
        return cp
    }

    public var activeCheckpoint: Checkpoint? { state.withLock { $0.active } }

    public func willModify(_ url: URL, relativePath: String) {
        let shouldCapture: String? = state.withLock {
            guard let cp = $0.active, !$0.captured.contains(relativePath) else { return nil }
            $0.captured.insert(relativePath)
            return cp.id
        }
        guard let id = shouldCapture else { return }
        let existed = workspace.withSecurityScope { FileManager.default.fileExists(atPath: url.path) }
        if existed {
            switch storage {
            case .clone:
                let dest = snapshotURL(id: id, path: relativePath)
                workspace.withSecurityScope {
                    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    if clonefile(url.path, dest.path, 0) != 0 {
                        try? FileManager.default.copyItem(at: url, to: dest)
                    }
                }
            case .memory:
                let data = workspace.withSecurityScope { try? Data(contentsOf: url) }
                state.withLock { $0.memory[id, default: [:]][relativePath] = data ?? Data() }
            }
        }
        state.withLock { $0.active?.files.append(CheckpointFile(path: relativePath, existed: existed)) }
    }

    /// Registers a checkpoint read back from a session.
    public func register(_ checkpoint: Checkpoint) {
        state.withLock { $0.known[checkpoint.id] = checkpoint }
    }

    public func checkpoint(id: String) -> Checkpoint? {
        if let cp = state.withLock({ $0.known[id] }) { return cp }
        let url = directory.appending(path: id).appending(path: "manifest.json")
        guard let data = workspace.withSecurityScope({ try? Data(contentsOf: url) }),
              let cp = try? JSONDecoder.checkpoint.decode(Checkpoint.self, from: data) else { return nil }
        state.withLock { $0.known[id] = cp }
        return cp
    }

    /// The original bytes of `path`, or nil if it did not exist before.
    public func originalData(_ checkpoint: Checkpoint, path: String) -> Data? {
        guard let f = checkpoint.files.first(where: { $0.path == path }), f.existed else { return nil }
        switch checkpoint.storage {
        case .memory:
            return state.withLock { $0.memory[checkpoint.id]?[path] }
        case .clone:
            let url = snapshotURL(id: checkpoint.id, path: path)
            return workspace.withSecurityScope { try? Data(contentsOf: url) }
        }
    }

    /// Puts files back as they were (all of them, or just `paths`).
    public func restore(_ checkpoint: Checkpoint, paths: Set<String>? = nil) throws {
        for f in checkpoint.files where paths?.contains(f.path) ?? true {
            let target = workspace.rootURL.appending(path: f.path)
            try workspace.withSecurityScope {
                let fm = FileManager.default
                if !f.existed {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    return
                }
                guard let data = originalData(checkpoint, path: f.path) else {
                    throw WorkspaceError.io("Checkpoint \(checkpoint.id) has no copy of \(f.path)")
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
        }
    }

    /// Deletes a checkpoint's stored copies.
    public func discard(_ checkpoint: Checkpoint) {
        state.withLock {
            $0.known[checkpoint.id] = nil
            $0.memory[checkpoint.id] = nil
        }
        if checkpoint.storage == .clone {
            let dir = directory.appending(path: checkpoint.id)
            workspace.withSecurityScope { _ = try? FileManager.default.removeItem(at: dir) }
        }
    }

    private func snapshotURL(id: String, path: String) -> URL {
        directory.appending(path: id).appending(path: "files").appending(path: path)
    }

    private func writeManifest(_ cp: Checkpoint) throws {
        let url = directory.appending(path: cp.id).appending(path: "manifest.json")
        let data = try JSONEncoder.checkpoint.encode(cp)
        try workspace.withSecurityScope {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}

extension JSONEncoder {
    static var checkpoint: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }
}

extension JSONDecoder {
    static var checkpoint: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
