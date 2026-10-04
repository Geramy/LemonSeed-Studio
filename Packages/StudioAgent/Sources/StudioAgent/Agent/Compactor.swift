import Foundation

/// Context compaction, after pi's: when the context nears the window,
/// summarize everything before a recent cut point and keep the tail verbatim.
///
/// LSE's window is its KV length (32768 by default). A reply may use what the
/// window has left, so the trigger is `estimate + reserve > threshold ×
/// window`, the reserve being the user's limit on one reply when there is
/// one (otherwise nothing), with the threshold at 75%:
/// compaction rewrites the prompt prefix (a full re-prefill, ~30 s at 20K
/// tokens), so it should be rare.
public struct CompactionPolicy: Sendable, Hashable {
    public var contextWindow: Int
    /// The user's limit on one reply, nil for none (see `OutputBudget`).
    public var maxOutputTokens: Int?
    public var threshold: Double
    /// Recent context kept verbatim after compaction.
    public var keepRecentTokens: Int

    public init(contextWindow: Int = 32768, maxOutputTokens: Int? = nil, threshold: Double = 0.75,
                keepRecentTokens: Int = 6000) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.threshold = threshold
        self.keepRecentTokens = keepRecentTokens
    }

    public func shouldCompact(estimatedTokens: Int) -> Bool {
        Double(estimatedTokens + (maxOutputTokens ?? 0)) > threshold * Double(contextWindow)
    }

    /// The first entry kept after compaction: walking back from the end until
    /// `keepRecentTokens` is reached, then forward to a user message so a tool
    /// call is never separated from its result. Nil keeps nothing.
    public func cutPoint(_ context: [(entryId: String, message: AgentMessage)]) -> String? {
        var tokens = 0
        var index = context.count
        while index > 0 {
            let m = context[index - 1].message
            let size = Self.estimate(m)
            if tokens + size > keepRecentTokens { break }
            tokens += size
            index -= 1
        }
        var forward = index
        while forward < context.count {
            if case .user = context[forward].message { return context[forward].entryId }
            forward += 1
        }
        // The recent tail is one long turn: keep it whole from its user
        // message, so the request being answered is never summarized away.
        var back = min(index, context.count - 1)
        while back >= 0 {
            if case .user = context[back].message { return back == 0 ? nil : context[back].entryId }
            back -= 1
        }
        return nil
    }

    /// Approximate tokens of one message as the model sees it.
    static func estimate(_ m: AgentMessage) -> Int {
        var bytes = 24
        switch m {
        case .user(let u): bytes += u.text.utf8.count
        case .assistant(let a):
            bytes += a.text.utf8.count + a.thinking.utf8.count
            for c in a.toolCalls { bytes += c.arguments.utf8.count + c.name.utf8.count + 48 }
        case .toolResult(let r): bytes += r.text.utf8.count
        case .custom(let c): bytes += c.content.textJoined.utf8.count
        case .branchSummary(let s, _, _), .compactionSummary(let s, _, _): bytes += s.utf8.count
        case .system, .other: break
        }
        return Int((Double(bytes) / 3.6).rounded(.up))
    }

    static let summarySystemPrompt = """
    You write the working summary of a coding session so it can continue with a smaller context. \
    Be specific and complete: file paths, function names, decisions, errors and their fixes. \
    Do not invent anything. Answer with the summary only.
    """

    /// The one-off summarization request (thinking off).
    public func summaryRequest(model: String, conversation: [ChatMessage]) -> ChatRequest {
        var transcript = ""
        for m in conversation where m.role != .system {
            switch m.role {
            case .user: transcript += "[User]\n\(m.content ?? "")\n\n"
            case .assistant:
                if let c = m.content, !c.isEmpty { transcript += "[Agent]\n\(c)\n\n" }
                for call in m.toolCalls { transcript += "[Tool call] \(call.name) \(call.arguments.prefix(600))\n\n" }
            case .tool:
                let text = m.content ?? ""
                transcript += "[Tool result]\n\(text.count > 1500 ? String(text.prefix(1500)) + " […]" : text)\n\n"
            case .system: break
            }
        }
        let instructions = """
        Summarize the session below. Use exactly these sections:

        ## Goal
        ## Constraints and preferences
        ## Progress
        (what is done, what is in progress, what is blocked)
        ## Key decisions
        ## Files
        (files read and files modified, with what changed)
        ## Next steps
        ## Critical context
        (exact names, values, errors and anything else needed to continue)

        <session>
        \(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        </session>
        """
        let messages: [ChatMessage] = [.system(Self.summarySystemPrompt), .user(instructions)]
        // The summary, like any reply, may use what the window has left.
        let budget = OutputBudget(contextWindow: contextWindow, promptTokens: TokenEstimator.rawEstimate(messages),
                                  limit: maxOutputTokens)
        return ChatRequest(model: model, messages: messages, maxTokens: budget.maxTokens, temperature: 0.2,
                           thinking: .off)
    }

    /// Paths the tool calls in `context` read and modified (pi's `details`).
    public static func fileActivity(_ context: [AgentMessage]) -> (read: [String], modified: [String]) {
        var read = Set<String>(), modified = Set<String>()
        for m in context {
            guard case .assistant(let a) = m else { continue }
            for c in a.toolCalls {
                guard let path = c.parsedArguments?["path"]?.stringValue else { continue }
                switch c.name {
                case "read": read.insert(path)
                case "write", "edit": modified.insert(path)
                default: break
                }
            }
        }
        return (read.sorted(), modified.sorted())
    }
}
