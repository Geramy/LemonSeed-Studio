import XCTest

/// The on-screen keyboard button and the programmer key bar.
///
/// Two tests force the hardware-keyboard state with a launch argument, so
/// they run anywhere. `testFollowsSimulatorHardwareKeyboard` checks real
/// detection: scripts/simulator-keyboard.sh sets the simulator's
/// "Connect Hardware Keyboard" and passes the expected state in
/// STUDIO_EXPECT_HARDWARE_KEYBOARD (1 or 0); without it the test is skipped.
final class KeyboardTests: StudioUITestCase {
    func testButtonsHiddenWithHardwareKeyboard() {
        launch(extra: ["-StudioHardwareKeyboard", "YES"])
        expect("toolbar.keyboard", exists: false, timeout: 2)
        expect("editor.keyboardButton", exists: false, timeout: 2)
    }

    func testButtonsShownWithoutHardwareKeyboard() {
        launch(extra: ["-StudioHardwareKeyboard", "NO"])
        expect("toolbar.keyboard")
        expectValue("toolbar.keyboard", "hidden")
        expect("editor.keyboardButton")
        tap("editor.keyboardButton")
        let editor = element("editor.text")
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed, "the editor took keyboard focus")
        if app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            // The simulator has no hardware keyboard: the full flow is visible.
            verifySoftwareKeyboardFlow()
        }
    }

    func testFollowsSimulatorHardwareKeyboard() throws {
        guard let expected = ProcessInfo.processInfo.environment["STUDIO_EXPECT_HARDWARE_KEYBOARD"] else {
            throw XCTSkip("Run through scripts/simulator-keyboard.sh to set the simulator's keyboard state")
        }
        launch()
        if expected == "1" {
            expect("toolbar.keyboard", exists: false, timeout: 3, "a hardware keyboard is connected")
            expect("editor.keyboardButton", exists: false, timeout: 2)
        } else {
            expect("toolbar.keyboard", timeout: 5, "no hardware keyboard is connected")
            expect("editor.keyboardButton")
            tap("editor.keyboardButton")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the on-screen keyboard appeared")
            verifySoftwareKeyboardFlow()
        }
    }

    /// With the on-screen keyboard up: the key bar shows, its keys type into
    /// the editor, and the toolbar button lowers the keyboard again.
    private func verifySoftwareKeyboardFlow() {
        expect("keybar")
        expectValue("toolbar.keyboard", "shown")
        expect("editor.keyboardButton", exists: false)
        tap("keybar.sym.{")
        tap("keybar.sym.}")
        tap("keybar.left")
        tap("keybar.sym.;")
        let editor = element("editor.text")
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "{;}"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "key bar keys typed into the editor")
        tap("keybar.undo")
        tap("toolbar.keyboard")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "the keyboard was dismissed")
        expectValue("toolbar.keyboard", "hidden")
        expect("keybar", exists: false)
        expect("editor.keyboardButton")
    }
}
