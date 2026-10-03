import XCTest
import SwiftUI
import StudioCore
import StudioDesign
import LemonText
@testable import LemonSeedStudio

@MainActor
final class CommandSetTests: XCTestCase {
    private func registry() -> CommandRegistry {
        let registry = CommandRegistry()
        StudioCommands.register(into: registry)
        return registry
    }

    func testCommandIDsAreUniqueAndShortcutsDoNotConflict() {
        let commands = registry().commands
        XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
        XCTAssertTrue(registry().conflicts.isEmpty, "conflicts: \(registry().conflicts)")
    }

    /// App shortcuts must never take keys text input needs: every one has
    /// ⌘, ⌃ or ⌥, so plain letters, space, delete, Return and arrows (and
    /// their key repeat) always reach the editor, terminal or prompt.
    func testNoShortcutBindsUnmodifiedTypingKeys() {
        for command in registry().commands {
            guard let shortcut = command.shortcut else { continue }
            let modified = !shortcut.modifiers.isDisjoint(with: [.command, .control, .option])
            XCTAssertTrue(modified || shortcut.key == "escape", "\(command.id) binds \(shortcut) without ⌘, ⌃ or ⌥")
        }
    }

    func testEveryShortcutMapsToSwiftUI() {
        for command in registry().commands {
            guard let shortcut = command.shortcut else { continue }
            XCTAssertNotNil(shortcut.swiftUI, command.id)
        }
    }

    func testPlanKeymapIsBound() {
        // The plan's keymap (section 1.2) for the shell's commands.
        let expected: [String: KeyShortcut] = [
            "go.quickOpen": KeyShortcut("p"),
            "go.commandPalette": KeyShortcut("p", [.command, .shift]),
            "view.toggleSidebar": KeyShortcut("b"),
            "view.togglePanel": KeyShortcut("j"),
            "terminal.toggle": KeyShortcut("`", .control),
            "view.splitRight": KeyShortcut("\\"),
            "view.focusPane1": KeyShortcut("1"),
            "view.sidebar.agent": KeyShortcut("l"),
            "view.sidebar.sourceControl": KeyShortcut("g", [.command, .shift]),
        ]
        let registry = registry()
        for (id, shortcut) in expected {
            XCTAssertEqual(registry.command(id: id)?.shortcut, shortcut, id)
        }
    }

    func testMenuCommandsExist() {
        // Every id the menu bar refers to must be registered, or its item silently disappears.
        let menuIDs = ["file.newFile", "file.newFolder", "file.closeWorkspace", "file.save", "file.saveAll", "file.closeTab",
                       "file.revealActive", "view.toggleSidebar", "view.togglePanel", "view.problems", "view.output",
                       "view.splitRight", "view.splitDown", "view.joinPanes", "view.zoomIn", "view.zoomOut", "view.resetZoom",
                       "view.nextTheme", "go.quickOpen", "go.commandPalette", "go.line", "go.nextTab", "go.previousTab",
                       "terminal.toggle", "terminal.new"]
            + SidebarItem.allCases.map { "view.sidebar.\($0.rawValue)" }
            + (1...4).map { "view.focusPane\($0)" }
        let registry = registry()
        for id in menuIDs {
            XCTAssertNotNil(registry.command(id: id), id)
        }
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    func testSettingsPersist() {
        let suite = "StudioAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.themeID, Theme.lemonDark.id)
        settings.themeID = Theme.paper.id
        settings.codeFontSize = 17
        settings.codeFontFamily = .jetBrainsMono
        settings.editor.tabWidth = 2
        settings.lseEndpoint = "http://10.0.0.2:8080/v1"
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.themeID, Theme.paper.id)
        XCTAssertEqual(reloaded.codeFontSize, 17)
        XCTAssertEqual(reloaded.codeFontFamily, .jetBrainsMono)
        XCTAssertEqual(reloaded.editor.tabWidth, 2)
        XCTAssertEqual(reloaded.lseEndpointURL.host(), "10.0.0.2")
    }

    func testThemeSelectionAndSystemMatching() {
        let suite = "StudioAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.themeID = Theme.orchard.id
        XCTAssertEqual(settings.theme(for: .light).id, Theme.orchard.id)
        settings.matchSystemAppearance = true
        XCTAssertEqual(settings.theme(for: .light).id, Theme.lemonLight.id)
        XCTAssertEqual(settings.theme(for: .dark).id, Theme.lemonDark.id)
        settings.cycleTheme()
        XCTAssertFalse(settings.matchSystemAppearance)
        XCTAssertNotEqual(settings.themeID, Theme.orchard.id)
    }

    func testFontSizeAdjustmentIsClamped() {
        let suite = "StudioAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for _ in 0..<40 { settings.adjustFontSize(by: 1) }
        XCTAssertEqual(settings.codeFontSize, Double(CodeFont.sizeRange.upperBound))
        for _ in 0..<40 { settings.adjustFontSize(by: -1) }
        XCTAssertEqual(settings.codeFontSize, Double(CodeFont.sizeRange.lowerBound))
    }
}

@MainActor
final class WorkspaceControllerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("int main(void) { return 0; }\n".utf8).write(to: root.appendingPathComponent("src/main.c"))
        try Data("# Readme\n".utf8).write(to: root.appendingPathComponent("README.md"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOpenTracksRecentsAndSelection() async throws {
        let controller = WorkspaceController(workspace: Workspace(rootURL: root), router: nil)
        defer { controller.tearDown() }
        await controller.workspace.open()
        controller.open(root.appendingPathComponent("README.md"), preview: true)
        controller.open(root.appendingPathComponent("src/main.c"), preview: false)
        XCTAssertEqual(controller.recentFiles, ["src/main.c", "README.md"])
        XCTAssertEqual(controller.activeDocument?.name, "main.c")
        XCTAssertEqual(controller.explorerSelection?.lastPathComponent, "main.c")
        XCTAssertEqual(controller.targetFolder.lastPathComponent, "src")
    }

    func testWindowStateRoundTrip() async throws {
        let controller = WorkspaceController(workspace: Workspace(rootURL: root), router: nil)
        defer { controller.tearDown() }
        await controller.workspace.open()
        controller.open(root.appendingPathComponent("README.md"), preview: false)
        controller.split(.right)
        controller.open(root.appendingPathComponent("src/main.c"), preview: false)
        controller.sidebarItem = .search
        controller.panelTab = .problems
        let data = try JSONEncoder().encode(controller.windowState)
        let state = try JSONDecoder().decode(WindowState.self, from: data)

        let restored = WorkspaceController(workspace: Workspace(rootURL: root), router: nil)
        defer { restored.tearDown() }
        await restored.workspace.open()
        restored.restore(state)
        XCTAssertEqual(restored.layout.paneCount, 2)
        XCTAssertEqual(restored.layout.orderedPanes.map { $0.tabs.map(\.document.name) }, [["README.md"], ["README.md", "main.c"]])
        XCTAssertEqual(restored.sidebarItem, .search)
        XCTAssertEqual(restored.panelTab, .problems)
    }

    func testChromeToggles() {
        let controller = WorkspaceController(workspace: Workspace(rootURL: root), router: nil)
        defer { controller.tearDown() }
        controller.toggleSidebar()
        XCTAssertFalse(controller.isSidebarVisible)
        controller.show(.search)
        XCTAssertTrue(controller.isSidebarVisible)
        XCTAssertEqual(controller.sidebarItem, .search)
        controller.show(.search, toggle: true)
        XCTAssertFalse(controller.isSidebarVisible)
        controller.show(.problems)
        XCTAssertTrue(controller.isPanelVisible)
        controller.togglePanel()
        XCTAssertFalse(controller.isPanelVisible)
        controller.showPalette(.commands)
        XCTAssertEqual(controller.paletteQuery, ">")
        controller.dismissPalette()
        XCTAssertNil(controller.paletteMode)
    }

    func testFileCommandsThroughController() async throws {
        let controller = WorkspaceController(workspace: Workspace(rootURL: root), router: nil)
        defer { controller.tearDown() }
        await controller.workspace.open()
        controller.newFolder(in: root)
        let created = await waitFor { FileManager.default.fileExists(atPath: self.root.appendingPathComponent("New Folder").path) }
        XCTAssertTrue(created)
        XCTAssertEqual(controller.renamingURL?.lastPathComponent, "New Folder")
        controller.rename(root.appendingPathComponent("New Folder"), to: "lib")
        let renamed = await waitFor { FileManager.default.fileExists(atPath: self.root.appendingPathComponent("lib").path) }
        XCTAssertTrue(renamed)
        controller.delete(root.appendingPathComponent("lib"))
        let deleted = await waitFor { !FileManager.default.fileExists(atPath: self.root.appendingPathComponent("lib").path) }
        XCTAssertTrue(deleted)
    }

    private func waitFor(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@MainActor
final class DriverMonitorTests: XCTestCase {
    func testSimulatorReportsNoEmbeddedDriver() {
        let monitor = DriverMonitor()
        XCTAssertTrue(monitor.isSimulator)
        XCTAssertNil(monitor.embeddedDext, "simulator builds do not embed the dext")
        if let service = monitor.service {
            // The simulator shares the Mac's I/O Registry: a Mac with a GPU on
            // its own MacLinuxGPU driver shows that service, never this app's.
            XCTAssertNotEqual(service.userServerName, DriverMonitor.dextBundleID)
        } else {
            XCTAssertEqual(monitor.engineState, .unknown)
        }
        XCTAssertNotNil(monitor.lastChecked)
    }
}

@MainActor
final class LemonTextBridgeTests: XCTestCase {
    func testThemeMapsStudioColors() {
        for theme in StudioDesign.Theme.builtIn {
            let editor = LemonText.EditorTheme(studio: theme)
            XCTAssertEqual(editor.isDark, theme.appearance == .dark, theme.name)
            XCTAssertEqual(editor.background.red, theme.palette.editor.red, accuracy: 0.001, theme.name)
            XCTAssertEqual(editor.caret.green, theme.palette.accent.green, accuracy: 0.001, theme.name)
            XCTAssertEqual(editor.style(forCapture: "keyword.control")?.color.red ?? -1, theme.syntax.keyword.red, accuracy: 0.001)
            XCTAssertEqual(editor.style(forCapture: "string")?.color.blue ?? -1, theme.syntax.string.blue, accuracy: 0.001)
            XCTAssertEqual(editor.style(forCapture: "comment")?.isItalic, true)
        }
    }

    func testProviderClaimsLoadedTextOnly() async throws {
        let provider = LemonTextEditorProvider()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString).c")
        try Data("int x;".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        XCTAssertNil(provider.priority(for: document), "not while loading")
        await document.load()
        XCTAssertEqual(provider.priority(for: document), 100)
        let services = StudioServices()
        services.register(editor: provider)
        XCTAssertTrue(services.editor(for: document) === provider, "LemonText wins over the plain editor")
    }

    func testFontFamiliesMapToPostScriptNames() {
        XCTAssertNil(LemonTextSessionNames.postScriptName(.sfMono))
        XCTAssertEqual(LemonTextSessionNames.postScriptName(.jetBrainsMono), "JetBrainsMono-Regular")
    }
}
