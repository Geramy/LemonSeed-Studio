import Observation
import SwiftUI
import UIKit

/// Observable state for a ``LemonTextEditor``: the document, appearance and the caret, for SwiftUI.
///
/// The text itself lives in the editor (it can be many megabytes), so reading ``text`` copies it on demand
/// instead of mirroring every keystroke into SwiftUI.
@MainActor
@Observable
public final class LemonTextEditorModel {
    public var theme: EditorTheme {
        didSet { controller?.theme = theme }
    }
    public var configuration: EditorConfiguration {
        didSet { controller?.configuration = configuration }
    }
    public var diagnostics: [Diagnostic] = [] {
        didSet { controller?.diagnostics = diagnostics }
    }
    public var gutterMarkers: [GutterMarker] = [] {
        didSet { controller?.gutterMarkers = gutterMarkers }
    }

    public private(set) var language: LemonLanguage = .plainText
    public private(set) var caretLine = 1
    public private(set) var caretColumn = 1
    public private(set) var selectionLength = 0
    public private(set) var caretCount = 1
    public private(set) var lineCount = 1
    public private(set) var isHighlighting = false
    public private(set) var hasUnsavedChanges = false
    public private(set) var lastLoadMetrics: EditorLoadMetrics?

    /// Called on every text change. Keep it cheap; read ``text`` lazily.
    @ObservationIgnored public var onTextChange: (@MainActor () -> Void)?
    @ObservationIgnored public var onHover: (@MainActor (Int?, EditorHoverInput) -> Void)?
    @ObservationIgnored public var onPencilGesture: (@MainActor (EditorPencilGesture, Int?) -> Void)?

    /// The editor's view controller once the view is on screen, for features not covered by ``perform(_:)``.
    @ObservationIgnored public private(set) weak var controller: LemonTextViewController?
    @ObservationIgnored private var pendingLoad: (text: String, language: LemonLanguage)?

    public init(text: String = "", language: LemonLanguage = .plainText, theme: EditorTheme = .lemonDark,
                configuration: EditorConfiguration? = nil) {
        self.theme = theme
        self.configuration = configuration ?? EditorConfiguration.defaults(for: language)
        self.language = language
        pendingLoad = (text, language)
    }

    /// The current text. Copies the document.
    public var text: String {
        controller?.text ?? pendingLoad?.text ?? ""
    }

    public func load(text: String, language: LemonLanguage) {
        self.language = language
        hasUnsavedChanges = false
        if let controller {
            controller.load(text: text, language: language)
        } else {
            pendingLoad = (text, language)
        }
    }

    public func load(text: String, fileName: String) {
        load(text: text, language: LanguageDetector.language(forFileName: fileName, contents: String(text.prefix(4096))))
    }

    /// Marks the current text as saved.
    public func markSaved() {
        hasUnsavedChanges = false
    }

    /// Runs an editor command, e.g. from a toolbar or menu.
    public func perform(_ command: EditorCommand) {
        guard let controller else {
            return
        }
        switch command {
        case .find: controller.showFind()
        case .findAndReplace: controller.showFind(replace: true)
        case .findNext: controller.findNext()
        case .findPrevious: controller.findPrevious()
        case .goToLine(let line): controller.goToLine(line)
        case .showGoToLine: controller.showGoToLine()
        case .toggleComment: controller.toggleComment()
        case .indent: controller.indentLines()
        case .outdent: controller.outdentLines()
        case .moveLinesUp: controller.moveLinesUp()
        case .moveLinesDown: controller.moveLinesDown()
        case .selectNextOccurrence: controller.selectNextOccurrence()
        case .foldAll: controller.foldAll()
        case .unfoldAll: controller.unfoldAll()
        case .triggerCompletion: controller.triggerCompletion()
        case .setInlineSuggestion(let text): controller.setInlineSuggestion(text)
        case .findQuery(let query): controller.find(query)
        case .setSelections(let ranges): controller.selections = ranges
        case .showCompletions(let items): controller.showCompletions(items)
        case .fold(let line): controller.fold(atLine: line)
        case .scrollToLine(let line): controller.goToLine(line)
        }
    }

    func attach(_ controller: LemonTextViewController) {
        self.controller = controller
        controller.theme = theme
        controller.configuration = configuration
        if let pendingLoad {
            self.pendingLoad = nil
            controller.load(text: pendingLoad.text, language: pendingLoad.language)
        }
        controller.diagnostics = diagnostics
        controller.gutterMarkers = gutterMarkers
    }

    func refresh(from controller: LemonTextViewController) {
        let position = controller.caretPosition
        if caretLine != position.line { caretLine = position.line }
        if caretColumn != position.column { caretColumn = position.column }
        let length = controller.selectedRange.length
        if selectionLength != length { selectionLength = length }
        let carets = controller.selections.count
        if caretCount != carets { caretCount = carets }
        let lines = controller.lineCount
        if lineCount != lines { lineCount = lines }
        if isHighlighting != controller.isHighlighting { isHighlighting = controller.isHighlighting }
    }

    fileprivate func textDidChange() {
        if !hasUnsavedChanges {
            hasUnsavedChanges = true
        }
        onTextChange?()
    }

    fileprivate func didLoad(metrics: EditorLoadMetrics, language: LemonLanguage) {
        lastLoadMetrics = metrics
        self.language = language
    }
}

/// Commands a SwiftUI host can send to the editor.
public enum EditorCommand: Sendable {
    case find
    case findAndReplace
    case findNext
    case findPrevious
    case goToLine(Int)
    case showGoToLine
    case toggleComment
    case indent
    case outdent
    case moveLinesUp
    case moveLinesDown
    case selectNextOccurrence
    case foldAll
    case unfoldAll
    case triggerCompletion
    case setInlineSuggestion(String?)
    case findQuery(FindQuery)
    /// Primary selection first; more than one creates extra carets.
    case setSelections([NSRange])
    case showCompletions([CompletionItem])
    /// Folds the region starting on a zero-based line.
    case fold(line: Int)
    case scrollToLine(Int)
}

/// The LemonText editor as a SwiftUI view.
///
/// ```swift
/// @State private var model = LemonTextEditorModel(text: source, language: .cpp)
/// var body: some View {
///     LemonTextEditor(model: model)
///         .ignoresSafeArea(.container, edges: .bottom)
/// }
/// ```
public struct LemonTextEditor: UIViewControllerRepresentable {
    let model: LemonTextEditorModel

    public init(model: LemonTextEditorModel) {
        self.model = model
    }

    public func makeUIViewController(context: Context) -> LemonTextViewController {
        let controller = LemonTextViewController(configuration: model.configuration, theme: model.theme)
        controller.delegate = context.coordinator
        model.attach(controller)
        return controller
    }

    public func updateUIViewController(_ controller: LemonTextViewController, context: Context) {
        if controller.theme != model.theme {
            controller.theme = model.theme
        }
        if controller.configuration != model.configuration {
            controller.configuration = model.configuration
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    public final class Coordinator: LemonTextViewControllerDelegate {
        let model: LemonTextEditorModel

        init(model: LemonTextEditorModel) {
            self.model = model
        }

        public func editorDidChangeText(_ editor: LemonTextViewController) {
            model.textDidChange()
            model.refresh(from: editor)
        }

        public func editorDidChangeSelection(_ editor: LemonTextViewController) {
            model.refresh(from: editor)
        }

        public func editorDidLoad(_ editor: LemonTextViewController, metrics: EditorLoadMetrics) {
            model.didLoad(metrics: metrics, language: editor.language)
            model.refresh(from: editor)
        }

        public func editorDidFinishHighlighting(_ editor: LemonTextViewController) {
            model.refresh(from: editor)
        }

        public func editor(_ editor: LemonTextViewController, didHoverAt location: Int?, with input: EditorHoverInput) {
            model.onHover?(location, input)
        }

        public func editor(_ editor: LemonTextViewController, didReceivePencilGesture gesture: EditorPencilGesture, at location: Int?) {
            model.onPencilGesture?(gesture, location)
        }
    }
}
