import Foundation
import Testing
@testable import StudioAgent

/// Studio against LSE 0.5.2's contract (docs/API.md): no output limit, the
/// context-full stop and error, model-defined thinking levels and sampling
/// defaults.
@Suite("LSE contract")
struct LSEContractTests {
    /// A Qwen3.8 entry of /v1/models, as docs/API.md shows it.
    static let qwen38 = try! JSONValue.parse(#"""
    {"id":"qwen-q4","object":"model","context_length":32768,"max_tokens":null,
     "generation_defaults":{"temperature":1.0,"top_k":20,"top_p":0.95,"min_p":0.0,"repetition_penalty":1.0,
       "presence_penalty":0.0,"max_new_tokens":null,"max_length":null,
       "sources":{"temperature":"generation_config.json","top_k":"generation_config.json","min_p":"lse_default"}},
     "thinking":{"supported":true,"source":"/m/chat_template.jinja","toggle":"enable_thinking","effort":"reasoning_effort",
       "default_level":"xhigh","levels":[
        {"id":"none","enable_thinking":false,"reasoning_effort":null,"instruction":null,"opens_reasoning":false,"default":false},
        {"id":"xhigh","enable_thinking":true,"reasoning_effort":"xhigh","instruction":"Reasoning effort is set to xhigh.","opens_reasoning":true,"default":true},
        {"id":"medium","enable_thinking":true,"reasoning_effort":"medium","instruction":null,"opens_reasoning":true,"default":false},
        {"id":"low","enable_thinking":true,"reasoning_effort":"low","instruction":"Reasoning effort is set to low.","opens_reasoning":true,"default":false}]}}
    """#)

    static var capabilities: ModelCapabilities { ModelCapabilities(json: qwen38)! }

    @Test func modelEntriesParse() throws {
        let c = Self.capabilities
        #expect(c.id == "qwen-q4" && c.contextLength == 32768 && c.maxTokens == nil)
        let thinking = try #require(c.thinking)
        #expect(thinking.supported && thinking.defaultLevel == "xhigh")
        #expect(thinking.levels.map(\.id) == ["none", "xhigh", "medium", "low"])
        #expect(thinking.levels.map(\.title) == ["Off", "Extra high", "Medium", "Low"])
        #expect(!thinking.defines("high"))
        let d = try #require(c.generationDefaults)
        #expect(d.temperature == 1.0 && d.topK == 20 && d.topP == 0.95 && d.minP == 0 && d.maxNewTokens == nil)
        #expect(d.sources["top_k"] == "generation_config.json" && d.sources["min_p"] == "lse_default")
        let none = ModelThinking(json: try JSONValue.parse(#"{"supported":false,"source":null,"levels":[]}"#))
        #expect(none?.supported == false && none?.levels.isEmpty == true)
    }

    @Test func theFinalChunkCarriesTheStopReasonAndTheContext() throws {
        let chunk = #"{"object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"length","stop_reason":"context_full"}],"lse_context":{"tokens_used":512,"context_length":512,"tokens_remaining":0}}"#
        guard case .events(let events) = try ChatChunkDecoder.decode(chunk) else { Issue.record(); return }
        #expect(events.contains(.finished(.length)) && events.contains(.stopReason("context_full")))
        #expect(events.contains(.context(ContextUsage(tokensUsed: 512, contextLength: 512, tokensRemaining: 0))))
    }

    @Test func errorCodesAreReadNotMatched() {
        let body = Data(#"{"error":{"message":"the prompt is 600 tokens and the context holds 512; compact or shorten the conversation","type":"invalid_request_error","code":"context_full","param":"messages","lse_context":{"tokens_used":600,"context_length":512,"tokens_remaining":0}}}"#.utf8)
        let error = LLMError.fromResponse(status: 400, body: body)
        #expect(error.isContextFull && error.code == "context_full")
        if case .api(400, _, _, let usage, _) = error { #expect(usage?.tokensUsed == 600) } else { Issue.record("\(error)") }
        let level = LLMError.fromResponse(status: 400, body: Data(#"{"error":{"message":"no","code":"unsupported_reasoning_effort","levels":["none","xhigh"]}}"#.utf8))
        if case .api(_, "unsupported_reasoning_effort", _, _, let levels) = level { #expect(levels == ["none", "xhigh"]) } else { Issue.record() }
        // Without a code it stays a plain HTTP error.
        #expect(LLMError.fromResponse(status: 500, body: Data(#"{"error":{"message":"x"}}"#.utf8)) == .http(status: 500, message: "x"))
    }

    @Test func noOutputLimitIsSentAndOnlyOverridesAre() async throws {
        let ws = try TempWorkspace([:])
        let client = ScriptedLLMClient([.text("hi")])
        let cfg = AgentConfiguration(sampling: SamplingOverrides(topK: 40), model: Self.capabilities, checkpointStorage: .memory)
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(), configuration: cfg)
        _ = await collect(agent.prompt("hello"))
        let body = try #require(client.requests.first).body()
        #expect(body["max_tokens"] == nil)
        #expect(body["top_k"] == 40)
        for key in ["temperature", "top_p", "min_p", "presence_penalty", "repetition_penalty", "reasoning_effort"] {
            #expect(body[key] == nil, "\(key) is left to the model")
        }
    }

    @Test func aReplyThatFillsTheContextStopsAndOffersNothingAutomatic() async throws {
        let ws = try TempWorkspace([:])
        let usage = ContextUsage(tokensUsed: 512, contextLength: 512, tokensRemaining: 0)
        let cut = ScriptedLLMClient.Reply(events: [.reasoningDelta("think "), .contentDelta("partial"),
                                                    .finished(.length), .stopReason("context_full"), .context(usage)])
        let client = ScriptedLLMClient([cut])
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(checkpointStorage: .memory))
        let events = await collect(agent.prompt("explain"))
        #expect(events.contains(.replyStopped(.contextFull(usage))))
        guard case .agentEnd(.completed) = events.last else { Issue.record("\(String(describing: events.last))"); return }
        let ended = events.compactMap { if case .assistantEnd(let m, _) = $0 { m } else { nil } }
        #expect(ended.last?.text == "partial" && ended.last?.stopReason == .length)
        #expect(!events.contains { if case .compactionStart = $0 { true } else { false } }, "nothing compacts on its own")
        #expect(client.requests.count == 1)
    }

    @Test func aPromptThatFillsTheContextEndsTheRunWithoutAReply() async throws {
        let ws = try TempWorkspace([:])
        let usage = ContextUsage(tokensUsed: 600, contextLength: 512, tokensRemaining: 0)
        let full = LLMError.api(status: 400, code: "context_full", message: "the prompt is 600 tokens", context: usage, levels: [])
        let client = ScriptedLLMClient([.init(events: [], error: full)])
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(checkpointStorage: .memory))
        let events = await collect(agent.prompt("one more"))
        #expect(events.last == .agentEnd(.contextFull(usage)))
        #expect(!events.contains { if case .compactionStart = $0 { true } else { false } })
    }

    @Test func compactionRunsOnlyWhenAsked() async throws {
        let ws = try TempWorkspace(["notes.txt": String(repeating: "0123456789abcdef\n", count: 60)])
        let client = ScriptedLLMClient([
            .toolCalls([("read", ["path": "notes.txt"])]),
            .text("Read it."),
            .text("Still there."),
            .text("## Goal\nRead notes.txt"),  // the summary
            .text("Answer after compaction."),
        ])
        var cfg = AgentConfiguration(model: Self.capabilities, checkpointStorage: .memory)
        cfg.compaction = CompactionPolicy(keepRecentTokens: 10)
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(), configuration: cfg)
        _ = await collect(agent.prompt("read notes.txt"))
        _ = await collect(agent.prompt("is it still there?"))
        #expect(client.requests.count == 3, "nothing compacted on its own")
        let compaction = await collect(agent.compactConversation())
        #expect(compaction.contains { if case .compactionEnd = $0 { true } else { false } })
        #expect(compaction.last == .agentEnd(.completed))
        let summary = client.requests[3]
        #expect(summary.thinking == ThinkingLevel.off && summary.maxTokens == nil)
        #expect(summary.messages[1].content?.contains("[Tool call] read") == true)
        _ = await collect(agent.prompt("go on"))
        let last = client.requests.last!.messages
        #expect(last[1].content?.contains("<summary>\n## Goal") == true)
        #expect(last.last == .user("go on"))
    }

    @Test func compactingTheLatestTurnAloneIsRefusedPlainly() async throws {
        let ws = try TempWorkspace([:])
        let client = ScriptedLLMClient([.text("one")])
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(checkpointStorage: .memory))
        _ = await collect(agent.prompt("only turn"))
        let events = await collect(agent.compactConversation())
        guard case .agentEnd(.error(let why)) = events.last else { Issue.record("\(events)"); return }
        #expect(why.contains("nothing older to summarize"))
        #expect(client.requests.count == 1, "no summary request")
    }

    @Test func aLevelTheModelDoesNotDefineIsNeverSent() async throws {
        let ws = try TempWorkspace([:])
        let client = ScriptedLLMClient([.text("a"), .text("b"), .text("c")])
        let cfg = AgentConfiguration(thinking: .level("high"), model: Self.capabilities, checkpointStorage: .memory)
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(), configuration: cfg)
        let first = await collect(agent.prompt("one"))
        #expect(client.requests[0].thinking == nil, "Qwen3.8 has no high: the model's default is used")
        #expect(first.contains { if case .notice(let n) = $0 { n.contains("no High thinking level") } else { false } })
        let second = await collect(agent.prompt("two"))
        #expect(!second.contains { if case .notice = $0 { true } else { false } }, "said once")
        try await agent.setThinking(.level("low"))
        _ = await collect(agent.prompt("three"))
        #expect(client.requests[2].thinking == .level("low"))
    }

    @Test func modelDefaultSendsNoLevel() async throws {
        let ws = try TempWorkspace([:])
        let client = ScriptedLLMClient([.text("a")])
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(model: Self.capabilities, checkpointStorage: .memory))
        _ = await collect(agent.prompt("one"))
        #expect(client.requests[0].body()["reasoning_effort"] == nil)
    }
}

@Suite("Sampling")
struct SamplingTests {
    @Test func onlySetFieldsAreSent() {
        guard case .object(let o) = ChatRequest(model: "m", messages: [.user("hi")]).body() else { Issue.record(); return }
        for key in ["temperature", "top_k", "top_p", "min_p", "presence_penalty", "repetition_penalty", "max_tokens"] {
            #expect(o[key] == nil)
        }
        let set = SamplingOverrides(temperature: 0.7, topK: 20, topP: 0.8, minP: 0.05, presencePenalty: 0.5,
                                    repetitionPenalty: 1.1)
        guard case .object(let s) = ChatRequest(model: "m", messages: [], sampling: set).body() else { Issue.record(); return }
        #expect(s["temperature"] == .number(0.7) && s["top_k"] == .int(20) && s["top_p"] == .number(0.8))
        #expect(s["min_p"] == .number(0.05) && s["presence_penalty"] == .number(0.5) && s["repetition_penalty"] == .number(1.1))
    }

    @Test func theAgentTakesASamplingChange() async throws {
        let ws = try TempWorkspace([:])
        let client = ScriptedLLMClient([.text("one"), .text("two")])
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(sampling: .init(temperature: 0.7), checkpointStorage: .memory))
        _ = await collect(agent.prompt("a"))
        await agent.setSampling(SamplingOverrides(topK: 40))
        _ = await collect(agent.prompt("b"))
        #expect(client.requests[0].sampling == SamplingOverrides(temperature: 0.7))
        #expect(client.requests[1].sampling == SamplingOverrides(topK: 40))
    }
}
