import XCTest

/// Taps every toolbar button, in-window menu item and chrome control and
/// checks each one visibly takes effect.
final class ToolbarTests: StudioUITestCase {
    func testTopBarButtons() {
        launch()
        tap("toolbar.toggleSidebar")
        expect("sidebar.explorer", exists: false)
        tap("toolbar.toggleSidebar")
        expect("sidebar.explorer")

        tap("toolbar.togglePanel")
        expect("panel")
        tap("toolbar.togglePanel")
        expect("panel", exists: false)

        tap("toolbar.splitRight")
        expect("editor.pane.1")

        tap("toolbar.agent")
        expect("sidebar.agent")
        tap("toolbar.agent")
        expect("sidebar.agent", exists: false)

        // The search field opens quick open; picking a result opens the file.
        tap("toolbar.quickOpen")
        expect("palette")
        app.typeText("util.h")
        tap("palette.item.file:Sources/util.h")
        expect("palette", exists: false)
        expect("tab.util.h")
    }

    func testWorkspaceMenu() {
        launch()
        tap("toolbar.workspaceMenu")
        app.buttons["New Project…"].firstMatch.tap()
        XCTAssertTrue(app.alerts["New Project"].waitForExistence(timeout: 5))
        app.alerts["New Project"].buttons["Cancel"].tap()

        tap("toolbar.workspaceMenu")
        app.buttons["Open Folder…"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10), "the folder picker appeared")
        app.buttons["Cancel"].firstMatch.tap()

        tap("toolbar.workspaceMenu")
        app.buttons["Close Workspace"].firstMatch.tap()
        expect("welcome.openFolder")

        // Reopen from Recent.
        tap("welcome.recent.Demo")
        expect("toolbar.workspaceMenu")
        tap("toolbar.workspaceMenu")
        XCTAssertTrue(app.buttons["Demo"].firstMatch.waitForExistence(timeout: 3), "recent workspaces are listed")
        app.buttons["New Window"].firstMatch.tap()
        expect("welcome", timeout: 10)
        menu("Window", "Close")
    }

    func testMoreMenu() {
        launch()
        let items: [(String, () -> Void)] = [
            ("Show All Commands", { self.expectValue("palette.field", ">"); self.dismissPalette() }),
            ("Go to File…", { self.expect("palette"); self.dismissPalette() }),
            ("Split Editor Down", { self.expect("editor.pane.1") }),
            ("New Terminal", { self.expect("terminal.view") }),
            ("Settings…", { self.expect("settings"); self.dismissSettings() }),
        ]
        for (title, check) in items {
            tap("toolbar.more")
            let item = app.buttons[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "More › \(title)")
            item.tap()
            check()
        }
        tap("toolbar.more")
        app.buttons["GPU Monitor in New Window"].firstMatch.tap()
        expect("gpu.monitorWindow", timeout: 10)
        menu("Window", "Close")
    }

    /// A window left open by an earlier run (here the GPU Monitor, in
    /// front) must not take the place of the workspace a launch asks for.
    func testARestoredGPUMonitorDoesNotReplaceTheWorkspace() {
        launch()
        tap("toolbar.more")
        app.buttons["GPU Monitor in New Window"].firstMatch.tap()
        expect("gpu.monitorWindow", timeout: 10)
        // UIKit records which windows are open, and which is in front, on its
        // own schedule a few seconds after a change; this is the state a run
        // that failed with the monitor open leaves behind.
        Thread.sleep(forTimeInterval: 10)
        app.terminate()
        launch()
        expect("gpu.monitorWindow", exists: false)
    }

    func testActivityBar() {
        launch()
        for item in ["search", "sourceControl", "agent", "gpu", "extensions", "explorer"] {
            tap("activity.\(item)")
            expect("sidebar.\(item)")
        }
        // Tapping the selected item hides the sidebar.
        tap("activity.explorer")
        expect("sidebar.explorer", exists: false)
        tap("activity.settings")
        expect("settings")
        dismissSettings()
    }

    func testExplorerButtonsAndRows() {
        launch()
        tap("explorer.newFolder")
        expect("explorer.rename")
        app.typeText("lib\n")
        // New items go next to the selected item (main.c is open, so Sources).
        expect("explorer.row.Sources/lib")

        tap("explorer.newFile")
        expect("tab.untitled.txt")
        app.typeText("\n")

        tap("explorer.collapseAll")
        expect("explorer.row.Sources/main.c", exists: false)
        tap("explorer.row.Sources")
        expect("explorer.row.Sources/main.c")
        tap("explorer.refresh")
        expect("explorer.row.Sources/main.c")

        // A file row opens a tab.
        tap("explorer.row.Makefile")
        expect("tab.Makefile")
    }

    func testTabStripAndBreadcrumb() {
        launch()
        tap("tab.README.md")
        XCTAssertTrue(isSelected("tab.README.md"))
        tap("tab.close.README.md")
        expect("tab.README.md", exists: false)

        tap("tabs.split")
        expect("editor.pane.1")
        tap("tabs.more")
        app.buttons["Join All Panes"].firstMatch.tap()
        expect("editor.pane.1", exists: false)

        tap("tabs.more")
        app.buttons["Split Down"].firstMatch.tap()
        expect("editor.pane.1")
        tap("tabs.more")
        app.buttons["Close Pane"].firstMatch.tap()
        expect("editor.pane.1", exists: false)

        tap("tabs.more")
        app.buttons["Close All"].firstMatch.tap()
        expect("tab.main.c", exists: false)
        // The empty pane's shortcuts all work.
        tap("empty.commands")
        expectValue("palette.field", ">")
        dismissPalette()
        tap("empty.quickOpen")
        expect("palette")
        dismissPalette()
        tap("empty.terminal")
        expect("terminal.view")
        tap("empty.newFile")
        expect("tab.untitled.txt")
    }

    func testBottomPanel() {
        launch()
        tap("toolbar.togglePanel")
        for (tab, content) in [("problems", "problems.empty"), ("output", "output.view"), ("build", "build.view"),
                               ("terminal", "terminal.view")] {
            tap("panel.tab.\(tab)")
            expect(content)
        }
        tap("terminal.new")
        expect("terminal.sessions")
        tap("terminal.kill")
        expect("terminal.sessions", exists: false)
        tap("panel.maximize")
        expect("editor.pane.0", exists: false, "a maximized panel hides the editor")
        tap("panel.maximize")
        expect("editor.pane.0")
        tap("panel.close")
        expect("panel", exists: false)
    }

    func testStatusBar() {
        launch()
        tap("status.problems")
        expect("problems.empty")
        tap("status.engine")
        expect("sidebar.gpu")
        tap("status.model")
        expect("sidebar.agent")
        tap("status.cursor")
        expectValue("palette.field", ":")
        app.typeText("3\n")
        expect("palette", exists: false)
        // The Demo project is not a Git repository, so there is no branch item.
        XCTAssertFalse(element("status.branch").exists)
    }

    func testSearchSidebar() {
        launch()
        tap("activity.search")
        // The styled field shares its identifier with its icon; type into the field itself.
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("add")
        expect("search.file.Sources/util.c")
        expect("search.summary")
        tap("search.case")
        tap("search.word")
        tap("search.regex")
        tap("search.filters")
        expect("search.include")
        tap("search.clear")
        expect("search.file.Sources/util.c", exists: false)
    }

    func testWelcomeScreen() {
        launchWelcome()
        tap("welcome.settings")
        expect("settings")
        tap("settings.page.editor")
        tap("settings.page.about")
        dismissSettings()
        tap("welcome.newProject")
        XCTAssertTrue(app.alerts["New Project"].waitForExistence(timeout: 5))
        app.alerts["New Project"].buttons["Cancel"].tap()
        tap("welcome.openFolder")
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Cancel"].firstMatch.tap()
        tap("welcome.project.Demo")
        expect("toolbar.workspaceMenu")
    }

    func testSettingsControls() {
        launch()
        tap("activity.settings")
        tap("settings.theme.lemon-light")
        XCTAssertTrue(isSelected("settings.theme.lemon-light"))
        tap("settings.theme.lemon-dark")
        tap("settings.page.keyboard")
        expect("settings.keyboard")
        tap("settings.page.model")
        expect("settings.endpoint")
        tap("settings.testEndpoint")
        tap("settings.page.engine")
        expect("engine.state")
        tap("engine.refresh")
        dismissSettings()
    }
}
