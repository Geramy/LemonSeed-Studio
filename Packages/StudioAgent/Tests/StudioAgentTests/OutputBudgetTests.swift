import Foundation
import Testing
@testable import StudioAgent

@Suite("Output budget")
struct OutputBudgetTests {
    @Test func withoutALimitAReplyMayFillTheContext() {
        let b = OutputBudget(contextWindow: 32768, promptTokens: 5000, limit: nil)
        #expect(b.maxTokens == 27768 && b.boundByContext && !b.contextIsFull)
    }

    @Test func aSmallerUserLimitWinsAndALargerOneDoesNot() {
        let small = OutputBudget(contextWindow: 32768, promptTokens: 5000, limit: 8192)
        #expect(small.maxTokens == 8192 && !small.boundByContext)
        let large = OutputBudget(contextWindow: 32768, promptTokens: 30000, limit: 8192)
        #expect(large.maxTokens == 2768 && large.boundByContext)
    }

    @Test func aFullContextLeavesNothing() {
        #expect(OutputBudget(contextWindow: 4096, promptTokens: 4096, limit: nil).contextIsFull)
        #expect(OutputBudget(contextWindow: 4096, promptTokens: 5000, limit: 100).contextIsFull)
    }

    @Test func theAgentAsksForWhatTheContextHasLeftAndSaysWhenItIsFull() async throws {
        let ws = try TempWorkspace([:])
        let cut = ScriptedLLMClient.Reply(events: [.reasoningDelta("thinking it through "), .contentDelta("partial"),
                                                    .finished(.length)])
        let client = ScriptedLLMClient([cut])
        let cfg = AgentConfiguration(endpoint: EndpointConfiguration(contextWindow: 16384), checkpointStorage: .memory)
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(), configuration: cfg)
        let events = await collect(agent.prompt("explain"))
        let request = try #require(client.requests.first)
        // No constant: everything the estimated prompt leaves of the window.
        let prompt = TokenEstimator().estimate(request.messages, tools: request.tools)
        #expect(request.maxTokens == 16384 - prompt)
        #expect(request.maxTokens > 2048)
        #expect(events.contains { $0 == .replyStopped(.contextFull(contextWindow: 16384)) })
    }

    @Test func aUserLimitThatStopsTheReplyIsNamed() async throws {
        let ws = try TempWorkspace([:])
        let client = ScriptedLLMClient([.init(events: [.contentDelta("partial"), .finished(.length)])])
        let cfg = AgentConfiguration(endpoint: EndpointConfiguration(contextWindow: 16384, maxOutputTokens: 300),
                                     checkpointStorage: .memory)
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(), configuration: cfg)
        let events = await collect(agent.prompt("explain"))
        #expect(client.requests.first?.maxTokens == 300)
        #expect(events.contains { $0 == .replyStopped(.replyLimit(300)) })
    }

    @Test func theEngineRunningOutOfKVIsAFullContextNotAnError() async throws {
        let ws = try TempWorkspace([:])
        let overflow = LLMError.stream(type: "server_error",
                                       message: "this pass would reach KV position 16385, past the engine length 16384")
        let client = ScriptedLLMClient([.init(events: [.contentDelta("most of the answer")], error: overflow)])
        let cfg = AgentConfiguration(endpoint: EndpointConfiguration(contextWindow: 16384), checkpointStorage: .memory)
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(), configuration: cfg)
        let events = await collect(agent.prompt("explain"))
        #expect(events.contains { $0 == .replyStopped(.contextFull(contextWindow: 16384)) })
        guard case .agentEnd(.completed) = events.last else { Issue.record("\(String(describing: events.last))"); return }
        let ended = events.compactMap { if case .assistantEnd(let m, _) = $0 { m } else { nil } }
        #expect(ended.last?.text == "most of the answer" && ended.last?.stopReason == .length)
    }

    @Test func noRequestIsSentWhenNothingIsLeft() async throws {
        let ws = try TempWorkspace([:])
        let client = ScriptedLLMClient([])
        var cfg = AgentConfiguration(endpoint: EndpointConfiguration(contextWindow: 600), checkpointStorage: .memory)
        cfg.compaction = CompactionPolicy(contextWindow: 600, threshold: 10)  // never compacts
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(), configuration: cfg)
        let events = await collect(agent.prompt(String(repeating: "a long message ", count: 200)))
        #expect(client.requests.isEmpty)
        #expect(events.contains { $0 == .replyStopped(.contextFull(contextWindow: 600)) })
    }
}

@Suite("Sampling")
struct SamplingTests {
    @Test func topPAndTopKAreSentOnlyWhenSet() {
        let plain = ChatRequest(model: "m", messages: [.user("hi")]).body()
        guard case .object(let o) = plain else { Issue.record(); return }
        #expect(o["top_p"] == nil && o["top_k"] == nil && o["temperature"] == nil)
        let set = ChatRequest(model: "m", messages: [.user("hi")], temperature: 0.7, topP: 0.8, topK: 20).body()
        guard case .object(let s) = set else { Issue.record(); return }
        #expect(s["top_p"] == .number(0.8) && s["top_k"] == .int(20) && s["temperature"] == .number(0.7))
    }

    @Test func theAgentSendsItsSamplingAndTakesChanges() async throws {
        let ws = try TempWorkspace([:])
        let client = ScriptedLLMClient([.text("one"), .text("two")])
        let cfg = AgentConfiguration(temperature: 0.7, topP: 0.8, topK: 20, checkpointStorage: .memory)
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(), configuration: cfg)
        _ = await collect(agent.prompt("a"))
        await agent.setSampling(temperature: nil, topP: nil, topK: 40)
        _ = await collect(agent.prompt("b"))
        let (first, second) = (client.requests[0], client.requests[1])
        #expect(first.temperature == 0.7 && first.topP == 0.8 && first.topK == 20)
        #expect(second.temperature == nil && second.topP == nil && second.topK == 40)
    }
}
