import Foundation

/// How tool calls travel between the agent and the model server.
public enum ToolProtocol: String, Sendable, Hashable, Codable, CaseIterable {
    /// OpenAI `tools` / `tool_calls`. LSE implements this natively: it renders
    /// declarations in Qwen's trained XML syntax and parses calls server-side.
    case native
    /// Tool declarations are written into the system prompt and calls are
    /// parsed from the reply text on the client (`TextToolProtocol`). For
    /// OpenAI-compatible servers without function calling.
    case text
}

/// Where and how the agent reaches its model.
public struct EndpointConfiguration: Sendable, Hashable, Codable {
    public var baseURL: URL
    public var model: String
    /// Sent as a bearer token when set. Remote keys belong in the Keychain;
    /// this struct only carries one for the duration of a request.
    public var apiKey: String?
    public var toolProtocol: ToolProtocol
    /// Must match the engine's KV length (`--kv-len`); LSE's default is 32768.
    public var contextWindow: Int
    /// The user's limit on one reply, reasoning included. Nil sets none: each
    /// request asks for what the context window has left (`OutputBudget`).
    public var maxOutputTokens: Int?
    public var requestTimeout: TimeInterval

    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8080/v1")!

    public init(baseURL: URL = EndpointConfiguration.defaultBaseURL, model: String = "qwen-q4",
                apiKey: String? = nil, toolProtocol: ToolProtocol = .native,
                contextWindow: Int = 32768, maxOutputTokens: Int? = nil,
                requestTimeout: TimeInterval = 900) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.toolProtocol = toolProtocol
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
    }

    public static let lseDefault = EndpointConfiguration()

    /// Loopback endpoints are the on-device engine (or a developer's Mac);
    /// anything else is labeled "remote" in the UI.
    public var isRemote: Bool {
        guard let host = baseURL.host() else { return true }
        return !(host == "127.0.0.1" || host == "localhost" || host == "::1")
    }
}

/// How many tokens one reply may generate: what the context window has left
/// after the prompt, or the user's limit when that is smaller. Reasoning
/// counts toward it like any other output; nothing caps it separately.
public struct OutputBudget: Sendable, Hashable {
    /// The `max_tokens` to request; zero or less when the context is full.
    public var maxTokens: Int
    /// Whether the context, not the user's limit, decided `maxTokens`: a reply
    /// that reaches it stopped because the context is full.
    public var boundByContext: Bool

    public init(contextWindow: Int, promptTokens: Int, limit: Int?) {
        let left = contextWindow - promptTokens
        if let limit, limit < left {
            maxTokens = limit
            boundByContext = false
        } else {
            maxTokens = left
            boundByContext = true
        }
    }

    public var contextIsFull: Bool { maxTokens <= 0 }
}
