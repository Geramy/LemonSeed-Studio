import SwiftUI
import StudioCore
import StudioDesign

// MARK: - Top bar

/// The window's top bar: sidebar toggle, workspace switcher, branch, the
/// search field that opens quick open, and layout toggles.
struct TopBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.typeScale) private var type
    @Environment(\.openWindow) private var openWindow
    let controller: WorkspaceController

    var body: some View {
        HStack(spacing: Space.xs) {
            StudioIconButton(StudioSymbol.sidebar, help: "Toggle Sidebar (⌘B)", isActive: controller.isSidebarVisible) {
                controller.toggleSidebar()
            }
            .accessibilityIdentifier("toolbar.toggleSidebar")

            workspaceMenu

            if let status = controller.gitStatus {
                Label(status.headDescription, systemImage: StudioSymbol.sourceControl)
                    .font(.studio(type.caption, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary.color)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, Space.s)
                    .frame(height: 24)
                    .background(theme.palette.hover.color, in: Capsule())
                    .lineLimit(1)
                    .accessibilityIdentifier("toolbar.branch")
            }

            Spacer(minLength: Space.m)
            omnibox
            Spacer(minLength: Space.m)

            KeyboardButton()
            StudioIconButton(StudioSymbol.splitRight, help: "Split Editor Right (⌘\\)") { controller.split(.right) }
                .accessibilityIdentifier("toolbar.splitRight")
            StudioIconButton(StudioSymbol.panel, help: "Toggle Panel (⌘J)", isActive: controller.isPanelVisible) {
                controller.togglePanel()
            }
            .accessibilityIdentifier("toolbar.togglePanel")
            StudioIconButton(StudioSymbol.agent, help: "AI (⌘L)",
                             isActive: controller.isSidebarVisible && controller.sidebarItem == .agent) {
                controller.show(.agent, toggle: true)
            }
            .accessibilityIdentifier("toolbar.agent")
            moreMenu
        }
        .padding(.leading, Space.s)
        .padding(.trailing, Space.s)
        .frame(height: metrics.toolbarHeight)
        .background(theme.palette.chrome.color)
    }

    private var workspaceMenu: some View {
        Menu {
            Section("Recent") {
                ForEach(app.library.recents.prefix(8)) { reference in
                    Button(reference.displayName, systemImage: reference.isProject ? "folder" : "externaldrive") {
                        controller.router?.open(reference)
                    }
                }
            }
            Button("Open Folder…", systemImage: StudioSymbol.filesApp) { controller.router?.showOpenFolder() }
            Button("New Project…", systemImage: "plus.square.on.square") { controller.router?.showNewProject() }
            Button("New Window", systemImage: "macwindow.badge.plus") { openWindow(id: StudioScenes.workspace) }
            Divider()
            Button("Close Workspace", systemImage: "xmark.rectangle") { controller.router?.closeWorkspace() }
        } label: {
            HStack(spacing: Space.xs + 2) {
                LemonMark(size: 18)
                Text(controller.displayName)
                    .font(.studio(type.label + 0.5, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary.color)
                    .lineLimit(1)
                Image(systemName: StudioSymbol.chevronDown)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.palette.textTertiary.color)
            }
            .padding(.horizontal, Space.s)
            .frame(minHeight: metrics.hitTarget)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("toolbar.workspaceMenu")
    }

    private var omnibox: some View {
        Button {
            controller.showPalette(.files)
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: StudioSymbol.search)
                    .font(.system(size: type.caption, weight: .semibold))
                Text("Search files and commands")
                    .font(.studio(type.label))
                Spacer(minLength: Space.s)
                KeyCaps("⌘P")
            }
            .foregroundStyle(theme.palette.textTertiary.color)
            .padding(.horizontal, Space.m)
            .frame(maxWidth: 440, minHeight: max(30, metrics.hitTarget - 10))
            .background(theme.palette.editor.color, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.palette.hairline.color, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("toolbar.quickOpen")
        .accessibilityLabel("Search files and commands")
    }

    private var moreMenu: some View {
        Menu {
            Button("Show All Commands", systemImage: StudioSymbol.command) { controller.showPalette(.commands) }
            Button("Go to File…", systemImage: "doc.text.magnifyingglass") { controller.showPalette(.files) }
            Divider()
            Button("Split Editor Down", systemImage: StudioSymbol.splitDown) { controller.split(.down) }
            Button("New Terminal", systemImage: "plus.rectangle") { controller.newTerminal() }
            Button("GPU Monitor in New Window", systemImage: StudioSymbol.gpu) {
                app.openedGPUMonitorWindow = true
                openWindow(id: StudioScenes.gpuMonitor)
            }
            Divider()
            Button("Settings…", systemImage: StudioSymbol.settings) { controller.router?.showSettings() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: metrics.iconSize, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary.color)
                .frame(width: metrics.hitTarget, height: metrics.hitTarget)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("toolbar.more")
        .accessibilityLabel("More")
    }
}

// MARK: - Activity bar

struct ActivityBar: View {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    let controller: WorkspaceController

    var body: some View {
        VStack(spacing: Space.xs) {
            ForEach(SidebarItem.allCases) { item in
                ActivityButton(item: item, controller: controller)
            }
            Spacer()
            StudioIconButton(StudioSymbol.settings, help: "Settings (⌘,)") { controller.router?.showSettings() }
                .accessibilityIdentifier("activity.settings")
        }
        .padding(.vertical, Space.s)
        .frame(width: metrics.activityBarWidth)
        .background(theme.palette.chrome.color)
    }
}

private struct ActivityButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    let item: SidebarItem
    let controller: WorkspaceController
    @State private var hovering = false

    private var selected: Bool { controller.isSidebarVisible && controller.sidebarItem == item }

    var body: some View {
        Button {
            controller.show(item, toggle: true)
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: metrics.iconSize + 2, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.palette.textPrimary.color
                                 : hovering ? theme.palette.textSecondary.color : theme.palette.textTertiary.color)
                .frame(width: metrics.activityBarWidth, height: max(metrics.hitTarget, 40))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(theme.palette.accentFill.color)
                        .frame(width: 3, height: selected ? 22 : 0)
                        .opacity(selected ? 1 : 0)
                }
                .overlay(alignment: .topTrailing) { badge }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .studioHover($hovering)
        .hoverEffect(.highlight)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("activity.\(item.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(Motion.select, value: selected)
    }

    @ViewBuilder private var badge: some View {
        if item == .search, controller.search.totalMatches > 0 {
            CountBadge(controller.search.totalMatches, prominent: true)
                .scaleEffect(0.8)
                .offset(x: -4, y: 2)
        } else if item == .sourceControl, let count = controller.gitStatus?.changes?.count, count > 0 {
            CountBadge(count, prominent: true)
                .scaleEffect(0.8)
                .offset(x: -4, y: 2)
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.typeScale) private var type
    @Environment(\.editorSettings) private var editorSettings
    let controller: WorkspaceController

    var body: some View {
        HStack(spacing: 0) {
            if let status = controller.gitStatus {
                item(status.headDescription, symbol: StudioSymbol.sourceControl, id: "status.branch") {
                    controller.show(.sourceControl)
                }
            }
            item(nil, symbol: nil, id: "status.problems") { controller.show(.problems) } label: {
                HStack(spacing: Space.s) {
                    Label("\(controller.workspace.diagnostics.errorCount)", systemImage: "xmark.circle")
                    Label("\(controller.workspace.diagnostics.warningCount)", systemImage: "exclamationmark.triangle")
                }
            }
            Spacer(minLength: Space.s)
            if let document = controller.activeDocument, document.loadState == .loaded {
                item(cursorText(document), symbol: nil, id: "status.cursor") { controller.showPalette(.goToLine) }
                item(editorSettings.insertSpaces ? "Spaces: \(editorSettings.tabWidth)" : "Tab Size: \(editorSettings.tabWidth)",
                     symbol: nil, id: "status.indent") { controller.router?.showSettings() }
                item(encodingName(document) + "  " + document.lineEnding.label, symbol: nil, id: "status.encoding") {}
                item(document.language.name, symbol: nil, id: "status.language") {}
            }
            powerItem
            engineItem
            modelItem
        }
        .font(.studio(type.caption))
        .foregroundStyle(theme.palette.textSecondary.color)
        .labelStyle(StatusLabelStyle())
        .frame(height: metrics.statusBarHeight)
        .background(theme.palette.chrome.color)
    }

    private func cursorText(_ document: EditorDocument) -> String {
        let base = "Ln \(document.cursor.line), Col \(document.cursor.column)"
        return document.selectionLength > 0 ? base + " (\(document.selectionLength) selected)" : base
    }

    private func encodingName(_ document: EditorDocument) -> String {
        switch document.encoding {
        case .utf8: document.hasByteOrderMark ? "UTF-8 BOM" : "UTF-8"
        case .utf16: "UTF-16"
        case .windowsCP1252: "Windows 1252"
        default: "Text"
        }
    }

    private var engineItem: some View {
        let state = app.services.telemetry.engineState
        return item(nil, symbol: nil, id: "status.engine") { controller.show(.gpu) } label: {
            HStack(spacing: Space.xs + 2) {
                StatusDot(engineColor(state), live: state.isReady)
                Text(engineText(state, summary: app.services.telemetry.summary))
            }
        }
    }

    /// The GPU's power state (active, suspended, lost) when the engine
    /// tracks it.
    @ViewBuilder private var powerItem: some View {
        let power = app.enginePower
        if power.recovering || power.disconnected || power.state != .unknown {
            item(nil, symbol: nil, id: "status.power") { controller.show(.gpu) } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: powerSymbol(power))
                        .foregroundStyle(powerColor(power))
                    Text(powerText(power))
                        .lineLimit(1)
                }
            }
            .help(power.lastTransition ?? "GPU power")
        }
    }

    private func powerText(_ power: EnginePower) -> String {
        if power.disconnected { return "Disconnected" }
        if power.recovering { return "GPU reset, reloading" }
        switch power.state {
        case .active: return "Active"
        case .suspending: return "Suspending"
        case .suspended: return "Suspended"
        case .resuming: return "Resuming"
        case .lost: return "GPU lost"
        case .unknown: return "Power n/a"
        }
    }

    private func powerSymbol(_ power: EnginePower) -> String {
        if power.disconnected { return "cable.connector.slash" }
        if power.recovering { return "arrow.clockwise" }
        switch power.state {
        case .active: return "bolt.fill"
        case .suspending, .suspended: return "moon.zzz.fill"
        case .resuming: return "sunrise.fill"
        case .lost: return "exclamationmark.triangle.fill"
        case .unknown: return "bolt.slash"
        }
    }

    private func powerColor(_ power: EnginePower) -> Color {
        if power.recovering || power.disconnected { return theme.palette.warning.color }
        switch power.state {
        case .active: return theme.palette.success.color
        case .suspending, .suspended, .resuming: return theme.palette.info.color
        case .lost: return theme.palette.error.color
        case .unknown: return theme.palette.textTertiary.color
        }
    }

    private var modelItem: some View {
        let status = app.services.agent.status
        return item(nil, symbol: nil, id: "status.model") { controller.show(.agent) } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: StudioSymbol.agent)
                    .foregroundStyle(status.modelName != nil ? theme.palette.accent.color : theme.palette.textTertiary.color)
                Text(status.modelName ?? modelPlaceholder(status))
                    .lineLimit(1)
            }
        }
    }

    private func modelPlaceholder(_ status: AgentStatus) -> String {
        switch status.state {
        case .connecting: "Connecting…"
        case .unavailable: "No model"
        default: "Model"
        }
    }

    private func engineText(_ state: EngineState, summary: GPUSummary?) -> String {
        switch state {
        case .unknown: return "GPU: n/a"
        case .driverNotEnabled: return "GPU: driver off"
        case .noDevice: return "GPU: driver not running"
        case .deviceMatched: return "GPU: ready to start"
        case .initializing: return "GPU: starting…"
        case .ready:
            if let load = summary?.loadPercent { return "GPU \(Int(load))%" }
            return "GPU: ready"
        case .quarantined: return "GPU: quarantined"
        case .faulted: return "GPU: fault"
        case .disconnected: return "GPU: disconnected"
        }
    }

    private func engineColor(_ state: EngineState) -> Color {
        switch state {
        case .ready: theme.palette.success.color
        case .deviceMatched, .initializing: theme.palette.warning.color
        case .quarantined, .faulted: theme.palette.error.color
        case .disconnected: theme.palette.warning.color
        default: theme.palette.textTertiary.color
        }
    }

    private func item(_ text: String?, symbol: String?, id: String, action: @escaping () -> Void) -> some View {
        item(text, symbol: symbol, id: id, action: action) {
            if let symbol, let text { Label(text, systemImage: symbol) } else if let text { Text(text) }
        }
    }

    private func item<Content: View>(_ text: String?, symbol: String?, id: String, action: @escaping () -> Void,
                                     @ViewBuilder label: () -> Content) -> some View {
        StatusBarItem(action: action, label: label())
            .accessibilityIdentifier(id)
    }
}

private struct StatusBarItem<Content: View>: View {
    @Environment(\.theme) private var theme
    let action: () -> Void
    let label: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, Space.s + 1)
                .frame(maxHeight: .infinity)
                .background(hovering ? theme.palette.hover.color : .clear)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .studioHover($hovering)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
