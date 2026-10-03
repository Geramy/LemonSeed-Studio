import Foundation

/// Turns session context into chat.completions messages.
///
/// The conversion is a pure function of the session, so the same history
/// always produces the same request bytes. Reasoning is replayed in
/// `reasoning_content` because LSE renders it back into the assistant turn;
/// leaving it out would change the prompt and miss the engine's KV cache.
public enum WireConverter {
    public static let compactionPrefix =
        "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
    public static let compactionSuffix = "\n</summary>"
    public static let branchPrefix =
        "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n"
    public static let branchSuffix = "</summary>"

    public static func messages(systemPrompt: String, context: [AgentMessage]) -> [ChatMessage] {
        // Tool results that exist, so calls without one (an aborted turn) are dropped.
        var answered = Set<String>()
        for m in context { if case .toolResult(let r) = m { answered.insert(r.toolCallId) } }

        var out: [ChatMessage] = []
        if !systemPrompt.isEmpty { out.append(.system(systemPrompt)) }
        var pending = Set<String>()
        for m in context {
            switch m {
            case .system, .other:
                continue
            case .user(let u):
                out.append(.user(userText(u.content)))
            case .assistant(let a):
                let calls = a.toolCalls.filter { answered.contains($0.id) }
                let text = a.text
                if calls.isEmpty && text.isEmpty { continue }  // empty aborted or failed turn
                pending.formUnion(calls.map(\.id))
                out.append(ChatMessage(role: .assistant, content: text,
                                       reasoningContent: a.thinking.isEmpty ? nil : a.thinking,
                                       toolCalls: calls))
            case .toolResult(let r):
                guard pending.remove(r.toolCallId) != nil else { continue }
                out.append(.tool(id: r.toolCallId, r.text.isEmpty ? "(no output)" : r.text))
            case .custom(let c):
                out.append(.user(userText(c.content)))
            case .branchSummary(let summary, _, _):
                out.append(.user(branchPrefix + summary + branchSuffix))
            case .compactionSummary(let summary, _, _):
                out.append(.user(compactionPrefix + summary + compactionSuffix))
            }
        }
        return out
    }

    static func userText(_ blocks: [ContentBlock]) -> String {
        blocks.map { b -> String in
            switch b {
            case .text(let t, _): t
            case .image: "[An image was attached; this model reads text only.]"
            default: ""
            }
        }.joined()
    }
}

/// Token estimates for compaction decisions, calibrated against the counts
/// the server reports (`usage.prompt_tokens`).
public struct TokenEstimator: Sendable, Hashable {
    /// Server tokens per estimated token, learned from the last response.
    public var calibration: Double = 1.0

    public init() {}

    /// Roughly 3.6 UTF-8 bytes per token for code and English with Qwen's
    /// tokenizer, plus template overhead per message.
    public static func rawEstimate(_ messages: [ChatMessage], tools: [ToolDefinition] = []) -> Int {
        var bytes = 0
        for m in messages {
            bytes += (m.content?.utf8.count ?? 0) + (m.reasoningContent?.utf8.count ?? 0) + 24
            for c in m.toolCalls { bytes += c.arguments.utf8.count + c.name.utf8.count + 48 }
        }
        for t in tools { bytes += t.json.serialized().utf8.count }
        return Int((Double(bytes) / 3.6).rounded(.up)) + 400  // tool-format instructions
    }

    public func estimate(_ messages: [ChatMessage], tools: [ToolDefinition] = []) -> Int {
        Int((Double(Self.rawEstimate(messages, tools: tools)) * calibration).rounded(.up))
    }

    public mutating func calibrate(actualPromptTokens: Int, estimated: Int) {
        guard actualPromptTokens > 0, estimated > 0 else { return }
        let ratio = Double(actualPromptTokens) / Double(estimated)
        calibration = min(3.0, max(0.33, ratio))
    }
}
