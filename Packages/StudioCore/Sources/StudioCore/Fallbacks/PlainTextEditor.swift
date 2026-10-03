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

struct PlainTextEditorView: View {
    @Environment(\.theme) private var theme
    @Environment(\.codeFont) private var codeFont
    @Environment(\.editorSettings) private var settings
    @Bindable var document: EditorDocument
    /// Whether the pane has focus. The editor does not take keyboard focus
    /// by itself (that would raise the software keyboard on every open);
    /// a tap or a reveal request does.
    let isFocused: Bool
    @State private var selection: TextSelection?
    @State private var focusRequest = FocusRequest()
    @FocusState private var focused: Bool

    private var targetID: String { TextInputCoordinator.editorID(for: document) }

    /// Above this size the caret position is not recomputed on every
    /// selection change (it is O(n) here).
    private static let caretTrackingLimit = 2_000_000

    var body: some View {
        DocumentStateView(document: document) {
            TextEditor(text: Binding(get: { document.text }, set: { document.setText($0) }),
                       selection: $selection)
                .font(codeFont.font())
                .foregroundStyle(theme.syntax.plain.color)
                .lineSpacing(codeFont.lineHeight - codeFont.size * 1.2)
                .scrollContentBackground(.hidden)
                .background(theme.palette.editor.color)
                .contentMargins(.horizontal, Space.l, for: .scrollContent)
                .contentMargins(.vertical, Space.m, for: .scrollContent)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($focused)
                .onChange(of: selection) { _, newValue in updateCaret(newValue) }
                .onChange(of: document.pendingReveal, initial: true) { _, position in reveal(position) }
                .onChange(of: focusRequest.count) { _, _ in focused = true }
                .onChange(of: focused) { _, isFocused in
                    if isFocused {
                        TextInputCoordinator.shared.didFocus(id: targetID)
                        #if canImport(UIKit)
                        ProgrammerKeyPerformer.tabText = settings.insertSpaces ? String(repeating: " ", count: settings.tabWidth) : "\t"
                        #endif
                    }
                }
                .onAppear {
                    let request = focusRequest
                    TextInputCoordinator.shared.register(TextInputTarget(id: targetID, kind: .editor) {
                        request.fire()
                        return true
                    })
                }
                .onDisappear { TextInputCoordinator.shared.unregister(id: targetID) }
                .accessibilityIdentifier("editor.text")
        }
    }

    private func updateCaret(_ selection: TextSelection?) {
        guard let selection, document.text.utf8.count <= Self.caretTrackingLimit else { return }
        guard case .selection(let range) = selection.indices else { return }
        let text = document.text
        let lower = min(range.lowerBound, text.endIndex)
        var line = 1
        var lineStart = text.startIndex
        var index = text.startIndex
        while index < lower {
            if text[index] == "\n" {
                line += 1
                lineStart = text.index(after: index)
            }
            index = text.index(after: index)
        }
        document.cursor = TextPosition(line: line, column: text.distance(from: lineStart, to: lower) + 1)
        document.selectionLength = text.distance(from: lower, to: min(range.upperBound, text.endIndex))
    }

    private func reveal(_ position: TextPosition?) {
        guard let position, document.loadState == .loaded else { return }
        let text = document.text
        var line = 1
        var index = text.startIndex
        while line < position.line, index < text.endIndex {
            if text[index] == "\n" { line += 1 }
            index = text.index(after: index)
        }
        let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
        let column = min(position.column - 1, text.distance(from: index, to: lineEnd))
        let target = text.index(index, offsetBy: column)
        selection = TextSelection(insertionPoint: target)
        document.cursor = TextPosition(line: line, column: column + 1)
        document.pendingReveal = nil
        focused = true
    }
}
