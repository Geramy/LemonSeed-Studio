import StudioAgent
import SwiftUI

/// Sessions stored in the workspace's `.lemonseed/sessions/`, newest first.
public struct SessionListView: View {
    let model: AgentViewModel
    var onDone: () -> Void
    @State private var query = ""
    @Environment(\.agentTheme) private var theme

    public init(model: AgentViewModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    private var filtered: [SessionSummary] {
        guard !query.isEmpty else { return model.sessions }
        return model.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    public var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No sessions yet" : "No matches",
                                       systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text(query.isEmpty ? "Sessions are saved as you work, in .lemonseed/sessions." : ""))
                    .listRowBackground(Color.clear)
            }
            ForEach(filtered) { s in
                Button {
                    model.open(s)
                    onDone()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .foregroundStyle(theme.accent)
                            .frame(width: 30, height: 30)
                            .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.title).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(s.modified, format: .relative(presentation: .named))
                                Text("·")
                                Text("\(s.messageCount) message\(s.messageCount == 1 ? "" : "s")")
                            }
                            .font(theme.captionFont)
                            .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSession(s) }
                }
            }
        }
        .searchable(text: $query, prompt: "Search sessions")
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New", systemImage: "square.and.pencil") {
                    model.newSession()
                    onDone()
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onDone)
            }
        }
        .onAppear { model.refreshSessions() }
    }
}
