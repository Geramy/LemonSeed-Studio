import Foundation

/// One message on the chat.completions wire.
public struct ChatMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable { case system, user, assistant, tool }

    public var role: Role
    public var content: String?
    /// Reasoning text. LSE returns it in `reasoning_content` and renders it back
    /// into the prompt, so replaying it keeps the engine's cached prefix exact.
    public var reasoningContent: String?
    public var toolCalls: [ToolCall]
    public var toolCallID: String?

    public init(role: Role, content: String?, reasoningContent: String? = nil,
                toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, content: text) }
    public static func tool(id: String, _ text: String) -> ChatMessage {
        .init(role: .tool, content: text, toolCallID: id)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["role": .string(role.rawValue)]
        o["content"] = content.map(JSONValue.string) ?? .null
        if let reasoningContent, !reasoningContent.isEmpty {
            o["reasoning_content"] = .string(reasoningContent)
        }
        if !toolCalls.isEmpty { o["tool_calls"] = .array(toolCalls.map(\.json)) }
        if let toolCallID { o["tool_call_id"] = .string(toolCallID) }
        return .object(o)
    }
}

/// A complete function call. `arguments` holds the JSON text exactly as the
/// model produced it (or as it will be replayed).
public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Arguments parsed as a JSON object; a malformed payload yields nil.
    public var parsedArguments: JSONValue? {
        guard let v = try? JSONValue.parse(arguments), v.objectValue != nil else { return nil }
        return v
    }

    var json: JSONValue {
        ["id": .string(id), "type": "function",
         "function": ["name": .string(name), "arguments": .string(arguments)]]
    }
}

/// A function tool declaration (`strict` is never sent: LSE rejects it).
public struct ToolDefinition: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    var json: JSONValue {
        ["type": "function",
         "function": ["name": .string(name), "description": .string(description),
                      "parameters": parameters]]
    }
}

/// Reasoning control. LSE maps these onto Qwen's thinking switch and a
/// system-prompt instruction, so the level is part of the cached prefix and
/// should stay fixed within a session.
public enum ThinkingLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case off, minimal, low, medium, high

    var reasoningEffort: String {
        switch self {
        case .off: "none"
        case .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}

public enum ToolChoice: Sendable, Hashable {
    case auto, none, required
    case function(String)

    var json: JSONValue {
        switch self {
        case .auto: "auto"
        case .none: "none"
        case .required: "required"
        case .function(let name): ["type": "function", "function": ["name": .string(name)]]
        }
    }
}

public struct ChatRequest: Sendable, Hashable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]
    public var toolChoice: ToolChoice
    public var parallelToolCalls: Bool
    public var maxTokens: Int
    public var temperature: Double?
    public var thinking: ThinkingLevel?
    public var stop: [String]
    /// Conversation identity for engines that keep one KV cache per
    /// conversation (requested from LSE as R1). Ignored by servers that do not
    /// know it.
    public var sessionID: String?

    public init(model: String, messages: [ChatMessage], tools: [ToolDefinition] = [],
                toolChoice: ToolChoice = .auto, parallelToolCalls: Bool = true,
                maxTokens: Int = 2048, temperature: Double? = nil,
                thinking: ThinkingLevel? = nil, stop: [String] = [], sessionID: String? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.thinking = thinking
        self.stop = stop
        self.sessionID = sessionID
    }

    /// The request body. Always streams with usage.
    public func body() -> JSONValue {
        var o: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map(\.json)),
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": .int(maxTokens),
        ]
        if !tools.isEmpty {
            o["tools"] = .array(tools.map(\.json))
            o["tool_choice"] = toolChoice.json
            o["parallel_tool_calls"] = .bool(parallelToolCalls)
        }
        if let temperature { o["temperature"] = .number(temperature) }
        if let thinking { o["reasoning_effort"] = .string(thinking.reasoningEffort) }
        if !stop.isEmpty { o["stop"] = .array(stop.map(JSONValue.string)) }
        if let sessionID { o["session_id"] = .string(sessionID) }
        return .object(o)
    }
}

/// OpenAI usage, plus the cached-prompt count LSE reports.
public struct TokenUsage: Sendable, Hashable, Codable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var cachedPromptTokens: Int

    public init(promptTokens: Int = 0, completionTokens: Int = 0, cachedPromptTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedPromptTokens = cachedPromptTokens
    }

    public var totalTokens: Int { promptTokens + completionTokens }

    init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        promptTokens = json["prompt_tokens"]?.intValue ?? 0
        completionTokens = json["completion_tokens"]?.intValue ?? 0
        cachedPromptTokens = json["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
    }
}

/// LSE's per-request `timings` object (llama.cpp-compatible names plus
/// speculative-decoding statistics). Absent fields stay nil: unavailable is
/// shown as "n/a", never as zero.
public struct GenerationTimings: Sendable, Hashable, Codable {
    public var promptTokens: Int?
    public var promptCachedTokens: Int?
    public var promptMilliseconds: Double?
    public var promptPerSecond: Double?
    public var decodeTokens: Int?
    public var decodeMilliseconds: Double?
    public var decodePerSecond: Double?
    public var acceptanceRate: Double?
    public var speculationMethod: String?
    public var speculationDepth: Int?

    public init(promptTokens: Int? = nil, promptCachedTokens: Int? = nil,
                promptMilliseconds: Double? = nil, promptPerSecond: Double? = nil,
                decodeTokens: Int? = nil, decodeMilliseconds: Double? = nil,
                decodePerSecond: Double? = nil, acceptanceRate: Double? = nil,
                speculationMethod: String? = nil, speculationDepth: Int? = nil) {
        self.promptTokens = promptTokens
        self.promptCachedTokens = promptCachedTokens
        self.promptMilliseconds = promptMilliseconds
        self.promptPerSecond = promptPerSecond
        self.decodeTokens = decodeTokens
        self.decodeMilliseconds = decodeMilliseconds
        self.decodePerSecond = decodePerSecond
        self.acceptanceRate = acceptanceRate
        self.speculationMethod = speculationMethod
        self.speculationDepth = speculationDepth
    }

    init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        promptTokens = json["prompt_n"]?.intValue
        promptCachedTokens = json["prompt_cached_n"]?.intValue
        promptMilliseconds = json["prompt_ms"]?.doubleValue
        promptPerSecond = json["prompt_per_second"]?.doubleValue
        decodeTokens = (json["decode_n"] ?? json["predicted_n"])?.intValue
        decodeMilliseconds = (json["decode_ms"] ?? json["predicted_ms"])?.doubleValue
        decodePerSecond = (json["decode_per_second"] ?? json["predicted_per_second"])?.doubleValue
        acceptanceRate = json["acceptance_rate"]?.doubleValue
        speculationMethod = json["spec_method"]?.stringValue
        let dflash = json["dflash2_depth"]?.intValue ?? 0
        let mtp = json["mtp_depth"]?.intValue ?? 0
        speculationDepth = dflash != 0 ? dflash : (mtp != 0 ? mtp : nil)
    }
}

/// Why a completion ended, in OpenAI's vocabulary.
public enum FinishReason: String, Sendable, Hashable, Codable {
    case stop, length, toolCalls = "tool_calls", contentFilter = "content_filter"
}

/// Incremental output of a streaming completion.
public enum ChatStreamEvent: Sendable, Hashable {
    case contentDelta(String)
    case reasoningDelta(String)
    /// An indexed tool-call fragment. LSE sends each call whole; other servers
    /// stream `arguments` in pieces, which the accumulator concatenates.
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
    case finished(FinishReason)
    case usage(TokenUsage)
    case timings(GenerationTimings)
}

/// Folds stream events into a finished assistant turn.
public struct ChatCompletionAccumulator: Sendable {
    public private(set) var content = ""
    public private(set) var reasoning = ""
    public private(set) var finishReason: FinishReason?
    public private(set) var usage: TokenUsage?
    public private(set) var timings: GenerationTimings?
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]

    public init() {}

    public mutating func apply(_ event: ChatStreamEvent) {
        switch event {
        case .contentDelta(let s): content += s
        case .reasoningDelta(let s): reasoning += s
        case .toolCallDelta(let index, let id, let name, let arguments):
            var call = calls[index] ?? (id: "", name: "", arguments: "")
            if let id, !id.isEmpty { call.id = id }
            if let name, !name.isEmpty, call.name.isEmpty { call.name = name }
            if let arguments { call.arguments += arguments }
            calls[index] = call
        case .finished(let r): finishReason = r
        case .usage(let u): usage = u
        case .timings(let t): timings = t
        }
    }

    public var toolCalls: [ToolCall] {
        calls.keys.sorted().map { i in
            let c = calls[i]!
            return ToolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name,
                            arguments: c.arguments.isEmpty ? "{}" : c.arguments)
        }
    }
}
