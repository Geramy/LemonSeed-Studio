import SwiftUI
import StudioDesign

/// The built-in editor: a SwiftUI TextEditor with the theme and code font.
/// It is the fallback for any document no other provider claims, and it
/// keeps the document's caret and reveal requests working so the status
/// bar, search results and Problems panel behave the same with it.
@MainActor
public final class PlainTextEditorProvider: EditorProviding {
    public static let shared = PlainTextEditorProvider()

    public let id = "com.geramyloveless.LemonSeedStudio.plain-editor"
    public let displayName = "Plain Text Editor"

    public init() {}

    public func priority(for document: EditorDocument) -> Int? { 0 }

    public func makeEditor(for document: EditorDocument, context: EditorContext) -> AnyView {
        AnyView(PlainTextEditorView(document: document, isFocused: context.isFocused))
    }
}

/// Load-state handling shared by editors: a spinner, binary and too-large
/// notices, and read errors. Editors wrap their surface in it.
public struct DocumentStateView<Content: View>: View {
    @Environment(\.theme) private var theme
    private let document: EditorDocument
    private let content: () -> Content

    public init(document: EditorDocument, @ViewBuilder content: @escaping () -> Content) {
        self.document = document
        self.content = content
    }

    public var body: some View {
        switch document.loadState {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.palette.editor.color)
        case .loaded:
            content()
        case .binary(let bytes):
            StudioEmptyState(symbol: "cube", title: "Binary file",
                             message: "\(document.name) is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of binary data and is not shown as text.")
                .background(theme.palette.editor.color)
        case .tooLarge(let bytes):
            StudioEmptyState(symbol: "doc.text.magnifyingglass", title: "File too large",
                             message: "\(document.name) is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), more than this editor opens.")
                .background(theme.palette.editor.color)
        case .failed(let message):
            StudioEmptyState(symbol: "exclamationmark.triangle", title: "Could not open \(document.name)", message: message)
                .background(theme.palette.editor.color)
        }
    }
}

#if canImport(UIKit)
import UIKit

/// The built-in editor surface: a UITextView that owns the text. Each
/// keystroke costs O(1) on the document side (`noteEdit()`); the text is
/// copied out only when needed, and caret updates are coalesced, so held
/// keys and fast typing never wait on the size of the file.
struct PlainTextEditorView: View {
    @Bindable var document: EditorDocument
    /// Whether the pane has focus. The editor does not take keyboard focus
    /// by itself (that would raise the on-screen keyboard on every open);
    /// a tap, the keyboard button or a reveal request does.
    let isFocused: Bool

    var body: some View {
        DocumentStateView(document: document) {
            PlainTextView(document: document)
                .id(document.contentGeneration)
                .accessibilityIdentifier("editor.text")
        }
    }
}

private struct PlainTextView: UIViewRepresentable {
    @Environment(\.theme) private var theme
    @Environment(\.codeFont) private var codeFont
    @Environment(\.editorSettings) private var settings
    let document: EditorDocument

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.text = document.text
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        apply(to: view, coordinator: context.coordinator)
        if let position = document.pendingReveal {
            // Outside the update pass: revealing writes document state.
            let coordinator = context.coordinator
            DispatchQueue.main.async { MainActor.assumeIsolated { coordinator.reveal(position) } }
        }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    private func apply(to view: UITextView, coordinator: Coordinator) {
        let style = "\(theme.id)|\(codeFont.family.rawValue)|\(codeFont.size)|\(settings.wordWrap)"
        guard coordinator.appliedStyle != style else { return }
        coordinator.appliedStyle = style
        let paragraph = NSMutableParagraphStyle()
        let font = codeFont.uiFont()
        paragraph.minimumLineHeight = codeFont.lineHeight
        paragraph.maximumLineHeight = codeFont.lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: theme.syntax.plain.uiColor, .paragraphStyle: paragraph,
        ]
        view.typingAttributes = attributes
        let selection = view.selectedRange
        view.textStorage.setAttributes(attributes, range: NSRange(location: 0, length: view.textStorage.length))
        view.selectedRange = selection
        view.backgroundColor = theme.palette.editor.uiColor
        view.tintColor = theme.palette.accent.uiColor
        view.keyboardAppearance = theme.appearance == .dark ? .dark : .light
        view.textContainer.widthTracksTextView = true
        view.textContainer.lineBreakMode = settings.wordWrap ? .byWordWrapping : .byCharWrapping
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let document: EditorDocument
        weak var view: UITextView?
        var appliedStyle: String?
        private var caretUpdateScheduled = false
        private let focusRequest = FocusRequest()

        init(document: EditorDocument) {
            self.document = document
        }

        private var targetID: String { TextInputCoordinator.editorID(for: document) }

        func attach(_ view: UITextView) {
            self.view = view
            document.attachTextSource { [weak view] in view?.text ?? "" }
            TextInputCoordinator.shared.register(TextInputTarget(id: targetID, kind: .editor) { [weak view] in
                view?.becomeFirstResponder() ?? false
            })
        }

        func detach() {
            if view != nil { document.detachTextSource() }
            TextInputCoordinator.shared.unregister(id: targetID)
        }

        func textViewDidChange(_ textView: UITextView) {
            document.noteEdit()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            TextInputCoordinator.shared.didFocus(id: targetID)
            ProgrammerKeyPerformer.tabText = "    "
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Coalesce: held arrows and typing update the caret at most once per frame.
            guard !caretUpdateScheduled else { return }
            caretUpdateScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                MainActor.assumeIsolated {
                    self?.caretUpdateScheduled = false
                    self?.updateCaret()
                }
            }
        }

        private func updateCaret() {
            guard let view else { return }
            let text = view.text as NSString
            let range = view.selectedRange
            let location = min(range.location, text.length)
            var line = 1
            var lineStart = 0
            var index = 0
            while index < location {
                let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: location - index))
                guard found.location != NSNotFound else { break }
                line += 1
                lineStart = found.location + 1
                index = lineStart
            }
            let column = text.substring(with: NSRange(location: lineStart, length: location - lineStart)).count + 1
            let position = TextPosition(line: line, column: column)
            if document.cursor != position { document.cursor = position }
            if document.selectionLength != range.length { document.selectionLength = range.length }
        }

        func reveal(_ position: TextPosition) {
            guard let view, document.pendingReveal == position else { return }
            document.pendingReveal = nil
            let text = view.text as NSString
            var line = 1
            var location = 0
            while line < position.line {
                let found = text.range(of: "\n", options: .literal, range: NSRange(location: location, length: text.length - location))
                guard found.location != NSNotFound else { break }
                location = found.location + 1
                line += 1
            }
            let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            var lineLength = lineRange.length
            if lineLength > 0, text.character(at: NSMaxRange(lineRange) - 1) == 0x0A { lineLength -= 1 }
            let column = min(position.column - 1, lineLength)
            let target = NSRange(location: min(location + max(0, column), text.length), length: 0)
            view.becomeFirstResponder()
            view.selectedRange = target
            view.scrollRangeToVisible(target)
            document.cursor = TextPosition(line: line, column: column + 1)
        }
    }
}
#else
struct PlainTextEditorView: View {
    @Bindable var document: EditorDocument
    let isFocused: Bool

    var body: some View {
        DocumentStateView(document: document) {
            TextEditor(text: Binding(get: { document.text }, set: { document.setText($0) }))
                .font(.system(.body, design: .monospaced))
        }
    }
}
#endif
