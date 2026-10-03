import Foundation

/// The first line of a pi v3 session file.
public struct SessionHeader: Sendable, Hashable {
    public static let currentVersion = 3
    public var id: String
    public var timestamp: String
    public var cwd: String
    public var version: Int
    public var parentSession: String?
    public var extra: [String: JSONValue] = [:]

    public init(id: String = SessionIDs.uuid(), timestamp: String = SessionTime.string(Date()), cwd: String,
                version: Int = SessionHeader.currentVersion, parentSession: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.cwd = cwd
        self.version = version
        self.parentSession = parentSession
    }

    init?(json: JSONValue) {
        guard var o = json.objectValue, o.removeValue(forKey: "type")?.stringValue == "session" else { return nil }
        id = o.removeValue(forKey: "id")?.stringValue ?? SessionIDs.uuid()
        timestamp = o.removeValue(forKey: "timestamp")?.stringValue ?? ""
        cwd = o.removeValue(forKey: "cwd")?.stringValue ?? ""
        version = o.removeValue(forKey: "version")?.intValue ?? 1
        parentSession = o.removeValue(forKey: "parentSession")?.stringValue
        extra = o
    }

    var json: JSONValue {
        var o = extra
        o["type"] = "session"
        o["version"] = .int(version)
        o["id"] = .string(id)
        o["timestamp"] = .string(timestamp)
        o["cwd"] = .string(cwd)
        if let parentSession { o["parentSession"] = .string(parentSession) }
        return .object(o)
    }
}

/// One tree entry of a pi v3 session (`SessionEntryBase` plus its payload).
public struct SessionEntry: Sendable, Hashable, Identifiable {
    public enum Payload: Sendable, Hashable {
        case message(AgentMessage)
        case modelChange(provider: String, modelId: String)
        case thinkingLevelChange(String)
        case compaction(summary: String, firstKeptEntryId: String, tokensBefore: Int,
                        systemMessage: AgentMessage?, details: JSONValue?)
        case branchSummary(fromId: String?, summary: String)
        case contextEdit(targetId: String, replacement: JSONValue?)
        case custom(customType: String, data: JSONValue?)
        case customMessage(customType: String, content: JSONValue, display: Bool)
        case label(targetId: String, label: String?)
        case sessionInfo(name: String?)
        case usage(kind: String, provider: String, model: String, usage: MessageUsage)
        /// An entry type this version does not know; kept verbatim.
        case unknown(type: String)

        var type: String {
            switch self {
            case .message: "message"
            case .modelChange: "model_change"
            case .thinkingLevelChange: "thinking_level_change"
            case .compaction: "compaction"
            case .branchSummary: "branch_summary"
            case .contextEdit: "context_edit"
            case .custom: "custom"
            case .customMessage: "custom_message"
            case .label: "label"
            case .sessionInfo: "session_info"
            case .usage: "usage"
            case .unknown(let t): t
            }
        }
    }

    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var payload: Payload
    /// Fields not modeled above, preserved for round trips.
    public var extra: [String: JSONValue] = [:]

    public init(id: String = SessionIDs.short(), parentId: String?, timestamp: String = SessionTime.string(Date()),
                payload: Payload) {
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.payload = payload
    }

    public var type: String { payload.type }

    public var message: AgentMessage? {
        if case .message(let m) = payload { return m }
        return nil
    }

    public init?(json: JSONValue) {
        guard var o = json.objectValue, let type = o.removeValue(forKey: "type")?.stringValue,
              type != "session" else { return nil }
        func take(_ k: String) -> JSONValue? { o.removeValue(forKey: k) }
        id = take("id")?.stringValue ?? SessionIDs.short()
        let parent = take("parentId")
        parentId = parent?.stringValue
        timestamp = take("timestamp")?.stringValue ?? ""
        switch type {
        case "message":
            payload = .message(AgentMessage(json: take("message") ?? [:]))
        case "model_change":
            payload = .modelChange(provider: take("provider")?.stringValue ?? "",
                                   modelId: take("modelId")?.stringValue ?? "")
        case "thinking_level_change":
            payload = .thinkingLevelChange(take("thinkingLevel")?.stringValue ?? "")
        case "compaction":
            payload = .compaction(summary: take("summary")?.stringValue ?? "",
                                  firstKeptEntryId: take("firstKeptEntryId")?.stringValue ?? "",
                                  tokensBefore: take("tokensBefore")?.intValue ?? 0,
                                  systemMessage: take("systemMessage").map(AgentMessage.init(json:)),
                                  details: take("details"))
        case "branch_summary":
            payload = .branchSummary(fromId: take("fromId")?.stringValue, summary: take("summary")?.stringValue ?? "")
        case "context_edit":
            let r = take("replacement")
            payload = .contextEdit(targetId: take("targetId")?.stringValue ?? "",
                                   replacement: (r?.isNull ?? true) ? nil : r)
        case "custom":
            payload = .custom(customType: take("customType")?.stringValue ?? "", data: take("data"))
        case "custom_message":
            payload = .customMessage(customType: take("customType")?.stringValue ?? "",
                                     content: take("content") ?? "", display: take("display")?.boolValue ?? true)
        case "label":
            payload = .label(targetId: take("targetId")?.stringValue ?? "", label: take("label")?.stringValue)
        case "session_info":
            payload = .sessionInfo(name: take("name")?.stringValue)
        case "usage":
            payload = .usage(kind: take("kind")?.stringValue ?? "", provider: take("provider")?.stringValue ?? "",
                             model: take("model")?.stringValue ?? "", usage: MessageUsage(json: take("usage")))
        default:
            payload = .unknown(type: type)
        }
        extra = o
    }

    public var json: JSONValue {
        var o = extra
        o["type"] = .string(type)
        o["id"] = .string(id)
        o["parentId"] = parentId.map(JSONValue.string) ?? .null
        o["timestamp"] = .string(timestamp)
        switch payload {
        case .message(let m): o["message"] = m.json
        case .modelChange(let p, let m): o["provider"] = .string(p); o["modelId"] = .string(m)
        case .thinkingLevelChange(let l): o["thinkingLevel"] = .string(l)
        case .compaction(let summary, let first, let before, let sys, let details):
            o["summary"] = .string(summary)
            o["firstKeptEntryId"] = .string(first)
            o["tokensBefore"] = .int(before)
            if let sys { o["systemMessage"] = sys.json }
            if let details { o["details"] = details }
        case .branchSummary(let fromId, let summary):
            o["fromId"] = fromId.map(JSONValue.string) ?? .null
            o["summary"] = .string(summary)
        case .contextEdit(let target, let replacement):
            o["targetId"] = .string(target)
            o["replacement"] = replacement ?? .null
        case .custom(let t, let data):
            o["customType"] = .string(t)
            if let data { o["data"] = data }
        case .customMessage(let t, let content, let display):
            o["customType"] = .string(t)
            o["content"] = content
            o["display"] = .bool(display)
        case .label(let target, let label):
            o["targetId"] = .string(target)
            if let label { o["label"] = .string(label) }
        case .sessionInfo(let name):
            if let name { o["name"] = .string(name) }
        case .usage(let kind, let provider, let model, let usage):
            o["kind"] = .string(kind)
            o["provider"] = .string(provider)
            o["model"] = .string(model)
            o["usage"] = usage.json
        case .unknown:
            break
        }
        return .object(o)
    }
}
