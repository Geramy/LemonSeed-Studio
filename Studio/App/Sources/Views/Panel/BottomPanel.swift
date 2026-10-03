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
        case .build: BuildView(controller: controller)
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

/// Build: detects the workspace's build system. Builds run in process once
/// the toolchain is installed.
struct BuildView: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let controller: WorkspaceController

    var body: some View {
        let system = detected
        StudioEmptyState(symbol: StudioSymbol.build,
                         title: system.map { "\($0) project" } ?? "No build system found",
                         message: system == nil
                         ? "Add a CMakeLists.txt or Makefile to build this workspace."
                         : "Builds run on this iPad with the in-process toolchain (clang, lld, CMake, ninja) once it is installed.") {
            Button("Build") {}
                .buttonStyle(.studioPrimary)
                .disabled(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("build.view")
    }

    private var detected: String? {
        let index = Set(controller.workspace.fileIndex.filter { !$0.contains("/") })
        if index.contains("CMakeLists.txt") { return "CMake" }
        if index.contains("Makefile") || index.contains("makefile") { return "Make" }
        if index.contains("Package.swift") { return "Swift package" }
        if index.contains("build.sh") { return "Script-built" }
        return nil
    }
}
