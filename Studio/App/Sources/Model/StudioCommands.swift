import SwiftUI
import StudioCore
import StudioDesign

/// The Studio's built-in commands. They live in the CommandRegistry, which
/// feeds the command palette, the menu bar and the keymap screen, so a
/// command behaves the same however it is invoked.
@MainActor
enum StudioCommands {
    /// Runs `body` with the window's controller (commands only run inside a
    /// workspace window, whose controller is the context).
    private static func on(_ body: @escaping @MainActor (WorkspaceController) -> Void) -> @MainActor @Sendable (any WorkspaceContext) -> Void {
        { context in if let controller = context as? WorkspaceController { body(controller) } }
    }

    private static let hasDocument: @MainActor @Sendable (any WorkspaceContext) -> Bool = { $0.activeDocument != nil }

    static func register(into registry: CommandRegistry) {
        var commands: [StudioCommand] = [
            // File
            StudioCommand(id: "file.newFile", title: "New File", category: "File", symbol: StudioSymbol.newFile,
                          shortcut: KeyShortcut("n"), run: on { $0.newFile() }),
            StudioCommand(id: "file.newFolder", title: "New Folder", category: "File", symbol: StudioSymbol.newFolder,
                          shortcut: KeyShortcut("n", [.command, .option]), run: on { $0.newFolder() }),
            StudioCommand(id: "file.openFolder", title: "Open Folder…", category: "File", symbol: StudioSymbol.filesApp,
                          shortcut: KeyShortcut("o"), run: on { $0.router?.showOpenFolder() }),
            StudioCommand(id: "file.newProject", title: "New Project…", category: "File", symbol: StudioSymbol.projects,
                          run: on { $0.router?.showNewProject() }),
            StudioCommand(id: "file.save", title: "Save", category: "File", symbol: "square.and.arrow.down",
                          shortcut: KeyShortcut("s"), isEnabled: hasDocument, run: on { $0.save() }),
            StudioCommand(id: "file.saveAll", title: "Save All", category: "File", symbol: "square.and.arrow.down.on.square",
                          shortcut: KeyShortcut("s", [.command, .option]), run: on { $0.saveAll() }),
            StudioCommand(id: "file.closeTab", title: "Close Editor", category: "File", symbol: StudioSymbol.close,
                          shortcut: KeyShortcut("w"), run: on { $0.closeActiveTab() }),
            StudioCommand(id: "file.closeWorkspace", title: "Close Workspace", category: "File", symbol: "xmark.rectangle",
                          run: on { $0.router?.closeWorkspace() }),
            StudioCommand(id: "file.revealActive", title: "Reveal Active File in Explorer", category: "File",
                          symbol: "scope", isEnabled: hasDocument,
                          run: on { controller in controller.activeDocument.map { controller.reveal($0.url) } }),

            // Go
            StudioCommand(id: "go.quickOpen", title: "Go to File…", category: "Go", symbol: "doc.text.magnifyingglass",
                          shortcut: KeyShortcut("p"), run: on { $0.showPalette(.files) }),
            StudioCommand(id: "go.commandPalette", title: "Show All Commands", category: "Go", symbol: StudioSymbol.command,
                          shortcut: KeyShortcut("p", [.command, .shift]), run: on { $0.showPalette(.commands) }),
            StudioCommand(id: "go.line", title: "Go to Line…", category: "Go", symbol: "text.line.first.and.arrowtriangle.forward",
                          shortcut: KeyShortcut("g", .control), isEnabled: hasDocument, run: on { $0.showPalette(.goToLine) }),
            StudioCommand(id: "go.nextTab", title: "Next Editor", category: "Go", symbol: "chevron.right.square",
                          shortcut: KeyShortcut("]", [.command, .shift]), run: on { $0.layout.cycleTabs(forward: true) }),
            StudioCommand(id: "go.previousTab", title: "Previous Editor", category: "Go", symbol: "chevron.left.square",
                          shortcut: KeyShortcut("[", [.command, .shift]), run: on { $0.layout.cycleTabs(forward: false) }),

            // View
            StudioCommand(id: "view.toggleSidebar", title: "Toggle Sidebar", category: "View", symbol: StudioSymbol.sidebar,
                          shortcut: KeyShortcut("b"), run: on { $0.toggleSidebar() }),
            StudioCommand(id: "view.togglePanel", title: "Toggle Panel", category: "View", symbol: StudioSymbol.panel,
                          shortcut: KeyShortcut("j"), run: on { $0.togglePanel() }),
            StudioCommand(id: "view.splitRight", title: "Split Editor Right", category: "View", symbol: StudioSymbol.splitRight,
                          shortcut: KeyShortcut("\\"), run: on { $0.split(.right) }),
            StudioCommand(id: "view.splitDown", title: "Split Editor Down", category: "View", symbol: StudioSymbol.splitDown,
                          shortcut: KeyShortcut("\\", [.command, .option]), run: on { $0.split(.down) }),
            StudioCommand(id: "view.joinPanes", title: "Join All Editor Panes", category: "View", symbol: "rectangle",
                          run: on { controller in withAnimation(Motion.layout) { controller.layout.joinAll() } }),
            StudioCommand(id: "view.equalizePanes", title: "Make Editor Panes Equal", category: "View", symbol: "rectangle.split.3x1",
                          run: on { controller in withAnimation(Motion.layout) { controller.layout.equalize() } }),
            StudioCommand(id: "view.zoomIn", title: "Increase Font Size", category: "View", symbol: "textformat.size.larger",
                          shortcut: KeyShortcut("="), run: on { $0.zoom(by: 1) }),
            StudioCommand(id: "view.zoomOut", title: "Decrease Font Size", category: "View", symbol: "textformat.size.smaller",
                          shortcut: KeyShortcut("-"), run: on { $0.zoom(by: -1) }),
            StudioCommand(id: "view.resetZoom", title: "Reset Font Size", category: "View", symbol: "textformat.size",
                          shortcut: KeyShortcut("0"), run: on { $0.zoom(to: 14) }),
            StudioCommand(id: "view.nextTheme", title: "Next Color Theme", category: "View", symbol: "paintpalette",
                          shortcut: KeyShortcut("t", [.command, .control]), run: on { controller in
                              controller.app.settings.cycleTheme()
                              controller.showToast(Theme.named(controller.app.settings.themeID)?.name ?? "")
                          }),

            // Terminal and panels
            StudioCommand(id: "terminal.toggle", title: "Toggle Terminal", category: "Terminal", symbol: StudioSymbol.terminal,
                          shortcut: KeyShortcut("`", .control), run: on { $0.toggleTerminal() }),
            StudioCommand(id: "terminal.new", title: "New Terminal", category: "Terminal", symbol: "plus.rectangle",
                          shortcut: KeyShortcut("`", [.control, .shift]), run: on { $0.newTerminal() }),
            StudioCommand(id: "view.problems", title: "Show Problems", category: "View", symbol: StudioSymbol.problems,
                          shortcut: KeyShortcut("m", [.command, .shift]), run: on { $0.show(.problems) }),
            StudioCommand(id: "view.output", title: "Show Output", category: "View", symbol: StudioSymbol.output,
                          shortcut: KeyShortcut("y", [.command, .shift]), run: on { $0.show(.output) }),
            StudioCommand(id: "view.build", title: "Show Build", category: "View", symbol: StudioSymbol.build,
                          run: on { $0.show(.build) }),
            StudioCommand(id: "build.build", title: "Build", category: "Build", symbol: StudioSymbol.build,
                          shortcut: KeyShortcut("b", [.command, .shift]), run: on { c in
                              c.show(.build)
                              Task { _ = await c.builds.build() }
                          }),
            StudioCommand(id: "build.run", title: "Build and Run", category: "Build", symbol: "play.fill",
                          shortcut: KeyShortcut("r", .command), run: on { c in Task { await c.builds.run() } }),

            // Workspace
            StudioCommand(id: "search.clear", title: "Clear Search Results", category: "Search", symbol: "xmark.circle",
                          run: on { $0.search.clear() }),
            StudioCommand(id: "explorer.collapseAll", title: "Collapse Folders in Explorer", category: "Explorer",
                          symbol: StudioSymbol.collapseAll, run: on { $0.workspace.tree.collapseAll() }),
            StudioCommand(id: "explorer.refresh", title: "Refresh Explorer", category: "Explorer", symbol: StudioSymbol.refresh,
                          run: on { controller in Task { await controller.workspace.tree.reloadAll(); controller.workspace.rebuildIndex() } }),
            StudioCommand(id: "git.refresh", title: "Refresh Repository Status", category: "Git", symbol: StudioSymbol.refresh,
                          run: on { controller in Task { await controller.refreshGitStatus() } }),
            StudioCommand(id: "agent.refresh", title: "Check Model Endpoint", category: "AI", symbol: StudioSymbol.agent,
                          run: on { controller in Task { await controller.app.services.agent.refresh() } }),
            StudioCommand(id: "gpu.refresh", title: "Refresh Driver State", category: "GPU", symbol: StudioSymbol.gpu,
                          run: on { $0.app.services.telemetry.refresh() }),
            StudioCommand(id: "app.settings", title: "Settings…", category: "Studio", symbol: StudioSymbol.settings,
                          shortcut: KeyShortcut(","), run: on { $0.router?.showSettings() }),
        ]
        for item in SidebarItem.allCases {
            commands.append(StudioCommand(id: "view.sidebar.\(item.rawValue)", title: "Show \(item.title)", category: "View",
                                          symbol: item.symbol, shortcut: item.shortcut, run: on { $0.show(item) }))
        }
        for number in 1...4 {
            commands.append(StudioCommand(id: "view.focusPane\(number)", title: "Focus Editor Pane \(number)", category: "View",
                                          symbol: "\(number).square", shortcut: KeyShortcut("\(number)"),
                                          run: on { $0.layout.focusPane(number: number) }))
        }
        registry.register(commands)
    }
}

extension KeyShortcut {
    /// The SwiftUI shortcut, or nil for keys SwiftUI cannot express.
    var swiftUI: KeyboardShortcut? {
        let key: KeyEquivalent
        switch self.key {
        case "return": key = .return
        case "escape": key = .escape
        case "tab": key = .tab
        case "delete": key = .delete
        case "up": key = .upArrow
        case "down": key = .downArrow
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        default:
            guard self.key.count == 1, let character = self.key.first else { return nil }
            key = KeyEquivalent(character)
        }
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return KeyboardShortcut(key, modifiers: flags)
    }
}

/// The menu bar. Every item targets the frontmost window through its
/// SceneRouter, which each window publishes with `focusedSceneValue`; when
/// no window has published one yet, the most recently active window's
/// router is used, so the menus never act on nil.
struct StudioMenuCommands: Commands {
    @FocusedValue(\.sceneRouter) private var focusedRouter
    @Environment(\.openWindow) private var openWindow
    let app: AppModel

    private var router: SceneRouter? { focusedRouter ?? app.activeRouter }
    private var controller: WorkspaceController? { router?.controller }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item("file.newFile")
            item("file.newFolder")
            Button("New Window") { openWindow(id: StudioScenes.workspace) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("New Project…") { router?.showNewProject() }
                .disabled(router == nil)
            Button("Open Folder…") { router?.showOpenFolder() }
                .keyboardShortcut("o")
                .disabled(router == nil)
            item("file.closeWorkspace")
        }
        CommandGroup(replacing: .saveItem) {
            item("file.save")
            item("file.saveAll")
            item("file.closeTab")
            item("file.revealActive")
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router?.showSettings() }
                .keyboardShortcut(",")
                .disabled(router == nil)
            // Help stays the system's menu search (it finds every command
            // here); items placed in it would not be shown on iPadOS.
            Button("Keyboard Shortcuts") { router?.showSettings(page: .keyboard) }
                .disabled(router == nil)
        }
        // Replaces the system "Show Sidebar" item, which targets a
        // NavigationSplitView this window does not have and would do nothing.
        CommandGroup(replacing: .sidebar) {
            item("view.toggleSidebar")
            item("view.togglePanel")
            Divider()
            ForEach(SidebarItem.allCases) { item("view.sidebar.\($0.rawValue)") }
            Divider()
            item("view.problems")
            item("view.output")
            Divider()
            item("view.splitRight")
            item("view.splitDown")
            item("view.joinPanes")
            Divider()
            item("view.zoomIn")
            item("view.zoomOut")
            item("view.resetZoom")
            item("view.nextTheme")
        }
        CommandMenu("Go") {
            item("go.quickOpen")
            item("go.commandPalette")
            item("go.line")
            Divider()
            item("go.nextTab")
            item("go.previousTab")
            Divider()
            ForEach(1...4, id: \.self) { item("view.focusPane\($0)") }
        }
        CommandMenu("Terminal") {
            item("terminal.toggle")
            item("terminal.new")
        }

    }

    /// A menu item for a registered command.
    @ViewBuilder
    private func item(_ id: String) -> some View {
        if let command = app.commands.command(id: id) {
            let enabled = controller.map { command.isEnabled($0) } ?? false
            Button(command.title) {
                guard let controller else { return }
                app.commands.run(id: id, in: controller)
            }
            .keyboardShortcut(command.shortcut?.swiftUI)
            .disabled(!enabled)
        }
    }
}
