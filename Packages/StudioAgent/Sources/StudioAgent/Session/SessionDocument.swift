import Foundation

/// An in-memory pi v3 session: a header and a tree of entries with a leaf.
///
/// Context construction follows pi's `buildSessionContext`: walk root → leaf,
/// honor the latest compaction (its summary replaces everything before
/// `firstKeptEntryId`), apply the latest `context_edit` per target, and turn
/// summaries and custom messages into model-visible messages.
public struct SessionDocument: Sendable, Hashable {
    public var header: SessionHeader
    public private(set) var entries: [SessionEntry] = []
    public private(set) var leafId: String?
    private var index: [String: Int] = [:]

    public init(header: SessionHeader) {
        self.header = header
    }

    // MARK: Tree

    public func entry(_ id: String) -> SessionEntry? { index[id].map { entries[$0] } }

    /// Appends a child of the current leaf and makes it the leaf.
    @discardableResult
    public mutating func append(_ payload: SessionEntry.Payload, id: String? = nil,
                                timestamp: Date = Date()) -> SessionEntry {
        let e = SessionEntry(id: id ?? newEntryID(), parentId: leafId, timestamp: SessionTime.string(timestamp),
                             payload: payload)
        insert(e)
        return e
    }

    /// A fresh entry id, unique in this session.
    public func newEntryID() -> String {
        var id = SessionIDs.short()
        while index[id] != nil { id = SessionIDs.short() }
        return id
    }

    /// Adds an entry exactly as given (loading, or replaying a file).
    public mutating func insert(_ e: SessionEntry) {
        index[e.id] = entries.count
        entries.append(e)
        leafId = e.id
    }

    /// Moves the leaf. The next append branches from `id` (nil: a new root).
    public mutating func moveLeaf(to id: String?) {
        precondition(id == nil || index[id!] != nil, "unknown entry")
        leafId = id
    }

    public func children(of id: String?) -> [SessionEntry] {
        entries.filter { $0.parentId == id }
    }

    /// Entries from the root to `leaf` (default: the current leaf).
    public func path(to leaf: String? = nil) -> [SessionEntry] {
        var out: [SessionEntry] = []
        var cursor = leaf ?? leafId
        var seen = Set<String>()
        while let id = cursor, let e = entry(id), seen.insert(id).inserted {
            out.append(e)
            cursor = e.parentId
        }
        return out.reversed()
    }

    // MARK: Metadata

    /// The latest `session_info` name.
    public var name: String? {
        for e in entries.reversed() { if case .sessionInfo(let n) = e.payload { return n } }
        return nil
    }

    public var firstUserText: String? {
        for e in entries { if case .message(.user(let m)) = e.payload { return m.text } }
        return nil
    }

    public var thinkingLevel: String? {
        for e in path().reversed() { if case .thinkingLevelChange(let l) = e.payload { return l } }
        return nil
    }

    // MARK: Context

    /// The model-visible messages for the current leaf, in order.
    public func contextMessages() -> [AgentMessage] {
        contextEntries().map(\.message)
    }

    /// Context messages paired with the entry each came from.
    public func contextEntries() -> [(entryId: String, message: AgentMessage)] {
        let path = path()
        var selected: [SessionEntry] = path
        if let c = path.lastIndex(where: { if case .compaction = $0.payload { true } else { false } }),
           case .compaction(_, let firstKept, _, _, _) = path[c].payload {
            var kept: [SessionEntry] = []
            if firstKept != path[c].id, let start = path.firstIndex(where: { $0.id == firstKept }), start < c {
                kept = path[start..<c].filter {
                    if case .message(.system) = $0.payload { false } else { true }
                }
            }
            selected = [path[c]] + kept + path[(c + 1)...]
        }

        var edits: [String: JSONValue?] = [:]
        for e in path { if case .contextEdit(let target, let replacement) = e.payload { edits[target] = replacement } }

        var out: [(String, AgentMessage)] = []
        for e in selected {
            switch e.payload {
            case .message(var m):
                if let edit = edits[e.id] {
                    guard let replacement = edit else { continue }
                    m = m.replacingContent(replacement)
                }
                out.append((e.id, m))
            case .compaction(let summary, _, let before, let sys, _):
                if let sys { out.append((e.id, sys)) }
                out.append((e.id, .compactionSummary(summary: summary, tokensBefore: before,
                                                     timestamp: SessionTime.millis(SessionTime.date(e.timestamp) ?? Date()))))
            case .branchSummary(let fromId, let summary):
                out.append((e.id, .branchSummary(summary: summary, fromId: fromId,
                                                 timestamp: SessionTime.millis(SessionTime.date(e.timestamp) ?? Date()))))
            case .customMessage(let type, let content, let display):
                if let edit = edits[e.id], edit == nil { continue }
                let blocks: [ContentBlock] = content.stringValue.map { [.text($0)] }
                    ?? (content.arrayValue ?? []).map(ContentBlock.init(json:))
                out.append((e.id, .custom(.init(customType: type, content: blocks, display: display, details: nil,
                                                timestamp: SessionTime.millis(SessionTime.date(e.timestamp) ?? Date())))))
            default:
                continue
            }
        }
        return out
    }

    /// The system prompt and tools declared by the context's system messages.
    public func systemState() -> SystemPromptState {
        var state = SystemPromptState()
        for m in contextMessages() { if case .system(let s) = m { state.apply(s) } }
        return state
    }

    // MARK: JSONL

    public init(jsonl: String) throws {
        var header: SessionHeader?
        var entries: [SessionEntry] = []
        for (n, raw) in jsonl.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let json: JSONValue
            do { json = try JSONValue.parse(line) } catch { throw SessionError.malformedLine(n + 1) }
            if header == nil, let h = SessionHeader(json: json) { header = h; continue }
            if let e = SessionEntry(json: json) { entries.append(e) }
        }
        guard var header else { throw SessionError.missingHeader }
        // v1 files are a linear list without ids; link them in order.
        if header.version < 2 {
            var prev: String?
            entries = entries.map { var e = $0; e.parentId = prev; prev = e.id; return e }
        }
        header.version = SessionHeader.currentVersion
        self.init(header: header)
        for e in entries { insert(e) }
    }

    public func jsonl() -> String {
        ([header.json] + entries.map(\.json)).map { $0.serialized() }.joined(separator: "\n") + "\n"
    }
}

public enum SessionError: Error, Hashable, Sendable {
    case missingHeader
    case malformedLine(Int)
}

/// The prompt and tool loadout obtained by replaying system messages.
public struct SystemPromptState: Sendable, Hashable {
    public private(set) var sections: [(name: String, text: String)] = []
    public private(set) var appended: [String] = []
    public private(set) var tools: [ToolDefinition] = []

    public static func == (a: Self, b: Self) -> Bool {
        a.prompt == b.prompt && a.tools == b.tools
    }

    public func hash(into h: inout Hasher) {
        h.combine(prompt)
        h.combine(tools)
    }

    /// Where new sections go: known names in this order, then the rest by name.
    public static let sectionOrder = ["preamble", "tools", "workspace", "context"]

    static func order(_ name: String) -> Int { sectionOrder.firstIndex(of: name) ?? sectionOrder.count }

    public mutating func apply(_ m: AgentMessage.SystemMessage) {
        if m.replace { sections = []; appended = []; tools = [] }
        let keys = m.sections.keys.sorted {
            (Self.order($0), $0) < (Self.order($1), $1)
        }
        for key in keys {
            let value = m.sections[key]!
            if let i = sections.firstIndex(where: { $0.name == key }) {
                if let value { sections[i].text = value } else { sections.remove(at: i) }
            } else if let value {
                sections.append((key, value))
            }
        }
        if !m.content.isEmpty { appended.append(m.content) }
        tools.removeAll { m.toolsRemoved.contains($0.name) }
        for t in m.toolsAdded {
            if let i = tools.firstIndex(where: { $0.name == t.name }) { tools[i] = t } else { tools.append(t) }
        }
    }

    /// The rendered system prompt. Stable for a given state.
    public var prompt: String {
        (sections.map(\.text) + appended).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

extension AgentMessage {
    /// pi `context_edit`: replaces only the content; strings become one text block.
    func replacingContent(_ replacement: JSONValue) -> AgentMessage {
        let blocks: [ContentBlock] = replacement.stringValue.map { [.text($0)] }
            ?? (replacement.arrayValue ?? []).map(ContentBlock.init(json:))
        switch self {
        case .user(var m): m.content = blocks; m.contentIsString = replacement.stringValue != nil; return .user(m)
        case .assistant(var m): m.content = blocks; return .assistant(m)
        case .toolResult(var m): m.content = blocks; return .toolResult(m)
        case .custom(var m): m.content = blocks; return .custom(m)
        default: return self
        }
    }
}
