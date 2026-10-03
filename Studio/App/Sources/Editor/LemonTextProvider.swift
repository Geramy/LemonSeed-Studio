import SwiftUI
import UIKit
import LemonText
import StudioCore
import StudioDesign

/// LemonText as the Studio's editor. LemonText owns the live text (a piece
/// table behind Runestone's text view); the document is told about each
/// edit in O(1) and copies the text out only when it needs it (save, the
/// agent, the terminal). Theme, font and editor settings come from the
/// Studio; the caret, reveal requests, diagnostics and keyboard focus are
/// bridged both ways.
@MainActor
final class LemonTextEditorProvider: EditorProviding {
    let id = "com.geramyloveless.LemonSeedStudio.lemontext"
    let displayName = "LemonText"

    func priority(for document: EditorDocument) -> Int? {
        document.loadState == .loaded ? 100 : nil
    }

    func makeEditor(for document: EditorDocument, context: EditorContext) -> AnyView {
        AnyView(LemonTextDocumentEditor(document: document, workspace: context.workspace))
    }
}

struct LemonTextDocumentEditor: View {
    let document: EditorDocument
    let workspace: (any WorkspaceContext)?

    var body: some View {
        DocumentStateView(document: document) {
            LemonTextSession(document: document, workspace: workspace)
                .id(document.contentGeneration)
        }
    }
}

/// One editor instance for one load of a document.
private struct LemonTextSession: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.codeFont) private var codeFont
    @Environment(\.editorSettings) private var settings
    let document: EditorDocument
    let workspace: (any WorkspaceContext)?
    @State private var model: LemonTextEditorModel?

    private var targetID: String { TextInputCoordinator.editorID(for: document) }

    var body: some View {
        Group {
            if let model {
                LemonTextEditor(model: model)
                    .accessibilityIdentifier("editor.text")
                    .onChange(of: model.caretLine) { _, _ in caretMoved(model) }
                    .onChange(of: model.caretColumn) { _, _ in caretMoved(model) }
                    .onChange(of: model.selectionLength) { _, length in document.selectionLength = length }
                    .onChange(of: document.pendingReveal, initial: true) { _, position in reveal(position, in: model) }
                    .onChange(of: theme) { _, theme in model.theme = EditorTheme(studio: theme) }
                    .onChange(of: configuration) { _, configuration in model.configuration = configuration }
                    .onChange(of: app.keyboard.hasHardwareKeyboard, initial: true) { _, _ in installKeyBar(model) }
                    .onChange(of: diagnostics, initial: true) { _, diagnostics in apply(diagnostics, to: model) }
            } else {
                theme.palette.editor.color
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    // MARK: Lifecycle

    private func start() {
        guard model == nil else { return }
        let language = LanguageDetector.language(forFileName: document.name, contents: String(document.text.prefix(4096)))
        var configuration = configuration
        if language == .markdown || language == .plainText { configuration.softWrap = true }
        let model = LemonTextEditorModel(text: document.text, language: language, theme: EditorTheme(studio: theme),
                                         configuration: configuration)
        let document = document
        model.onTextChange = { document.noteEdit() }
        document.attachTextSource { [weak model] in model?.text ?? document.text }
        TextInputCoordinator.shared.register(TextInputTarget(id: targetID, kind: .editor) { [weak model] in
            model?.controller?.textView.becomeFirstResponder() ?? false
        })
        self.model = model
    }

    private func stop() {
        document.detachTextSource()
        TextInputCoordinator.shared.unregister(id: targetID)
    }

    // MARK: Bridging

    private var configuration: EditorConfiguration {
        var configuration = EditorConfiguration()
        configuration.font = EditorFont(familyName: Self.postScriptName(codeFont.family), size: codeFont.size,
                                        baselineGrid: Grid.unit, lineSpacing: codeFont.lineSpacing)
        configuration.showLineNumbers = settings.showLineNumbers
        configuration.highlightCurrentLine = settings.highlightCurrentLine
        configuration.showInvisibles = settings.showInvisibles
        configuration.softWrap = settings.wordWrap
        configuration.showMinimap = settings.showMinimap
        configuration.tabWidth = settings.tabWidth
        configuration.insertSpaces = settings.insertSpaces
        return configuration
    }

    static func postScriptName(_ family: CodeFontFamily) -> String? {
        LemonTextSessionNames.postScriptName(family)
    }

    private func caretMoved(_ model: LemonTextEditorModel) {
        let position = TextPosition(line: model.caretLine, column: model.caretColumn)
        if document.cursor != position { document.cursor = position }
        if model.controller?.textView.isFirstResponder == true {
            TextInputCoordinator.shared.didFocus(id: targetID)
            ProgrammerKeyPerformer.tabText = settings.insertSpaces ? String(repeating: " ", count: settings.tabWidth) : "\t"
        }
    }

    private func reveal(_ position: TextPosition?, in model: LemonTextEditorModel) {
        guard let position else { return }
        Task { @MainActor in
            // After the controller has attached and loaded.
            for _ in 0..<50 where model.controller == nil { try? await Task.sleep(for: .milliseconds(20)) }
            model.perform(.goToLine(position.line))
            document.pendingReveal = nil
            model.controller?.textView.becomeFirstResponder()
        }
    }

    /// Without a hardware keyboard the editor carries the programmer key bar
    /// above the on-screen keyboard; with one, the system shortcuts bar.
    private func installKeyBar(_ model: LemonTextEditorModel) {
        Task { @MainActor in
            for _ in 0..<50 where model.controller == nil { try? await Task.sleep(for: .milliseconds(20)) }
            guard let textView = model.controller?.textView else { return }
            textView.inputAccessoryView = app.keyboard.hasHardwareKeyboard ? nil : ProgrammerKeyBar.makeInputAccessoryView(theme: theme)
            if textView.isFirstResponder { textView.reloadInputViews() }
        }
    }

    private var diagnostics: [StudioCore.Diagnostic] {
        workspace?.workspace.diagnostics.diagnostics(for: document.url) ?? []
    }

    private func apply(_ diagnostics: [StudioCore.Diagnostic], to model: LemonTextEditorModel) {
        guard !diagnostics.isEmpty else {
            if !model.diagnostics.isEmpty { model.diagnostics = [] }
            return
        }
        let text = model.text as NSString
        var lineStarts = [0]
        var index = 0
        while index < text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index))
            guard found.location != NSNotFound else { break }
            lineStarts.append(found.location + 1)
            index = found.location + 1
        }
        func offset(_ position: TextPosition) -> Int {
            let start = lineStarts[min(position.line - 1, lineStarts.count - 1)]
            return min(start + position.column - 1, text.length)
        }
        model.diagnostics = diagnostics.map { diagnostic in
            let lower = offset(diagnostic.range.lowerBound)
            let upper = max(lower + 1, offset(diagnostic.range.upperBound))
            let severity: DiagnosticSeverity = switch diagnostic.severity {
            case .error: .error
            case .warning: .warning
            case .info: .information
            case .hint: .hint
            }
            return LemonText.Diagnostic(id: diagnostic.id.uuidString, range: NSRange(location: lower, length: min(upper, text.length) - lower),
                                        severity: severity, message: diagnostic.message, source: diagnostic.source,
                                        code: diagnostic.code)
        }
    }
}

/// Font names LemonText loads by PostScript name (nil: SF Mono).
enum LemonTextSessionNames {
    static func postScriptName(_ family: CodeFontFamily) -> String? {
        switch family {
        case .sfMono: nil
        case .jetBrainsMono: "JetBrainsMono-Regular"
        case .menlo: "Menlo-Regular"
        }
    }
}

extension EditorTheme {
    /// LemonText's theme built from a Studio theme, so the editor matches
    /// the chrome exactly (syntax roles map one to one).
    init(studio theme: StudioDesign.Theme) {
        func c(_ color: RGBA) -> ThemeColor { ThemeColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha) }
        let p = theme.palette
        let s = theme.syntax
        let palette = ThemePalette(isDark: theme.appearance == .dark,
                                   background: c(p.editor), elevatedBackground: c(p.elevated),
                                   text: c(s.plain), secondaryText: c(p.textSecondary), tertiaryText: c(p.textTertiary),
                                   separator: c(p.separator), accent: c(p.accent),
                                   red: c(p.error), orange: c(s.number), yellow: c(p.warning), green: c(s.string),
                                   teal: c(s.type), cyan: c(p.info), blue: c(s.function), indigo: c(s.property),
                                   purple: c(s.keyword), pink: c(s.preprocessor))
        self.init(name: theme.name, palette: palette)
        gutterBackground = c(p.gutter)
        selection = c(p.selection)
        currentLine = c(p.currentLine)
        caret = c(p.accent)
        let roles: [(String, RGBA, Bool)] = [
            ("comment", s.comment, true), ("keyword", s.keyword, false), ("keyword.function", s.keyword, false),
            ("keyword.return", s.keyword, false), ("keyword.directive", s.preprocessor, false), ("string", s.string, false),
            ("number", s.number, false), ("constant", s.constant, false), ("constant.builtin", s.constant, false),
            ("function", s.function, false), ("type", s.type, false), ("type.builtin", s.type, false),
            ("variable", s.variable, false), ("property", s.property, false), ("operator", s.operator, false),
            ("punctuation", s.punctuation, false), ("punctuation.bracket", s.punctuation, false),
            ("punctuation.delimiter", s.punctuation, false), ("attribute", s.attribute, false), ("tag", s.tag, false),
        ]
        for (capture, color, italic) in roles {
            syntax[capture] = SyntaxStyle(c(color), italic: italic)
        }
    }
}
