import StudioAgent
import SwiftUI

/// The user's message: a soft lemon bubble on the trailing side.
struct UserMessageView: View {
    let text: String
    var onRewind: (() -> Void)?
    @Environment(\.agentTheme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(theme.bodyFont)
                .foregroundStyle(theme.primaryText)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { copy(text) }
                    if let onRewind {
                        Button("Rewind to here", systemImage: "arrow.uturn.backward", action: onRewind)
                    }
                }
        }
    }
}

/// An assistant message: collapsible reasoning, then the Markdown answer.
struct AssistantMessageView: View {
    let block: AssistantBlock
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !block.reasoning.isEmpty {
                ReasoningView(text: block.reasoning, isThinking: block.isStreaming && block.text.isEmpty,
                              seconds: block.reasoningSeconds)
            }
            if !block.text.isEmpty {
                MarkdownView(block.text)
            } else if block.isStreaming && block.reasoning.isEmpty {
                TypingIndicator()
            }
            if let error = block.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.danger)
            } else if block.stopReason == .aborted {
                Label("Stopped", systemImage: "stop.circle")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.tertiaryText)
            } else if block.stopReason == .length {
                Label("Reached the output limit", systemImage: "text.badge.xmark")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reasoning, collapsed to one line by default; shimmering while it streams.
struct ReasoningView: View {
    let text: String
    let isThinking: Bool
    let seconds: Int?
    @State private var expanded = false
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .symbolEffect(.pulse, isActive: isThinking)
                    Text(isThinking ? "Thinking…" : seconds.map { "Thought for \($0) s" } ?? "Thought")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(theme.captionFont)
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide reasoning" : "Show reasoning")

            if expanded || isThinking {
                Text(isThinking && !expanded ? String(text.suffix(280)) : text)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.tertiaryText)
                    .lineSpacing(2)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.hairline).frame(width: 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct TypingIndicator: View {
    @Environment(\.agentTheme) private var theme
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityLabel("Generating")
    }
}

/// A one-line notice in the transcript.
struct NoticeView: View {
    let text: String
    let isError: Bool
    @Environment(\.agentTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
            Text(text).textSelection(.enabled)
        }
        .font(theme.captionFont)
        .foregroundStyle(isError ? theme.danger : theme.tertiaryText)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }
}

/// The summary that replaced older context.
struct CompactionView: View {
    let summary: String
    @State private var expanded = false
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack {
                    Image(systemName: "rectangle.compress.vertical")
                    Text("Earlier conversation summarized")
                    Spacer()
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(theme.captionFont)
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { MarkdownView(summary).transition(.opacity) }
        }
        .padding(12)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// The files a run changed, with a button into the review sheet.
struct ChangesSummaryView: View {
    let changes: ChangeSet
    var onReview: () -> Void
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(changes.files.count) file\(changes.files.count == 1 ? "" : "s") changed",
                      systemImage: "doc.badge.gearshape")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                DiffCountView(additions: changes.additions, deletions: changes.deletions)
            }
            ForEach(changes.files) { f in
                HStack(spacing: 8) {
                    FileKindBadge(kind: f.kind)
                    Text(f.path).font(theme.smallCodeFont).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    DiffCountView(additions: f.additions, deletions: f.deletions)
                }
            }
            Button(action: onReview) {
                Label("Review changes", systemImage: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .foregroundStyle(theme.onAccent)
        }
        .padding(14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous).strokeBorder(theme.hairline))
    }
}

struct DiffCountView: View {
    let additions: Int
    let deletions: Int
    @Environment(\.agentTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)").foregroundStyle(theme.addition)
            Text("−\(deletions)").foregroundStyle(theme.deletion)
        }
        .font(theme.smallCodeFont.monospacedDigit())
    }
}

struct FileKindBadge: View {
    let kind: FileChange.Kind
    @Environment(\.agentTheme) private var theme

    var body: some View {
        let (letter, color): (String, Color) = switch kind {
        case .added: ("A", theme.addition)
        case .modified: ("M", theme.warning)
        case .deleted: ("D", theme.deletion)
        }
        Text(letter)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
