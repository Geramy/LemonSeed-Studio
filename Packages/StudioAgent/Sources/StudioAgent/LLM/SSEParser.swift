import Foundation

/// One server-sent event (WHATWG HTML, "Server-sent events", section 9.2.6).
public struct SSEEvent: Sendable, Hashable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental `text/event-stream` parser.
///
/// Feed it bytes in chunks of any size; it returns each event once its
/// terminating blank line arrives. Lines may end in LF, CRLF or a lone CR,
/// including a CRLF split across two chunks. Bytes are buffered until a line
/// is complete, so multi-byte UTF-8 sequences split across chunks decode
/// correctly. Comment lines (starting with ':') are ignored.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastWasCR = false
    private var dataLines: [String] = []
    private var eventType = ""
    private var lastEventID: String?
    private var sawField = false

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        var out: [SSEEvent] = []
        for b in bytes {
            if lastWasCR {
                lastWasCR = false
                if b == 0x0A { continue }  // the LF of a CRLF
            }
            switch b {
            case 0x0D:
                lastWasCR = true
                endLine(into: &out)
            case 0x0A:
                endLine(into: &out)
            default:
                line.append(b)
            }
        }
        return out
    }

    /// Flushes a final event when the stream ends without a trailing blank line.
    public mutating func finish() -> [SSEEvent] {
        var out: [SSEEvent] = []
        if !line.isEmpty { endLine(into: &out) }
        dispatch(into: &out)
        return out
    }

    private mutating func endLine(into out: inout [SSEEvent]) {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            dispatch(into: &out)
            return
        }
        if line.first == UInt8(ascii: ":") { return }
        let text = String(decoding: line, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "data":
            dataLines.append(String(value))
            sawField = true
        case "event":
            eventType = String(value)
            sawField = true
        case "id":
            if !value.contains("\0") { lastEventID = String(value) }
        default:
            break  // "retry" and unknown fields have no meaning for a one-shot completion
        }
    }

    private mutating func dispatch(into out: inout [SSEEvent]) {
        defer {
            dataLines.removeAll()
            eventType = ""
            sawField = false
        }
        guard sawField, !dataLines.isEmpty else { return }
        out.append(SSEEvent(event: eventType.isEmpty ? "message" : eventType,
                            data: dataLines.joined(separator: "\n"), id: lastEventID))
    }
}

/// Errors from the chat client.
public enum LLMError: Error, Sendable, Hashable, LocalizedError {
    /// Non-2xx status, with the server's error message when it sent the
    /// OpenAI error envelope.
    case http(status: Int, message: String)
    /// An `{"error": …}` frame inside the stream. LSE uses type
    /// `model_output_error` when the model produced an unparseable tool call.
    case stream(type: String, message: String)
    case malformedChunk(String)
    case unreachable(String)
    /// An error envelope with a code (LSE's `error.code`, e.g. `context_full`
    /// or `unsupported_reasoning_effort`), its `lse_context` and `levels`
    /// when present. `status` is 0 for one that arrived inside the stream.
    case api(status: Int, code: String, message: String, context: ContextUsage?, levels: [String])

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .api(_, _, let message, _, _): message
        case .stream(let type, let message): "\(type): \(message)"
        case .malformedChunk(let s): "Malformed stream chunk: \(s.prefix(200))"
        case .unreachable(let s): "Endpoint unreachable: \(s)"
        }
    }

    public var isModelOutputError: Bool {
        if case .stream(let type, _) = self { return type == "model_output_error" }
        return false
    }

    /// The error code, when the server sent one.
    public var code: String? {
        if case .api(_, let code, _, _, _) = self { return code }
        return nil
    }

    /// The prompt already fills the context (LSE's `context_full`).
    public var isContextFull: Bool { code == "context_full" }

    /// Maps an OpenAI error envelope (`{"error": {...}}`).
    static func envelope(_ err: JSONValue, status: Int) -> LLMError {
        let message = err["message"]?.stringValue ?? err.serialized()
        if let code = err["code"]?.stringValue {
            return .api(status: status, code: code, message: message,
                        context: err["lse_context"].flatMap(ContextUsage.init(json:)),
                        levels: (err["levels"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
        if status == 0 { return .stream(type: err["type"]?.stringValue ?? "server_error", message: message) }
        return .http(status: status, message: message)
    }
}

/// Decodes `chat.completion.chunk` payloads into stream events.
public enum ChatChunkDecoder {
    public enum Output: Sendable, Hashable {
        case events([ChatStreamEvent])
        case done
    }

    public static func decode(_ data: String) throws -> Output {
        let trimmed = data.trimmingCharacters(in: .whitespaces)
        if trimmed == "[DONE]" { return .done }
        let json: JSONValue
        do { json = try JSONValue.parse(trimmed) } catch { throw LLMError.malformedChunk(trimmed) }
        if let err = json["error"] { throw LLMError.envelope(err, status: 0) }
        var events: [ChatStreamEvent] = []
        for choice in json["choices"]?.arrayValue ?? [] {
            if let delta = choice["delta"] {
                if let r = delta["reasoning_content"]?.stringValue, !r.isEmpty {
                    events.append(.reasoningDelta(r))
                } else if let r = delta["reasoning"]?.stringValue, !r.isEmpty {
                    events.append(.reasoningDelta(r))
                }
                if let c = delta["content"]?.stringValue, !c.isEmpty {
                    events.append(.contentDelta(c))
                }
                for (position, call) in (delta["tool_calls"]?.arrayValue ?? []).enumerated() {
                    let fn = call["function"]
                    events.append(.toolCallDelta(
                        index: call["index"]?.intValue ?? position,
                        id: call["id"]?.stringValue,
                        name: fn?["name"]?.stringValue,
                        arguments: fn?["arguments"]?.stringValue))
                }
            }
            if let reason = choice["finish_reason"]?.stringValue {
                events.append(.finished(FinishReason(rawValue: reason) ?? .stop))
            }
            if let reason = choice["stop_reason"]?.stringValue { events.append(.stopReason(reason)) }
        }
        if let c = json["lse_context"].flatMap(ContextUsage.init(json:)) { events.append(.context(c)) }
        if let t = json["timings"].flatMap(GenerationTimings.init(json:)) { events.append(.timings(t)) }
        if let u = json["usage"].flatMap(TokenUsage.init(json:)) { events.append(.usage(u)) }
        return .events(events)
    }
}
