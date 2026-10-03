import Foundation
import StudioAgent
import Testing
@testable import StudioAgentUI

@MainActor
@Suite("Agent view model")
struct AgentViewModelTests {
    func workspace(_ files: [String: String]) throws -> LocalWorkspace {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lemonseed-ui-\(UUID().uuidString)")
        for (p, t) in files {
            let url = dir.appending(path: p)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(t.utf8).write(to: url)
        }
        return LocalWorkspace(rootURL: dir)
    }

    func waitUntilIdle(_ model: AgentViewModel) async throws {
        for _ in 0..<500 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isRunning)
    }

    @Test func foldsARunIntoTheTranscript() async throws {
        let ws = try workspace(["a.txt": "one\n"])
        let client = ScriptedLLMClient([
            .toolCalls([("edit", ["path": "a.txt", "edits": [["oldText": "one", "newText": "two"]]])], reasoning: "edit it"),
            .text("Changed **one** to `two`."),
        ])
        let model = AgentViewModel(workspace: ws, client: client,
                                   configuration: AgentConfiguration(permissionMode: .autopilot, checkpointStorage: .memory))
        model.composer = "change it"
        model.send()
        #expect(model.composer.isEmpty)
        try await waitUntilIdle(model)

        let kinds = model.items.map { item -> String in
            switch item.kind {
            case .user: "user"
            case .assistant: "assistant"
            case .tool(let c): "tool:\(c.name):\(c.status)"
            case .notice: "notice"
            case .compaction: "compaction"
            case .changes(let c): "changes:\(c.files.count)"
            }
        }
        #expect(kinds == ["user", "assistant", "tool:edit:done", "assistant", "changes:1"])
        guard case .assistant(let b) = model.items[3].kind else { Issue.record(); return }
        #expect(b.text == "Changed **one** to `two`.")
        #expect(!b.isStreaming)
        #expect(model.stats.lastTimings?.decodePerSecond == GenerationTimings.sample.decodePerSecond)
        #expect(model.sessionTitle == "change it")
    }

    @Test func approvalPromptsResumeTheAgent() async throws {
        let ws = try workspace(["a.txt": "one\n"])
        let client = ScriptedLLMClient([
            .toolCalls([("write", ["path": "a.txt", "content": "two\n"])]),
            .text("Done."),
        ])
        let model = AgentViewModel(workspace: ws, client: client,
                                   configuration: AgentConfiguration(permissionMode: .ask, checkpointStorage: .memory))
        model.send("write it")
        for _ in 0..<500 where model.pendingApproval == nil { try await Task.sleep(for: .milliseconds(10)) }
        let request = try #require(model.pendingApproval)
        #expect(request.toolName == "write")
        model.respond(.allowOnce)
        try await waitUntilIdle(model)
        #expect(try String(contentsOf: ws.rootURL.appending(path: "a.txt"), encoding: .utf8) == "two\n")
    }

    @Test func markdownBlocks() {
        let md = "# Title\n\nSome *text*\nmore.\n\n- a\n- b\n\n1. x\n2. y\n\n> quote\n\n```c\nint x;\n```\n\n---\n```swift\nlet open"
        #expect(MarkdownBlock.parse(md) == [
            .heading(1, "Title"), .paragraph("Some *text*\nmore."), .list(["a", "b"], ordered: false),
            .list(["x", "y"], ordered: true), .quote("quote"), .code(language: "c", "int x;"), .rule,
            .code(language: "swift", "let open"),  // unterminated while streaming
        ])
    }
}
