import XCTest
import SwiftUI
import StudioAgent
@testable import StudioAgentUI

/// The AI panel while a long reply streams: the main-thread time each
/// update takes must not grow with how much has streamed already.
///
/// The panel is hosted in a real window. Each update is one coalesced flush
/// (what the view model applies about 30 times a second) followed by the
/// SwiftUI update and layout it causes, timed on the main thread.
@MainActor
final class StreamingPerformanceTests: XCTestCase {
    /// Tokens per update: more than a fast decode delivers per flush.
    static let tokensPerUpdate = 25

    private struct Run {
        var milliseconds: [Double] = []
        func mean(_ range: Range<Double>) -> Double {
            let lo = Int(Double(milliseconds.count) * range.lowerBound)
            let hi = max(lo + 1, Int(Double(milliseconds.count) * range.upperBound))
            let slice = milliseconds[lo..<min(hi, milliseconds.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
        var total: Double { milliseconds.reduce(0, +) }
    }

    private func host(_ model: AgentViewModel) -> (UIWindow, UIHostingController<AnyView>) {
        let controller = UIHostingController(rootView: AnyView(AgentPanel(model: model).agentTheme(.standard)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 520, height: 1100))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    private func settle(_ view: UIView) {
        RunLoop.main.run(until: Date())
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// A model-like stream: words, line breaks, paragraphs, now and then a
    /// list or a fenced block.
    static func piece(_ i: Int) -> String {
        if i % 400 == 399 { return "\n\n```swift\nlet x = \(i)\n```\n\n" }
        if i % 180 == 179 { return "\n\n- item \(i)\n- item \(i + 1)\n\n" }
        if i % 90 == 89 { return ".\n\n" }
        if i % 30 == 29 { return ",\n" }
        return ["the ", "model ", "keeps ", "thinking ", "about ", "it ", "and "][i % 7]
    }

    private func stream(_ model: AgentViewModel, view: UIView, tokens: Int, reasoning: Bool) -> Run {
        var run = Run()
        var i = 0
        while i < tokens {
            let start = CACurrentMediaTime()
            for _ in 0..<Self.tokensPerUpdate {
                model.apply(reasoning ? .reasoningDelta(Self.piece(i)) : .textDelta(Self.piece(i)))
                i += 1
            }
            model.apply(.turnStart(index: 1))  // any other event flushes the coalesced deltas
            settle(view)
            run.milliseconds.append((CACurrentMediaTime() - start) * 1000)
        }
        return run
    }

    private func report(_ name: String, _ run: Run) {
        let line = String(format: "%@: %d updates, first 10%% %.2f ms, middle %.2f ms, last 10%% %.2f ms, total %.0f ms",
                          name, run.milliseconds.count, run.mean(0..<0.1), run.mean(0.45..<0.55), run.mean(0.9..<1),
                          run.total)
        print("STREAMING-PERF " + line)
        add(XCTAttachment(string: line))
    }

    func testLongReasoningThenAnswerStayFlat() throws {
        let tokens = Int(ProcessInfo.processInfo.environment["STREAM_TOKENS"] ?? "") ?? 50_000
        let model = AgentViewModel(workspace: LocalWorkspace(rootURL: FileManager.default.temporaryDirectory),
                                   client: ScriptedLLMClient([]))
        let (window, controller) = host(model)
        defer { window.isHidden = true }
        model.apply(.agentStart)
        model.apply(.assistantStart)
        settle(controller.view)

        let thinking = stream(model, view: controller.view, tokens: tokens, reasoning: true)
        report("reasoning \(tokens) tokens", thinking)
        let answer = stream(model, view: controller.view, tokens: tokens / 2, reasoning: false)
        report("answer \(tokens / 2) tokens", answer)

        // Flat: the last updates cost about what the first ones did.
        for (name, run) in [("reasoning", thinking), ("answer", answer)] {
            let first = run.mean(0..<0.1), last = run.mean(0.9..<1)
            XCTAssertLessThan(last, max(first * 2, first + 4), "\(name): an update grows with the stream (\(first) → \(last) ms)")
        }
        XCTAssertLessThan(thinking.mean(0.9..<1), 16, "a reasoning update fits in a frame")
    }

    /// The same stream measured by XCTest (clock and CPU time).
    func testStreamingMetrics() {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            let model = AgentViewModel(workspace: LocalWorkspace(rootURL: FileManager.default.temporaryDirectory),
                                       client: ScriptedLLMClient([]))
            let (window, controller) = host(model)
            model.apply(.agentStart)
            model.apply(.assistantStart)
            _ = stream(model, view: controller.view, tokens: 10_000, reasoning: true)
            window.isHidden = true
        }
    }
}
