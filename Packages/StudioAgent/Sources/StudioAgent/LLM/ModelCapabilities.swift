import Foundation

/// What a served model defines, as LSE reports it in each `/v1/models` entry
/// (docs/API.md): its context, its thinking levels from the chat template and
/// its sampling defaults from its generation config. Other servers leave the
/// LSE fields out; then nothing is known and nothing is restricted.
public struct ModelCapabilities: Sendable, Hashable {
    public var id: String
    /// The context the engine enforces (`context_length`).
    public var contextLength: Int?
    /// An operator's cap on one reply (`max_tokens`), nil for none.
    public var maxTokens: Int?
    public var thinking: ModelThinking?
    public var generationDefaults: GenerationDefaults?

    public init(id: String, contextLength: Int? = nil, maxTokens: Int? = nil, thinking: ModelThinking? = nil,
                generationDefaults: GenerationDefaults? = nil) {
        self.id = id
        self.contextLength = contextLength
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.generationDefaults = generationDefaults
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.init(id: id, contextLength: json["context_length"]?.intValue, maxTokens: json["max_tokens"]?.intValue,
                  thinking: json["thinking"].flatMap(ModelThinking.init(json:)),
                  generationDefaults: json["generation_defaults"].flatMap(GenerationDefaults.init(json:)))
    }
}

/// The thinking levels a model's chat template defines (LSE's `thinking`).
public struct ModelThinking: Sendable, Hashable {
    public struct Level: Sendable, Hashable, Identifiable {
        /// What a request sends as `reasoning_effort`.
        public var id: String
        public var isDefault: Bool
        /// Whether the level thinks (the template's switch), nil without one.
        public var enableThinking: Bool?
        /// The template's instruction for the level, nil when it adds none.
        public var instruction: String?

        public init(id: String, isDefault: Bool = false, enableThinking: Bool? = nil, instruction: String? = nil) {
            self.id = id
            self.isDefault = isDefault
            self.enableThinking = enableThinking
            self.instruction = instruction
        }

        public var title: String { ThinkingLevel(rawValue: id).title }
    }

    /// The template defines at least one level.
    public var supported: Bool
    public var defaultLevel: String?
    /// In the template's order.
    public var levels: [Level]

    public init(supported: Bool, defaultLevel: String?, levels: [Level]) {
        self.supported = supported
        self.defaultLevel = defaultLevel
        self.levels = levels
    }

    public init?(json: JSONValue) {
        guard case .object = json else { return nil }
        let levels = (json["levels"]?.arrayValue ?? []).compactMap { l -> Level? in
            guard let id = l["id"]?.stringValue else { return nil }
            return Level(id: id, isDefault: l["default"]?.boolValue ?? false,
                         enableThinking: l["enable_thinking"]?.boolValue, instruction: l["instruction"]?.stringValue)
        }
        self.init(supported: json["supported"]?.boolValue ?? !levels.isEmpty,
                  defaultLevel: json["default_level"]?.stringValue, levels: levels)
    }

    public func defines(_ id: String) -> Bool { levels.contains { $0.id == id } }
}

/// The model's sampling defaults (LSE's `generation_defaults`), each with the
/// file it came from.
public struct GenerationDefaults: Sendable, Hashable {
    public var temperature: Double?
    public var topK: Int?
    public var topP: Double?
    public var minP: Double?
    public var repetitionPenalty: Double?
    public var presencePenalty: Double?
    /// Output limits the model's files declare, nil for none.
    public var maxNewTokens: Int?
    public var maxLength: Int?
    /// Field name (LSE's spelling) to `generation_config.json`, `config.json`,
    /// `server_option` or `lse_default`.
    public var sources: [String: String]

    public init(temperature: Double? = nil, topK: Int? = nil, topP: Double? = nil, minP: Double? = nil,
                repetitionPenalty: Double? = nil, presencePenalty: Double? = nil, maxNewTokens: Int? = nil,
                maxLength: Int? = nil, sources: [String: String] = [:]) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
        self.maxNewTokens = maxNewTokens
        self.maxLength = maxLength
        self.sources = sources
    }

    public init?(json: JSONValue) {
        guard case .object = json else { return nil }
        var sources: [String: String] = [:]
        if case .object(let o)? = json["sources"] {
            for (k, v) in o { if let s = v.stringValue { sources[k] = s } }
        }
        self.init(temperature: json["temperature"]?.doubleValue, topK: json["top_k"]?.intValue,
                  topP: json["top_p"]?.doubleValue, minP: json["min_p"]?.doubleValue,
                  repetitionPenalty: json["repetition_penalty"]?.doubleValue,
                  presencePenalty: json["presence_penalty"]?.doubleValue,
                  maxNewTokens: json["max_new_tokens"]?.intValue, maxLength: json["max_length"]?.intValue,
                  sources: sources)
    }
}

/// How full the context is (LSE's `lse_context`).
public struct ContextUsage: Sendable, Hashable, Codable {
    public var tokensUsed: Int
    public var contextLength: Int
    public var tokensRemaining: Int

    public init(tokensUsed: Int, contextLength: Int, tokensRemaining: Int) {
        self.tokensUsed = tokensUsed
        self.contextLength = contextLength
        self.tokensRemaining = tokensRemaining
    }

    public init?(json: JSONValue) {
        guard let used = json["tokens_used"]?.intValue, let length = json["context_length"]?.intValue else { return nil }
        self.init(tokensUsed: used, contextLength: length,
                  tokensRemaining: json["tokens_remaining"]?.intValue ?? max(0, length - used))
    }
}
