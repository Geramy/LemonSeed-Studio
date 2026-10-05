import StudioAgent
import SwiftUI

/// A tool call: what it does, its status, and its output (live for bash).
struct ToolCallCard: View {
    let card: ToolCard
    var approval: PermissionRequest?
    var onRespond: (PermissionResponse) -> Void = { _ in }
    @State private var expanded = false
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } label: { header }
                .buttonStyle(.plain)
            if let approval { ApprovalView(request: approval, onRespond: onRespond) }
            if showsBody {
                Rectangle().fill(theme.hairline).frame(height: 1)
                content.transition(.opacity)
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(card.status == .awaitingApproval ? theme.accent : theme.hairline,
                          lineWidth: card.status == .awaitingApproval ? 1.5 : 1))
        .animation(.snappy(duration: 0.25), value: card.status)
    }

    private var showsBody: Bool {
        expanded || (card.status == .running && card.name == "bash" && !card.live.isEmpty)
            || (card.status == .failed && card.result != nil && card.name != "read")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(card.name))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 26, height: 26)
                .background(theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.primaryText)
                if let subtitle {
                    Text(subtitle).font(theme.smallCodeFont).foregroundStyle(theme.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let diff = diffCounts { DiffCountView(additions: diff.0, deletions: diff.1) }
            statusView
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var statusView: some View {
        switch card.status {
        case .running: ProgressView().controlSize(.small)
        case .awaitingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(theme.accent)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(theme.danger)
        }
    }

    @ViewBuilder private var content: some View {
        if let diff = card.result?.details?["diff"]?.stringValue, !diff.isEmpty, card.result?.isError == false {
            UnifiedDiffText(diff: diff).padding(12)
        } else {
            ScrollView(.vertical) {
                if let result = card.result {
                    // Final: drawn once, and selectable.
                    Text(result.text.isEmpty ? "(no output)" : String(result.text.suffix(12_000)))
                        .font(theme.smallCodeFont)
                        .foregroundStyle(result.isError ? theme.danger : theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else if card.live.isEmpty {
                    Text("(no output)")
                        .font(theme.smallCodeFont)
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    // Live: the last chunks, each laid out once, and the tail.
                    // Not selectable: selectable text is a UITextView, too
                    // costly to lay out for every chunk (see ReasoningView).
                    ChunkedTextView(text: card.live, lastChunks: 12, font: theme.smallCodeFont,
                                    color: theme.secondaryText, lineSpacing: 0)
                        .padding(12)
                }
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: 260)
        }
    }

    private var title: String {
        let a = card.arguments
        switch card.name {
        case "read": return "Read \(a["path"]?.stringValue ?? "file")"
        case "write": return "Write \(a["path"]?.stringValue ?? "file")"
        case "edit": return "Edit \(a["path"]?.stringValue ?? "file")"
        case "list": return "List \(a["path"]?.stringValue ?? "/")"
        case "glob": return "Find \(a["pattern"]?.stringValue ?? "files")"
        case "grep": return "Search \u{201C}\(a["pattern"]?.stringValue ?? "")\u{201D}"
        case "bash": return "Run command"
        default: return card.name
        }
    }

    private var subtitle: String? {
        let a = card.arguments
        switch card.name {
        case "bash": return a["command"]?.stringValue
        case "read":
            if let d = card.result?.details, let s = d["startLine"]?.intValue, let e = d["endLine"]?.intValue,
               let t = d["totalLines"]?.intValue {
                return "lines \(s)–\(e) of \(t)"
            }
            return nil
        case "grep":
            if let m = card.result?.details?["matches"]?.intValue { return "\(m) match\(m == 1 ? "" : "es")" }
            return a["path"]?.stringValue
        case "glob":
            if let c = card.result?.details?["count"]?.intValue { return "\(c) file\(c == 1 ? "" : "s")" }
            return nil
        case "edit":
            let n = a["edits"]?.arrayValue?.count ?? 1
            return card.result?.isError == true ? "failed" : "\(n) replacement\(n == 1 ? "" : "s")"
        default: return nil
        }
    }

    private var diffCounts: (Int, Int)? {
        guard let diff = card.result?.details?["diff"]?.stringValue, card.result?.isError == false else { return nil }
        var add = 0, del = 0
        for l in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if l.hasPrefix("+") && !l.hasPrefix("+++") { add += 1 }
            if l.hasPrefix("-") && !l.hasPrefix("---") { del += 1 }
        }
        return (add, del)
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "read": "doc.text"
        case "write": "doc.badge.plus"
        case "edit": "pencil"
        case "list": "folder"
        case "glob": "sparkle.magnifyingglass"
        case "grep": "magnifyingglass"
        case "bash": "terminal"
        default: "wrench.and.screwdriver"
        }
    }
}

/// The inline permission prompt inside a tool card.
struct ApprovalView: View {
    let request: PermissionRequest
    var onRespond: (PermissionResponse) -> Void
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(theme.hairline).frame(height: 1)
            if case .shell(let command, let c) = request.effect {
                Text(command)
                    .font(theme.codeFont)
                    .foregroundStyle(theme.primaryText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 12)
                Text("This command \(c.label == "unknown command" ? "is not a known read-only command" : c.label).")
                    .font(theme.captionFont).foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 12)
            } else {
                Text("The agent wants to \(request.title.lowercased()).")
                    .font(theme.captionFont).foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 12)
                if let preview = Self.preview(request) {
                    UnifiedDiffText(diff: preview).padding(.horizontal, 12)
                }
            }
            HStack(spacing: 8) {
                Button("Allow") { onRespond(.allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .foregroundStyle(theme.onAccent)
                    .keyboardShortcut(.defaultAction)
                Button("Allow for session") { onRespond(.allowForSession) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Deny", role: .destructive) { onRespond(.deny(reason: nil)) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

extension ApprovalView {
    /// What an edit or write would change, as diff lines, before it runs.
    static func preview(_ request: PermissionRequest, maxLines: Int = 24) -> String? {
        var lines: [String] = []
        switch request.toolName {
        case "edit":
            let edits = (try? EditTool.replacements(from: request.arguments)) ?? []
            for (i, e) in edits.enumerated() {
                if i > 0 { lines.append("@@") }
                lines += LineDiff.lines(e.oldText).map { "-" + $0 }
                lines += LineDiff.lines(e.newText).map { "+" + $0 }
            }
        case "write":
            lines = LineDiff.lines(request.arguments["content"]?.stringValue ?? "").map { "+" + $0 }
        default:
            return nil
        }
        guard !lines.isEmpty else { return nil }
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)) + ["@@ … \(lines.count - maxLines) more lines"] }
        return lines.joined(separator: "\n")
    }
}

/// A unified diff with tinted lines.
struct UnifiedDiffText: View {
    let diff: String
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("---") || line.hasPrefix("+++") {
                    EmptyView()
                } else {
                    Text(line.isEmpty ? " " : String(line))
                        .font(theme.smallCodeFont)
                        .foregroundStyle(color(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(background(line))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func color(_ l: Substring) -> Color {
        if l.hasPrefix("@@") { return theme.tertiaryText }
        if l.hasPrefix("+") { return theme.addition }
        if l.hasPrefix("-") { return theme.deletion }
        return theme.secondaryText
    }

    private func background(_ l: Substring) -> Color {
        if l.hasPrefix("+") { return theme.additionBackground }
        if l.hasPrefix("-") { return theme.deletionBackground }
        return .clear
    }
}

