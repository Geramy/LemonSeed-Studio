public import SwiftUI
public import GitKit

/// Inline unified diff with old/new line numbers.
///
/// Hunk headers can carry actions (stage, unstage, discard); lines can be
/// selected for line-level staging; and a line can show a marker (for
/// review comments).
public struct DiffView: View {
    public struct HunkAction: Identifiable {
        public let id: String
        public let title: String
        public let systemImage: String
        public let role: ButtonRole?
        public let perform: (DiffHunk) -> Void
        public init(_ title: String, systemImage: String, role: ButtonRole? = nil, perform: @escaping (DiffHunk) -> Void) {
            self.id = title
            self.title = title
            self.systemImage = systemImage
            self.role = role
            self.perform = perform
        }
    }

    let hunks: [DiffHunk]
    let isBinary: Bool
    var hunkActions: [HunkAction]
    var selectedLines: Set<LineSelection>
    var onTapLine: ((DiffLine, DiffHunk) -> Void)?
    var lineMarker: ((DiffLine) -> Int)?
    @Environment(\.gitTheme) private var theme

    public init(hunks: [DiffHunk], isBinary: Bool = false, hunkActions: [HunkAction] = [],
                selectedLines: Set<LineSelection> = [], onTapLine: ((DiffLine, DiffHunk) -> Void)? = nil,
                lineMarker: ((DiffLine) -> Int)? = nil) {
        self.hunks = hunks
        self.isBinary = isBinary
        self.hunkActions = hunkActions
        self.selectedLines = selectedLines
        self.onTapLine = onTapLine
        self.lineMarker = lineMarker
    }

    public var body: some View {
        if isBinary {
            ContentUnavailableView("Binary file", systemImage: "doc.zipper", description: Text("No text diff to show."))
        } else if hunks.isEmpty {
            ContentUnavailableView("No changes", systemImage: "equal.circle")
        } else {
            // Hunk headers stay full width so their actions remain visible;
            // each hunk's lines scroll sideways on their own.
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(hunks) { hunk in
                            header(hunk)
                            ScrollView(.horizontal, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(hunk.lines) { line in
                                        row(line, hunk: hunk)
                                            .frame(minWidth: proxy.size.width, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func header(_ hunk: DiffHunk) -> some View {
        HStack(spacing: 10) {
            Text(hunk.header)
                .font(theme.codeFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            ForEach(hunkActions) { action in
                Button(role: action.role) { action.perform(hunk) } label: {
                    Label(action.title, systemImage: action.systemImage).font(.caption.weight(.medium)).fixedSize()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.diffHunkHeaderBackground)
    }

    private func row(_ line: DiffLine, hunk: DiffHunk) -> some View {
        let selected = selectedLines.contains(LineSelection(hunk: hunk.id, line: line.id))
        return HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
            Text(line.newLineNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
            Text(sign(line))
                .frame(width: 22)
                .foregroundStyle(line.kind == .addition ? theme.added : line.kind == .deletion ? theme.deleted : .secondary)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
            if !line.hasNewline {
                Image(systemName: "return").font(.caption2).foregroundStyle(.secondary).padding(.leading, 4)
                    .accessibilityLabel("No newline at end of file")
            }
            if let count = lineMarker?(line), count > 0 {
                Label("\(count)", systemImage: "text.bubble.fill")
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 0)
        }
        .font(theme.codeFont)
        .foregroundStyle(.secondary)
        .frame(minHeight: theme.codeLineHeight)
        .background(background(line, selected: selected))
        .contentShape(Rectangle())
        .onTapGesture { onTapLine?(line, hunk) }
    }

    private func sign(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "−"
        case .context: return " "
        }
    }

    private func background(_ line: DiffLine, selected: Bool) -> Color {
        if selected { return theme.selectionBackground }
        switch line.kind {
        case .addition: return theme.diffAddedBackground
        case .deletion: return theme.diffRemovedBackground
        case .context: return .clear
        }
    }
}
