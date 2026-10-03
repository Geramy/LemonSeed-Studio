import Foundation
import Synchronization
import Testing
@testable import StudioAgent

/// Round trips against a running LemonSeed Engine server.
///
/// The endpoint defaults to http://127.0.0.1:8080/v1 with model "qwen-q4"
/// (override with LSE_BASE_URL and LSE_MODEL). The tests send small requests
/// only and never manage the server; when /health does not answer within two
/// seconds they are skipped and say so.
enum LiveLSE {
    static let endpoint: EndpointConfiguration = {
        let env = ProcessInfo.processInfo.environment
        return EndpointConfiguration(
            baseURL: env["LSE_BASE_URL"].flatMap(URL.init(string:)) ?? EndpointConfiguration.defaultBaseURL,
            model: env["LSE_MODEL"] ?? "qwen-q4", maxOutputTokens: 384, requestTimeout: 600)
    }()

    static let isAvailable: Bool = {
        let url = endpoint.baseURL.deletingLastPathComponent().appending(path: "health")
        let done = DispatchSemaphore(value: 0)
        let ok = Mutex(false)
        let task = URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 2)) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let data, (try? JSONValue.parse(data))?["status"] == "ok" { ok.withLock { $0 = true } }
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + 3)
        let available = ok.withLock { $0 }
        if !available {
            print("LiveLSE: SKIPPED. No LSE server answered at \(url.absoluteString); start lse-server to run these tests.")
        }
        return available
    }()

    static func report(_ label: String, _ t: GenerationTimings?) {
        guard let t else { print("LiveLSE \(label): no timings"); return }
        func f(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "n/a" }
        print("LiveLSE \(label): prompt \(t.promptTokens.map(String.init) ?? "n/a") tok (+\(t.promptCachedTokens.map(String.init) ?? "n/a") cached) "
              + "at \(f(t.promptPerSecond)) tok/s; decode \(t.decodeTokens.map(String.init) ?? "n/a") tok at "
              + "\(f(t.decodePerSecond)) tok/s; acceptance \(t.acceptanceRate.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a") "
              + "(\(t.speculationMethod ?? "none")×\(t.speculationDepth.map(String.init) ?? "-"))")
    }
}

@Suite("Live LSE round trip", .serialized, .enabled(if: LiveLSE.isAvailable, "LSE server not reachable"))
struct LiveLSETests {
    @Test(.timeLimit(.minutes(10)))
    func clientStreamsANativeToolCallAndItsAnswer() async throws {
        let client = OpenAICompatibleClient(configuration: LiveLSE.endpoint)
        #expect(try await client.models().contains(LiveLSE.endpoint.model))
        let tools = [ReadTool().definition]
        var messages: [ChatMessage] = [
            .system("You are a test harness assistant. Use tools when asked."),
            .user("Call the read tool on the path \"secret.txt\". Do not answer before reading it."),
        ]
        let first = try await client.complete(ChatRequest(model: LiveLSE.endpoint.model, messages: messages,
                                                          tools: tools, maxTokens: 128, thinking: .off))
        LiveLSE.report("tool turn", first.timings)
        #expect(first.finishReason == .toolCalls)
        let call = try #require(first.toolCalls.first)
        #expect(call.name == "read")
        #expect(call.parsedArguments?["path"]?.stringValue?.contains("secret.txt") == true)

        messages.append(ChatMessage(role: .assistant, content: first.content,
                                    reasoningContent: first.reasoning.isEmpty ? nil : first.reasoning,
                                    toolCalls: [call]))
        messages.append(.tool(id: call.id, "1\tThe code word is marigold-826."))
        let second = try await client.complete(ChatRequest(model: LiveLSE.endpoint.model, messages: messages,
                                                           tools: tools, maxTokens: 64, thinking: .off))
        LiveLSE.report("answer turn", second.timings)
        #expect(second.content.contains("marigold-826"))
        #expect(second.usage != nil)
    }

    @Test(.timeLimit(.minutes(10)))
    func agentReadsAFileInATempWorkspaceAndAnswers() async throws {
        let ws = try TempWorkspace(["secret.txt": "The code word is sapphire-517.\n",
                                    "AGENTS.md": "Answers in this project are a single line."])
        let client = OpenAICompatibleClient(configuration: LiveLSE.endpoint)
        let agent = try Agent.start(
            workspace: ws.workspace, client: client, approver: DenyingApprover(),
            configuration: AgentConfiguration(endpoint: LiveLSE.endpoint, thinking: .off, permissionMode: .review,
                                              maxTurns: 4, checkpointStorage: .memory))
        let started = Date()
        let events = await collect(agent.prompt(
            "Use the read tool to read secret.txt, then reply with only the code word it contains."))
        let elapsed = Date().timeIntervalSince(started)

        let calls = events.compactMap { if case .toolExecutionEnd(_, let n, let o, _) = $0 { (n, o) } else { nil } }
        let answer = events.compactMap { if case .assistantEnd(let m, _) = $0 { m.text } else { nil } }.last ?? ""
        for case .turnEnd(let i, let t, let u, _) in events {
            LiveLSE.report("agent turn \(i) (usage: \(u.map { "\($0.promptTokens) prompt, \($0.cachedPromptTokens) cached, \($0.completionTokens) out" } ?? "n/a"))", t)
        }
        print("LiveLSE agent: \(calls.count) tool call(s) \(calls.map(\.0)), answer \"\(answer)\", \(String(format: "%.1f", elapsed)) s")
        #expect(events.last == .agentEnd(.completed))
        #expect(calls.first?.0 == "read")
        #expect(calls.first?.1.isError == false)
        #expect(answer.contains("sapphire-517"))
        // The session file is a valid pi v3 session.
        let doc = try SessionDocument(jsonl: String(contentsOf: agent.sessionURL, encoding: .utf8))
        #expect(doc.contextMessages().map(\.role) == ["system", "user", "assistant", "toolResult", "assistant"])
    }
}
