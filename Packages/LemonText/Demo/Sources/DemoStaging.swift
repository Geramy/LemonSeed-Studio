import Foundation
import LemonText

/// Puts the editor into a known state, for screenshots and for trying features from the Demo menu.
@MainActor
enum DemoStaging {
    static func apply(_ stage: String, to model: LemonTextEditorModel) {
        for part in stage.split(separator: "+") {
            applyOne(String(part), to: model)
        }
    }

    private static func applyOne(_ stage: String, to model: LemonTextEditorModel) {
        switch stage {
        case "find":
            model.perform(.findQuery(FindQuery("dispatch", matchesWholeWord: false)))
        case "replace":
            model.perform(.findAndReplace)
            model.perform(.findQuery(FindQuery("inFlight_")))
        case "regex":
            model.perform(.findQuery(FindQuery("std::(\\w+)", isRegularExpression: true, isCaseSensitive: true)))
        case "diagnostics":
            showDiagnostics(in: model)
        case "completion":
            showCompletion(in: model)
        case "multicursor":
            showMultipleCarets(in: model)
        case "fold":
            foldSomething(in: model)
        case "goto":
            model.perform(.showGoToLine)
        case "ghost":
            showInlineSuggestion(in: model)
        case "wrap":
            model.configuration.softWrap = true
        case "invisibles":
            model.configuration.showInvisibles = true
        case "nominimap":
            model.configuration.showMinimap = false
        case "bracket":
            selectAfter("submit(", in: model, offset: 0)
        case let line where line.hasPrefix("line"):
            if let number = Int(line.dropFirst(4)) {
                model.perform(.scrollToLine(number))
            }
        default:
            break
        }
    }

    static func showDiagnostics(in model: LemonTextEditorModel) {
        let text = model.text as NSString
        var diagnostics: [Diagnostic] = []
        func range(of needle: String, occurrence: Int = 0) -> NSRange? {
            var searchRange = NSRange(location: 0, length: text.length)
            var found = NSRange(location: NSNotFound, length: 0)
            for _ in 0 ... occurrence {
                found = text.range(of: needle, options: [], range: searchRange)
                guard found.location != NSNotFound else { return nil }
                searchRange = NSRange(location: found.location + found.length, length: text.length - found.location - found.length)
            }
            return found
        }
        if let range = range(of: "label") {
            diagnostics.append(Diagnostic(range: range, severity: .warning, message: "Unused parameter 'label'",
                                          source: "clangd", code: "-Wunused-parameter"))
        }
        if let range = range(of: "fold_left") {
            diagnostics.append(Diagnostic(range: range, severity: .error,
                                          message: "No member named 'fold_left' in namespace 'std::ranges'; did you mean 'for_each'?",
                                          source: "clangd", code: "no_member_suggest"))
        }
        if let range = range(of: "nextID_", occurrence: 1) {
            diagnostics.append(Diagnostic(range: range, severity: .information, message: "Consider std::atomic for IDs shared across queues",
                                          source: "LemonSeed"))
        }
        if let range = range(of: "#include <chrono>") {
            diagnostics.append(Diagnostic(range: range, severity: .hint, message: "Included header chrono is not used directly",
                                          source: "clangd", code: "unused-includes"))
        }
        model.diagnostics = diagnostics
        // Git gutter placeholder: a modified block and an added line.
        let lemon = ThemeColor(0xF4D03F)
        model.gutterMarkers = (27 ... 33).map { GutterMarker(line: $0, kind: .bar, color: ThemeColor(0x73CDBD)) }
            + [GutterMarker(line: 44, kind: .bar, color: lemon), GutterMarker(line: 45, kind: .bar, color: lemon),
               GutterMarker(line: 20, kind: .deletion, color: ThemeColor(0xF2777A))]
    }

    static func showCompletion(in model: LemonTextEditorModel) {
        selectAfter("inFlight_.push_back(dispatch);", in: model, offset: 0)
        let items = [
            CompletionItem(label: "inFlight_", kind: .field, detail: "std::deque<Dispatch>"),
            CompletionItem(label: "finished_", kind: .field, detail: "std::vector<Dispatch>"),
            CompletionItem(label: "submit", kind: .method, detail: "optional<uint64_t>(span<const uint32_t, 3>)"),
            CompletionItem(label: "complete", kind: .method, detail: "void(uint64_t, nanoseconds) noexcept"),
            CompletionItem(label: "throughput", kind: .method, detail: "double(string_view) const"),
            CompletionItem(label: "depth_", kind: .field, detail: "std::size_t"),
            CompletionItem(label: "DispatchState", kind: .enum, detail: "enum class : uint8_t"),
            CompletionItem(label: "nextID_", kind: .field, detail: "std::uint64_t")
        ]
        model.perform(.setSelections([caretAfterNewLine(in: model, after: "inFlight_.push_back(dispatch);", typing: "i")]))
        model.perform(.showCompletions(items))
    }

    static func showMultipleCarets(in model: LemonTextEditorModel) {
        let text = model.text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: "dispatch", options: [.literal], range: searchRange)
            if found.location == NSNotFound { break }
            ranges.append(found)
            searchRange = NSRange(location: found.location + found.length, length: text.length - found.location - found.length)
        }
        if !ranges.isEmpty {
            model.perform(.setSelections(ranges))
        }
    }

    static func showInlineSuggestion(in model: LemonTextEditorModel) {
        let caret = caretAfterNewLine(in: model, after: "match->elapsed = elapsed;", typing: nil)
        model.perform(.setSelections([caret]))
        model.perform(.setInlineSuggestion("totalElapsed_ += elapsed;  // keep a running sum for throughput()"))
    }

    static func foldSomething(in model: LemonTextEditorModel) {
        let text = model.text as NSString
        let target = text.range(of: "void complete(")
        guard target.location != NSNotFound else { return }
        let line = text.substring(to: target.location).filter { $0 == "\n" }.count
        model.perform(.fold(line: line))
        let other = text.range(of: "struct Dispatch {")
        if other.location != NSNotFound {
            model.perform(.fold(line: text.substring(to: other.location).filter { $0 == "\n" }.count))
        }
    }

    private static func selectAfter(_ needle: String, in model: LemonTextEditorModel, offset: Int) {
        let text = model.text as NSString
        let found = text.range(of: needle)
        guard found.location != NSNotFound else { return }
        model.perform(.setSelections([NSRange(location: found.location + found.length + offset, length: 0)]))
    }

    /// Inserts a new indented line after `needle` (optionally typing a prefix) and returns the caret there.
    private static func caretAfterNewLine(in model: LemonTextEditorModel, after needle: String, typing: String?) -> NSRange {
        let text = model.text as NSString
        let found = text.range(of: needle)
        guard found.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let lineRange = text.lineRange(for: found)
        let line = text.substring(with: lineRange)
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        let insertion = "\n" + indentation + (typing ?? "")
        let location = found.location + found.length
        model.controller?.textView.replace(NSRange(location: location, length: 0), withText: insertion)
        return NSRange(location: location + (insertion as NSString).length, length: 0)
    }
}
