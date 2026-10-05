import SwiftUI
import StudioCore
import StudioDesign

/// The bottom panel: Terminal, Problems, Output and Build.
struct BottomPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.typeScale) private var type
    let controller: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(controller.panelTab == .terminal ? theme.terminal.background.color : theme.palette.chrome.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel")
    }

    private var header: some View {
        HStack(spacing: Space.xs) {
            ForEach(PanelTab.allCases) { tab in
                PanelTabButton(tab: tab, isSelected: controller.panelTab == tab, badge: badge(for: tab)) {
                    controller.show(tab)
                }
            }
            Spacer(minLength: Space.s)
            if controller.panelTab == .terminal { terminalControls }
            if controller.panelTab == .output, let channel = selectedChannel {
                StudioIconButton("trash", help: "Clear Output") { controller.workspace.output.clear(channel: channel) }
                    .accessibilityIdentifier("panel.clearOutput")
            }
            StudioIconButton(controller.isPanelMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             help: controller.isPanelMaximized ? "Restore Panel Size" : "Maximize Panel") {
                withAnimation(Motion.layout) { controller.isPanelMaximized.toggle() }
            }
            .accessibilityIdentifier("panel.maximize")
            StudioIconButton(StudioSymbol.close, help: "Close Panel (⌘J)") { controller.togglePanel() }
                .accessibilityIdentifier("panel.close")
        }
        .padding(.horizontal, Space.s)
        .frame(height: metrics.tabHeight)
        .background(theme.palette.chrome.color)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func badge(for tab: PanelTab) -> Int? {
        switch tab {
        case .problems:
            let count = controller.workspace.diagnostics.errorCount + controller.workspace.diagnostics.warningCount
            return count > 0 ? count : nil
        default: return nil
        }
    }

    @ViewBuilder private var terminalControls: some View {
        if controller.terminalSessions.count > 1 {
            Picker("Session", selection: Binding(get: { controller.selectedTerminalID ?? UUID() },
                                                 set: { controller.selectedTerminalID = $0 })) {
                ForEach(controller.terminalSessions, id: \.id) { session in
                    Text(session.title).tag(session.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("terminal.sessions")
        }
        StudioIconButton("plus", help: "New Terminal (⌃⇧`)") { controller.newTerminal() }
            .accessibilityIdentifier("terminal.new")
        if let id = controller.selectedTerminalID {
            StudioIconButton("trash", help: "Kill Terminal") { controller.closeTerminal(id) }
                .accessibilityIdentifier("terminal.kill")
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.panelTab {
        case .terminal: terminal
        case .problems: ProblemsView(controller: controller)
        case .output: OutputView(controller: controller, channel: selectedChannel)
        case .build: BuildView(controller: controller, builds: controller.builds)
        }
    }

    private var selectedChannel: String? {
        controller.workspace.output.channelOrder.first
    }

    @ViewBuilder private var terminal: some View {
        if let provider = app.services.terminal {
            if let session = controller.terminalSessions.first(where: { $0.id == controller.selectedTerminalID }) {
                provider.makeTerminalView(for: session)
                    .id(session.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("terminal.view")
            } else {
                StudioEmptyState(symbol: StudioSymbol.terminal, title: "No terminal",
                                 message: "Start a shell in this workspace.") {
                    Button("New Terminal") { controller.newTerminal() }
                        .buttonStyle(.studioPrimary)
                }
            }
        } else {
            StudioEmptyState(symbol: StudioSymbol.terminal, title: "Terminal unavailable",
                             message: "No terminal is installed in this build.")
        }
    }
}

private struct PanelTabButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    let tab: PanelTab
    let isSelected: Bool
    let badge: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs + 1) {
                Text(tab.title.uppercased())
                    .font(.studioSection(type.micro + 0.5))
                    .tracking(0.6)
                if let badge { CountBadge(badge) }
            }
            .foregroundStyle(isSelected ? theme.palette.textPrimary.color
                             : hovering ? theme.palette.textSecondary.color : theme.palette.textTertiary.color)
            .padding(.horizontal, Space.s + 2)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(theme.palette.accentFill.color).frame(height: 2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .studioHover($hovering)
        .frame(minWidth: metrics.hitTarget)
        .accessibilityIdentifier("panel.tab.\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Every diagnostic in the workspace, by file.
struct ProblemsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    let controller: WorkspaceController

    var body: some View {
        let diagnostics = controller.workspace.diagnostics.all
        if diagnostics.isEmpty {
            StudioEmptyState(symbol: StudioSymbol.check, title: "No problems",
                             message: "Errors and warnings from compilers, language servers and linters appear here.")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("problems.empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diagnostics) { diagnostic in
                        Button {
                            controller.open(diagnostic.url, at: diagnostic.range.lowerBound, preview: false)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Image(systemName: symbol(diagnostic.severity))
                                    .foregroundStyle(color(diagnostic.severity))
                                Text(diagnostic.message)
                                    .foregroundStyle(theme.palette.textPrimary.color)
                                Text("\(diagnostic.url.lastPathComponent):\(diagnostic.range.lowerBound.line):\(diagnostic.range.lowerBound.column)")
                                    .foregroundStyle(theme.palette.textTertiary.color)
                                Text(diagnostic.source)
                                    .foregroundStyle(theme.palette.textTertiary.color)
                                Spacer(minLength: 0)
                            }
                            .font(.studio(type.caption + 0.5))
                            .padding(.horizontal, Space.m)
                            .frame(minHeight: metrics.rowHeight)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                    }
                }
            }
        }
    }

    private func symbol(_ severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: StudioSymbol.error
        case .warning: StudioSymbol.warning
        case .info, .hint: StudioSymbol.info
        }
    }

    private func color(_ severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: theme.palette.error.color
        case .warning: theme.palette.warning.color
        case .info, .hint: theme.palette.info.color
        }
    }
}

/// Output channels.
struct OutputView: View {
    @Environment(\.theme) private var theme
    @Environment(\.codeFont) private var codeFont
    let controller: WorkspaceController
    let channel: String?
    @State private var selected: String?

    var body: some View {
        let output = controller.workspace.output
        let current = selected ?? channel
        VStack(alignment: .leading, spacing: 0) {
            if output.channelOrder.count > 1 {
                Picker("Channel", selection: Binding(get: { current ?? "" }, set: { selected = $0 })) {
                    ForEach(output.channelOrder, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(Space.s)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(current.map { output.lines($0) } ?? []) { line in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text(line.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(theme.palette.textTertiary.color)
                            Text(line.text)
                                .foregroundStyle(theme.palette.textPrimary.color)
                                .textSelection(.enabled)
                        }
                        .font(CodeFont(family: codeFont.family, size: max(10, codeFont.size - 2)).font())
                    }
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("output.view")
    }
}

/// Build: builds the project (studio-build.json) or the C/C++ file in the
/// editor with the in-process clang, and runs the program in the terminal.
/// Shows the target, the compiler's output, the error and warning counts
/// (their locations are in Problems) and which runner the program will use.
struct BuildView: View {
    @Environment(\.theme) private var theme
    @Environment(\.codeFont) private var codeFont
    let controller: WorkspaceController
    let builds: BuildModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Button {
                    Task { _ = await builds.build() }
                } label: {
                    Label("Build", systemImage: StudioSymbol.build)
                }
                .buttonStyle(.studioPrimary)
                .disabled(builds.isBuilding || ToolchainService.shared.unavailableReason != nil)
                .accessibilityIdentifier("build.build")
                Button {
                    Task { await builds.run() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.studioSecondary)
                .disabled(builds.isBuilding || ToolchainService.shared.unavailableReason != nil)
                .accessibilityIdentifier("build.run")
                VStack(alignment: .leading, spacing: 1) {
                    Text(builds.subject)
                        .foregroundStyle(theme.palette.textPrimary.color)
                    Text("Target: \(builds.projectTarget.title) (\(builds.projectTarget.rawValue))")
                        .foregroundStyle(theme.palette.textTertiary.color)
                }
                .font(.system(size: 12))
                Spacer()
                status
            }
            .padding(Space.s)
            Divider()
            if let reason = ToolchainService.shared.unavailableReason {
                StudioEmptyState(symbol: StudioSymbol.build, title: "No compiler in this build", message: reason)
            } else if builds.log.isEmpty, case .built(true) = builds.state {
                summary
            } else if builds.log.isEmpty {
                StudioEmptyState(symbol: StudioSymbol.build, title: "C and C++ to WebAssembly",
                                 message: "Build compiles the project\u{2019}s studio-build.json, or the C or C++ file in the editor, with clang inside the app. Run builds, then runs the program in the terminal.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s) {
                        summary
                        Text(builds.log)
                            .font(CodeFont(family: codeFont.family, size: max(10, codeFont.size - 2)).font())
                            .foregroundStyle(theme.palette.textPrimary.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Space.m)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("build.view")
    }

    @ViewBuilder private var status: some View {
        switch builds.state {
        case .idle: EmptyView()
        case .building:
            ProgressView().controlSize(.small)
        case .built(let ok):
            Label(ok ? "Built" : "Failed", systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(ok ? theme.palette.success.color : theme.palette.error.color)
                .font(.system(size: 12, weight: .medium))
                .accessibilityIdentifier("build.status")
        case .failed(let why):
            Label(why, systemImage: "xmark.octagon.fill")
                .foregroundStyle(theme.palette.error.color)
                .font(.system(size: 12))
                .lineLimit(2)
                .accessibilityIdentifier("build.status")
        }
    }

    @ViewBuilder private var summary: some View {
        if case .built = builds.state {
            VStack(alignment: .leading, spacing: 4) {
                Text(builds.title + String(format: " · %.0f ms", builds.milliseconds))
                    .font(.system(size: 12, weight: .medium))
                if builds.errorCount + builds.warningCount > 0 {
                    Button {
                        controller.show(.problems)
                    } label: {
                        Text("\(builds.errorCount) error\(builds.errorCount == 1 ? "" : "s"), \(builds.warningCount) warning\(builds.warningCount == 1 ? "" : "s") \u{2192} Problems")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.palette.accent.color)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("build.problems")
                }
                if let runner = builds.runner, let output = builds.output {
                    Text("\(output.lastPathComponent) runs in \(runner.runner.title): \(runner.reason)")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textSecondary.color)
                        .accessibilityIdentifier("build.runner")
                }
            }
        }
    }
}
