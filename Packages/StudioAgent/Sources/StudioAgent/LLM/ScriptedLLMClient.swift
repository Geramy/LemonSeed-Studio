import Foundation
import Synchronization

/// A client that replays prepared replies, one per request. Used by tests,
/// SwiftUI previews and the demo app's offline mode.
public final class ScriptedLLMClient: LLMClient, Sendable {
    public struct Reply: Sendable {
        public var events: [ChatStreamEvent]
        public var error: LLMError?

        public init(events: [ChatStreamEvent], error: LLMError? = nil) {
            self.events = events
            self.error = error
        }

        /// A plain text answer, streamed in small pieces.
        public static func text(_ s: String, reasoning: String? = nil, chunk: Int = 12) -> Reply {
            var ev: [ChatStreamEvent] = []
            if let reasoning { ev += pieces(reasoning, chunk).map(ChatStreamEvent.reasoningDelta) }
            ev += pieces(s, chunk).map(ChatStreamEvent.contentDelta)
            ev.append(.finished(.stop))
            ev.append(.timings(.sample))
            return Reply(events: ev)
        }

        /// Tool calls, optionally preceded by text and reasoning.
        public static func toolCalls(_ calls: [(name: String, arguments: JSONValue)], text: String? = nil,
                                     reasoning: String? = nil) -> Reply {
            var ev: [ChatStreamEvent] = []
            if let reasoning { ev += pieces(reasoning, 12).map(ChatStreamEvent.reasoningDelta) }
            if let text { ev += pieces(text, 12).map(ChatStreamEvent.contentDelta) }
            for (i, c) in calls.enumerated() {
                ev.append(.toolCallDelta(index: i, id: "call_scripted_\(UUID().uuidString.prefix(8))_\(i)",
                                         name: c.name, arguments: c.arguments.serialized()))
            }
            ev.append(.finished(.toolCalls))
            ev.append(.timings(.sample))
            return Reply(events: ev)
        }

        static func pieces(_ s: String, _ n: Int) -> [String] {
            var out: [String] = []
            var cur = ""
            for ch in s {
                cur.append(ch)
                if cur.count >= n { out.append(cur); cur = "" }
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }
    }

    private let state: Mutex<(replies: [Reply], requests: [ChatRequest])>
    private let delay: Duration

    public init(_ replies: [Reply], delay: Duration = .zero) {
        state = Mutex((replies, []))
        self.delay = delay
    }

    /// Requests received so far.
    public var requests: [ChatRequest] { state.withLock { $0.requests } }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let reply: Reply? = state.withLock {
            $0.requests.append(request)
            return $0.replies.isEmpty ? nil : $0.replies.removeFirst()
        }
        let delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let reply else {
                    continuation.yield(.contentDelta("(no scripted reply left)"))
                    continuation.yield(.finished(.stop))
                    continuation.finish()
                    return
                }
                for e in reply.events {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    continuation.yield(e)
                }
                if let error = reply.error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension GenerationTimings {
    /// Representative numbers for previews (Qwen3.8-27B Q4 with DFlash2).
    public static let sample = GenerationTimings(
        promptTokens: 214, promptCachedTokens: 1873, promptMilliseconds: 1010, promptPerSecond: 211.9,
        decodeTokens: 182, decodeMilliseconds: 4011, decodePerSecond: 45.4, acceptanceRate: 0.81,
        speculationMethod: "dflash2", speculationDepth: 7)
}
