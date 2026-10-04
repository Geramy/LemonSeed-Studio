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
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        lock.withLock { bodies.append(json) }
        let messages = json["messages"] as? [[String: Any]] ?? []
        let last = messages.last ?? [:]
        let chunks: [[String: Any]]
        if last["role"] as? String == "tool" {
            chunks = [Self.delta(["content": "Wrote it."]), Self.finish("stop")]
        } else if (last["content"] as? String)?.contains("file") == true {
            let arguments = #"{"path":"hello.c","content":"int main(void) { return 0; }\n"}"#
            chunks = [Self.delta(["reasoning_content": "Write the file."]),
                      Self.delta(["tool_calls": [["index": 0, "id": "call_1", "type": "function",
                                                  "function": ["name": "write", "arguments": arguments]]]]),
                      Self.finish("tool_calls")]
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
        let endpoint = EndpointConfiguration(model: engine.servedName, contextWindow: engine.contextWindow,
                                             maxOutputTokens: engine.replyLimit)
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
        // And no constant capped the reply: it may use what the context has left.
        XCTAssertGreaterThan(second["max_tokens"] as? Int ?? 0, 2048)
        engine.stop()
    }
}
