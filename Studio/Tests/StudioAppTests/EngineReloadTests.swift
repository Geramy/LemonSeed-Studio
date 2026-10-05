import XCTest
import StudioAgent
import StudioAgentUI
@testable import LemonSeedStudio

/// A fake engine that answers chat completions the way LSE streams them:
/// a user turn that asks for a file gets a `write` tool call, a tool result
/// gets a short answer, anything else a greeting. Every request body is kept,
/// so a test can check what reached which engine.
final class ChatEngine: EngineHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    private(set) var closed = false
    var requests: [[String: Any]] { lock.withLock { bodies } }

    func request(method: String, path: String, body: Data?,
                 handler: @escaping @Sendable (EngineEvent) -> Void) throws -> UInt64 {
        if method == "GET" {
            // /health and /v1/models, as LSE 0.5.2 answers them.
            let answer: [String: Any] = path.hasSuffix("/health") ? ["status": "ok"]
                : ["object": "list", "data": [Self.modelEntry]]
            let data = try JSONSerialization.data(withJSONObject: answer)
            Thread { handler(.response(status: 200, body: data)) }.start()
            return 2
        }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        lock.withLock { bodies.append(json) }
        if (json["messages"] as? [[String: Any]])?.last?["content"] as? String == "fill the context" {
            // A reply that fills the context: LSE 0.5.2 ends it with
            // stop_reason context_full and lse_context in the final chunk.
            let chunks: [[String: Any]] = [
                Self.delta(["content": "A long answer that"]),
                ["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "length", "stop_reason": "context_full"]],
                 "lse_context": ["tokens_used": 4096, "context_length": 4096, "tokens_remaining": 0]],
            ]
            Thread {
                for c in chunks { handler(.chunk(try! JSONSerialization.data(withJSONObject: c))) }
                handler(.done)
            }.start()
            return 1
        }
        let messages = json["messages"] as? [[String: Any]] ?? []
        let last = messages.last ?? [:]
        let chunks: [[String: Any]]
        if (last["content"] as? String)?.contains("Summarize the session") == true {
            chunks = [Self.delta(["content": "## Goal\nGreet."]), Self.finish("stop")]
        } else if last["role"] as? String == "tool" {
            chunks = [Self.delta(["content": "Wrote it."]), Self.finish("stop")]
        } else if (last["content"] as? String)?.contains("file") == true {
            let arguments = #"{"path":"hello.c","content":"int main(void) { return 0; }\n"}"#
            chunks = [Self.delta(["reasoning_content": "Write the file."]),
                      Self.delta(["tool_calls": [["index": 0, "id": "call_1", "type": "function",
                                                  "function": ["name": "write", "arguments": arguments]]]]),
                      Self.finish("tool_calls")]
        } else if last["content"] as? String == "hi" {
            // A long first answer, so there is something older to compact.
            chunks = [Self.delta(["reasoning_content": "Greet."]),
                      Self.delta(["content": String(repeating: "Hello there, this is a long answer. ", count: 300)]),
                      Self.finish("stop")]
        } else {
            chunks = [Self.delta(["reasoning_content": "Greet."]), Self.delta(["content": "Hello."]), Self.finish("stop")]
        }
        Thread {
            for c in chunks {
                handler(.chunk(try! JSONSerialization.data(withJSONObject: c)))
                Thread.sleep(forTimeInterval: 0.005)
            }
            handler(.done)
        }.start()
        return 1
    }

    static func delta(_ d: [String: Any]) -> [String: Any] { ["choices": [["index": 0, "delta": d]]] }

    /// Qwen3.8's /v1/models entry (LSE docs/API.md), with a small context.
    nonisolated(unsafe) static let modelEntry: [String: Any] = [
        "id": "qwen-q4", "object": "model", "context_length": 4096, "max_tokens": NSNull(),
        "generation_defaults": ["temperature": 1.0, "top_k": 20, "top_p": 0.95, "min_p": 0.0,
                                "repetition_penalty": 1.0, "presence_penalty": 0.0, "sources": [String: String]()],
        "thinking": ["supported": true, "default_level": "xhigh", "levels": [
            ["id": "none", "enable_thinking": false, "default": false],
            ["id": "xhigh", "enable_thinking": true, "default": true],
            ["id": "medium", "enable_thinking": true, "default": false],
            ["id": "low", "enable_thinking": true, "default": false],
        ]],
    ]
    static func finish(_ reason: String) -> [String: Any] {
        ["choices": [["index": 0, "delta": [String: Any](), "finish_reason": reason]]]
    }

    func cancel(_ id: UInt64) {}
    func close() { lock.withLock { closed = true } }
    func status() -> [String: Any] { ["power": ["state": "active"], "requests": ["active": 0]] }
    func closeSession(_ id: String) -> Bool { true }
    func prepareLowPower(drainMilliseconds: UInt32) -> EnginePowerResult { .init(state: .suspended) }
    func resumeFromLowPower() -> EnginePowerResult { .init(state: .active) }
}

final class ChatEngines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ChatEngine] = []
    var opened: [ChatEngine] { lock.withLock { all } }

    var opener: EngineOpener {
        EngineOpener(isAvailable: true, version: "fake", supportsPower: true, supportsSessions: true,
                     open: { [self] _ in
                         let e = ChatEngine()
                         lock.withLock { all.append(e) }
                         return e
                     },
                     loadStatus: { [:] })
    }
}

@MainActor
final class EngineReloadTests: XCTestCase {
    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// Load a model, chat, unload it, load it again and go on in the same
    /// chat with a tool call: the chat continues on the new engine with its
    /// whole history and the same session, and the tool runs.
    func testAChatContinuesWithAToolAfterTheModelReloads() async throws {
        let engines = ChatEngines()
        let opened = { engines.opened }
        let engine = EngineService(opener: engines.opener)
        let launch = EngineLaunch(modelID: "fake-q4", modelName: "Fake Q4", modelDirectory: URL(fileURLWithPath: "/tmp/fake"))
        engine.start(launch)
        await waitFor("the engine to load") { engine.phase == .ready }

        let root = FileManager.default.temporaryDirectory.appending(path: "lemonseed-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = EndpointConfiguration(model: engine.servedName, contextWindow: engine.contextWindow)
        let client = OpenAICompatibleClient(configuration: endpoint, transport: engine.chatTransport())
        let model = AgentViewModel(workspace: LocalWorkspace(rootURL: root), client: client,
                                   configuration: AgentConfiguration(endpoint: endpoint, permissionMode: .autopilot,
                                                                     checkpointStorage: .memory))
        model.send("hi")
        await waitFor("the first reply") { !model.isRunning && opened().first?.requests.count == 1 }

        // Unload, then load the same model again.
        engine.stop()
        await waitFor("the engine to unload") { engine.phase == .idle }
        XCTAssertTrue(try XCTUnwrap(opened().first).closed)
        engine.start(launch)
        await waitFor("the engine to load again") { engine.phase == .ready && opened().count == 2 }

        model.send("make a file with the code")
        await waitFor("the tool call and the answer") { !model.isRunning && (opened().last?.requests.count ?? 0) == 2 }

        let written = try String(contentsOf: root.appending(path: "hello.c"), encoding: .utf8)
        XCTAssertEqual(written, "int main(void) { return 0; }\n")
        let errors = model.items.compactMap { item -> String? in
            if case .notice(let text, true) = item.kind { return text }
            if case .assistant(let b) = item.kind { return b.errorMessage }
            return nil
        }
        XCTAssertEqual(errors, [], "nothing failed")

        // The new engine got the whole conversation under the same session.
        let first = try XCTUnwrap(opened().first?.requests.first)
        let second = try XCTUnwrap(opened().last?.requests.first)
        XCTAssertEqual(second["session_id"] as? String, first["session_id"] as? String)
        let roles = (second["messages"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String }
        XCTAssertEqual(roles.filter { $0 != "system" }, ["user", "assistant", "user"])
        // And nothing capped the reply: no max_tokens at all.
        XCTAssertNil(second["max_tokens"])
        engine.stop()
    }

    /// The panel against LSE 0.5.2: the model's thinking levels from
    /// /v1/models, a reply that fills the context, and a compaction that
    /// runs only when the user taps Compact.
    func testModelLevelsAndContextFullThenCompactOnlyWhenAsked() async throws {
        let engines = ChatEngines()
        let engine = EngineService(opener: engines.opener)
        let launch = EngineLaunch(modelID: "fake-q4", modelName: "Fake Q4", modelDirectory: URL(fileURLWithPath: "/tmp/fake"))
        engine.start(launch)
        await waitFor("the engine to load") { engine.phase == .ready }
        let root = FileManager.default.temporaryDirectory.appending(path: "lemonseed-full-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = EndpointConfiguration(model: engine.servedName, contextWindow: engine.contextWindow)
        let client = OpenAICompatibleClient(configuration: endpoint, transport: engine.chatTransport())
        let model = AgentViewModel(workspace: LocalWorkspace(rootURL: root), client: client,
                                   configuration: AgentConfiguration(endpoint: endpoint, permissionMode: .autopilot,
                                                                     checkpointStorage: .memory))
        await model.checkEngine()
        XCTAssertEqual(model.thinkingLevels.map(\.id), ["none", "xhigh", "medium", "low"])
        XCTAssertEqual(model.shownThinkingLevel, "xhigh", "the model's default is shown")
        XCTAssertEqual(model.capabilities?.generationDefaults?.topK, 20)

        model.send("hi")
        await waitFor("the first reply") { !model.isRunning && (engines.opened.first?.requests.count ?? 0) == 1 }
        model.send("fill the context")
        await waitFor("the cut-off reply") { !model.isRunning && (engines.opened.first?.requests.count ?? 0) == 2 }
        let cards = model.items.compactMap { item -> ContextFullCard? in
            if case .contextFull(let card) = item.kind { return card }
            return nil
        }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.state, .offered)
        XCTAssertEqual(cards.first?.usage?.contextLength, 4096)
        // Nothing compacted on its own, and no request carried max_tokens.
        XCTAssertEqual(engines.opened.first?.requests.count, 2)
        XCTAssertTrue(engines.opened.first?.requests.allSatisfy { $0["max_tokens"] == nil } ?? false)
        XCTAssertNil(engines.opened.first?.requests.first?["reasoning_effort"], "the model's default level sends nothing")

        // Declining changes nothing.
        model.declineCompaction()
        XCTAssertEqual(engines.opened.first?.requests.count, 2)

        // The user asks: one summary request, then the card says it is done.
        model.compactConversation()
        await waitFor("the compaction") {
            !model.isRunning && model.items.contains { if case .contextFull(let c) = $0.kind { c.state != .compacting && c.state != .declined } else { false } }
        }
        XCTAssertEqual(engines.opened.first?.requests.count, 3)
        XCTAssertEqual(engines.opened.first?.requests.last?["reasoning_effort"] as? String, "none", "the summary does not think")
        let states = model.items.compactMap { item -> ContextFullCard.State? in
            if case .contextFull(let c) = item.kind { return c.state }
            return nil
        }
        XCTAssertEqual(states, [.compacted])
        XCTAssertTrue(model.items.contains { if case .compaction = $0.kind { true } else { false } })
        engine.stop()
    }
}
