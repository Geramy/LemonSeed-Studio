import SwiftUI
import StudioCore
import StudioDesign

/// The sidebar: a header with the view's title and actions, then the view.
struct SidebarContainer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    let controller: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            StudioSectionHeader(controller.sidebarItem.title) { actions }
                .padding(.leading, Space.l)
                .padding(.trailing, Space.xs)
                .frame(height: metrics.tabHeight)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(theme.palette.chrome.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.\(controller.sidebarItem.rawValue)")
    }

    @ViewBuilder private var content: some View {
        switch controller.sidebarItem {
        case .explorer: ExplorerView(controller: controller)
        case .search: SearchSidebar(controller: controller, search: controller.search)
        case .sourceControl: app.services.git.makeSourceControlView(context: controller)
        case .agent: app.services.agent.makePanel(context: controller)
        case .models: ModelsSidebar()
        case .gpu: app.services.telemetry.makeGPUView(context: controller)
        case .extensions: ExtensionsView()
        }
    }

    @ViewBuilder private var actions: some View {
        switch controller.sidebarItem {
        case .explorer:
            HStack(spacing: 0) {
                StudioIconButton(StudioSymbol.newFile, help: "New File (⌘N)") { controller.newFile() }
                    .accessibilityIdentifier("explorer.newFile")
                StudioIconButton(StudioSymbol.newFolder, help: "New Folder (⌥⌘N)") { controller.newFolder() }
                    .accessibilityIdentifier("explorer.newFolder")
                StudioIconButton(StudioSymbol.refresh, help: "Refresh") {
                    Task { await controller.workspace.tree.reloadAll() }
                    controller.workspace.rebuildIndex()
                }
                .accessibilityIdentifier("explorer.refresh")
                StudioIconButton(StudioSymbol.collapseAll, help: "Collapse Folders") { controller.workspace.tree.collapseAll() }
                    .accessibilityIdentifier("explorer.collapseAll")
            }
        case .search:
            HStack(spacing: 0) {
                StudioIconButton(StudioSymbol.refresh, help: "Search Again") { controller.search.run() }
                    .accessibilityIdentifier("search.refresh")
                StudioIconButton("xmark.circle", help: "Clear Results") { controller.search.clear() }
                    .accessibilityIdentifier("search.clear")
            }
        case .sourceControl:
            StudioIconButton(StudioSymbol.refresh, help: "Refresh") { Task { await controller.refreshGitStatus() } }
                .accessibilityIdentifier("git.refresh")
        case .gpu:
            HStack(spacing: 0) {
                StudioIconButton("rectangle.expand.vertical", help: "Open GPU Monitor") { app.isGPUMonitorPresented = true }
                    .accessibilityIdentifier("gpu.openMonitorHeader")
                StudioIconButton(StudioSymbol.refresh, help: "Refresh") { app.services.telemetry.refresh() }
                    .accessibilityIdentifier("gpu.refresh")
            }
        case .models:
            StudioIconButton(StudioSymbol.refresh, help: "Rescan Models") { Task { await app.models.refresh() } }
                .accessibilityIdentifier("models.refresh")
        case .agent, .extensions:
            EmptyView()
        }
    }
}

/// Lists the providers plugged into this build: the extension points other
/// packages fill.
struct ExtensionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Installed components")
                    .font(.studio(type.caption, weight: .semibold))
                    .foregroundStyle(theme.palette.textTertiary.color)
                ForEach(rows, id: \.role) { row in
                    HStack(alignment: .top, spacing: Space.m) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 16))
                            .foregroundStyle(theme.palette.accent.color)
                            .frame(width: 32, height: 32)
                            .background(theme.palette.accentWash.color, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.role)
                                .font(.studio(type.body, weight: .semibold))
                                .foregroundStyle(theme.palette.textPrimary.color)
                            Text(row.name)
                                .font(.studio(type.caption))
                                .foregroundStyle(theme.palette.textSecondary.color)
                            Text(row.id)
                                .font(.system(size: type.micro, design: .monospaced))
                                .foregroundStyle(theme.palette.textTertiary.color)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .elevatedSurface()
                }
                Text("Third-party extensions are planned. Today the editor, Git, agent, telemetry and terminal plug in as Studio packages.")
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.l)
        }
        .accessibilityIdentifier("extensions.list")
    }

    private var rows: [(role: String, name: String, id: String, symbol: String)] {
        let s = app.services
        var result = s.editors.map { ("Editor", $0.displayName, $0.id, "pencil.and.scribble") }
        result.append(("Source Control", s.git.displayName, s.git.id, StudioSymbol.sourceControl))
        result.append(("Agent", s.agent.displayName, s.agent.id, StudioSymbol.agent))
        result.append(("Telemetry", s.telemetry.displayName, s.telemetry.id, StudioSymbol.gpu))
        if let terminal = s.terminal {
            result.append(("Terminal", terminal.displayName, terminal.id, StudioSymbol.terminal))
        }
        return result.map { (role: $0.0, name: $0.1, id: $0.2, symbol: $0.3) }
    }
}
