import Foundation

/// A session file's listing row.
public struct SessionSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var url: URL
    public var name: String?
    public var firstMessage: String?
    public var created: Date?
    public var modified: Date
    public var messageCount: Int
    /// The model the session last used (its latest model_change).
    public var model: String?
    /// The session's thinking level (its latest thinking_level_change).
    public var thinking: String?
    public var pinned = false

    public var title: String {
        if let name, !name.isEmpty { return name }
        if let firstMessage, !firstMessage.isEmpty { return String(firstMessage.prefix(80)) }
        return "Untitled session"
    }
}

/// pi v3 JSONL session files in `<state>/sessions/`.
///
/// Files are named `<timestamp>_<session-id>.jsonl` like pi's, so a session
/// started on iPad opens in pi on a Mac. Entries are appended one line at a
/// time; nothing is ever rewritten in place.
public struct SessionStore: Sendable {
    public let directory: URL
    private let workspace: any AgentWorkspace

    public init(workspace: any AgentWorkspace, directory: URL? = nil) {
        self.workspace = workspace
        self.directory = directory ?? workspace.stateDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    }

    public func create(cwd: String) throws -> (url: URL, document: SessionDocument) {
        let header = SessionHeader(cwd: cwd)
        let stamp = header.timestamp.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
        let url = directory.appending(path: "\(stamp)_\(header.id).jsonl")
        let doc = SessionDocument(header: header)
        try workspace.withSecurityScope {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((header.json.serialized() + "\n").utf8).write(to: url, options: .atomic)
        }
        return (url, doc)
    }

    public func append(_ entries: [SessionEntry], to url: URL) throws {
        guard !entries.isEmpty else { return }
        let text = entries.map { $0.json.serialized() + "\n" }.joined()
        try workspace.withSecurityScope {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(text.utf8))
        }
    }

    public func load(_ url: URL) throws -> SessionDocument {
        let text = try workspace.withSecurityScope { try String(contentsOf: url, encoding: .utf8) }
        return try SessionDocument(jsonl: text)
    }

    public func list() -> [SessionSummary] {
        workspace.withSecurityScope {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            else { return [] }
            return names.filter { $0.pathExtension == "jsonl" }.compactMap { url -> SessionSummary? in
                guard let doc = try? load(url) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let count = doc.entries.filter {
                    if case .message(let m) = $0.payload { m.role == "user" || m.role == "assistant" } else { false }
                }.count
                var model: String?
                for e in doc.entries { if case .modelChange(_, let id) = e.payload { model = id } }
                return SessionSummary(id: doc.header.id, url: url, name: doc.name, firstMessage: doc.firstUserText,
                                      created: SessionTime.date(doc.header.timestamp),
                                      modified: modified ?? .distantPast, messageCount: count,
                                      model: model, thinking: doc.thinkingLevel, pinned: pins.contains(doc.header.id))
            }.sorted { $0.modified > $1.modified }
        }
    }

    // MARK: Names and pins

    /// Renames a session by appending a session_info entry (pi's way).
    public func rename(_ url: URL, to name: String) throws {
        var doc = try load(url)
        let entry = doc.append(.sessionInfo(name: name))
        try append([entry], to: url)
    }

    /// Pinned session ids, kept beside the sessions (`pinned.json`) so the
    /// JSONL files stay pi's format.
    public var pins: Set<String> {
        workspace.withSecurityScope {
            guard let data = try? Data(contentsOf: directory.appending(path: "pinned.json")),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(ids)
        }
    }

    public func setPinned(_ pinned: Bool, id: String) throws {
        var ids = pins
        if pinned { ids.insert(id) } else { ids.remove(id) }
        let data = try JSONEncoder().encode(ids.sorted())
        try workspace.withSecurityScope {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: "pinned.json"), options: .atomic)
        }
    }

    public func delete(_ url: URL) throws {
        if let id = try? load(url).header.id, pins.contains(id) { try? setPinned(false, id: id) }
        try workspace.withSecurityScope { try FileManager.default.removeItem(at: url) }
    }
}
