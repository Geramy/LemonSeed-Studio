import Foundation
import Synchronization
import Testing
@testable import StudioAgent

/// The in-process seam: the same client over a closure transport, the shape
/// LSE's `lse_request(engine, method, path, json_body, cb, …)` binds to.
@Suite("Chat transports")
struct TransportTests {
    /// The chunk payloads of SSEParserTests.lseStream, without SSE framing.
    static var lseChunks: [Data] {
        var p = SSEParser()
        return (p.feed(Array(SSEParserTests.lseStream.utf8)) + p.finish()).map { Data($0.data.utf8) }
    }

    let request = ChatRequest(model: "qwen-q4", messages: [.user("read hello.txt")],
                              tools: [ToolDefinition(name: "read", description: "Read", parameters: ["type": "object"])],
                              maxTokens: 64, thinking: .off)

    @Test func closureTransportCarriesTheSameJSONBothWays() async throws {
        let seen = Mutex<(String, String, Data?)?>(nil)
        let transport = ClosureChatTransport { method, path, body, emit in
            seen.withLock { $0 = (method, path, body) }
            for c in Self.lseChunks.dropLast() { _ = emit(c) }  // engines may omit [DONE]
            return .init()
        }
        let client = OpenAICompatibleClient(configuration: .lseDefault, transport: transport)
        let acc = try await client.complete(request)
        #expect(acc.toolCalls == [ToolCall(id: "call_chatcmpl-1_0", name: "read", arguments: #"{"path":"hello.txt"}"#)])
        #expect(acc.finishReason == .toolCalls)
        #expect(acc.timings?.decodePerSecond == 45.375)
        #expect(acc.usage?.promptTokens == 267)
        let (method, path, body) = try #require(seen.withLock { $0 })
        #expect(method == "POST" && path == "chat/completions")
        #expect(body == client.encode(request))
        #expect(try JSONValue.parse(body!)["stream"] == true)
    }

    @Test func droppingTheStreamTellsTheEngineToStop() async throws {
        let stopped = Mutex(false)
        let transport = ClosureChatTransport { _, _, _, emit in
            let delta = Data(#"{"choices":[{"delta":{"content":"tok "},"index":0}]}"#.utf8)
            for _ in 0..<10_000 {
                if !emit(delta) { stopped.withLock { $0 = true }; break }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return .init()
        }
        let client = OpenAICompatibleClient(configuration: .lseDefault, transport: transport)
        var n = 0
        for try await _ in client.stream(request) {
            n += 1
            if n == 3 { break }
        }
        for _ in 0..<200 where !stopped.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stopped.withLock { $0 })
    }

    /// Reasoning and answer deltas reach the consumer while the engine is
    /// still generating: the in-process path never accumulates a response.
    @Test func reasoningAndAnswerStreamIncrementally() async throws {
        let produced = Mutex(0)
        let transport = ClosureChatTransport { _, _, _, emit in
            let think = Data(#"{"choices":[{"delta":{"reasoning_content":"hmm "},"index":0}]}"#.utf8)
            let say = Data(#"{"choices":[{"delta":{"content":"tok "},"index":0}]}"#.utf8)
            for i in 0..<200 {
                produced.withLock { $0 = i + 1 }
                if !emit(i < 100 ? think : say) { break }
                Thread.sleep(forTimeInterval: 0.002)
            }
            return .init()
        }
        let client = OpenAICompatibleClient(configuration: .lseDefault, transport: transport)
        var reasoning = 0, text = 0
        var producedAtFirstText: Int?
        for try await event in client.stream(request) {
            switch event {
            case .reasoningDelta: reasoning += 1
            case .contentDelta:
                text += 1
                if producedAtFirstText == nil { producedAtFirstText = produced.withLock { $0 } }
            default: break
            }
        }
        #expect(reasoning == 100 && text == 100)
        // The first answer token arrived long before the last one was made.
        #expect((producedAtFirstText ?? 200) < 150)
    }

    @Test func thinkingLevelsMapToReasoningEffort() throws {
        func effort(_ level: ThinkingLevel?) throws -> JSONValue? {
            var r = request
            r.thinking = level
            return try JSONValue.parse(OpenAICompatibleClient(configuration: .lseDefault, transport: ClosureChatTransport { _, _, _, _ in .init() })
                .encode(r))["reasoning_effort"]
        }
        #expect(try effort(.modelDefault) == nil)
        #expect(try effort(nil) == nil)
        #expect(try effort(.off) == "none")
        #expect(try effort(.low) == "low")
        #expect(try effort(.max) == "xhigh")
    }

    @Test func errorStatusesAndStreamErrorsSurface() async throws {
        let rejecting = ClosureChatTransport { _, _, _, _ in
            .init(status: 400, body: Data(#"{"error":{"message":"max_tokens 9000 exceeds this server's cap of 4096","type":"invalid_request_error"}}"#.utf8))
        }
        await #expect(throws: LLMError.http(status: 400, message: "max_tokens 9000 exceeds this server's cap of 4096")) {
            _ = try await OpenAICompatibleClient(configuration: .lseDefault, transport: rejecting).complete(request)
        }
        let failing = ClosureChatTransport { _, _, _, emit in
            _ = emit(Data(#"{"error":{"message":"malformed function call","type":"model_output_error"}}"#.utf8))
            return .init()
        }
        do {
            _ = try await OpenAICompatibleClient(configuration: .lseDefault, transport: failing).complete(request)
            Issue.record("expected an error")
        } catch let e as LLMError {
            #expect(e.isModelOutputError)
        }
    }

    @Test func plainRequestsUseTheSameSeam() async throws {
        let transport = ClosureChatTransport { method, path, _, _ in
            switch (method, path) {
            case ("GET", "models"): .init(body: Data(#"{"data":[{"id":"qwen-q4","object":"model"}],"object":"list"}"#.utf8))
            case ("GET", "/health"): .init(body: Data(#"{"status":"ok","dflash2_enabled":true,"dflash2_depth":7}"#.utf8))
            default: .init(status: 404, body: Data())
            }
        }
        let client = OpenAICompatibleClient(configuration: .lseDefault, transport: transport)
        #expect(try await client.models() == ["qwen-q4"])
        #expect(await client.health()?.speculation == "DFlash2 ×7")
    }

    @Test func textToolModeWorksOverAnyTransport() async throws {
        let sentTools = Mutex<JSONValue?>(nil)
        let transport = ClosureChatTransport { _, _, body, emit in
            sentTools.withLock { $0 = try? JSONValue.parse(body!)["tools"] }
            for piece in ["Reading.\n<tool_", "call>\n<function=read>\n<parameter=path>\nhello.txt\n</parameter>\n</function>\n</tool_call>"] {
                _ = emit(Data(JSONValue.object(["choices": [["delta": ["content": .string(piece)], "index": 0]]]).serializedData()))
            }
            _ = emit(Data(#"{"choices":[{"delta":{},"finish_reason":"stop","index":0}]}"#.utf8))
            return .init()
        }
        let config = EndpointConfiguration(toolProtocol: .text)
        let acc = try await OpenAICompatibleClient(configuration: config, transport: transport).complete(request)
        #expect(sentTools.withLock { $0 } == nil)  // declarations went into the prompt instead
        #expect(acc.content == "Reading.\n")
        #expect(acc.toolCalls.first?.parsedArguments == ["path": "hello.txt"])
        #expect(acc.finishReason == .toolCalls)
    }

    @Test func httpTransportResolvesV1AndRootPaths() {
        let t = HTTPChatTransport(baseURL: URL(string: "http://127.0.0.1:8080/v1")!)
        #expect(t.url("chat/completions").absoluteString == "http://127.0.0.1:8080/v1/chat/completions")
        #expect(t.url("/health").absoluteString == "http://127.0.0.1:8080/health")
    }
}
