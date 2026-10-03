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

    /// Review mode: a write and an edit become pending changes; Accept keeps
    /// one, Deny reverts the other, and the next turn tells the model.
    @Test func reviewCardAcceptsAndDeniesPerFile() async throws {
        let ws = try workspace(["main.c": "int main(void) { return 0; }\n"])
        let client = ScriptedLLMClient([
            .toolCalls([("write", ["path": "gcd.c", "content": "int gcd(int a, int b) { return b ? gcd(b, a % b) : a; }\n"]),
                        ("edit", ["path": "main.c", "edits": [["oldText": "return 0;", "newText": "return gcd(4, 6) != 2;"]]])]),
            .text("Created gcd.c and used it in main."),
            .text("Understood."),
        ])
        let model = AgentViewModel(workspace: ws, client: client,
                                   configuration: AgentConfiguration(permissionMode: .review, checkpointStorage: .memory))
        var opened: [String] = []
        var changed: [String] = []
        model.onOpenFile = { opened.append($0) }
        model.onFilesChanged = { changed.append(contentsOf: $0) }
        model.send("add gcd")
        try await waitUntilIdle(model)

        let changes = try #require(model.items.lazy.compactMap { item -> ChangeSet? in
            if case .changes(let c) = item.kind { return c } else { return nil }
        }.first)
        #expect(changes.files.map(\.path) == ["gcd.c", "main.c"])
        #expect(model.review == nil, "the card, not a sheet, presents the changes")
        #expect(model.pendingPaths == ["gcd.c", "main.c"])
        #expect(Set(changed) == ["gcd.c", "main.c"])

        model.acceptFile(changes, path: "gcd.c")
        #expect(model.reviewState(changes, path: "gcd.c") == .accepted)
        #expect(opened == ["gcd.c"])
        model.denyFile(changes, path: "main.c")
        for _ in 0..<200 where model.reviewState(changes, path: "main.c") != .denied {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.reviewState(changes, path: "main.c") == .denied)
        #expect(try String(contentsOf: ws.rootURL.appending(path: "main.c"), encoding: .utf8) == "int main(void) { return 0; }\n")
        #expect(FileManager.default.fileExists(atPath: ws.rootURL.appending(path: "gcd.c").path))
        #expect(model.pendingPaths.isEmpty)

        model.send("ok")
        try await waitUntilIdle(model)
        let last = try #require(client.requests.last)
        let texts = last.messages.compactMap { $0.role == .user ? $0.content : nil }
        #expect(texts.contains { $0.hasPrefix(Agent.reviewNotePrefix) && $0.contains("main.c") })
    }

    @Test func newChatsStartInReviewMode() async throws {
        let ws = try workspace([:])
        let model = AgentViewModel(workspace: ws, client: ScriptedLLMClient([]),
                                   configuration: AgentConfiguration(permissionMode: .review, checkpointStorage: .memory))
        model.mode = .readOnly
        model.newSession()
        #expect(model.mode == .review)
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
