import XCTest

/// Held Delete, Space and characters, arrows, Return and fast bursts in the
/// full shell (LemonText inside the workspace window, with the chrome
/// changing while typing). The keys are replayed in process through the
/// editor's UITextInput, the way UIKit delivers a Magic Keyboard's keys,
/// because XCUITest on a simulator without a hardware keyboard only
/// delivers characters.
final class KeyboardStressTests: StudioUITestCase {
    func testKeyboardStressInShell() {
        runStress(extra: [])
    }

    /// The built-in fallback editor must hold up the same way.
    func testKeyboardStressWithFallbackEditor() {
        runStress(extra: ["-StudioEditor", "plain"])
    }

    private func runStress(extra: [String]) {
        launch(files: nil, extra: ["-StudioKeyboardStress", "YES"] + extra)
        let result = element("stress.result")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'done'"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 240), .completed, "the replay finished: \(result.label)")
        let attachment = XCTAttachment(string: result.label)
        attachment.name = "Keyboard stress result"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("STUDIO_KEYBOARD_STRESS \(result.label)")
        XCTAssertTrue(result.label.hasPrefix("done;failed=0;"), result.label)
    }
}
