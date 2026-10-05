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
            if !block.thinking.isEmpty {
                ReasoningView(text: block.thinking, isThinking: block.isStreaming && block.answer.isEmpty,
                              seconds: block.reasoningSeconds, started: block.reasoningStarted)
            }
            if !block.answer.isEmpty {
                MarkdownView(chunks: block.answer)
            } else if block.isStreaming && block.thinking.isEmpty {
                TypingIndicator()
            }
            MessageStatsFooter(block: block)
            if let error = block.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.danger)
            } else if block.stopReason == .aborted {
                Label("Stopped", systemImage: "stop.circle")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.tertiaryText)
            } else if let stop = block.replyStop {
                Label(stop.title, systemImage: "text.badge.xmark")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.warning)
                    .accessibilityIdentifier("agent.replyStopped")
            } else if block.stopReason == .length {
                Label("Stopped: output limit reached", systemImage: "text.badge.xmark")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reasoning, collapsed to one line by default; shimmering while it streams.
struct ReasoningView: View {
    let text: ChunkedText
    let isThinking: Bool
    let seconds: Int?
    var started: Date? = nil
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
                    if isThinking, let started {
                        // The elapsed time ticks while the reasoning streams.
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text("Thinking… \(max(0, Int(context.date.timeIntervalSince(started)))) s")
                                .monospacedDigit()
                        }
                    } else {
                        Text(isThinking ? "Thinking…" : seconds.map { "Thought for \($0) s" } ?? "Thought")
                    }
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

            if expanded {
                reasoningText(lastChunks: nil)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if isThinking {
                // Collapsed while it streams: the reasoning wrapped as usual in
                // a few lines' height, following its newest line at the bottom
                // like the transcript. The text itself never shifts: it grows
                // downward and scrolls up, and scrolling up by hand stops the
                // following until the bottom is reached again. Only the last
                // chunks are in it (the whole reasoning is a tap away), so an
                // update costs the same at any length.
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            reasoningText(lastChunks: Self.liveChunks)
                            Color.clear.frame(height: 1).id(Self.liveBottom)
                        }
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .followsBottom(text.utf8Count) { proxy.scrollTo(Self.liveBottom, anchor: .bottom) }
                }
                .frame(maxHeight: Self.liveHeight)
                .accessibilityIdentifier("agent.reasoning.live")
                .transition(.opacity)
            }
        }
    }

    private static let liveBottom = "reasoning.bottom"
    /// About four lines of the reasoning font.
    private static let liveHeight: CGFloat = 72
    /// Sealed chunks (about 1 KB each) above the tail in the live preview.
    private static let liveChunks = 2

    // Plain Text, never `.textSelection(.enabled)`: iPadOS backs selectable
    // text with a UITextView whose TextKit 2 layout runs on the main thread
    // each time the reasoning grows, and that stalled the app long enough
    // for the watchdog to kill it (0x8BADF00D). Copy is in the context menu.
    // Chunked (ChunkedText): sealed chunks are laid out once, and only the
    // tail again as it grows; expanded, only the chunks on screen.
    private func reasoningText(lastChunks: Int?) -> some View {
        ChunkedTextView(text: text, lastChunks: lastChunks, lazy: lastChunks == nil,
                        font: .system(size: 13), color: theme.tertiaryText)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Copy reasoning", systemImage: "doc.on.doc") { copy(text.string) }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(theme.hairline).frame(width: 2)
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

/// Under an assistant message: live progress while it streams (tokens so
/// far, decode speed from their arrival), then the engine's final timings
/// (decode and prefill speed, DFlash2/MTP acceptance).
struct MessageStatsFooter: View {
    let block: AssistantBlock
    @Environment(\.agentTheme) private var theme

    var body: some View {
        Group {
            if block.isStreaming, block.firstTokenAt != nil {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    line(live: context.date)
                }
            } else if !block.isStreaming, block.finalTimings != nil || block.streamedTokens > 0 {
                line(live: nil)
            }
        }
        .font(theme.captionFont.monospacedDigit())
        .foregroundStyle(theme.tertiaryText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.messageStats")
    }

    private func line(live now: Date?) -> some View {
        var parts: [String] = []
        if let now {
            let phase = block.answer.isEmpty && !block.thinking.isEmpty ? "thinking" : "answering"
            parts.append("\(phase) · \(block.streamedTokens) tok")
            if let rate = block.liveTokensPerSecond(now: now) { parts.append(String(format: "%.1f tok/s", rate)) }
        } else if let t = block.finalTimings {
            if let n = t.decodeTokens { parts.append("\(n) tok") }
            if let d = t.decodePerSecond { parts.append(String(format: "%.1f tok/s decode", d)) }
            if let p = t.promptPerSecond { parts.append(String(format: "%.0f tok/s prefill", p)) }
            if let a = t.acceptanceRate {
                parts.append(String(format: "%.0f%% %@ accepted", a * 100, t.speculationMethod ?? "draft"))
            }
            if let cached = t.promptCachedTokens, cached > 0 { parts.append("\(cached) cached") }
        } else {
            parts.append("\(block.streamedTokens) tok")
        }
        return HStack(spacing: 6) {
            Image(systemName: now != nil ? "waveform" : "bolt")
                .symbolEffect(.variableColor.iterative, isActive: now != nil)
            Text(parts.joined(separator: " · "))
                .lineLimit(2)
        }
    }
}

/// The files one agent run changed, each with its decision: Accept (keep it
/// and open it), Deny (revert it to the checkpoint; the agent hears about
/// it), or the diff with per-block decisions. Accept all / Deny all act on
/// the files still open. In autopilot the changes are already applied and
/// the card offers Undo.
struct PendingChangesCard: View {
    let model: AgentViewModel
    let changes: ChangeSet
    @Environment(\.agentTheme) private var theme

    private var states: [FileReviewState] { changes.files.map { model.reviewState(changes, path: $0.path) } }
    private var openCount: Int { states.filter(\.isOpen).count }
    private var autopilot: Bool { states.contains(.applied) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: openCount > 0 ? "doc.badge.ellipsis" : "checkmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                DiffCountView(additions: changes.additions, deletions: changes.deletions)
            }
            ForEach(changes.files) { file in
                row(file)
            }
            if openCount > 0 {
                HStack(spacing: 8) {
                    Button {
                        model.denyAll(changes)
                    } label: {
                        Label(autopilot ? "Undo all" : "Deny all", systemImage: autopilot ? "arrow.uturn.backward" : "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.danger)
                    .accessibilityIdentifier("changes.denyAll")
                    if !autopilot {
                        Button {
                            model.acceptAll(changes)
                        } label: {
                            Label("Accept all", systemImage: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                        .foregroundStyle(theme.onAccent)
                        .accessibilityIdentifier("changes.acceptAll")
                    }
                }
            }
        }
        .padding(14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(openCount > 0 ? theme.accent.opacity(0.6) : theme.hairline, lineWidth: openCount > 0 ? 1.5 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("changes.card")
    }

    private var title: String {
        let n = changes.files.count
        let files = "\(n) file\(n == 1 ? "" : "s")"
        if openCount == 0 { return "\(files) reviewed" }
        if autopilot { return "\(files) changed" }
        return openCount == n ? "\(files) to review" : "\(openCount) of \(files) to review"
    }

    private func row(_ file: FileChange) -> some View {
        let state = model.reviewState(changes, path: file.path)
        return HStack(spacing: 8) {
            FileKindBadge(kind: file.kind)
            Button {
                model.showDiff(changes, path: file.path)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(state == .denied ? theme.tertiaryText : theme.primaryText)
                        .strikethrough(state == .denied)
                        .lineLimit(1)
                    if file.path.contains("/") {
                        Text((file.path as NSString).deletingLastPathComponent)
                            .font(theme.captionFont)
                            .foregroundStyle(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("changes.diff.\(file.path)")
            Spacer(minLength: 4)
            DiffCountView(additions: file.additions, deletions: file.deletions)
            switch state {
            case .pending, .applied:
                Button { model.showDiff(changes, path: file.path) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .accessibilityLabel("View diff of \(file.path)")
                Button { model.denyFile(changes, path: file.path) } label: {
                    Image(systemName: state == .applied ? "arrow.uturn.backward" : "xmark")
                        .foregroundStyle(theme.danger)
                }
                .accessibilityLabel((state == .applied ? "Undo " : "Deny ") + file.path)
                .accessibilityIdentifier("changes.deny.\(file.path)")
                if state == .pending {
                    Button { model.acceptFile(changes, path: file.path) } label: {
                        Image(systemName: "checkmark").foregroundStyle(theme.success)
                    }
                    .accessibilityLabel("Accept \(file.path)")
                    .accessibilityIdentifier("changes.accept.\(file.path)")
                }
            default:
                Text(label(state))
                    .font(theme.captionFont)
                    .foregroundStyle(state == .denied ? theme.danger : theme.secondaryText)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .semibold))
    }

    private func label(_ state: FileReviewState) -> String {
        switch state {
        case .accepted: "Accepted"
        case .denied: "Denied"
        case .partial: "Partly kept"
        case .superseded: "Changed again below"
        case .pending, .applied: ""
        }
    }
}
