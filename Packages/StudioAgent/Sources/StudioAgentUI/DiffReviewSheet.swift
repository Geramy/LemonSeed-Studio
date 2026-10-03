import StudioAgent
import SwiftUI

/// Review of a run's changes: files on the left, hunks on the right, each
/// hunk accepted or rejected (buttons, or swipe right / left). Applying
/// keeps accepted hunks and restores rejected ones from the checkpoint.
public struct DiffReviewSheet: View {
    let changes: ChangeSet
    var onApply: (ChangeSet.Decisions) -> Void
    @State private var decisions = ChangeSet.Decisions()
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.agentTheme) private var theme

    public init(changes: ChangeSet, onApply: @escaping (ChangeSet.Decisions) -> Void) {
        self.changes = changes
        self.onApply = onApply
        _selection = State(initialValue: changes.files.first?.path)
    }

    public var body: some View {
        NavigationSplitView {
            List(changes.files, selection: $selection) { file in
                FileRow(file: file, rejected: decisions.rejected[file.path]?.count ?? 0)
                    .tag(file.path)
            }
            .navigationTitle("Review changes")
            .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        } detail: {
            if let file = changes.files.first(where: { $0.path == selection }) {
                FileReview(file: file, decisions: $decisions)
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc")
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .frame(minWidth: 700, minHeight: 560)
    }

    private var rejectedCount: Int { decisions.rejected.values.reduce(0) { $0 + $1.count } }
    private var totalHunks: Int { changes.files.reduce(0) { $0 + max(1, $1.hunks.count) } }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(totalHunks - rejectedCount) of \(totalHunks) changes kept")
                    .font(.system(size: 14, weight: .semibold))
                Text(rejectedCount == 0 ? "Everything the agent did stays." : "Rejected changes go back to the checkpoint.")
                    .font(theme.captionFont).foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button("Later") { dismiss() }
                .buttonStyle(.bordered)
            Button {
                onApply(decisions)
                dismiss()
            } label: {
                Text(rejectedCount == 0 ? "Keep all" : "Apply review").frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .foregroundStyle(theme.onAccent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct FileRow: View {
    let file: FileChange
    let rejected: Int
    @Environment(\.agentTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            FileKindBadge(kind: file.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent).font(.system(size: 14, weight: .medium))
                let dir = (file.path as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).font(theme.captionFont).foregroundStyle(theme.tertiaryText) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                DiffCountView(additions: file.additions, deletions: file.deletions)
                if rejected > 0 {
                    Text("\(rejected) rejected").font(theme.captionFont).foregroundStyle(theme.deletion)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct FileReview: View {
    let file: FileChange
    @Binding var decisions: ChangeSet.Decisions
    @Environment(\.agentTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(file.path).font(theme.codeFont.weight(.semibold))
                    Spacer()
                    Button("Accept all") { decisions.setAll(file, accepted: true) }
                    Button("Reject all", role: .destructive) { decisions.setAll(file, accepted: false) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if file.isBinary {
                    Label("Binary file; it can only be kept or restored as a whole.", systemImage: "doc.zipper")
                        .font(theme.captionFont).foregroundStyle(theme.secondaryText)
                } else {
                    ForEach(file.hunks) { hunk in
                        HunkView(hunk: hunk, accepted: decisions.isAccepted(file.path, hunk: hunk.id)) { accepted in
                            withAnimation(.snappy) { decisions.set(file.path, hunk: hunk.id, accepted: accepted) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(theme.background)
        .navigationTitle((file.path as NSString).lastPathComponent)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One hunk. Swipe right (finger or Pencil) to accept, left to reject.
struct HunkView: View {
    let hunk: LineDiff.Hunk
    let accepted: Bool
    var onDecide: (Bool) -> Void
    @State private var drag: CGFloat = 0
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.header).font(theme.smallCodeFont).foregroundStyle(theme.tertiaryText)
                Spacer()
                Picker("Decision", selection: Binding(get: { accepted }, set: { onDecide($0) })) {
                    Label("Keep", systemImage: "checkmark").tag(true)
                    Label("Revert", systemImage: "arrow.uturn.backward").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                let oldStart = hunk.oldStart - hunk.contextBefore.count
                let newStart = hunk.newStart - hunk.contextBefore.count
                ForEach(Array(hunk.contextBefore.enumerated()), id: \.offset) { i, l in
                    line(" ", l, old: oldStart + i + 1, new: newStart + i + 1)
                }
                ForEach(Array(hunk.oldLines.enumerated()), id: \.offset) { i, l in
                    line("-", l, old: hunk.oldStart + i + 1, new: nil)
                }
                ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { i, l in
                    line("+", l, old: nil, new: hunk.newStart + i + 1)
                }
                ForEach(Array(hunk.contextAfter.enumerated()), id: \.offset) { i, l in
                    line(" ", l, old: hunk.oldStart + hunk.oldLines.count + i + 1,
                         new: hunk.newStart + hunk.newLines.count + i + 1)
                }
            }
            .padding(.vertical, 4)
            .opacity(accepted ? 1 : 0.55)
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(accepted ? theme.hairline : theme.deletion.opacity(0.6), lineWidth: accepted ? 1 : 1.5))
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .offset(x: drag)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { drag = v.translation.width / 3 } }
                .onEnded { v in
                    if v.translation.width > 120 { onDecide(true) } else if v.translation.width < -120 { onDecide(false) }
                    withAnimation(.snappy) { drag = 0 }
                })
        .accessibilityAction(named: "Keep") { onDecide(true) }
        .accessibilityAction(named: "Revert") { onDecide(false) }
    }

    private func line(_ mark: String, _ text: String, old: Int?, new: Int?) -> some View {
        HStack(spacing: 0) {
            Text(old.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(new.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(" \(mark) ").foregroundStyle(mark == "+" ? theme.addition : mark == "-" ? theme.deletion : theme.tertiaryText)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(mark == " " ? theme.secondaryText : theme.primaryText)
            Spacer(minLength: 0)
        }
        .font(theme.smallCodeFont)
        .foregroundStyle(theme.tertiaryText)
        .padding(.vertical, 1.5)
        .background(mark == "+" ? theme.additionBackground : mark == "-" ? theme.deletionBackground : .clear)
    }
}
