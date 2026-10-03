import Foundation

/// Why a run ended.
public enum AgentEndReason: Sendable, Hashable {
    case completed
    case aborted
    case maxTurns(Int)
    case error(String)
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
    case agentEnd(AgentEndReason)
}
