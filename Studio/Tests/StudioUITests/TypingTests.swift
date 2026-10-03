import XCTest

/// Typing inside the full shell: plain keys, delete, space, arrows and
/// key repeat must reach the editor with all the chrome around it, and the
/// palette and menus must give the keyboard back when they close.
final class TypingTests: StudioUITestCase {
    private var editor: XCUIElement { element("editor.text") }

    private func waitForEditorValue(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       "editor should read \(expected.debugDescription), reads \(String(describing: editor.value).debugDescription)",
                       file: file, line: line)
    }

    /// Opens an empty file and puts the caret in it.
    private func startTyping() {
        launch(files: nil)
        tap("explorer.newFile")
        expect("explorer.rename")
        app.typeText("scratch.txt\n")
        expect("tab.scratch.txt")
        editor.tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed, "the editor has keyboard focus")
    }

    func testTypingDeleteSpaceAndArrows() {
        startTyping()
        app.typeText("hello world")
        waitForEditorValue("hello world")
        for _ in 0..<5 { app.typeKey(.delete, modifierFlags: []) }
        waitForEditorValue("hello ")
        for _ in 0..<3 { app.typeKey(.space, modifierFlags: []) }
        app.typeText("x")
        waitForEditorValue("hello    x")
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeText("y")
        waitForEditorValue("hello   y x")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("next")
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
            let shorter = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value.length < 30"), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [shorter], timeout: 5), .completed, "holding delete repeats")
        } else {
            // Hardware keyboard: repeat as fast as the system delivers it.
            for _ in 0..<25 { app.typeKey(.delete, modifierFlags: []) }
            waitForEditorValue(String(repeating: "a", count: 15))
            for _ in 0..<20 { app.typeKey(.space, modifierFlags: []) }
            waitForEditorValue(String(repeating: "a", count: 15) + String(repeating: " ", count: 20))
        }
    }

    /// The palette and the menu bar must hand typing back to the editor.
    func testChromeGivesFocusBack() {
        startTyping()
        app.typeText("one")
        app.typeKey("p", modifierFlags: .command)
        expect("palette")
        app.typeKey(.escape, modifierFlags: [])
        expect("palette", exists: false)
        app.typeText(" two")
        waitForEditorValue("one two")

        tap("toolbar.toggleSidebar")
        tap("toolbar.toggleSidebar")
        editor.tap()
        app.typeText(" three")
        waitForEditorValue("one two three")
    }
}
