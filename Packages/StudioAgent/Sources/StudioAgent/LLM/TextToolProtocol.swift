import Foundation

/// Tool calling over plain text, for OpenAI-compatible servers without
/// function calling.
///
/// The format is the one Qwen3.x models are trained on and the one LSE itself
/// renders server-side, so a model behaves the same in either mode:
///
///     <tool_call>
///     <function=read>
///     <parameter=path>
///     src/main.c
///     </parameter>
///     </function>
///     </tool_call>
///
/// A JSON body (`<tool_call>{"name": "read", "arguments": {...}}</tool_call>`)
/// is accepted too. Results go back as a user message of `<tool_response>`
/// blocks in call order. Parameter values are JSON-decoded unless the tool's
/// schema declares the parameter a string, so "007" stays a string.
public enum TextToolProtocol {
    static let callOpen = "<tool_call>"
    static let callClose = "</tool_call>"

    /// The instructions appended to the system prompt in text mode.
    public static func instructions(for tools: [ToolDefinition]) -> String {
        var s = "# Tools\n\nYou have access to the following functions:\n\n<tools>"
        for t in tools { s += "\n" + t.json.serialized() }
        s += """

        </tools>

        If you choose to call a function ONLY reply in the following format with NO suffix:

        <tool_call>
        <function=example_function_name>
        <parameter=example_parameter_1>
        value_1
        </parameter>
        <parameter=example_parameter_2>
        This is the value for the second parameter
        that can span
        multiple lines
        </parameter>
        </function>
        </tool_call>

        <IMPORTANT>
        Reminder:
        - Function calls MUST follow the specified format: an inner <function=...></function> block must be nested within <tool_call></tool_call> XML tags
        - Required parameters MUST be specified
        - You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after
        - If there is no function call available, answer the question like normal with your current knowledge and do not tell the user about function calls
        </IMPORTANT>
        """
        return s
    }

    /// Renders one call the way the model would have written it.
    public static func render(_ call: ToolCall) -> String {
        var s = "<tool_call>\n<function=\(call.name)>\n"
        let args = call.parsedArguments?.objectValue ?? [:]
        for key in args.keys.sorted() {
            let v = args[key]!
            s += "<parameter=\(key)>\n\(v.stringValue ?? v.serialized())\n</parameter>\n"
        }
        return s + "</function>\n</tool_call>"
    }

    /// Moves tools into the system prompt and calls/results into text.
    public static func rewrite(_ request: ChatRequest) -> ChatRequest {
        var out = request
        let toolText = instructions(for: request.tools)
        var messages: [ChatMessage] = []
        var pendingResults: [String] = []

        func flushResults() {
            guard !pendingResults.isEmpty else { return }
            messages.append(.user(pendingResults.map { "<tool_response>\n\($0)\n</tool_response>" }
                .joined(separator: "\n")))
            pendingResults.removeAll()
        }

        for m in request.messages {
            switch m.role {
            case .tool:
                pendingResults.append(m.content ?? "")
            case .assistant where !m.toolCalls.isEmpty:
                flushResults()
                var text = m.content ?? ""
                for call in m.toolCalls {
                    if !text.isEmpty && !text.hasSuffix("\n\n") { text += "\n\n" }
                    text += render(call)
                }
                messages.append(ChatMessage(role: .assistant, content: text,
                                            reasoningContent: m.reasoningContent))
            default:
                flushResults()
                messages.append(m)
            }
        }
        flushResults()

        if let i = messages.firstIndex(where: { $0.role == .system }), i == 0 {
            messages[0].content = toolText + "\n\n" + (messages[0].content ?? "")
        } else {
            messages.insert(.system(toolText), at: 0)
        }
        out.messages = messages
        out.tools = []
        out.toolChoice = .auto
        return out
    }

    /// Parses the inside of one `<tool_call>` block.
    public static func parseCall(_ raw: String, tools: [ToolDefinition]) throws -> (name: String, arguments: JSONValue) {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("{") {
            let json = try JSONValue.parse(body)
            guard let name = json["name"]?.stringValue else { throw TextToolError.malformed("missing name") }
            var args = json["arguments"] ?? json["parameters"] ?? [:]
            if let s = args.stringValue { args = try JSONValue.parse(s) }
            guard args.objectValue != nil else { throw TextToolError.malformed("arguments must be an object") }
            return (name, args)
        }
        guard body.hasPrefix("<function="), let close = body.firstIndex(of: ">") else {
            throw TextToolError.malformed("expected <function=…>")
        }
        let name = String(body[body.index(body.startIndex, offsetBy: 10)..<close])
        guard let end = body.range(of: "</function>", options: .backwards) else {
            throw TextToolError.malformed("missing </function>")
        }
        var tail = body[body.index(after: close)..<end.lowerBound]
        let schema = tools.first { $0.name == name }?.parameters
        var args: [String: JSONValue] = [:]
        while true {
            tail = tail.drop(while: { $0.isWhitespace })
            if tail.isEmpty { break }
            guard tail.hasPrefix("<parameter="), let keyEnd = tail.firstIndex(of: ">"),
                  let valueEnd = tail.range(of: "</parameter>") else {
                throw TextToolError.malformed("malformed <parameter>")
            }
            let key = String(tail[tail.index(tail.startIndex, offsetBy: 11)..<keyEnd])
            var value = String(tail[tail.index(after: keyEnd)..<valueEnd.lowerBound])
            if value.hasPrefix("\n") { value.removeFirst() }
            if value.hasSuffix("\n") { value.removeLast() }
            if isStringParameter(key, schema: schema) {
                args[key] = .string(value)
            } else {
                args[key] = (try? JSONValue.parse(value)) ?? .string(value)
            }
            tail = tail[valueEnd.upperBound...]
        }
        return (name, .object(args))
    }

    static func isStringParameter(_ key: String, schema: JSONValue?) -> Bool {
        guard let prop = schema?["properties"]?[key] else { return false }
        if let t = prop["type"]?.stringValue { return t == "string" }
        if let ts = prop["type"]?.arrayValue { return ts.contains("string") }
        for k in ["anyOf", "oneOf"] {
            if prop[k]?.arrayValue?.contains(where: { $0["type"]?.stringValue == "string" }) == true { return true }
        }
        return false
    }
}

public enum TextToolError: Error, Hashable, Sendable {
    case malformed(String)
}

/// Splits streamed reply text into visible text, reasoning and tool calls.
///
/// Text that could be the start of `<tool_call>` (or `</think>`) is held back
/// until it is decided, so no marker fragment ever reaches the screen. A call
/// cut off by the token limit is returned as plain text, never executed.
public struct TextToolCallExtractor: Sendable {
    private let tools: [ToolDefinition]
    private var pending = ""
    private var inCall = false
    private var inThink = false
    private var atStart = true
    private var trimLeading = false
    private var callCount = 0

    public init(tools: [ToolDefinition]) { self.tools = tools }

    public mutating func process(_ event: ChatStreamEvent) -> [ChatStreamEvent] {
        switch event {
        case .contentDelta(let s):
            pending += s
            return drain(final: false)
        case .finished(let reason):
            var out = drain(final: true)
            out.append(.finished(callCount > 0 && reason == .stop ? .toolCalls : reason))
            return out
        default:
            return [event]
        }
    }

    public mutating func finish() -> [ChatStreamEvent] { drain(final: true) }

    private mutating func drain(final: Bool) -> [ChatStreamEvent] {
        var out: [ChatStreamEvent] = []
        while !pending.isEmpty {
            if atStart {
                let trimmed = pending.drop(while: { $0.isWhitespace })
                if trimmed.isEmpty, !final { break }
                if trimmed.hasPrefix("<think>") {
                    pending = String(trimmed.dropFirst(7))
                    inThink = true
                } else if !final, "<think>".hasPrefix(trimmed) {
                    break
                }
                atStart = false
                continue
            }
            if inThink {
                if let r = pending.range(of: "</think>") {
                    let text = String(pending[..<r.lowerBound])
                    if !text.isEmpty { out.append(.reasoningDelta(text)) }
                    pending = String(pending[r.upperBound...])
                    inThink = false
                    trimLeading = true
                    continue
                }
                let keep = final ? 0 : Self.heldSuffix(pending, "</think>")
                let text = String(pending.dropLast(keep))
                if !text.isEmpty { out.append(.reasoningDelta(text)) }
                pending = String(pending.suffix(keep))
                break
            }
            if trimLeading {
                // The blank lines after </think> belong to the template, not the answer.
                pending = String(pending.drop(while: { $0.isWhitespace }))
                if pending.isEmpty { break }
                trimLeading = false
            }
            if inCall {
                guard let r = pending.range(of: TextToolProtocol.callClose) else {
                    if final {
                        out.append(.contentDelta(TextToolProtocol.callOpen + pending))
                        pending = ""
                    }
                    break
                }
                let raw = String(pending[..<r.lowerBound])
                pending = String(pending[r.upperBound...])
                inCall = false
                if let parsed = try? TextToolProtocol.parseCall(raw, tools: tools) {
                    out.append(.toolCallDelta(index: callCount, id: "call_text_\(callCount)",
                                              name: parsed.name, arguments: parsed.arguments.serialized()))
                    callCount += 1
                } else {
                    out.append(.contentDelta(TextToolProtocol.callOpen + raw + TextToolProtocol.callClose))
                }
                continue
            }
            if let r = pending.range(of: TextToolProtocol.callOpen) {
                let text = String(pending[..<r.lowerBound])
                if !text.isEmpty { out.append(.contentDelta(text)) }
                pending = String(pending[r.upperBound...])
                inCall = true
                continue
            }
            let keep = final ? 0 : Self.heldSuffix(pending, TextToolProtocol.callOpen)
            let text = String(pending.dropLast(keep))
            if !text.isEmpty { out.append(.contentDelta(text)) }
            pending = String(pending.suffix(keep))
            break
        }
        return out
    }

    /// Length of the longest suffix of `s` that is a proper prefix of `marker`.
    static func heldSuffix(_ s: String, _ marker: String) -> Int {
        let m = Array(marker)
        let tail = Array(s.suffix(m.count - 1))
        var n = min(tail.count, m.count - 1)
        while n > 0 {
            if Array(tail.suffix(n)) == Array(m.prefix(n)) { return n }
            n -= 1
        }
        return 0
    }
}
