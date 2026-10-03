import Foundation
import Testing
@testable import StudioAgent

@Suite("Permission gating")
struct PermissionTests {
    let write = ToolEffect.write(paths: ["a.c"])
    func shell(_ c: ShellCommandClass) -> ToolEffect { .shell(command: "x", commandClass: c) }

    @Test func modeTable() {
        let cases: [(PermissionMode, ToolEffect, PermissionDecision)] = [
            (.readOnly, .read, .allow),
            (.readOnly, shell(.readOnly), .allow),
            (.ask, .read, .allow),
            (.ask, write, .ask),
            (.ask, shell(.readOnly), .ask),
            (.review, write, .allow),
            (.review, shell(.readOnly), .allow),
            (.review, shell(.build), .allow),
            (.review, shell(.mutating), .ask),
            (.review, shell(.unknown), .ask),
            (.autopilot, write, .allow),
            (.autopilot, shell(.mutating), .allow),
            (.autopilot, shell(.network), .ask),
            (.autopilot, shell(.unknown), .ask),
        ]
        for (mode, effect, expected) in cases {
            #expect(PermissionPolicy(mode: mode).decide(effect) == expected, "\(mode) \(effect)")
        }
        if case .deny = PermissionPolicy(mode: .readOnly).decide(write) {} else { Issue.record("read-only must refuse writes") }
        if case .deny = PermissionPolicy(mode: .readOnly).decide(shell(.mutating)) {} else { Issue.record("read-only must refuse rm") }
    }

    @Test func sessionGrantsTurnAskIntoAllowButNeverOverrideRefusal() {
        var p = PermissionPolicy(mode: .ask)
        p.grant(write)
        #expect(p.decide(.write(paths: ["other.c"])) == .allow)
        #expect(p.decide(shell(.readOnly)) == .ask)
        p.mode = .readOnly
        if case .deny = p.decide(write) {} else { Issue.record("grant must not override read-only") }
        // Unknown commands are never granted wholesale.
        var q = PermissionPolicy(mode: .review)
        q.grant(shell(.unknown))
        #expect(q.decide(shell(.unknown)) == .ask)
    }

    @Test func shellClassificationIsExact() {
        let sh = InProcessShell()
        #expect(sh.classify("ls -la src | grep main") == .readOnly)
        #expect(sh.classify("grep -rn TODO . && wc -l src/*.c") == .readOnly)
        #expect(sh.classify("cat a.txt > b.txt") == .mutating)
        #expect(sh.classify("echo hi >> log.txt") == .mutating)
        #expect(sh.classify("ls > /dev/null") == .readOnly)
        #expect(sh.classify("rm -rf build") == .mutating)
        #expect(sh.classify("curl http://example.com") == .unknown)
        #expect(sh.classify("ls; python3 x.py") == .unknown)
        #expect(sh.classify("echo $(whoami)") == .unknown)  // unparseable is unknown, never guessed
    }

    // MARK: Gating inside the agent loop

    func agent(_ ws: TempWorkspace, mode: PermissionMode, approver: any PermissionApprover,
               replies: [ScriptedLLMClient.Reply]) throws -> (Agent, ScriptedLLMClient) {
        let client = ScriptedLLMClient(replies)
        let agent = try Agent.start(workspace: ws.workspace, client: client, approver: approver,
                                    configuration: AgentConfiguration(permissionMode: mode, checkpointStorage: .memory))
        return (agent, client)
    }

    @Test func readOnlyModeRefusesWritesAndTellsTheModel() async throws {
        let ws = try TempWorkspace(["a.txt": "old\n"])
        let (agent, client) = try agent(ws, mode: .readOnly, approver: AllowingApprover(), replies: [
            .toolCalls([("write", ["path": "a.txt", "content": "new\n"])]),
            .text("I could not change it."),
        ])
        let events = await collect(agent.prompt("change a.txt"))
        #expect(ws.read("a.txt") == "old\n")
        let result = events.compactMap { if case .toolExecutionEnd(_, _, let o, _) = $0 { o } else { nil } }.first
        #expect(result?.isError == true)
        #expect(result?.text.contains("read-only") == true)
        // The refusal went back to the model as a tool result.
        let second = client.requests[1].messages
        #expect(second.last?.role == .tool)
        #expect(second.last?.content?.contains("Permission denied") == true)
        #expect(!events.contains { if case .changesReady = $0 { true } else { false } })
    }

    @Test func askModeConsultsTheApprover() async throws {
        let ws = try TempWorkspace(["a.txt": "old\n"])
        let (agent, _) = try agent(ws, mode: .ask, approver: DenyingApprover(), replies: [
            .toolCalls([("write", ["path": "a.txt", "content": "new\n"]), ("read", ["path": "a.txt"])]),
            .text("Declined."),
        ])
        let events = await collect(agent.prompt("change a.txt"))
        #expect(ws.read("a.txt") == "old\n")
        let asked = events.compactMap { if case .permissionRequested(let r) = $0 { r } else { nil } }
        #expect(asked.map(\.toolName) == ["write"])  // reads never ask
        let results = events.compactMap { if case .toolExecutionEnd(_, let n, let o, _) = $0 { (n, o.isError) } else { nil } }
        #expect(results.map(\.0) == ["write", "read"])
        #expect(results.map(\.1) == [true, false])
    }

    @Test func reviewModeAppliesCheckpointsAndSupportsPerHunkReject() async throws {
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let ws = try TempWorkspace(["a.txt": original])
        let (agent, _) = try agent(ws, mode: .review, approver: DenyingApprover(), replies: [
            .toolCalls([("edit", ["path": "a.txt", "edits": [
                ["oldText": "line 2\n", "newText": "line two\n"],
                ["oldText": "line 18\n", "newText": "line eighteen\n"],
            ]]), ("write", ["path": "new.txt", "content": "fresh\n"])]),
            .text("Done."),
        ])
        let events = await collect(agent.prompt("edit"))
        guard case .agentEnd(.completed) = events.last else { Issue.record("\(events.last!)"); return }
        let changes = try #require(events.compactMap { if case .changesReady(let c) = $0 { c } else { nil } }.first)
        #expect(changes.files.map(\.path) == ["a.txt", "new.txt"])
        let a = try #require(changes.files.first)
        #expect(a.hunks.count == 2)
        #expect(changes.files[1].kind == .added)

        var decisions = ChangeSet.Decisions()
        decisions.set("a.txt", hunk: a.hunks[1].id, accepted: false)  // reject the second hunk
        decisions.setAll(changes.files[1], accepted: false)             // and the new file
        try await agent.applyReview(changes, decisions: decisions)
        #expect(ws.read("a.txt") == original.replacingOccurrences(of: "line 2\n", with: "line two\n"))
        #expect(!ws.exists("new.txt"))
    }
}
