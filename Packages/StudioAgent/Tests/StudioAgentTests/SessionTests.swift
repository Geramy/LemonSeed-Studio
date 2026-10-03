import Foundation
import Testing
@testable import StudioAgent

@Suite("pi v3 sessions")
struct SessionTests {
    /// Lines in the shapes pi's session-format.md documents, including fields
    /// this agent does not model (they must survive a round trip).
    static let piSession = """
    {"type":"session","version":3,"id":"8c5e1b9a-1111-4a2b-9c3d-000000000001","timestamp":"2024-12-03T14:00:00.000Z","cwd":"/project"}
    {"type":"message","id":"a0b1c2d3","parentId":null,"timestamp":"2024-12-03T14:00:00.000Z","message":{"role":"system","content":"","sections":{"preamble":"You are an expert coding assistant...","cwd":"/project"},"toolsAdded":[{"name":"read","description":"Read a file","parameters":{"type":"object"}}],"timestamp":1733234400000}}
    {"type":"message","id":"a1b2c3d4","parentId":"a0b1c2d3","timestamp":"2024-12-03T14:00:01.000Z","message":{"role":"user","content":"Hello","timestamp":1733234401000}}
    {"type":"message","id":"b2c3d4e5","parentId":"a1b2c3d4","timestamp":"2024-12-03T14:00:02.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"greet","thinkingSignature":"sig"},{"type":"text","text":"Hi!"},{"type":"toolCall","id":"call_123","name":"read","arguments":{"path":"a.c"}}],"api":"openai-completions","provider":"lse","model":"qwen-q4","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":0,"reasoning":1,"totalTokens":17,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","thinkingLevel":"low","timestamp":1733234402000}}
    {"type":"message","id":"c3d4e5f6","parentId":"b2c3d4e5","timestamp":"2024-12-03T14:00:03.000Z","message":{"role":"toolResult","toolCallId":"call_123","toolName":"read","content":[{"type":"text","text":"output"}],"details":{"lines":1},"isError":false,"timestamp":1733234403000}}
    {"type":"model_change","id":"d4e5f6a7","parentId":"c3d4e5f6","timestamp":"2024-12-03T14:05:00.000Z","provider":"openai","modelId":"gpt-4o"}
    {"type":"thinking_level_change","id":"e5f6a7b8","parentId":"d4e5f6a7","timestamp":"2024-12-03T14:06:00.000Z","thinkingLevel":"high"}
    {"type":"usage","id":"f6a7b8c9","parentId":"e5f6a7b8","timestamp":"2024-12-03T14:08:00.000Z","kind":"cache_warm","provider":"lse","model":"qwen-q4","usage":{"input":0,"output":0,"cacheRead":50000,"cacheWrite":0,"totalTokens":50000,"cost":{"input":0,"output":0,"cacheRead":0.015,"cacheWrite":0,"total":0.015}}}
    {"type":"custom","id":"h8i9j0k1","parentId":"f6a7b8c9","timestamp":"2024-12-03T14:20:00.000Z","customType":"my-extension","data":{"count":42}}
    {"type":"custom_message","id":"i9j0k1l2","parentId":"h8i9j0k1","timestamp":"2024-12-03T14:25:00.000Z","customType":"my-extension","content":"Injected context...","display":true,"details":{"x":1}}
    {"type":"label","id":"j0k1l2m3","parentId":"i9j0k1l2","timestamp":"2024-12-03T14:30:00.000Z","targetId":"a1b2c3d4","label":"checkpoint-1"}
    {"type":"session_info","id":"k1l2m3n4","parentId":"j0k1l2m3","timestamp":"2024-12-03T14:35:00.000Z","name":"Refactor auth module"}
    {"type":"future_entry","id":"l2m3n4o5","parentId":"k1l2m3n4","timestamp":"2024-12-03T14:36:00.000Z","whatever":[1,2,3]}
    """

    @Test func roundTripsEveryLineLosslessly() throws {
        let doc = try SessionDocument(jsonl: Self.piSession)
        let lines = Self.piSession.split(separator: "\n").map(String.init)
        let out = doc.jsonl().split(separator: "\n").map(String.init)
        #expect(out.count == lines.count)
        for (a, b) in zip(lines, out) {
            #expect(try JSONValue.parse(a) == JSONValue.parse(b), "\(a)")
        }
        // And a second pass is byte-identical (deterministic serialization).
        #expect(try SessionDocument(jsonl: doc.jsonl()).jsonl() == doc.jsonl())
    }

    @Test func readsTypedFields() throws {
        let doc = try SessionDocument(jsonl: Self.piSession)
        #expect(doc.header.cwd == "/project")
        #expect(doc.name == "Refactor auth module")
        #expect(doc.firstUserText == "Hello")
        #expect(doc.thinkingLevel == "high")
        #expect(doc.leafId == "l2m3n4o5")
        guard case .message(.assistant(let a)) = doc.entry("b2c3d4e5")?.payload else { Issue.record(); return }
        #expect(a.thinking == "greet")
        #expect(a.toolCalls == [ToolCall(id: "call_123", name: "read", arguments: #"{"path":"a.c"}"#)])
        #expect(a.usage.cacheRead == 2)
        #expect(a.stopReason == .toolUse)
        let state = doc.systemState()
        #expect(state.prompt == "You are an expert coding assistant...\n\n/project")
        #expect(state.tools.map(\.name) == ["read"])
    }

    @Test func buildsContextWithCompactionContextEditsAndBranches() throws {
        var doc = SessionDocument(header: SessionHeader(cwd: "/w"))
        doc.append(.message(.system(.init(sections: ["preamble": "P"]))))
        let u1 = doc.append(.message(.user(.init(text: "first"))))
        doc.append(.message(.assistant(.init(content: [.text("one")], model: "m", stopReason: .stop))))
        let u2 = doc.append(.message(.user(.init(text: "second"))))
        let a2 = doc.append(.message(.assistant(.init(content: [.text("two")], model: "m", stopReason: .stop))))
        doc.append(.contextEdit(targetId: a2.id, replacement: .string("TWO")))
        doc.append(.compaction(summary: "S", firstKeptEntryId: u2.id, tokensBefore: 100,
                               systemMessage: .system(.init(sections: ["preamble": "P2"], replace: true)), details: nil))
        doc.append(.message(.user(.init(text: "third"))))

        let roles = doc.contextMessages().map(\.role)
        #expect(roles == ["system", "compactionSummary", "user", "assistant", "user"])
        let wire = WireConverter.messages(systemPrompt: doc.systemState().prompt, context: doc.contextMessages())
        #expect(wire.map(\.content) == ["P2", WireConverter.compactionPrefix + "S" + WireConverter.compactionSuffix,
                                        "second", "TWO", "third"])

        // Branch from the first user message: the other path disappears from context.
        doc.moveLeaf(to: u1.id)
        doc.append(.branchSummary(fromId: a2.id, summary: "tried B"))
        doc.append(.message(.user(.init(text: "alt"))))
        #expect(doc.contextMessages().map(\.role) == ["system", "user", "branchSummary", "user"])
        #expect(doc.children(of: u1.id).count == 2)
    }

    @Test func storeWritesAppendOnlyJSONLAndListsSessions() throws {
        let ws = try TempWorkspace()
        let store = SessionStore(workspace: ws.workspace)
        var (url, doc) = try store.create(cwd: ws.root.path)
        #expect(url.path.contains("/.lemonseed/sessions/"))
        #expect(url.lastPathComponent.hasSuffix("_\(doc.header.id).jsonl"))
        let e1 = doc.append(.message(.user(.init(text: "Fix the build"))))
        let e2 = doc.append(.message(.assistant(.init(content: [.text("On it.")], model: "qwen-q4", stopReason: .stop))))
        try store.append([e1, e2], to: url)
        try store.append([doc.append(.sessionInfo(name: "Build fix"))], to: url)

        let loaded = try store.load(url)
        #expect(loaded.jsonl() == doc.jsonl())
        let list = store.list()
        #expect(list.count == 1)
        #expect(list[0].title == "Build fix")
        #expect(list[0].messageCount == 2)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").first?.contains(#""type":"session""#) == true)
        #expect(text.split(separator: "\n").first?.contains(#""version":3"#) == true)
    }

    @Test func migratesLinearV1Files() throws {
        let v1 = """
        {"type":"session","id":"x","timestamp":"2024-01-01T00:00:00.000Z","cwd":"/"}
        {"type":"message","id":"aaaaaaaa","timestamp":"2024-01-01T00:00:01.000Z","message":{"role":"user","content":"hi","timestamp":1}}
        {"type":"message","id":"bbbbbbbb","timestamp":"2024-01-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"yo"}],"api":"","provider":"","model":"","usage":{},"stopReason":"stop","timestamp":2}}
        """
        let doc = try SessionDocument(jsonl: v1)
        #expect(doc.header.version == 3)
        #expect(doc.entry("bbbbbbbb")?.parentId == "aaaaaaaa")
        #expect(doc.contextMessages().count == 2)
    }
}
