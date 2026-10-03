import XCTest

/// Typing inside the full shell: plain keys, delete, space, arrows and
/// key repeat must reach the editor with all the chrome around it, and the
/// palette and menus must give the keyboard back when they close.
final class TypingTests: StudioUITestCase {
    private var editor: XCUIElement { element("editor.text") }
    private var contents: XCUIElement { element("editor.contents") }

    private func waitForEditorValue(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let wanted = expected.isEmpty ? "<empty>" : expected
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", wanted), object: contents)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       "editor should read \(expected.debugDescription), reads \(contents.label.debugDescription)",
                       file: file, line: line)
    }

    /// Opens an empty file and puts the caret in it.
    private func startTyping() {
        launch(files: nil, extra: ["-StudioExposeEditorText", "YES"])
        tap("explorer.newFile")
        expect("explorer.rename")
        // Rename selects the base name, so the extension stays.
        app.typeText("scratch\n")
        expect("tab.scratch.txt")
        editor.tap()
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 5), "the editor has keyboard focus")
    }

    /// On a simulator without a hardware keyboard XCUITest's typeKey
    /// delivers only characters, so non-character keys go through the
    /// on-screen keyboard (Delete) and the programmer key bar (arrows).
    private var onScreenKeyboard: Bool { app.keyboards.firstMatch.exists }

    private func pressDelete(_ times: Int) {
        for _ in 0..<times {
            if onScreenKeyboard { app.keys["delete"].tap() } else { app.typeKey(.delete, modifierFlags: []) }
        }
    }

    private func pressLeft(_ times: Int) {
        for _ in 0..<times {
            if onScreenKeyboard { element("keybar.left").tap() } else { app.typeKey(.leftArrow, modifierFlags: []) }
        }
    }

    func testTypingDeleteSpaceAndArrows() {
        startTyping()
        app.typeText("hello world")
        waitForEditorValue("hello world")
        pressDelete(5)
        waitForEditorValue("hello ")
        app.typeText("   x")
        waitForEditorValue("hello    x")
        pressLeft(2)
        app.typeText("y")
        waitForEditorValue("hello   y x")
        app.typeText("\nnext")
        waitForEditorValue("hello   y\nnext x")
    }

    /// Held keys arrive as rapid repeats; every one must land.
    func testKeyRepeat() {
        startTyping()
        app.typeText(String(repeating: "a", count: 40))
        waitForEditorValue(String(repeating: "a", count: 40))
        if app.keyboards.firstMatch.exists, app.keys["delete"].exists {
            // On-screen keyboard: a real press-and-hold.
            app.keys["delete"].press(forDuration: 2.5)
            let shorter = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label.length < 30"), object: contents)
            XCTAssertEqual(XCTWaiter.wait(for: [shorter], timeout: 5), .completed, "holding delete repeats")
        } else {
            // Hardware keyboard: repeat as fast as the system delivers it.
            pressDelete(25)
            waitForEditorValue(String(repeating: "a", count: 15))
            for _ in 0..<20 { app.typeKey(.space, modifierFlags: []) }
            waitForEditorValue(String(repeating: "a", count: 15) + String(repeating: " ", count: 20))
        }
    }

    /// The palette and the menu bar must hand typing back to the editor.
    func testChromeGivesFocusBack() {
        startTyping()
        app.typeText("one")
        if onScreenKeyboard {
            tap("toolbar.quickOpen")
            dismissPalette()
        } else {
            app.typeKey("p", modifierFlags: .command)
            expect("palette")
            app.typeKey(.escape, modifierFlags: [])
            expect("palette", exists: false)
        }
        app.typeText(" two")
        waitForEditorValue("one two")

        tap("toolbar.toggleSidebar")
        tap("toolbar.toggleSidebar")
        editor.tap()
        app.typeText(" three")
        waitForEditorValue("one two three")
    }
}
