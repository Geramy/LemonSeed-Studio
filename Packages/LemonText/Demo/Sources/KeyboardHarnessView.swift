import LemonText
import SwiftUI

/// A bare editor for hardware-keyboard tests. Launch with `-keyboardHarness`, plus `-harnessText <text>`
/// (with `\n` for line breaks) or `-document <file in Documents>`, `-harnessLine <n>` to put the caret at the
/// end of line n, and `-autoclose 0` to turn off bracket auto-closing.
///
/// It publishes the editor's state through accessibility so UI tests can check the buffer:
/// `harness.status` carries `length`, an FNV-1a `hash` of the UTF-16 text, the `caret`, keystroke latency
/// percentiles and `idle=1` once the state is up to date; `harness.text` carries the text of small documents.
struct KeyboardHarnessView: View {
    @State private var model: LemonTextEditorModel
    @State private var status = "idle=0"
    @State private var text = ""
    @State private var revision = 0
    private let options = HarnessOptions.current

    init() {
        var configuration = EditorConfiguration()
        configuration.showMinimap = false
        configuration.autoClosePairs = HarnessOptions.current.autoClose
        _model = State(initialValue: LemonTextEditorModel(language: .c, theme: .lemonDark, configuration: configuration))
    }

    var body: some View {
        VStack(spacing: 0) {
            LemonTextEditor(model: model)
            HStack {
                Text(status)
                    .accessibilityIdentifier("harness.status")
                    .accessibilityLabel(status)
                Spacer()
                Button("Reset latency") { model.controller?.resetKeystrokeLatency(); revision += 1 }
                    .accessibilityIdentifier("harness.reset")
            }
            .font(.caption.monospaced())
            .padding(8)
            Text(text)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("harness.text")
                .accessibilityLabel(text)
        }
        .task { await start() }
        .onChange(of: model.caretColumn) { _, _ in revision += 1 }
        .onChange(of: model.caretLine) { _, _ in revision += 1 }
        .onChange(of: model.lineCount) { _, _ in revision += 1 }
        .task(id: revision) { await publish() }
    }

    private func start() async {
        model.onTextChange = { revision += 1 }
        if let document = options.document {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(document)
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            model.load(text: contents, fileName: document)
        } else {
            model.load(text: options.text, language: .c)
        }
        while model.controller?.view.window == nil || model.lastLoadMetrics == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let controller = model.controller else { return }
        controller.showsSoftwareKeyboard = !options.hidesSoftwareKeyboard
        if let line = options.line {
            controller.goToLine(line)
            if let range = controller.textView.range(ofLine: line - 1) {
                controller.selectedRange = NSRange(location: range.location + range.length, length: 0)
            }
        } else {
            controller.selectedRange = NSRange(location: controller.textView.textLength, length: 0)
        }
        _ = controller.textView.becomeFirstResponder()
        controller.resetKeystrokeLatency()
        revision += 1
    }

    /// Publishes the state after edits settle, hashing off the main thread.
    private func publish() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let controller = model.controller else { return }
        let snapshot = controller.textSnapshot()
        let box = SendableString(value: snapshot)
        let hash = await Task.detached { box.value.fnv1a() }.value
        guard !Task.isCancelled else { return }
        let latency = controller.keystrokeLatency()
        let caret = controller.selectedRange.location
        status = String(format: "length=%d;hash=%016llx;caret=%d;keys=%d;p50=%.2f;p95=%.2f;p99=%.2f;max=%.2f;idle=1",
                        snapshot.length, hash, caret, latency.count, latency.p50, latency.p95, latency.p99, latency.max)
        text = snapshot.length <= 4096 ? (snapshot as String) : ""
    }
}

private struct SendableString: @unchecked Sendable {
    let value: NSString
}

private extension NSString {
    func fnv1a() -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let chunk = 65_536
        var buffer = [unichar](repeating: 0, count: chunk)
        var location = 0
        while location < length {
            let count = Swift.min(chunk, length - location)
            getCharacters(&buffer, range: NSRange(location: location, length: count))
            for index in 0 ..< count {
                hash ^= UInt64(buffer[index])
                hash = hash &* 0x100_0000_01b3
            }
            location += count
        }
        return hash
    }
}

struct HarnessOptions {
    var isEnabled = false
    var text = ""
    var document: String?
    var line: Int?
    var autoClose = true
    var hidesSoftwareKeyboard = false

    static let current: HarnessOptions = {
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        var options = HarnessOptions()
        options.isEnabled = arguments.contains("-keyboardHarness")
        options.text = (value(after: "-harnessText") ?? "").replacingOccurrences(of: "\\n", with: "\n")
        options.document = value(after: "-document")
        options.line = value(after: "-harnessLine").flatMap(Int.init)
        options.autoClose = value(after: "-autoclose") != "0"
        options.hidesSoftwareKeyboard = arguments.contains("-hideSoftwareKeyboard")
        return options
    }()
}
