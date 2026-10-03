import XCTest

/// Shared setup for the Studio's UI tests: a fresh library, a generated
/// "Demo" project opened in the window, and helpers for the app's elements
/// and the iPadOS menu bar (which SpringBoard hosts).
@MainActor
class StudioUITestCase: XCTestCase {
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// Launches with the Demo project and `files` open (";" separates tabs).
    func launch(files: String? = "README.md;Sources/main.c", extra: [String] = []) {
        app.launchArguments = ["-StudioResetState", "YES", "-StudioSampleProject", "Demo", "-StudioOpenProject", "Demo"]
            + Self.fixedSettings
        if let files { app.launchArguments += ["-StudioOpenFiles", files] }
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(element("toolbar.workspaceMenu").waitForExistence(timeout: 15), "the workspace window opened")
    }

    func launchWelcome(extra: [String] = []) {
        app.launchArguments = ["-StudioResetState", "YES", "-StudioSampleProject", "Demo"] + Self.fixedSettings + extra
        app.launch()
        XCTAssertTrue(element("welcome.openFolder").waitForExistence(timeout: 15))
    }

    /// Settings pinned for every run (launch arguments shadow saved values).
    static let fixedSettings = ["-StudioDensity", "touch", "-themeID", "lemon-dark", "-codeFontSize", "14",
                                "-matchSystemAppearance", "NO", "-showActivityBar", "YES"]

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        dismissMenuBar()
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(identifier) exists", file: file, line: line)
        XCTAssertTrue(target.isHittable, "\(identifier) is hittable", file: file, line: line)
        target.tap()
    }

    func expect(_ identifier: String, exists: Bool = true, timeout: TimeInterval = 5,
                _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        if exists {
            XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) should appear. \(message)", file: file, line: line)
        } else {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: target)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed,
                           "\(identifier) should disappear. \(message)", file: file, line: line)
        }
    }

    func expectValue(_ identifier: String, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       "\(identifier) value should be \(value), is \(String(describing: target.value))", file: file, line: line)
    }

    /// Waits for the toast to show text containing `text`.
    func expectToast(containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        let toast = element("toast")
        let shows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: toast)
        XCTAssertEqual(XCTWaiter.wait(for: [shows], timeout: 5), .completed,
                       "toast should say \(text), says \(toast.exists ? toast.label : "nothing")", file: file, line: line)
    }

    /// Whatever has keyboard focus (the editor's text view, a field).
    var focusedElement: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
    }

    func isSelected(_ identifier: String) -> Bool {
        element(identifier).isSelected
    }

    /// Other apps share the simulator; bring the Studio back if one took over.
    func ensureForeground() {
        if app.state != .runningForeground {
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 5)
        }
    }

    // MARK: Menu bar

    /// The menu bar stays up after a choice and swallows the next tap
    /// (system behavior); close it first so taps reach the app.
    func dismissMenuBar() {
        ensureForeground()
        let file = springboard.buttons["File"].firstMatch
        guard file.exists, file.isHittable else { return }
        let frame = element("toolbar.workspaceMenu").exists ? element("editor.pane.0").frame : app.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.maxY - 30)).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: file)
        _ = XCTWaiter.wait(for: [gone], timeout: 3)
    }

    /// Shows the iPadOS menu bar (a swipe down from the top edge).
    func revealMenuBar() {
        ensureForeground()
        let file = springboard.buttons["File"].firstMatch
        if file.exists, file.isHittable { return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)))
        XCTAssertTrue(file.waitForExistence(timeout: 5), "the menu bar appeared")
    }

    /// Chooses `menu` › `item` in the menu bar. Items are matched by title
    /// (SpringBoard labels them "Title, , key").
    func menu(_ menu: String, _ item: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", item, item + ",")
        let entry = springboard.buttons.matching(predicate).firstMatch
        // Opening a menu can take a second try when the bar is mid-animation.
        for _ in 0..<3 where !entry.exists {
            revealMenuBar()
            let title = springboard.buttons[menu].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5), "menu \(menu) exists", file: file, line: line)
            title.tap()
            _ = entry.waitForExistence(timeout: 2)
        }
        if !entry.exists {
            print("Menu \(menu) shows:", springboard.buttons.allElementsBoundByIndex.map(\.label))
        }
        XCTAssertTrue(entry.exists, "menu item \(menu) › \(item) exists", file: file, line: line)
        XCTAssertTrue(entry.isEnabled, "menu item \(menu) › \(item) is enabled", file: file, line: line)
        entry.tap()
    }

    /// Closes the palette by tapping the dimmed backdrop below it.
    func dismissPalette() {
        expect("palette")
        dismissMenuBar()
        let frame = element("palette").frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.maxY + 40)).tap()
        expect("palette", exists: false)
    }

    func dismissSettings() {
        tap("settings.done")
        expect("settings", exists: false)
    }
}
