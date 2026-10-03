import XCTest

/// The sidebar's trailing-edge handle: dragging resizes it live, the width
/// survives a relaunch, double-tap resets it, and dragging well past the
/// minimum collapses the sidebar.
@MainActor
final class SidebarResizeTests: StudioUITestCase {
    override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private var sidebar: XCUIElement { element("sidebar.explorer") }

    private func sidebarWidth() -> CGFloat {
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "the explorer sidebar is showing")
        return sidebar.frame.width
    }

    /// Drags the handle by `dx` points.
    private func dragHandle(by dx: CGFloat) {
        let handle = element("sidebar.resize")
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "the resize handle exists")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: dx, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    func testDragResizesAndPersists() {
        launch(extra: ["-StudioSidebar", "explorer"])
        // Start from the default so earlier runs do not matter.
        element("sidebar.resize").doubleTap()
        let before = sidebarWidth()
        XCTAssertEqual(before, 290, accuracy: 4, "double-tap resets to the default width")

        dragHandle(by: 120)
        let after = sidebarWidth()
        XCTAssertEqual(after, before + 120, accuracy: 12, "the sidebar follows the drag")

        // Clamped to half the window.
        dragHandle(by: 2000)
        let window = app.windows.firstMatch.frame.width
        XCTAssertLessThanOrEqual(sidebarWidth(), window * 0.5 + 2, "at most half the window")
        dragHandle(by: -(sidebarWidth() - after))
        let chosen = sidebarWidth()

        app.terminate()
        launch(extra: ["-StudioSidebar", "explorer"])
        XCTAssertEqual(sidebarWidth(), chosen, accuracy: 4, "the width survives a relaunch")
    }

    func testDraggingPastTheMinimumCollapses() {
        launch(extra: ["-StudioSidebar", "explorer"])
        element("sidebar.resize").doubleTap()
        dragHandle(by: -120)
        XCTAssertGreaterThanOrEqual(sidebarWidth(), 199, "never narrower than the minimum while visible")
        dragHandle(by: -400)
        expect("sidebar.explorer", exists: false, "dragging well past the minimum collapses the sidebar")
    }
}
