import XCTest

/// Keyboard tests for the editor.
///
/// `testKeyboardStressSuite` replays hardware-keyboard input through the same `UITextInput` calls UIKit makes
/// for a Magic Keyboard (characters, Return, Delete with and without Option/Command, Fn-Delete, arrows with
/// Shift/Option/Command, undo/redo, held keys) and a large-file burst, inside the app.
///
/// The other tests inject real key events with XCUITest. On a simulator without a connected hardware keyboard
/// only character input arrives that way, so they cover typing and held-key bursts of characters.
final class HardwareKeyboardTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    func testKeyboardStressSuite() throws {
        app = XCUIApplication()
        app.launchArguments = ["-keyboardStress"]
        app.launch()
        let result = app.staticTexts["stress.result"]
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline && !result.label.hasPrefix("done") {
            Thread.sleep(forTimeInterval: 1)
        }
        let label = result.label
        let attachment = XCTAttachment(string: label)
        attachment.name = "Keyboard stress result"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("LEMONTEXT_KEYBOARD_STRESS \(label)")
        XCTAssertTrue(label.hasPrefix("done"), "the stress run did not finish: \(label)")
        XCTAssertTrue(label.contains(";failed=0;"), label)
        let values = Dictionary(uniqueKeysWithValues: label.split(separator: ";").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        })
        let p99 = Double(values["p99"] ?? "") ?? .infinity
        XCTAssertLessThan(p99, 8.3, "keystroke p99 \(p99) ms on the large file exceeds one 120 Hz frame")
    }

    // MARK: Real key events (characters)

    private func launchHarness(text: String = "") {
        app = XCUIApplication()
        app.launchArguments = ["-keyboardHarness", "-autoclose", "0", "-harnessText", text]
        app.launch()
        waitForIdle(timeout: 60)
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func statusValue(_ key: String) -> String? {
        let label = app.staticTexts["harness.status"].label
        for part in label.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0] == key {
                return pair[1]
            }
        }
        return nil
    }

    @discardableResult
    private func waitForIdle(timeout: TimeInterval = 20) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = ""
        var stableSince = Date()
        while Date() < deadline {
            let label = app.staticTexts["harness.status"].label
            if label != previous {
                previous = label
                stableSince = Date()
            } else if label.contains("idle=1") && Date().timeIntervalSince(stableSince) > 0.6 {
                return label
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("The harness did not settle: \(previous)")
        return previous
    }

    private var text: String {
        waitForIdle()
        return app.staticTexts["harness.text"].label
    }

    func testTypedCharactersAndSpacesArriveInOrder() {
        launchHarness()
        app.typeText("int main(void) { return 0; }")
        XCTAssertEqual(text, "int main(void) { return 0; }")
    }

    func testHeldSpaceAndCharacterBursts() {
        launchHarness()
        app.typeText(String(repeating: " ", count: 40) + String(repeating: "a", count: 120))
        XCTAssertEqual(text, String(repeating: " ", count: 40) + String(repeating: "a", count: 120))
    }
}
