import Foundation
import Testing
@testable import StudioAgent

@Suite("SSE parser")
struct SSEParserTests {
    /// A real LSE stream (captured from lse-server, trimmed timings).
    static let lseStream = """
    data: {"choices":[{"delta":{"role":"assistant"},"finish_reason":null,"index":0}],"created":1791001261,"id":"chatcmpl-1","model":"qwen-q4","object":"chat.completion.chunk"}

    data: {"choices":[{"delta":{"reasoning_content":"Need the file."},"finish_reason":null,"index":0}],"id":"chatcmpl-1","object":"chat.completion.chunk"}

    data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\\"path\\":\\"hello.txt\\"}","name":"read"},"id":"call_chatcmpl-1_0","index":0,"type":"function"}]},"finish_reason":null,"index":0}],"id":"chatcmpl-1","object":"chat.completion.chunk"}

    data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}],"id":"chatcmpl-1","object":"chat.completion.chunk","timings":{"acceptance_rate":0.9090909090909091,"decode_ms":506.88,"decode_n":23,"decode_per_second":45.375,"dflash2_depth":7,"generated_n":24,"mtp_depth":0,"prompt_cached_n":0,"prompt_ms":1259.7,"prompt_n":267,"prompt_per_second":211.955,"spec_method":"dflash2"}}

    data: {"choices":[],"id":"chatcmpl-1","object":"chat.completion.chunk","usage":{"completion_tokens":24,"prompt_tokens":267,"prompt_tokens_details":{"cached_tokens":0},"total_tokens":291}}

    data: [DONE]


    """

    func events(_ chunks: [[UInt8]]) -> [SSEEvent] {
        var p = SSEParser()
        var out: [SSEEvent] = []
        for c in chunks { out += p.feed(c) }
        return out + p.finish()
    }

    @Test func parsesEventsAtEveryTwoWaySplit() {
        let bytes = Array(Self.lseStream.utf8)
        let whole = events([bytes])
        #expect(whole.count == 6)
        #expect(whole.last?.data == "[DONE]")
        for split in stride(from: 0, through: bytes.count, by: 7) {
            #expect(events([Array(bytes[..<split]), Array(bytes[split...])]) == whole)
        }
    }

    @Test func parsesByteByByte() {
        let bytes = Array(Self.lseStream.utf8)
        #expect(events(bytes.map { [$0] }) == events([bytes]))
    }

    @Test func handlesCRLFAndCRAndCRLFSplitAcrossChunks() {
        let crlf = Array("data: a\r\n\r\ndata: b\r\r".utf8)
        #expect(events([crlf]).map(\.data) == ["a", "b"])
        // CR at the end of one chunk, LF at the start of the next: one line end, not two.
        let first = Array("data: x\r".utf8), second = Array("\ndata: y\r\n\r\n".utf8)
        #expect(events([first, second]).map(\.data) == ["x\ny"])
    }

    @Test func joinsMultiLineDataAndIgnoresComments() {
        let s = ": keep-alive\nevent: update\ndata: one\ndata:two\nid: 7\n\n"
        let e = events([Array(s.utf8)])
        #expect(e == [SSEEvent(event: "update", data: "one\ntwo", id: "7")])
    }

    @Test func decodesUTF8SplitInsideAMultiByteCharacter() {
        let s = "data: {\"choices\":[{\"delta\":{\"content\":\"héllo — 🍋\"},\"index\":0}]}\n\n"
        let bytes = Array(s.utf8)
        let lemon = bytes.firstIndex(of: 0xF0)!  // first byte of the emoji
        let e = events([Array(bytes[..<(lemon + 2)]), Array(bytes[(lemon + 2)...])])
        guard case .events(let evs) = try? ChatChunkDecoder.decode(e[0].data) else { Issue.record(); return }
        #expect(evs == [.contentDelta("héllo — 🍋")])
    }

    @Test func flushesFinalEventWithoutBlankLine() {
        #expect(events([Array("data: tail".utf8)]).map(\.data) == ["tail"])
    }

    @Test func decodesLSEStreamIntoACompletedTurn() throws {
        var acc = ChatCompletionAccumulator()
        var done = false
        for e in events([Array(Self.lseStream.utf8)]) {
            switch try ChatChunkDecoder.decode(e.data) {
            case .done: done = true
            case .events(let evs): evs.forEach { acc.apply($0) }
            }
        }
        #expect(done)
        #expect(acc.reasoning == "Need the file.")
        #expect(acc.content.isEmpty)
        #expect(acc.toolCalls == [ToolCall(id: "call_chatcmpl-1_0", name: "read", arguments: #"{"path":"hello.txt"}"#)])
        #expect(acc.finishReason == .toolCalls)
        #expect(acc.usage == TokenUsage(promptTokens: 267, completionTokens: 24, cachedPromptTokens: 0))
        let t = try #require(acc.timings)
        #expect(t.decodePerSecond == 45.375)
        #expect(t.acceptanceRate == 0.9090909090909091)
        #expect(t.speculationMethod == "dflash2")
        #expect(t.speculationDepth == 7)
    }

    @Test func accumulatesFragmentedToolCallArguments() {
        var acc = ChatCompletionAccumulator()
        acc.apply(.toolCallDelta(index: 0, id: "c1", name: "edit", arguments: "{\"pa"))
        acc.apply(.toolCallDelta(index: 0, id: nil, name: nil, arguments: "th\":\"a\"}"))
        acc.apply(.toolCallDelta(index: 1, id: "c2", name: "read", arguments: "{}"))
        #expect(acc.toolCalls.map(\.arguments) == [#"{"path":"a"}"#, "{}"])
        #expect(acc.toolCalls.map(\.name) == ["edit", "read"])
    }

    @Test func surfacesStreamErrorFrames() {
        #expect(throws: LLMError.stream(type: "model_output_error", message: "malformed function call")) {
            try ChatChunkDecoder.decode(#"{"error":{"message":"malformed function call","type":"model_output_error"}}"#)
        }
        #expect(LLMError.stream(type: "model_output_error", message: "").isModelOutputError)
    }

    @Test func requestBodyIsDeterministicAndLSECompatible() {
        let tools = [ToolDefinition(name: "read", description: "Read a file", parameters: ["type": "object", "properties": ["path": ["type": "string"]]]),
                     ToolDefinition(name: "edit", description: "Edit a file", parameters: ["type": "object"])]
        let r = ChatRequest(model: "qwen-q4", messages: [.system("s"), .user("u")], tools: tools,
                            maxTokens: 512, thinking: .low, sessionID: "abc")
        let a = r.body().serialized(), b = r.body().serialized()
        #expect(a == b)
        let body = r.body()
        #expect(body["stream"] == true)
        #expect(body["stream_options"]?["include_usage"] == true)
        #expect(body["reasoning_effort"] == "low")
        #expect(body["max_tokens"] == 512)
        // strict must never be sent: LSE answers 400 to strict:true.
        #expect(!a.contains("\"strict\""))
    }
}
