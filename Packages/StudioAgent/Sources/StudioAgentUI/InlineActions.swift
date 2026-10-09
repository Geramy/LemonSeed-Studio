import Observation
import StudioAgent
import SwiftUI

/// A selection in the editor, with its diagnostics.
public struct CodeSelection: Sendable, Hashable {
    public struct Diagnostic: Sendable, Hashable {
        public var line: Int
        public var severity: String
        public var message: String
        public init(line: Int, severity: String = "error", message: String) {
            self.line = line
            self.severity = severity
            self.message = message
        }
    }

    public var path: String
    /// 1-based, inclusive.
    public var startLine: Int
    public var endLine: Int
    public var text: String
    public var language: String?
    public var diagnostics: [Diagnostic]

    public init(path: String, startLine: Int, endLine: Int, text: String, language: String? = nil,
                diagnostics: [Diagnostic] = []) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
        self.language = language
        self.diagnostics = diagnostics
    }

    var fenced: String {
        "```\(language ?? "")\n\(text.hasSuffix("\n") ? String(text.dropLast()) : text)\n```"
    }

    var location: String { startLine == endLine ? "\(path):\(startLine)" : "\(path):\(startLine)-\(endLine)" }
}

/// Selection actions (context menu, keyboard, Pencil squeeze palette).
public enum InlineAction: String, CaseIterable, Identifiable, Sendable {
    case explain, refactor, document, addTests, fix

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .explain: "Explain"
        case .refactor: "Refactor…"
        case .document: "Document"
        case .addTests: "Add tests"
        case .fix: "Fix with LemonSeed"
        }
    }

    public var symbol: String {
        switch self {
        case .explain: "text.magnifyingglass"
        case .refactor: "wand.and.stars"
        case .document: "text.append"
        case .addTests: "checkmark.diamond"
        case .fix: "bandage"
        }
    }

    /// Explain answers in a peek card without tools; the others run as an
    /// agent task with edits checkpointed for review.
    public var runsInAgent: Bool { self != .explain }

    public func isAvailable(for selection: CodeSelection) -> Bool {
        self != .fix || !selection.diagnostics.isEmpty
    }

    /// The prompt for this action. `instruction` is the user's text for
    /// Refactor (for example a handwritten "make this faster").
    public func prompt(for s: CodeSelection, instruction: String? = nil) -> String {
        switch self {
        case .explain:
            return "Explain what this code from \(s.location) does, how it works, and anything surprising about it. "
                + "Be concise.\n\n\(s.fenced)"
        case .refactor:
            let goal = instruction.map { "Goal: \($0)\n\n" } ?? "Improve its clarity and structure without changing behavior.\n\n"
            return "Refactor the code at \(s.location). \(goal)Read the surrounding file first, keep the change "
                + "focused on this range, and edit the file in place.\n\n\(s.fenced)"
        case .document:
            return "Add concise documentation comments to the code at \(s.location), in the file's existing style. "
                + "Do not change behavior.\n\n\(s.fenced)"
        case .addTests:
            return "Add tests for the code at \(s.location). Find the project's existing tests and follow their "
                + "conventions; run them if the shell can.\n\n\(s.fenced)"
        case .fix:
            let diags = s.diagnostics.map { "- line \($0.line) (\($0.severity)): \($0.message)" }.joined(separator: "\n")
            return "Fix these diagnostics in \(s.path):\n\(diags)\n\nThe code around them (\(s.location)):\n\n\(s.fenced)\n\n"
                + "Read the file, make the smallest correct fix, and explain it in one or two sentences."
        }
    }
}

/// Streams an explanation of a selection into a peek card: one request,
/// thinking off, no tools, so it starts fast.
@MainActor @Observable
public final class InlineExplainer {
    public private(set) var text = ""
    public private(set) var isRunning = false
    public private(set) var error: String?
    public private(set) var selection: CodeSelection?
    private let client: any LLMClient
    private let model: String
    private let capabilities: ModelCapabilities?
    private var task: Task<Void, Never>?

    /// `capabilities` (when known) decides whether thinking can be switched
    /// off for the explanation.
    public init(client: any LLMClient, model: String, capabilities: ModelCapabilities? = nil) {
        self.client = client
        self.model = model
        self.capabilities = capabilities
    }

    public func explain(_ s: CodeSelection) {
        cancel()
        selection = s
        text = ""
        error = nil
        isRunning = true
        let messages: [ChatMessage] = [
            .system("You are the LemonSeed agent in LemonSeed Studio. Explain code clearly and briefly, in Markdown."),
            .user(InlineAction.explain.prompt(for: s)),
        ]
        let request = ChatRequest(model: model, messages: messages, thinking: CompactionPolicy.thinkingOff(capabilities))
        let client = client
        task = Task {
            do {
                for try await e in client.stream(request) {
                    if case .contentDelta(let d) = e { self.text += d }
                }
            } catch is CancellationError {
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            self.isRunning = false
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}

/// A floating bar of actions for the current selection.
public struct SelectionActionBar: View {
    let selection: CodeSelection
    var onAction: (InlineAction) -> Void
    @Environment(\.agentTheme) private var theme

    public init(selection: CodeSelection, onAction: @escaping (InlineAction) -> Void) {
        self.selection = selection
        self.onAction = onAction
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(iconsOnly: false)
            bar(iconsOnly: true)
        }
    }

    private func bar(iconsOnly: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(InlineAction.allCases.filter { $0.isAvailable(for: selection) }) { action in
                Button { onAction(action) } label: {
                    Group {
                        if iconsOnly && action != .explain {
                            Image(systemName: action.symbol)
                        } else {
                            Label(action.title, systemImage: action.symbol)
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(action == .fix ? theme.accent : theme.primaryText)
                .help(action.title)
                .accessibilityLabel(action.title)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
    }
}

/// The peek card that shows an explanation as it streams.
public struct InlineExplainCard: View {
    let explainer: InlineExplainer
    var onClose: () -> Void
    @Environment(\.agentTheme) private var theme

    public init(explainer: InlineExplainer, onClose: @escaping () -> Void) {
        self.explainer = explainer
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Explain \(explainer.selection?.location ?? "")", systemImage: InlineAction.explain.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                if explainer.isRunning { ProgressView().controlSize(.small) }
                Button { explainer.cancel(); onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.tertiaryText)
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView { explanation }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(theme.elevatedSurface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous).strokeBorder(theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
    }

    @ViewBuilder private var explanation: some View {
        if let error = explainer.error {
            NoticeView(text: error, isError: true)
        } else if explainer.text.isEmpty {
            TypingIndicator().frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownView(explainer.text, streaming: explainer.isRunning)
        }
    }
}
