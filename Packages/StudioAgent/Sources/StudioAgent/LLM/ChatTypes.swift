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

/// A thinking level: one of the levels the model's chat template defines
/// (`ModelThinking.levels`, sent as `reasoning_effort`), or the model's
/// default, which sends nothing. The level is part of the engine's cached
/// prompt prefix, so it should stay fixed within a session.
public struct ThinkingLevel: RawRepresentable, Sendable, Hashable, Codable {
    /// `"default"` or a level id.
    public let rawValue: String

    /// Earlier versions stored Studio's own names; "off" and "max" were
    /// LSE's `none` and `xhigh`. Other ids are kept as they are and checked
    /// against the model when a request is made.
    public init(rawValue: String) {
        switch rawValue {
        case "off": self.rawValue = "none"
        case "max": self.rawValue = "xhigh"
        default: self.rawValue = rawValue
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Sends no `reasoning_effort`: the model's own default level.
    public static let modelDefault = ThinkingLevel(rawValue: "default")
    /// Thinking off (the level id `none`), on a template with the switch.
    public static let off = ThinkingLevel(rawValue: "none")

    public static func level(_ id: String) -> ThinkingLevel { ThinkingLevel(rawValue: id) }

    public var isModelDefault: Bool { rawValue == "default" }

    /// The `reasoning_effort` value, or nil for the model's default.
    public var reasoningEffort: String? { isModelDefault ? nil : rawValue }

    /// A label from the id: none is Off, on is On, an "x" before a level
    /// name is Extra (xhigh is Extra high), anything else capitalized.
    public var title: String {
        switch rawValue {
        case "default": return "Default"
        case "none": return "Off"
        case "on": return "On"
        default:
            if rawValue.count > 1, rawValue.hasPrefix("x"), rawValue.dropFirst().allSatisfy(\.isLetter) {
                return "Extra " + rawValue.dropFirst()
            }
            return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// Sampling the user overrides; nil fields are left to the model's defaults.
public struct SamplingOverrides: Sendable, Hashable, Codable {
    public var temperature: Double?
    /// 0 or -1 turns top-k off.
    public var topK: Int?
    public var topP: Double?
    public var minP: Double?
    public var presencePenalty: Double?
    public var repetitionPenalty: Double?

    public init(temperature: Double? = nil, topK: Int? = nil, topP: Double? = nil, minP: Double? = nil,
                presencePenalty: Double? = nil, repetitionPenalty: Double? = nil) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.repetitionPenalty = repetitionPenalty
    }

    /// The request fields for what is set.
    public var fields: [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        if let temperature { o["temperature"] = .number(temperature) }
        if let topK { o["top_k"] = .int(topK) }
        if let topP { o["top_p"] = .number(topP) }
        if let minP { o["min_p"] = .number(minP) }
        if let presencePenalty { o["presence_penalty"] = .number(presencePenalty) }
        if let repetitionPenalty { o["repetition_penalty"] = .number(repetitionPenalty) }
        return o
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
    /// Nil sends no `max_tokens`: the reply runs until the model ends it or
    /// the context is full (or a limit the model's own files set).
    public var maxTokens: Int?
    /// Sampling: nil leaves each to the model's generation config (LSE's
    /// `generation_defaults`); only what the user overrides is sent.
    public var sampling: SamplingOverrides
    public var thinking: ThinkingLevel?
    public var stop: [String]
    /// Conversation identity for engines that keep one KV cache per
    /// conversation (requested from LSE as R1). Ignored by servers that do not
    /// know it.
    public var sessionID: String?

    public init(model: String, messages: [ChatMessage], tools: [ToolDefinition] = [],
                toolChoice: ToolChoice = .auto, parallelToolCalls: Bool = true,
                maxTokens: Int? = nil, sampling: SamplingOverrides = .init(),
                thinking: ThinkingLevel? = nil, stop: [String] = [], sessionID: String? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.maxTokens = maxTokens
        self.sampling = sampling
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
        ]
        if let maxTokens { o["max_tokens"] = .int(maxTokens) }
        if !tools.isEmpty {
            o["tools"] = .array(tools.map(\.json))
            o["tool_choice"] = toolChoice.json
            o["parallel_tool_calls"] = .bool(parallelToolCalls)
        }
        for (key, value) in sampling.fields { o[key] = value }
        if let effort = thinking?.reasoningEffort { o["reasoning_effort"] = .string(effort) }
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
    /// LSE's `stop_reason`: `stop_token`, `stop_sequence`, `max_tokens`,
    /// `context_full` or `cancelled`.
    case stopReason(String)
    /// LSE's `lse_context`, in the final chunk.
    case context(ContextUsage)
    case usage(TokenUsage)
    case timings(GenerationTimings)
}

/// Folds stream events into a finished assistant turn.
public struct ChatCompletionAccumulator: Sendable {
    public private(set) var content = ""
    public private(set) var reasoning = ""
    public private(set) var finishReason: FinishReason?
    public private(set) var stopReason: String?
    public private(set) var context: ContextUsage?
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
        case .stopReason(let r): stopReason = r
        case .context(let c): context = c
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
