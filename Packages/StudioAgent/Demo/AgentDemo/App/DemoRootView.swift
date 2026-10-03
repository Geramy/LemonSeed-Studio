import StudioAgent
import StudioAgentUI
import SwiftUI

struct DemoRootView: View {
    let demo: DemoEnvironment
    @State private var selectedFile: String? = "src/mathx.c"
    @State private var files: [String] = []
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @Environment(\.agentTheme) private var theme

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(files, id: \.self, selection: $selectedFile) { path in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent)
                        let dir = (path as NSString).deletingLastPathComponent
                        if !dir.isEmpty { Text(dir).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: {
                    Image(systemName: path.hasSuffix(".md") ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                }
            }
            .navigationTitle("mathx")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            GeometryReader { geo in
                let agentWidth = min(560, max(420, geo.size.width * 0.52))
                HStack(spacing: 0) {
                    CodePane(demo: demo, path: selectedFile) {
                        withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
                    }
                        .frame(width: max(0, geo.size.width - agentWidth - 1))
                    Rectangle().fill(theme.hairline).frame(width: 1)
                    AgentPanel(model: demo.model)
                        .frame(width: agentWidth)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear(perform: reloadFiles)
        .onChange(of: demo.model.isRunning) { reloadFiles() }
        .task {
            if demo.screen == "sessions" { await seedSessionsForScreenshot() }
            if let prompt = demo.autoPrompt {
                try? await Task.sleep(for: .milliseconds(600))
                demo.model.send(prompt)
            }
        }
    }

    private func reloadFiles() {
        files = WorkspaceFileSystem(workspace: demo.workspace).walkFiles()
    }

    /// Fills the session list with a few short scripted sessions.
    private func seedSessionsForScreenshot() async {
        let titles = ["Explain how median() handles even counts", "Add gcd tests for negative inputs",
                      "Fix mean() for negative numbers"]
        guard SessionStore(workspace: demo.workspace).list().isEmpty else { return }
        for t in titles {
            let a = try? Agent.start(workspace: demo.workspace, client: ScriptedLLMClient([.text("Done.")]),
                                     approver: DenyingApprover(), configuration: .init(checkpointStorage: .memory), name: t)
            if let a { for await _ in a.prompt(t) {} }
            try? await Task.sleep(for: .milliseconds(1100))
        }
        demo.model.refreshSessions()
        demo.model.isShowingSessions = true
    }
}

/// A read-only code view with line selection and the selection actions.
struct CodePane: View {
    let demo: DemoEnvironment
    let path: String?
    var onShowFiles: () -> Void = {}
    @State private var lines: [String] = []
    @State private var selection: ClosedRange<Int>?
    @State private var showingExplain = false
    @State private var paneWidth: CGFloat = 0
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onShowFiles() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityLabel("Files")
                Text(path ?? "No file").font(theme.codeFont.weight(.semibold)).foregroundStyle(theme.primaryText)
                Spacer()
                if selection != nil {
                    Button("Clear selection") { selection = nil }.font(theme.captionFont)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 64)
            Rectangle().fill(theme.hairline).frame(height: 1)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let n = i + 1
                        HStack(spacing: 14) {
                            Text("\(n)").frame(width: 34, alignment: .trailing).foregroundStyle(theme.tertiaryText)
                            Text(line.isEmpty ? " " : line).foregroundStyle(theme.primaryText)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .font(theme.codeFont)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 12)
                        .frame(minWidth: paneWidth, alignment: .leading)
                        .background(selection?.contains(n) == true ? theme.accent.opacity(0.16) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { select(n) }
                    }
                }
                .padding(.vertical, 10)
                .frame(minWidth: paneWidth, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
            .background(theme.surface)
        }
        .background(theme.background)
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if showingExplain {
                    InlineExplainCard(explainer: demo.explainer) { showingExplain = false }
                        .padding(.horizontal, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let s = currentSelection {
                    SelectionActionBar(selection: s) { action in perform(action, s) }
                }
            }
            .padding(.bottom, 18)
            .animation(.snappy, value: showingExplain)
        }
        .onAppear(perform: load)
        .onChange(of: path) { selection = nil; load() }
        .onChange(of: demo.model.isRunning) { load() }
        .task {
            if demo.screen == "inline", path == "src/mathx.c" {
                selection = 6...16
                try? await Task.sleep(for: .milliseconds(500))
                if let s = currentSelection { perform(.explain, s) }
            }
        }
    }

    private func load() {
        guard let path, let url = try? WorkspaceFileSystem(workspace: demo.workspace).resolve(path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { lines = []; return }
        lines = LineDiff.lines(text)
    }

    private func select(_ n: Int) {
        if let s = selection, s.count == 1, s.lowerBound != n {
            selection = min(s.lowerBound, n)...max(s.lowerBound, n)
        } else if selection == n...n {
            selection = nil
        } else {
            selection = n...n
        }
    }

    private var currentSelection: CodeSelection? {
        guard let path, let s = selection, s.upperBound <= lines.count else { return nil }
        let text = lines[(s.lowerBound - 1)...(s.upperBound - 1)].joined(separator: "\n")
        let diags = path == "src/mathx.c" && s.contains(15)
            ? [CodeSelection.Diagnostic(line: 15, severity: "warning",
                                        message: "implicit conversion of 'long' to 'size_t' changes signedness")]
            : []
        return CodeSelection(path: path, startLine: s.lowerBound, endLine: s.upperBound, text: text,
                             language: path.hasSuffix(".c") || path.hasSuffix(".h") ? "c" : nil, diagnostics: diags)
    }

    private func perform(_ action: InlineAction, _ s: CodeSelection) {
        if action.runsInAgent {
            demo.model.send(action.prompt(for: s))
        } else {
            showingExplain = true
            demo.explainer.explain(s)
        }
    }
}
