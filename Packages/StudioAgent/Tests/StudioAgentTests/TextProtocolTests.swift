import Foundation
import Testing
@testable import StudioAgent

@Suite("Text tool protocol")
struct TextProtocolTests {
    let tools = [ToolDefinition(name: "read", description: "Read a file", parameters: ["type": "object", "properties": ["path": ["type": "string"], "offset": ["type": "integer"]]]),
                 ToolDefinition(name: "code", description: "", parameters:
                    ["type": "object", "properties": ["value": ["type": "string"], "n": ["type": "integer"]]])]

    func run(_ chunks: [String]) -> [ChatStreamEvent] {
        var x = TextToolCallExtractor(tools: tools)
        var out: [ChatStreamEvent] = []
        for c in chunks { out += x.process(.contentDelta(c)) }
        out += x.process(.finished(.stop))
        return out
    }

    func fold(_ events: [ChatStreamEvent]) -> ChatCompletionAccumulator {
        var acc = ChatCompletionAccumulator()
        events.forEach { acc.apply($0) }
        return acc
    }

    static let reply = "<think>\nplan it\n</think>\n\nLet me look.\n\n<tool_call>\n<function=read>\n<parameter=path>\nsrc/a.c\n</parameter>\n<parameter=offset>\n10\n</parameter>\n</function>\n</tool_call>"

    @Test func extractsReasoningTextAndCallsAtEverySplit() {
        let whole = fold(run([Self.reply]))
        #expect(whole.reasoning == "\nplan it\n")
        #expect(whole.content == "Let me look.\n\n")
        #expect(whole.toolCalls.count == 1)
        #expect(whole.toolCalls[0].name == "read")
        #expect(whole.toolCalls[0].parsedArguments == ["path": "src/a.c", "offset": 10])
        #expect(whole.finishReason == .toolCalls)
        let chars = Array(Self.reply)
        for split in 1..<chars.count {
            let acc = fold(run([String(chars[..<split]), String(chars[split...])]))
            #expect(acc.content == whole.content, "split \(split)")
            #expect(acc.reasoning == whole.reasoning, "split \(split)")
            #expect(acc.toolCalls.map(\.arguments) == whole.toolCalls.map(\.arguments), "split \(split)")
        }
    }

    @Test func schemaStringParametersStayStrings() throws {
        let call = try TextToolProtocol.parseCall("<function=code>\n<parameter=value>\n007\n</parameter>\n<parameter=n>\n7\n</parameter>\n</function>", tools: tools)
        #expect(call.arguments["value"] == "007")
        #expect(call.arguments["n"] == 7)
    }

    @Test func acceptsJSONCallBodies() throws {
        let acc = fold(run([#"<tool_call>{"name": "read", "arguments": {"path": "x"}}</tool_call>"#]))
        #expect(acc.toolCalls.first?.parsedArguments == ["path": "x"])
    }

    @Test func truncatedCallsBecomeTextNotExecution() {
        var x = TextToolCallExtractor(tools: tools)
        var out = x.process(.contentDelta("Sure. <tool_call>\n<function=read>\n<parameter=pa"))
        out += x.process(.finished(.length))
        let acc = fold(out)
        #expect(acc.toolCalls.isEmpty)
        #expect(acc.content.contains("<tool_call>"))
        #expect(acc.finishReason == .length)
    }

    @Test func rewriteMovesToolsIntoPromptAndResultsIntoUserTurns() {
        let call = ToolCall(id: "c1", name: "read", arguments: #"{"path":"a"}"#)
        let req = ChatRequest(model: "m", messages: [
            .system("SYS"), .user("go"),
            ChatMessage(role: .assistant, content: "Reading.", reasoningContent: "r", toolCalls: [call]),
            .tool(id: "c1", "DATA"),
        ], tools: tools)
        let r = TextToolProtocol.rewrite(req)
        #expect(r.tools.isEmpty)
        #expect(r.messages.count == 4)
        #expect(r.messages[0].content?.hasPrefix("# Tools") == true)
        #expect(r.messages[0].content?.hasSuffix("SYS") == true)
        #expect(r.messages[2].content == "Reading.\n\n<tool_call>\n<function=read>\n<parameter=path>\na\n</parameter>\n</function>\n</tool_call>")
        #expect(r.messages[2].toolCalls.isEmpty)
        #expect(r.messages[3] == .user("<tool_response>\nDATA\n</tool_response>"))
    }
}
