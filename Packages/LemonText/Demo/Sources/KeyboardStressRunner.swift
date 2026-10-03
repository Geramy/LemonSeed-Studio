import LemonText

import SwiftUI
import UIKit

/// Replays hardware-keyboard input the way UIKit delivers it to a `UITextInput` first responder, and checks
/// the buffer after each burst. Launch with `-keyboardStress`; results are published on the
/// `stress.result` accessibility element and written to `Documents/keyboard-stress.json`.
///
/// For a key press on a hardware keyboard UIKit calls `insertText(_:)` for characters, Return ("\n") and Tab;
/// for Delete it selects what to remove (the previous character, the previous word with Option, the line
/// with Command) and calls `deleteBackward()`; arrows move or extend `selectedTextRange` through the
/// tokenizer and `position(from:in:offset:)`. Held keys repeat the same call about every 33 ms.
@MainActor
final class KeyboardStressRunner {
    struct CaseResult: Codable {
        var name: String
        var passed: Bool
        var detail: String
    }

    struct Report: Codable {
        var cases: [CaseResult]
        var largeFileLines: Int
        var largeFileKeystrokes: Int
        var latencyP50: Double
        var latencyP95: Double
        var latencyP99: Double
        var latencyMax: Double
        var passed: Bool { cases.allSatisfy(\.passed) }
    }

    private let controller: LemonTextViewController
    private var results: [CaseResult] = []
    private var textView: TextView { controller.textView }

    init(controller: LemonTextViewController) {
        self.controller = controller
    }

    // MARK: Key presses as UIKit performs them

    private func type(_ text: String) async {
        for character in text {
            textView.insertText(String(character))
            await keyRepeatInterval()
        }
    }

    private func pressReturn() async {
        textView.insertText("\n")
        await keyRepeatInterval()
    }

    /// Delete: UIKit selects the character before the caret and calls deleteBackward().
    private func pressDelete(times: Int = 1) async {
        for _ in 0 ..< times {
            if let range = textView.selectedTextRange, range.isEmpty,
               let previous = textView.position(from: range.start, offset: -1),
               let selection = textView.textRange(from: previous, to: range.start) {
                textView.selectedTextRange = selection
            }
            textView.deleteBackward()
            await keyRepeatInterval()
        }
    }

    /// Delete with a collapsed selection, as some input paths call it.
    private func pressRawDelete(times: Int) async {
        for _ in 0 ..< times {
            textView.deleteBackward()
            await keyRepeatInterval()
        }
    }

    /// Option-Delete and Command-Delete: select back to the word or line boundary, then delete.
    private func pressDelete(to granularity: UITextGranularity) async {
        guard let range = textView.selectedTextRange,
              let boundary = textView.tokenizer.position(from: range.start, toBoundary: granularity, inDirection: .storage(.backward)),
              let selection = textView.textRange(from: boundary, to: range.start) else {
            return
        }
        textView.selectedTextRange = selection
        textView.deleteBackward()
        await keyRepeatInterval()
    }

    /// Fn-Delete: select the character after the caret, then delete.
    private func pressForwardDelete() async {
        guard let range = textView.selectedTextRange, let next = textView.position(from: range.end, offset: 1),
              let selection = textView.textRange(from: range.end, to: next) else {
            return
        }
        textView.selectedTextRange = selection
        textView.deleteBackward()
        await keyRepeatInterval()
    }

    private func pressArrow(_ direction: UITextLayoutDirection, extending: Bool = false, times: Int = 1) async {
        for _ in 0 ..< times {
            guard let range = textView.selectedTextRange else { return }
            let anchor = range.start
            let moving = extending ? range.start : (direction == .left || direction == .up ? range.start : range.end)
            guard let target = textView.position(from: moving, in: direction, offset: 1) else { return }
            if extending {
                textView.selectedTextRange = textView.textRange(from: target, to: range.end) ?? range
            } else {
                textView.selectedTextRange = textView.textRange(from: target, to: target)
            }
            _ = anchor
            await keyRepeatInterval()
        }
    }

    private func pressArrow(to granularity: UITextGranularity, forward: Bool) async {
        guard let range = textView.selectedTextRange,
              let target = textView.tokenizer.position(from: forward ? range.end : range.start, toBoundary: granularity,
                                                       inDirection: .storage(forward ? .forward : .backward)) else {
            return
        }
        textView.selectedTextRange = textView.textRange(from: target, to: target)
        await keyRepeatInterval()
    }

    private func keyRepeatInterval() async {
        // Yield to the run loop between key events, like the 30 Hz key repeat does.
        try? await Task.sleep(for: .milliseconds(2))
    }

    // MARK: Cases

    private func reset(_ text: String, caret: Int? = nil, autoClose: Bool = false) async {
        var configuration = controller.configuration
        configuration.autoClosePairs = autoClose
        controller.configuration = configuration
        await withCheckedContinuation { continuation in
            controller.load(text: text, language: .c) { _ in continuation.resume() }
        }
        controller.selectedRange = NSRange(location: caret ?? (text as NSString).length, length: 0)
        _ = textView.becomeFirstResponder()
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func check(_ name: String, _ expected: String) {
        let actual = controller.text
        results.append(CaseResult(name: name, passed: actual == expected,
                                  detail: actual == expected ? "ok" : "expected \(expected.debugDescription), got \(actual.debugDescription)"))
    }

    private func check(_ name: String, caret expected: Int) {
        let actual = controller.selectedRange.location
        results.append(CaseResult(name: name, passed: actual == expected, detail: "caret \(actual), expected \(expected)"))
    }

    func run() async -> Report {
        await reset("")
        await type("int x = 1;")
        await pressDelete(times: 3)
        check("type then delete", "int x =")
        await pressRawDelete(times: 2)
        check("delete with a collapsed selection", "int x")

        await reset("x")
        await type(String(repeating: " ", count: 60))
        check("held space", "x" + String(repeating: " ", count: 60))
        await type(String(repeating: "a", count: 200))
        await pressDelete(times: 230)
        check("held key then held delete", "x" + String(repeating: " ", count: 30))

        // In leading whitespace Delete removes one indentation level at a time (soft tabs).
        await reset("")
        await type(String(repeating: " ", count: 12))
        await pressDelete(times: 1)
        check("delete in indentation removes a level", String(repeating: " ", count: 8))

        await reset("")
        await type("void f(void) {")
        await pressReturn()
        await type("g();")
        check("return indents inside a block", "void f(void) {\n    g();")

        await reset("foo bar baz")
        await pressDelete(to: .word)
        check("option-delete removes a word", "foo bar ")

        await reset("    foo bar")
        await pressDelete(to: .line)
        let afterLineDelete = controller.text
        results.append(CaseResult(name: "command-delete removes to the line start",
                                  passed: !afterLineDelete.contains("foo"), detail: afterLineDelete.debugDescription))

        await reset("abc", caret: 0)
        await pressForwardDelete()
        check("forward delete", "bc")

        await reset("int x = 42;")
        await pressArrow(.left, extending: true, times: 3)
        await type("7;")
        check("shift-left selects, typing replaces", "int x = 7;")

        await reset("hello world")
        await pressArrow(to: .word, forward: false)
        check("option-left moves by word", caret: 6)
        await pressArrow(to: .line, forward: false)
        check("command-left moves to the line start", caret: 0)
        await pressArrow(to: .line, forward: true)
        check("command-right moves to the line end", caret: 11)
        await pressArrow(.left, times: 5)
        check("left arrow repeats", caret: 6)

        await reset("let a = 1\n")
        try? await Task.sleep(for: .milliseconds(1100)) // close the previous undo group
        await type("zzz")
        textView.undoManager?.undo()
        check("undo", "let a = 1\n")
        textView.undoManager?.redo()
        check("redo", "let a = 1\nzzz")

        await reset("", autoClose: true)
        await type("f(")
        check("bracket auto-close", "f()")
        await type("x)")
        check("typing the closing bracket steps over it", "f(x)")
        await pressDelete(times: 4)
        check("delete through the pair", "")

        await reset("a = 1;\nb = 1;\nc = 1;")
        controller.selections = [NSRange(location: 1, length: 0), NSRange(location: 8, length: 0), NSRange(location: 15, length: 0)]
        await type("x")
        await pressDelete(times: 1)
        await type("yz")
        check("several carets", "ayz = 1;\nbyz = 1;\ncyz = 1;")

        let large = await runLargeFile()
        return Report(cases: results, largeFileLines: large.lines, largeFileKeystrokes: large.latency.count,
                      latencyP50: large.latency.p50, latencyP95: large.latency.p95, latencyP99: large.latency.p99,
                      latencyMax: large.latency.max)
    }

    /// Bursts of typing and deleting in the middle of a large file; the buffer must come back unchanged.
    private func runLargeFile() async -> (lines: Int, latency: EditorBenchmark.Distribution) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let source: String
        if let sqlite = try? String(contentsOf: documents.appendingPathComponent("sqlite3.c"), encoding: .utf8) {
            source = sqlite
        } else {
            // Without the amalgamation, synthesize a C file of similar size from the bundled sample.
            let sample = Sample(fileName: "ring_buffer.c").load()
            source = String(repeating: sample, count: 9_500_000 / max(sample.utf8.count, 1))
        }
        await reset(source)
        while controller.isHighlighting {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let middle = controller.lineCount / 2
        controller.goToLine(middle)
        if let range = textView.range(ofLine: middle - 1) {
            controller.selectedRange = NSRange(location: range.location + range.length, length: 0)
        }
        let before = controller.textSnapshot()
        controller.resetKeystrokeLatency()
        for burst in 0 ..< 3 {
            let text = String(repeating: "q", count: 60) + " lemon_\(burst); "
            await type(text)
            await pressDelete(times: text.count)
        }
        let latency = controller.keystrokeLatency()
        let after = controller.textSnapshot()
        results.append(CaseResult(name: "large file bursts restore the buffer", passed: before.isEqual(to: after as String),
                                  detail: "\(before.length) vs \(after.length) UTF-16 units"))
        return (controller.lineCount, latency)
    }
}

/// Hosts the stress run.
struct KeyboardStressView: View {
    @State private var model = LemonTextEditorModel(language: .c, theme: .lemonDark)
    @State private var result = "running"

    var body: some View {
        VStack(spacing: 0) {
            LemonTextEditor(model: model)
            Text(result)
                .font(.caption.monospaced())
                .lineLimit(3)
                .padding(8)
                .accessibilityIdentifier("stress.result")
                .accessibilityLabel(result)
        }
        .task { await run() }
    }

    private func run() async {
        while model.controller?.view.window == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let controller = model.controller else { return }
        var configuration = controller.configuration
        configuration.showMinimap = false
        controller.configuration = configuration
        controller.showsSoftwareKeyboard = false
        let report = await KeyboardStressRunner(controller: controller).run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("keyboard-stress.json")
            try? data.write(to: url)
        }
        let failures = report.cases.filter { !$0.passed }.map { "\($0.name): \($0.detail)" }
        result = String(format: "done;passed=%d;failed=%d;keys=%d;p50=%.2f;p99=%.2f;max=%.2f;failures=%@",
                        report.cases.count - failures.count, failures.count, report.largeFileKeystrokes,
                        report.latencyP50, report.latencyP99, report.latencyMax, failures.joined(separator: " | "))
    }
}
