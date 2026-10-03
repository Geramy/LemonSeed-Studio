import Foundation

/// A streaming chat model. The agent loop talks only to this protocol, so the
/// same loop runs over HTTP, the in-process engine, or a scripted client in
/// tests and previews.
public protocol LLMClient: Sendable {
    /// Streams one completion. Cancelling the consuming task (or dropping the
    /// stream) cancels the request and stops generation.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

extension LLMClient {
    /// Runs a completion to the end and returns the folded result.
    public func complete(_ request: ChatRequest) async throws -> ChatCompletionAccumulator {
        var acc = ChatCompletionAccumulator()
        for try await event in stream(request) { acc.apply(event) }
        return acc
    }
}

/// What `/health` reports. LSE adds its speculative-decoding configuration.
public struct EngineHealth: Sendable, Hashable {
    public var ok: Bool
    public var speculation: String?

    init(json: JSONValue) {
        ok = json["status"]?.stringValue == "ok"
        if json["dflash2_enabled"]?.boolValue == true {
            speculation = "DFlash2 ×\(json["dflash2_depth"]?.intValue ?? 0)"
        } else if json["mtp_enabled"]?.boolValue == true {
            speculation = "MTP ×\(json["mtp_depth"]?.intValue ?? 0)"
        }
    }
}

/// The OpenAI chat.completions protocol over any `ChatTransport`.
///
/// This type owns the protocol: it encodes `ChatRequest`s, decodes
/// `chat.completion.chunk` objects into `ChatStreamEvent`s and, in text tool
/// mode, extracts tool calls from reply text. The transport only moves the
/// JSON, so HTTP and the in-process engine share every line of it.
public struct OpenAICompatibleClient: LLMClient {
    public let configuration: EndpointConfiguration
    public let transport: any ChatTransport

    /// HTTP to `configuration.baseURL`.
    public init(configuration: EndpointConfiguration = .lseDefault, session: URLSession? = nil) {
        self.init(configuration: configuration,
                  transport: HTTPChatTransport(baseURL: configuration.baseURL, apiKey: configuration.apiKey,
                                               timeout: configuration.requestTimeout, session: session))
    }

    /// Any transport, e.g. a `ClosureChatTransport` over `lse_request`.
    public init(configuration: EndpointConfiguration, transport: any ChatTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    /// The request body as sent (after the text-protocol rewrite, if any).
    public func encode(_ request: ChatRequest) -> Data {
        let wire = usesTextTools(request) ? TextToolProtocol.rewrite(request) : request
        return wire.body().serializedData()
    }

    func usesTextTools(_ request: ChatRequest) -> Bool {
        configuration.toolProtocol == .text && !request.tools.isEmpty
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let chunks = transport.stream(method: "POST", path: "chat/completions", body: encode(request))
        let textMode = usesTextTools(request)
        let tools = request.tools
        return AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = ChatStreamDecoder(textTools: textMode ? tools : nil)
                do {
                    for try await chunk in chunks {
                        let (events, done) = try decoder.decode(chunk)
                        for e in events { continuation.yield(e) }
                        if done { break }
                    }
                    for e in decoder.finish() { continuation.yield(e) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `GET /health`; nil when the engine cannot be reached.
    public func health(timeout: TimeInterval = 3) async -> EngineHealth? {
        guard let data = try? await transport.request(method: "GET", path: "/health", body: nil, timeout: timeout),
              let json = try? JSONValue.parse(data) else { return nil }
        return EngineHealth(json: json)
    }

    /// `GET /v1/models`: the served model identifiers.
    public func models(timeout: TimeInterval = 5) async throws -> [String] {
        let data = try await transport.request(method: "GET", path: "models", body: nil, timeout: timeout)
        let json = try JSONValue.parse(data)
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }
}

/// Decodes a sequence of chunk payloads into stream events. Shared by every
/// transport; stateful only for text-mode tool extraction.
public struct ChatStreamDecoder: Sendable {
    private var extractor: TextToolCallExtractor?

    public init(textTools: [ToolDefinition]? = nil) {
        extractor = textTools.map(TextToolCallExtractor.init(tools:))
    }

    /// Decodes one chunk. `done` is true at the `[DONE]` sentinel.
    public mutating func decode(_ chunk: Data) throws -> (events: [ChatStreamEvent], done: Bool) {
        let text = String(decoding: chunk, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ([], false) }
        switch try ChatChunkDecoder.decode(text) {
        case .done:
            return (finish(), true)
        case .events(let evs):
            guard extractor != nil else { return (evs, false) }
            return (evs.flatMap { extractor!.process($0) }, false)
        }
    }

    public mutating func finish() -> [ChatStreamEvent] {
        guard extractor != nil else { return [] }
        return extractor!.finish()
    }
}
