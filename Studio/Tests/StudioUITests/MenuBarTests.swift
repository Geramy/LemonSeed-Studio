import XCTest

/// Chooses every Studio command in the iPadOS menu bar, by tapping (no
/// hardware keyboard needed), and checks each one visibly takes effect.
final class MenuBarTests: StudioUITestCase {
    func testFileMenu() {
        launch()
        // New File creates and opens untitled.txt, ready to rename.
        menu("File", "New File")
        expect("tab.untitled.txt")
        expect("explorer.rename")
        app.typeText("\n")

        menu("File", "New Folder")
        expect("explorer.row.Sources/New Folder", "new items go next to the selected file")

        menu("File", "Save")
        expectToast(containing: "Saved")

        menu("File", "Save All")
        expectToast(containing: "ave")

        // Close Editor closes the active tab.
        XCTAssertTrue(element("tab.untitled.txt").isSelected)
        menu("File", "Close Editor")
        expect("tab.untitled.txt", exists: false)

        // Reveal Active File brings the explorer back with the file selected.
        tap("toolbar.toggleSidebar")
        expect("sidebar.explorer", exists: false)
        menu("File", "Reveal Active File in Explorer")
        expect("sidebar.explorer")

        menu("File", "New Project…")
        XCTAssertTrue(app.alerts["New Project"].waitForExistence(timeout: 5))
        app.alerts["New Project"].textFields.firstMatch.typeText("Created From Menu")
        app.alerts["New Project"].buttons["Create"].tap()
        XCTAssertTrue(element("toolbar.workspaceMenu").waitForExistence(timeout: 5))
        let renamed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Created From Menu"),
                                                object: element("toolbar.workspaceMenu"))
        XCTAssertEqual(XCTWaiter.wait(for: [renamed], timeout: 5), .completed, "the new project opened")

        menu("File", "Open Folder…")
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the Files folder picker appeared")
        cancel.tap()

        menu("File", "Close Workspace")
        expect("welcome.openFolder")
    }

    func testNewWindow() {
        launch()
        menu("File", "New Window")
        expect("welcome", timeout: 10, "a new window opens on the welcome screen")
    }

    func testViewMenuChrome() {
        launch()
        menu("View", "Toggle Sidebar")
        expect("sidebar.explorer", exists: false)
        menu("View", "Toggle Sidebar")
        expect("sidebar.explorer")

        menu("View", "Toggle Panel")
        expect("panel")
        menu("View", "Toggle Panel")
        expect("panel", exists: false)

        for (title, id) in [("Show Search", "search"), ("Show Source Control", "sourceControl"), ("Show AI", "agent"),
                            ("Show GPU", "gpu"), ("Show Extensions", "extensions"), ("Show Explorer", "explorer")] {
            menu("View", title)
            expect("sidebar.\(id)", "\(title)")
        }

        menu("View", "Show Problems")
        expect("problems.empty")
        menu("View", "Show Output")
        expect("output.view")
    }

    func testViewMenuPanesAndFonts() {
        launch()
        menu("View", "Split Editor Right")
        expect("editor.pane.1")
        menu("View", "Split Editor Down")
        expect("editor.pane.2")
        menu("View", "Join All Editor Panes")
        expect("editor.pane.1", exists: false)

        menu("View", "Increase Font Size")
        expectToast(containing: "15 pt")
        menu("View", "Decrease Font Size")
        expectToast(containing: "14 pt")
        menu("View", "Increase Font Size")
        menu("View", "Reset Font Size")
        expectToast(containing: "14 pt")
        menu("View", "Next Color Theme")
        expectToast(containing: "Lemon Light")
        menu("View", "Next Color Theme")
        expectToast(containing: "Orchard")
    }

    func testGoMenu() {
        launch()
        menu("Go", "Go to File…")
        expect("palette")
        expectValue("palette.field", "")
        dismissPalette()

        menu("Go", "Show All Commands")
        expectValue("palette.field", ">")
        dismissPalette()

        menu("Go", "Go to Line…")
        expectValue("palette.field", ":")
        dismissPalette()

        XCTAssertTrue(isSelected("tab.main.c"))
        menu("Go", "Next Editor")
        XCTAssertTrue(element("tab.README.md").waitForExistence(timeout: 2))
        XCTAssertTrue(isSelected("tab.README.md"), "Next Editor wraps to the first tab")
        menu("Go", "Previous Editor")
        XCTAssertTrue(isSelected("tab.main.c"))

        menu("View", "Split Editor Right")
        expectValue("editor.pane.1", "focused")
        menu("Go", "Focus Editor Pane 1")
        expectValue("editor.pane.0", "focused")
        menu("Go", "Focus Editor Pane 2")
        expectValue("editor.pane.1", "focused")
    }

    func testTerminalMenu() {
        launch()
        menu("Terminal", "Toggle Terminal")
        expect("terminal.view")
        menu("Terminal", "New Terminal")
        expect("terminal.sessions", "a second session adds the session picker")
        menu("Terminal", "Toggle Terminal")
        expect("panel", exists: false)
    }

    func testAppMenu() {
        launch()
        menu("LemonSeed Studio", "Settings…")
        expect("settings")
        dismissSettings()
        menu("LemonSeed Studio", "Keyboard Shortcuts")
        expect("settings")
        XCTAssertTrue(app.staticTexts["Go: Show All Commands"].waitForExistence(timeout: 3), "opens on the keymap")
        dismissSettings()
    }

    /// ⌘W is also the system's Window › Close: in the Studio it must close
    /// the editor tab, never the window.
    func testCommandWClosesTheTabNotTheWindow() {
        launch()
        expect("tab.main.c")
        app.typeKey("w", modifierFlags: .command)
        expect("tab.main.c", exists: false)
        expect("tab.README.md")
        expect("toolbar.workspaceMenu")
    }

    /// The menu bar works on the welcome screen too, where no workspace is open.
    func testMenusWithoutWorkspace() {
        launchWelcome()
        menu("LemonSeed Studio", "Settings…")
        expect("settings")
        dismissSettings()
        menu("File", "New Project…")
        XCTAssertTrue(app.alerts["New Project"].waitForExistence(timeout: 5))
        app.alerts["New Project"].buttons["Cancel"].tap()
        menu("File", "Open Folder…")
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Cancel"].firstMatch.tap()
    }
}
