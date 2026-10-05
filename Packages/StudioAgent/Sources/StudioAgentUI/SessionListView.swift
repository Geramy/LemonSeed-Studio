import StudioAgent
import SwiftUI

/// Chats stored in the workspace's `.lemonseed/sessions/`: pinned first,
/// then grouped by last activity. Each row shows the title (from the first
/// message unless renamed), the model, the thinking level and when it was
/// last used. Rename, pin and delete from the context menu or by swiping.
public struct SessionListView: View {
    let model: AgentViewModel
    var onDone: () -> Void
    @State private var query = ""
    @State private var renaming: SessionSummary?
    @State private var newName = ""
    @Environment(\.agentTheme) private var theme

    public init(model: AgentViewModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    private var filtered: [SessionSummary] {
        guard !query.isEmpty else { return model.sessions }
        return model.sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.firstMessage ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [(String, [SessionSummary])] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [SessionSummary])] = [("Pinned", []), ("Today", []), ("Yesterday", []),
                                                     ("Previous 7 Days", []), ("Earlier", [])]
        for s in filtered {
            let i: Int
            if s.pinned { i = 0 }
            else if cal.isDateInToday(s.modified) { i = 1 }
            else if cal.isDateInYesterday(s.modified) { i = 2 }
            else if s.modified > now.addingTimeInterval(-7 * 86_400) { i = 3 }
            else { i = 4 }
            buckets[i].1.append(s)
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    public var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No chats yet" : "No matches",
                                       systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text(query.isEmpty ? "Chats are saved as you work, in this workspace's .lemonseed/sessions." : ""))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { s in row(s) }
                }
            }
        }
        .searchable(text: $query, prompt: "Search chats")
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") {
                    model.newSession()
                    onDone()
                }
                .accessibilityIdentifier("agent.newChat")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onDone)
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newName)
            Button("Rename") { if let s = renaming { model.renameSession(s, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { model.refreshSessions() }
    }

    private func row(_ s: SessionSummary) -> some View {
        Button {
            model.open(s)
            onDone()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: s.pinned ? "pin.fill" : "bubble.left.and.text.bubble.right")
                    .foregroundStyle(theme.accent)
                    .frame(width: 30, height: 30)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(s.title).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        if s.id == model.currentSessionID {
                            Text("current").font(theme.captionFont).foregroundStyle(theme.accent)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(s.modified, format: .relative(presentation: .named))
                        if let m = s.model { Text("·"); Text(m) }
                        if let t = s.thinking.map(ThinkingLevel.init(rawValue:)) { Text("·"); Text("thinking \(t.title)") }
                        Text("·")
                        Text("\(s.messageCount) msg")
                    }
                    .font(theme.captionFont)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…", systemImage: "pencil") { newName = s.title; renaming = s }
            Button(s.pinned ? "Unpin" : "Pin", systemImage: s.pinned ? "pin.slash" : "pin") { model.setPinned(s, !s.pinned) }
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSession(s) }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSession(s) }
            Button(s.pinned ? "Unpin" : "Pin", systemImage: "pin") { model.setPinned(s, !s.pinned) }.tint(theme.accent)
        }
    }
}
