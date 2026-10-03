import Foundation
import Testing
@testable import StudioAgent

@Suite("Agent loop")
struct AgentLoopTests {
    @Test func readEditAnswerLoopPersistsAPiSession() async throws {
        let ws = try TempWorkspace(["math.c": "int add(int a, int b) { return a - b; }\n"])
        let client = ScriptedLLMClient([
            .toolCalls([("read", ["path": "math.c"]), ("grep", ["pattern": "add"])], reasoning: "Check the file."),
            .toolCalls([("edit", ["path": "math.c", "edits": [["oldText": "a - b", "newText": "a + b"]]])]),
            .text("Fixed `add` to return `a + b`."),
        ])
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(checkpointStorage: .clone))
        let events = await collect(agent.prompt("Fix add"))
        #expect(ws.read("math.c") == "int add(int a, int b) { return a + b; }\n")
        guard case .agentEnd(.completed) = events.last else { Issue.record("\(String(describing: events.last))"); return }
        let names = events.compactMap { if case .toolExecutionEnd(_, let n, _, _) = $0 { n } else { nil } }
        #expect(names == ["read", "grep", "edit"])
        let turns = events.filter { if case .turnEnd = $0 { true } else { false } }
        #expect(turns.count == 3)
        #expect(events.contains { if case .changesReady(let c) = $0 { c.files.first?.path == "math.c" } else { false } })

        // The file on disk is a pi v3 session with the expected entry sequence.
        let text = try String(contentsOf: agent.sessionURL, encoding: .utf8)
        let doc = try SessionDocument(jsonl: text)
        let kinds = doc.path().map { e -> String in
            if case .message(let m) = e.payload { return m.role }
            if case .custom(let t, _) = e.payload { return t }
            return e.type
        }
        #expect(kinds == ["model_change", "thinking_level_change", "system", "user", "assistant", "toolResult",
                          "toolResult", "assistant", "toolResult", "assistant", "lemonseed.checkpoint"])
        // Rewinding to the prompt restores the file from the clonefile checkpoint.
        let userID = try #require(doc.path().first { $0.message?.role == "user" }?.id)
        let restoredPrompt = try await agent.rewind(toUserEntry: userID)
        #expect(restoredPrompt == "Fix add")
        #expect(ws.read("math.c") == "int add(int a, int b) { return a - b; }\n")
    }

    @Test func steeringIsInjectedAfterTheToolBatch() async throws {
        let ws = try TempWorkspace(["a.txt": "a\n"])
        let client = ScriptedLLMClient([
            .toolCalls([("read", ["path": "a.txt"])]),
            .text("ok"),
        ], delay: .milliseconds(20))
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(checkpointStorage: .memory))
        let stream = agent.prompt("read it")
        try await Task.sleep(for: .milliseconds(30))
        await agent.steer("also mention b")
        let events = await collect(stream)
        let users = events.compactMap { if case .userMessage(let t, _) = $0 { t } else { nil } }
        #expect(users == ["read it", "also mention b"])
        let last = client.requests.last!.messages
        #expect(last.last == .user("also mention b"))
        #expect(last[last.count - 2].role == .tool)
    }

    @Test func abortStopsTheStreamAndKeepsTheSessionValid() async throws {
        let ws = try TempWorkspace()
        let client = ScriptedLLMClient([.text(String(repeating: "word ", count: 400), chunk: 5)],
                                       delay: .milliseconds(5))
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(checkpointStorage: .memory))
        let stream = agent.prompt("talk")
        Task {
            try await Task.sleep(for: .milliseconds(60))
            await agent.abort()
        }
        let events = await collect(stream)
        #expect(events.last == .agentEnd(.aborted))
        let doc = await agent.document
        guard case .message(.assistant(let a)) = doc.path().last?.payload else { Issue.record(); return }
        #expect(a.stopReason == .aborted)
        #expect(!a.text.isEmpty && a.text.count < 2000)
    }

    @Test func retriesOnceOnModelOutputError() async throws {
        let ws = try TempWorkspace()
        let client = ScriptedLLMClient([
            .init(events: [.contentDelta("<tool_")], error: .stream(type: "model_output_error", message: "malformed function call")),
            .text("Recovered."),
        ])
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(checkpointStorage: .memory))
        let events = await collect(agent.prompt("hi"))
        #expect(events.last == .agentEnd(.completed))
        #expect(client.requests.count == 2)
    }

    @Test func compactsNearTheWindowAndKeepsRecentTurns() async throws {
        let ws = try TempWorkspace(["notes.txt": String(repeating: "0123456789abcdef\n", count: 60)])
        let client = ScriptedLLMClient([
            .toolCalls([("read", ["path": "notes.txt"])]),
            .text("Read it."),
            .text("## Goal\nRead notes.txt"),  // the summary
            .text("Answer after compaction."),
        ])
        var cfg = AgentConfiguration(endpoint: EndpointConfiguration(contextWindow: 8192, maxOutputTokens: 1024),
                                     checkpointStorage: .memory)
        cfg.compaction = CompactionPolicy(contextWindow: 8192, maxOutputTokens: 1024, threshold: 0.75,
                                          keepRecentTokens: 200)
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(), configuration: cfg)
        let first = await collect(agent.prompt("read notes.txt"))
        #expect(!first.contains { if case .compactionStart = $0 { true } else { false } })
        let big = "Here is a long spec:\n" + String(repeating: "The parser must accept nested blocks. ", count: 260)
        let events = await collect(agent.prompt(big))
        #expect(events.contains { if case .compactionEnd = $0 { true } else { false } })
        let last = client.requests.last!.messages
        #expect(last.count == 3)
        #expect(last[1].content?.contains("<summary>\n## Goal") == true)
        #expect(last.last == .user(big))
        #expect(!last.contains { $0.role == .tool })
        // The summary request itself saw the first run.
        let summaryRequest = client.requests[2]
        #expect(summaryRequest.thinking == .off)
        #expect(summaryRequest.messages[1].content?.contains("[Tool call] read") == true)
    }

    @Test func agentSessionReplaysAPrefixStableRequest() async throws {
        let ws = try TempWorkspace(["AGENTS.md": "Use tabs.", "a.txt": "hello\n"])
        let client = ScriptedLLMClient([
            .toolCalls([("read", ["path": "a.txt"])], reasoning: "look"),
            .text("It says hello."),
            .text("Still hello."),
        ])
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: DenyingApprover(),
                                    configuration: AgentConfiguration(checkpointStorage: .memory))
        _ = await collect(agent.prompt("What is in a.txt?"))
        _ = await collect(agent.prompt("And now?"))
        let reqs = client.requests
        #expect(reqs.count == 3)
        // Each request's messages extend the previous request's messages exactly.
        for (prev, next) in zip(reqs, reqs.dropFirst()) {
            #expect(Array(next.messages.prefix(prev.messages.count)) == prev.messages)
            #expect(next.tools == prev.tools)
        }
        #expect(reqs[0].messages[0].content?.contains("LemonSeed agent") == true)
        #expect(reqs[0].messages[0].content?.contains("Use tabs.") == true)
        #expect(reqs[1].messages[2].reasoningContent == "look")
        // The session file reloads to the same context.
        let url = agent.sessionURL
        let resumed = try Agent.resume(url: url, workspace: ws.workspace, client: client, approver: DenyingApprover())
        let doc = await resumed.document
        #expect(doc.contextMessages().count == (await agent.document).contextMessages().count)
    }
}

/// Collects agent events.
func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var out: [AgentEvent] = []
    for await e in stream { out.append(e) }
    return out
}
