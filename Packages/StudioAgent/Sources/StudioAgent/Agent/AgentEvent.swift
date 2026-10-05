import Foundation

/// Why a run ended.
public enum AgentEndReason: Sendable, Hashable {
    case completed
    case aborted
    case maxTurns(Int)
    case error(String)
    /// The prompt already fills the context, so no reply was started.
    case contextFull(ContextUsage?)
}

/// Why a reply was cut off before the model finished it.
public enum ReplyStop: Sendable, Hashable {
    /// The conversation and the reply fill the context. With the engine's
    /// count when it sent one.
    case contextFull(ContextUsage?)
    /// A limit on one reply: the operator's cap or the model's own
    /// (`max_new_tokens`); Studio sets none.
    case maxTokens

    public var title: String {
        switch self {
        case .contextFull: "Stopped: context full"
        case .maxTokens: "Stopped: the model's output limit"
        }
    }

    public var detail: String {
        switch self {
        case .contextFull(let usage):
            let size = usage.map { " (\($0.contextLength) tokens)" } ?? ""
            return "Stopped: context full. This conversation fills the model's context\(size). Compact the conversation to continue in this chat, or start a new one."
        case .maxTokens:
            return "Stopped: the reply reached an output limit the model or the engine sets."
        }
    }
}

/// The agent's event stream, after pi's lifecycle
/// (`agent_start → turn_start → message_* / tool_execution_* → turn_end → agent_end`).
public enum AgentEvent: Sendable, Hashable {
    case agentStart
    /// A user message entered the session (the prompt, a steering message or
    /// a follow-up).
    case userMessage(text: String, entryID: String)
    case turnStart(index: Int)
    case assistantStart
    case reasoningDelta(String)
    case textDelta(String)
    case toolCallStreamed(ToolCall)
    case assistantEnd(AgentMessage.AssistantMessage, entryID: String)
    /// A call is waiting for the user (the approver has been asked).
    case permissionRequested(PermissionRequest)
    case toolExecutionStart(callID: String, name: String, arguments: JSONValue, effect: ToolEffect)
    case toolExecutionUpdate(callID: String, output: String)
    case toolExecutionEnd(callID: String, name: String, output: ToolOutput, entryID: String)
    case turnEnd(index: Int, timings: GenerationTimings?, usage: TokenUsage?, contextTokens: Int)
    case compactionStart(tokensBefore: Int)
    case compactionEnd(summary: String)
    /// The run changed files; review them hunk by hunk.
    case changesReady(ChangeSet)
    case notice(String)
    /// The last reply was cut off, and why.
    case replyStopped(ReplyStop)
    case agentEnd(AgentEndReason)
}
