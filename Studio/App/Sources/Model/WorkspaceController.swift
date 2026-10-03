import SwiftUI
import Observation
import StudioCore
import StudioDesign

enum SidebarItem: String, CaseIterable, Identifiable, Codable {
    case explorer, search, sourceControl, agent, gpu, extensions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explorer: "Explorer"
        case .search: "Search"
        case .sourceControl: "Source Control"
        case .agent: "AI"
        case .gpu: "GPU"
        case .extensions: "Extensions"
        }
    }

    var symbol: String {
        switch self {
        case .explorer: StudioSymbol.explorer
        case .search: StudioSymbol.search
        case .sourceControl: StudioSymbol.sourceControl
        case .agent: StudioSymbol.agent
        case .gpu: StudioSymbol.gpu
        case .extensions: StudioSymbol.extensions
        }
    }

    var shortcut: KeyShortcut? {
        switch self {
        case .explorer: KeyShortcut("e", [.command, .shift])
        case .search: KeyShortcut("f", [.command, .shift])
        case .sourceControl: KeyShortcut("g", [.command, .shift])
        case .agent: KeyShortcut("l")
        case .gpu: KeyShortcut("u", [.command, .shift])
        case .extensions: KeyShortcut("x", [.command, .shift])
        }
    }
}

enum PanelTab: String, CaseIterable, Identifiable, Codable {
    case terminal, problems, output, build

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .problems: "Problems"
        case .output: "Output"
        case .build: "Build"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: StudioSymbol.terminal
        case .problems: StudioSymbol.problems
        case .output: StudioSymbol.output
        case .build: StudioSymbol.build
        }
    }
}

enum PaletteMode: Equatable {
    /// Quick open (files); also handles the ">" ":" "?" prefixes.
    case files
    case commands
    case goToLine

    var prefix: String {
        switch self {
        case .files: ""
        case .commands: ">"
        case .goToLine: ":"
        }
    }
}

/// Saved per window for state restoration.
struct WindowState: Codable, Equatable {
    var layout: EditorLayout.Snapshot?
    var sidebar: SidebarItem = .explorer
    var sidebarVisible = true
    var sidebarWidth: Double = 290
    var panelVisible = false
    var panelTab: PanelTab = .terminal
    var panelHeight: Double = 280
    var expandedFolders: [String] = []
    var recentFiles: [String] = []
}

/// One window's workspace UI: the editor layout, sidebar, bottom panel,
/// palette, terminals, search and Git status. It is the WorkspaceContext
/// providers see.
@MainActor
@Observable
final class WorkspaceController: WorkspaceContext {
    let workspace: Workspace
    let layout = EditorLayout()
    let search: SearchModel
    @ObservationIgnored weak var router: SceneRouter?
    var app: AppModel { router?.app ?? .shared }

    var sidebarItem: SidebarItem = .explorer
    var isSidebarVisible = true
    var sidebarWidth: CGFloat = 290
    var isPanelVisible = false
    var panelTab: PanelTab = .terminal
    var panelHeight: CGFloat = 280
    var isPanelMaximized = false

    var paletteMode: PaletteMode?
    var paletteQuery = ""

    private(set) var terminalSessions: [any TerminalSession] = []
    var selectedTerminalID: UUID?

    private(set) var gitStatus: GitStatusSummary?
    /// Most recently opened files (relative paths), for quick open.
    private(set) var recentFiles: [String] = []

    /// Set when launched with -StudioKeyboardStress.
    private(set) var keyboardStress: KeyboardStress?

    var explorerSelection: URL?
    var renamingURL: URL?
    var pendingDeletion: URL?
    /// A short confirmation shown at the bottom of the window.
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var gitTask: Task<Void, Never>?

    init(workspace: Workspace, router: SceneRouter?) {
        self.workspace = workspace
        self.router = router
        self.search = SearchModel(root: workspace.rootURL)
    }

    func start() async {
        await workspace.open()
        await refreshGitStatus()
        applyLaunchOptions()
    }

    func tearDown() {
        for session in terminalSessions { session.terminate() }
        terminalSessions.removeAll()
        search.cancel()
        workspace.close()
    }

    // MARK: WorkspaceContext

    var rootURL: URL { workspace.rootURL }
    var displayName: String { workspace.name }
    var activeDocument: EditorDocument? { layout.activeDocument }

    func open(_ url: URL, at position: TextPosition?) {
        open(url, at: position, preview: false)
    }

    func open(_ url: URL, at position: TextPosition? = nil, preview: Bool, in paneID: UUID? = nil) {
        guard !FileOperations.isDirectory(url) else {
            reveal(url)
            return
        }
        let document = workspace.document(for: url)
        layout.open(document, in: paneID, preview: preview)
        if let position { document.pendingReveal = position }
        if let relative = workspace.relativePath(of: url) {
            recentFiles.removeAll { $0 == relative }
            recentFiles.insert(relative, at: 0)
            if recentFiles.count > 30 { recentFiles.removeLast() }
        }
        explorerSelection = document.url
    }

    func reveal(_ url: URL) {
        sidebarItem = .explorer
        isSidebarVisible = true
        explorerSelection = url.standardizedFileURL
        Task { await workspace.tree.reveal(url) }
    }

    func log(_ text: String, channel: String) {
        workspace.output.append(text, channel: channel)
    }

    // MARK: Tabs and files

    func closeTab(_ tabID: UUID) {
        guard let pane = layout.pane(containing: tabID), let tab = pane.tab(id: tabID) else { return }
        if tab.document.isDirty, app.settings.editor.autosave {
            let document = tab.document
            Task { try? await document.save() }
        }
        if let released = layout.close(tabID) {
            workspace.release(released)
        }
    }

    func closeActiveTab() {
        if let tab = layout.focusedPane.selectedTab {
            closeTab(tab.id)
        } else if layout.paneCount > 1 {
            layout.removePane(layout.focusedPaneID)
        }
    }

    func save() {
        guard let document = layout.activeDocument else { return }
        Task {
            do {
                try await document.save()
                showToast("Saved \(document.name)")
            } catch {
                router?.errorMessage = "Could not save \(document.name): \(error.localizedDescription)"
            }
        }
    }

    func saveAll() {
        Task {
            let count = workspace.dirtyDocuments.count
            do {
                try await workspace.saveAll()
                showToast(count == 0 ? "Nothing to save" : "Saved \(count) file\(count == 1 ? "" : "s")")
            } catch {
                router?.errorMessage = error.localizedDescription
            }
        }
    }

    /// The folder new files go into: the selected folder, the selected
    /// file's folder, or the root.
    var targetFolder: URL {
        guard let selection = explorerSelection else { return rootURL }
        return FileOperations.isDirectory(selection) ? selection : selection.deletingLastPathComponent()
    }

    func newFile(in folder: URL? = nil) {
        let folder = folder ?? targetFolder
        Task {
            do {
                let url = FileOperations.uniqueURL(for: "untitled.txt", in: folder)
                let created = try await workspace.createFile(named: url.lastPathComponent, in: folder)
                await workspace.tree.reveal(created)
                explorerSelection = created
                renamingURL = created
                isSidebarVisible = true
                sidebarItem = .explorer
                open(created, preview: false)
            } catch {
                router?.errorMessage = error.localizedDescription
            }
        }
    }

    func newFolder(in folder: URL? = nil) {
        let folder = folder ?? targetFolder
        Task {
            do {
                let url = FileOperations.uniqueURL(for: "New Folder", in: folder)
                let created = try await workspace.createFolder(named: url.lastPathComponent, in: folder)
                await workspace.tree.reveal(created)
                explorerSelection = created
                renamingURL = created
                isSidebarVisible = true
                sidebarItem = .explorer
            } catch {
                router?.errorMessage = error.localizedDescription
            }
        }
    }

    func rename(_ url: URL, to name: String) {
        renamingURL = nil
        guard name != url.lastPathComponent, !name.isEmpty else { return }
        Task {
            do {
                let renamed = try await workspace.rename(url, to: name)
                explorerSelection = renamed
            } catch {
                router?.errorMessage = error.localizedDescription
            }
        }
    }

    func move(_ url: URL, into folder: URL) {
        Task {
            do {
                let moved = try await workspace.move(url, into: folder)
                await workspace.tree.reveal(moved)
                explorerSelection = moved
            } catch {
                router?.errorMessage = error.localizedDescription
            }
        }
    }

    func importItems(_ urls: [URL], into folder: URL) {
        Task {
            for url in urls {
                do {
                    if FileOperations.relativePath(of: url, to: rootURL) != nil {
                        _ = try await workspace.move(url, into: folder)
                    } else {
                        _ = try await workspace.importItem(url, into: folder)
                    }
                } catch {
                    router?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func duplicate(_ url: URL) {
        Task {
            do { explorerSelection = try await workspace.duplicate(url) } catch {
                router?.errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ url: URL) {
        pendingDeletion = nil
        Task {
            do {
                let affected = try await workspace.delete(url)
                for document in affected {
                    layout.close(document: document)
                    workspace.release(document)
                }
                if explorerSelection == url.standardizedFileURL { explorerSelection = nil }
                showToast("Deleted \(url.lastPathComponent)")
            } catch {
                router?.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Chrome

    func toggleSidebar() {
        withAnimation(Motion.layout) { isSidebarVisible.toggle() }
    }

    /// Shows a sidebar view; selecting the visible one again hides the sidebar.
    func show(_ item: SidebarItem, toggle: Bool = false) {
        withAnimation(Motion.layout) {
            if toggle, isSidebarVisible, sidebarItem == item {
                isSidebarVisible = false
            } else {
                sidebarItem = item
                isSidebarVisible = true
            }
        }
        if item == .search { search.focusRequest += 1 }
    }

    func togglePanel() {
        withAnimation(Motion.layout) { isPanelVisible.toggle() }
        if isPanelVisible, panelTab == .terminal { ensureTerminal() }
    }

    func show(_ tab: PanelTab) {
        withAnimation(Motion.layout) {
            panelTab = tab
            isPanelVisible = true
        }
        if tab == .terminal { ensureTerminal() }
    }

    func toggleTerminal() {
        if isPanelVisible, panelTab == .terminal { togglePanel() } else { show(.terminal) }
    }

    func split(_ direction: EditorLayout.SplitDirection) {
        withAnimation(Motion.layout) {
            if layout.split(direction: direction) == nil {
                showToast("The editor area has as many panes as it can hold")
            }
        }
    }

    func zoom(by delta: Double) {
        app.settings.adjustFontSize(by: delta)
        showToast("Font size \(Int(app.settings.codeFontSize)) pt")
    }

    func zoom(to size: Double) {
        app.settings.codeFontSize = size
        showToast("Font size \(Int(size)) pt")
    }

    /// The palette was opened while the user was typing somewhere.
    @ObservationIgnored private var paletteInterruptedTyping = false

    func showPalette(_ mode: PaletteMode, query: String? = nil) {
        if paletteMode == nil {
            paletteInterruptedTyping = app.keyboard.hasHardwareKeyboard || app.keyboard.isSoftwareKeyboardVisible
        }
        withAnimation(Motion.present) {
            paletteMode = mode
            paletteQuery = query ?? mode.prefix
        }
    }

    /// Closes the palette and, with a hardware keyboard, hands the keyboard
    /// back to where the user was typing so they can keep going.
    func dismissPalette(restoreFocus: Bool = true) {
        withAnimation(Motion.present) { paletteMode = nil }
        if restoreFocus, paletteInterruptedTyping {
            Task { @MainActor in
                // After the palette's field has left the hierarchy.
                try? await Task.sleep(for: .milliseconds(50))
                app.textInput.focus()
            }
        }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(Motion.present) { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.present) { self.toast = nil }
        }
    }

    // MARK: Terminal

    @discardableResult
    func ensureTerminal() -> (any TerminalSession)? {
        if let selected = terminalSessions.first(where: { $0.id == selectedTerminalID }) ?? terminalSessions.first {
            selectedTerminalID = selected.id
            return selected
        }
        return newTerminal()
    }

    @discardableResult
    func newTerminal() -> (any TerminalSession)? {
        guard let provider = app.services.terminal else { return nil }
        let session = provider.makeSession(workingDirectory: rootURL, context: self)
        terminalSessions.append(session)
        selectedTerminalID = session.id
        panelTab = .terminal
        isPanelVisible = true
        return session
    }

    func closeTerminal(_ id: UUID) {
        guard let index = terminalSessions.firstIndex(where: { $0.id == id }) else { return }
        terminalSessions[index].terminate()
        terminalSessions.remove(at: index)
        if selectedTerminalID == id { selectedTerminalID = terminalSessions.last?.id }
    }

    // MARK: Git

    func refreshGitStatus() async {
        gitStatus = await app.services.git.status(for: rootURL)
    }

    // MARK: State restoration

    var windowState: WindowState {
        WindowState(layout: layout.snapshot { [workspace] in workspace.relativePath(of: $0) },
                    sidebar: sidebarItem, sidebarVisible: isSidebarVisible, sidebarWidth: sidebarWidth,
                    panelVisible: isPanelVisible, panelTab: panelTab, panelHeight: panelHeight,
                    expandedFolders: workspace.tree.expandedRelativePaths, recentFiles: recentFiles)
    }

    func restore(_ state: WindowState) {
        sidebarItem = state.sidebar
        isSidebarVisible = state.sidebarVisible
        sidebarWidth = state.sidebarWidth
        panelTab = state.panelTab
        panelHeight = state.panelHeight
        recentFiles = state.recentFiles
        if let snapshot = state.layout {
            layout.restore(snapshot) { [workspace] path in
                let url = workspace.url(forRelativePath: path)
                return FileManager.default.fileExists(atPath: url.path) ? workspace.document(for: url) : nil
            }
        }
        if state.panelVisible { show(state.panelTab) }
        let folders = state.expandedFolders
        Task { await workspace.tree.restoreExpansion(folders) }
    }

    // MARK: Launch options (automation)

    private func applyLaunchOptions() {
        if let files = LaunchOptions.openFiles {
            for (index, group) in files.split(separator: "|").enumerated() {
                if index > 0 { layout.split(direction: .right) }
                for path in group.split(separator: ";") {
                    open(workspace.url(forRelativePath: String(path)), preview: false)
                }
            }
            layout.focusPane(number: 1)
        }
        if let reveal = LaunchOptions.revealPath {
            Task { await workspace.tree.reveal(workspace.url(forRelativePath: reveal)) }
        }
        if let item = LaunchOptions.sidebar.flatMap(SidebarItem.init(rawValue:)) { show(item) }
        if let text = LaunchOptions.search {
            show(.search)
            search.query = text
            search.run()
        }
        if let tab = LaunchOptions.panel.flatMap(PanelTab.init(rawValue:)) {
            show(tab)
            if tab == .terminal, let command = LaunchOptions.terminalCommand {
                Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    (terminalSessions.first as? CommandRunningSession)?.send(line: command)
                }
            }
        }
        if let mode = LaunchOptions.palette {
            // After the first layout: opening it while the editors are
            // still loading lands in a render that reads the old state.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                showPalette(mode == "commands" ? .commands : mode == "line" ? .goToLine : .files,
                            query: LaunchOptions.paletteQuery)
            }
        }
        if LaunchOptions.showSettings { router?.isSettingsPresented = true }
        if LaunchOptions.keyboardStress {
            let stress = KeyboardStress(controller: self)
            keyboardStress = stress
            Task { await stress.run() }
        }
    }
}

/// Terminal sessions that can run a line as if typed.
@MainActor
protocol CommandRunningSession: TerminalSession {
    func send(line: String)
}
