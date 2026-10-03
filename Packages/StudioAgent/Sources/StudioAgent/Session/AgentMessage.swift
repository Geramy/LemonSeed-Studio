import Foundation

/// A content block inside a message (pi `TextContent`, `ThinkingContent`,
/// `ToolCall`, `ImageContent`). Unknown fields are preserved.
public enum ContentBlock: Sendable, Hashable {
    case text(String, extra: [String: JSONValue] = [:])
    case thinking(String, extra: [String: JSONValue] = [:])
    case toolCall(id: String, name: String, arguments: JSONValue, extra: [String: JSONValue] = [:])
    case image(data: String, mimeType: String)
    case unknown([String: JSONValue])

    init(json: JSONValue) {
        guard var o = json.objectValue, let type = o.removeValue(forKey: "type")?.stringValue else {
            self = .unknown(json.objectValue ?? [:]); return
        }
        switch type {
        case "text":
            let t = o.removeValue(forKey: "text")?.stringValue ?? ""
            self = .text(t, extra: o)
        case "thinking":
            let t = o.removeValue(forKey: "thinking")?.stringValue ?? ""
            self = .thinking(t, extra: o)
        case "toolCall":
            let id = o.removeValue(forKey: "id")?.stringValue ?? ""
            let name = o.removeValue(forKey: "name")?.stringValue ?? ""
            let args = o.removeValue(forKey: "arguments") ?? [:]
            self = .toolCall(id: id, name: name, arguments: args, extra: o)
        case "image":
            self = .image(data: o["data"]?.stringValue ?? "", mimeType: o["mimeType"]?.stringValue ?? "")
        default:
            var all = o
            all["type"] = .string(type)
            self = .unknown(all)
        }
    }

    var json: JSONValue {
        switch self {
        case .text(let t, let extra):
            return .object(extra.merging(["type": "text", "text": .string(t)]) { $1 })
        case .thinking(let t, let extra):
            return .object(extra.merging(["type": "thinking", "thinking": .string(t)]) { $1 })
        case .toolCall(let id, let name, let args, let extra):
            return .object(extra.merging(["type": "toolCall", "id": .string(id), "name": .string(name),
                                          "arguments": args]) { $1 })
        case .image(let data, let mime):
            return ["type": "image", "data": .string(data), "mimeType": .string(mime)]
        case .unknown(let o):
            return .object(o)
        }
    }
}

/// pi `Usage`. LSE costs nothing, so cost fields are zero.
public struct MessageUsage: Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// Other usage fields (cost, reasoning, cacheWrite1h), kept for round trips.
    public var extra: [String: JSONValue] = [:]

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public init(_ u: TokenUsage) {
        // pi's `input` excludes cache reads.
        self.init(input: u.promptTokens - u.cachedPromptTokens, output: u.completionTokens,
                  cacheRead: u.cachedPromptTokens)
    }

    public var totalTokens: Int { input + output + cacheRead + cacheWrite }

    var json: JSONValue {
        var o = extra
        o["input"] = .int(input)
        o["output"] = .int(output)
        o["cacheRead"] = .int(cacheRead)
        o["cacheWrite"] = .int(cacheWrite)
        o["totalTokens"] = .int(totalTokens)
        if o["cost"] == nil {
            o["cost"] = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]
        }
        return .object(o)
    }

    init(json: JSONValue?) {
        self.init(input: json?["input"]?.intValue ?? 0, output: json?["output"]?.intValue ?? 0,
                  cacheRead: json?["cacheRead"]?.intValue ?? 0, cacheWrite: json?["cacheWrite"]?.intValue ?? 0)
        var rest = json?.objectValue ?? [:]
        for k in ["input", "output", "cacheRead", "cacheWrite", "totalTokens"] { rest[k] = nil }
        extra = rest
    }
}

public enum StopReason: String, Sendable, Hashable, Codable {
    case stop, length, toolUse, error, aborted
}

/// A pi `AgentMessage`. Each case keeps the fields this agent uses typed and
/// carries every other field in `extra`, so files written by pi round-trip.
public enum AgentMessage: Sendable, Hashable {
    case system(SystemMessage)
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
    case custom(CustomMessage)
    case branchSummary(summary: String, fromId: String?, timestamp: Int)
    case compactionSummary(summary: String, tokensBefore: Int, timestamp: Int)
    case other([String: JSONValue])

    public struct SystemMessage: Sendable, Hashable {
        public var content: String
        public var sections: [String: String?]
        public var toolsAdded: [ToolDefinition]
        public var toolsRemoved: [String]
        public var replace: Bool
        public var timestamp: Int
        public var extra: [String: JSONValue] = [:]

        public init(content: String = "", sections: [String: String?] = [:], toolsAdded: [ToolDefinition] = [],
                    toolsRemoved: [String] = [], replace: Bool = false, timestamp: Int = SessionTime.millis()) {
            self.content = content
            self.sections = sections
            self.toolsAdded = toolsAdded
            self.toolsRemoved = toolsRemoved
            self.replace = replace
            self.timestamp = timestamp
        }
    }

    public struct UserMessage: Sendable, Hashable {
        /// pi allows a string or blocks; a string is written back as a string.
        public var content: [ContentBlock]
        public var contentIsString: Bool
        public var timestamp: Int
        public var extra: [String: JSONValue] = [:]

        public init(text: String, timestamp: Int = SessionTime.millis()) {
            content = [.text(text)]
            contentIsString = true
            self.timestamp = timestamp
        }

        public var text: String { content.textJoined }
    }

    public struct AssistantMessage: Sendable, Hashable {
        public var content: [ContentBlock]
        public var api: String
        public var provider: String
        public var model: String
        public var usage: MessageUsage
        public var stopReason: StopReason
        public var errorMessage: String?
        public var timestamp: Int
        public var extra: [String: JSONValue] = [:]

        public init(content: [ContentBlock], api: String = "openai-completions", provider: String = "lse",
                    model: String, usage: MessageUsage = .init(), stopReason: StopReason,
                    errorMessage: String? = nil, timestamp: Int = SessionTime.millis()) {
            self.content = content
            self.api = api
            self.provider = provider
            self.model = model
            self.usage = usage
            self.stopReason = stopReason
            self.errorMessage = errorMessage
            self.timestamp = timestamp
        }

        public var text: String { content.textJoined }
        public var thinking: String {
            content.compactMap { if case .thinking(let t, _) = $0 { t } else { nil } }.joined()
        }
        public var toolCalls: [ToolCall] {
            content.compactMap {
                if case .toolCall(let id, let name, let args, _) = $0 {
                    ToolCall(id: id, name: name, arguments: args.serialized())
                } else { nil }
            }
        }
    }

    public struct ToolResultMessage: Sendable, Hashable {
        public var toolCallId: String
        public var toolName: String
        public var content: [ContentBlock]
        public var details: JSONValue?
        public var isError: Bool
        public var timestamp: Int
        public var extra: [String: JSONValue] = [:]

        public init(toolCallId: String, toolName: String, text: String, details: JSONValue? = nil,
                    isError: Bool, timestamp: Int = SessionTime.millis()) {
            self.toolCallId = toolCallId
            self.toolName = toolName
            content = [.text(text)]
            self.details = details
            self.isError = isError
            self.timestamp = timestamp
        }

        public var text: String { content.textJoined }
    }

    public struct CustomMessage: Sendable, Hashable {
        public var customType: String
        public var content: [ContentBlock]
        public var display: Bool
        public var details: JSONValue?
        public var timestamp: Int
        public var extra: [String: JSONValue] = [:]
    }

    public var role: String {
        switch self {
        case .system: "system"
        case .user: "user"
        case .assistant: "assistant"
        case .toolResult: "toolResult"
        case .custom: "custom"
        case .branchSummary: "branchSummary"
        case .compactionSummary: "compactionSummary"
        case .other(let o): o["role"]?.stringValue ?? "unknown"
        }
    }
}

extension [ContentBlock] {
    var textJoined: String {
        compactMap { if case .text(let t, _) = $0 { t } else { nil } }.joined()
    }
}

// MARK: - JSON

extension AgentMessage {
    public init(json: JSONValue) {
        guard var o = json.objectValue, let role = o["role"]?.stringValue else {
            self = .other(json.objectValue ?? [:]); return
        }
        func take(_ k: String) -> JSONValue? { o.removeValue(forKey: k) }
        func blocks(_ v: JSONValue?) -> ([ContentBlock], Bool) {
            if let s = v?.stringValue { return ([.text(s)], true) }
            return ((v?.arrayValue ?? []).map(ContentBlock.init(json:)), false)
        }
        _ = take("role")
        let ts = take("timestamp")?.intValue ?? 0
        switch role {
        case "system":
            var m = SystemMessage(timestamp: ts)
            let c = take("content")
            m.content = c?.stringValue ?? (c?.arrayValue.map { $0.map(ContentBlock.init(json:)).textJoined } ?? "")
            m.sections = (take("sections")?.objectValue ?? [:]).mapValues { $0.stringValue }
            m.toolsAdded = (take("toolsAdded")?.arrayValue ?? []).map {
                ToolDefinition(name: $0["name"]?.stringValue ?? "", description: $0["description"]?.stringValue ?? "",
                               parameters: $0["parameters"] ?? [:])
            }
            m.toolsRemoved = (take("toolsRemoved")?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            m.replace = take("replace")?.boolValue ?? false
            m.extra = o
            self = .system(m)
        case "user":
            var m = UserMessage(text: "", timestamp: ts)
            (m.content, m.contentIsString) = blocks(take("content"))
            m.extra = o
            self = .user(m)
        case "assistant":
            var m = AssistantMessage(content: blocks(take("content")).0,
                                     api: take("api")?.stringValue ?? "",
                                     provider: take("provider")?.stringValue ?? "",
                                     model: take("model")?.stringValue ?? "",
                                     usage: MessageUsage(json: take("usage")),
                                     stopReason: StopReason(rawValue: take("stopReason")?.stringValue ?? "") ?? .stop,
                                     errorMessage: take("errorMessage")?.stringValue, timestamp: ts)
            m.extra = o
            self = .assistant(m)
        case "toolResult":
            var m = ToolResultMessage(toolCallId: take("toolCallId")?.stringValue ?? "",
                                      toolName: take("toolName")?.stringValue ?? "", text: "",
                                      details: take("details"), isError: take("isError")?.boolValue ?? false,
                                      timestamp: ts)
            m.content = blocks(take("content")).0
            m.extra = o
            self = .toolResult(m)
        case "custom":
            let m = CustomMessage(customType: take("customType")?.stringValue ?? "",
                                  content: blocks(take("content")).0,
                                  display: take("display")?.boolValue ?? true,
                                  details: take("details"), timestamp: ts, extra: o)
            self = .custom(m)
        case "branchSummary":
            self = .branchSummary(summary: o["summary"]?.stringValue ?? "", fromId: o["fromId"]?.stringValue,
                                  timestamp: ts)
        case "compactionSummary":
            self = .compactionSummary(summary: o["summary"]?.stringValue ?? "",
                                      tokensBefore: o["tokensBefore"]?.intValue ?? 0, timestamp: ts)
        default:
            var all = o
            all["role"] = .string(role)
            all["timestamp"] = .int(ts)
            self = .other(all)
        }
    }

    public var json: JSONValue {
        switch self {
        case .system(let m):
            var o = m.extra
            o["role"] = "system"
            o["content"] = .string(m.content)
            if !m.sections.isEmpty {
                o["sections"] = .object(m.sections.mapValues { $0.map(JSONValue.string) ?? .null })
            }
            if !m.toolsAdded.isEmpty {
                o["toolsAdded"] = .array(m.toolsAdded.map {
                    ["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters]
                })
            }
            if !m.toolsRemoved.isEmpty { o["toolsRemoved"] = .array(m.toolsRemoved.map { ["name": .string($0)] }) }
            if m.replace { o["replace"] = true }
            o["timestamp"] = .int(m.timestamp)
            return .object(o)
        case .user(let m):
            var o = m.extra
            o["role"] = "user"
            o["content"] = m.contentIsString && m.content.count == 1
                ? .string(m.content.textJoined) : .array(m.content.map(\.json))
            o["timestamp"] = .int(m.timestamp)
            return .object(o)
        case .assistant(let m):
            var o = m.extra
            o["role"] = "assistant"
            o["content"] = .array(m.content.map(\.json))
            o["api"] = .string(m.api)
            o["provider"] = .string(m.provider)
            o["model"] = .string(m.model)
            o["usage"] = m.usage.json
            o["stopReason"] = .string(m.stopReason.rawValue)
            if let e = m.errorMessage { o["errorMessage"] = .string(e) }
            o["timestamp"] = .int(m.timestamp)
            return .object(o)
        case .toolResult(let m):
            var o = m.extra
            o["role"] = "toolResult"
            o["toolCallId"] = .string(m.toolCallId)
            o["toolName"] = .string(m.toolName)
            o["content"] = .array(m.content.map(\.json))
            if let d = m.details { o["details"] = d }
            o["isError"] = .bool(m.isError)
            o["timestamp"] = .int(m.timestamp)
            return .object(o)
        case .custom(let m):
            var o = m.extra
            o["role"] = "custom"
            o["customType"] = .string(m.customType)
            o["content"] = .array(m.content.map(\.json))
            o["display"] = .bool(m.display)
            if let d = m.details { o["details"] = d }
            o["timestamp"] = .int(m.timestamp)
            return .object(o)
        case .branchSummary(let summary, let fromId, let ts):
            return ["role": "branchSummary", "summary": .string(summary),
                    "fromId": fromId.map(JSONValue.string) ?? .null, "timestamp": .int(ts)]
        case .compactionSummary(let summary, let tokensBefore, let ts):
            return ["role": "compactionSummary", "summary": .string(summary),
                    "tokensBefore": .int(tokensBefore), "timestamp": .int(ts)]
        case .other(let o):
            return .object(o)
        }
    }
}
