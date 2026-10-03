import XCTest

/// Captures the screenshots in docs/screenshots/shell. Runs only when
/// STUDIO_SCREENSHOT_DIR is set (scripts/screenshots.sh sets it, and
/// STUDIO_SAMPLE_PATH to the folder copied in as the sample workspace).
final class ScreenshotTests: StudioUITestCase {
    private var directory: URL!
    private var samplePath: String!

    override func setUp() async throws {
        try await super.setUp()
        let environment = ProcessInfo.processInfo.environment
        guard let dir = environment["STUDIO_SCREENSHOT_DIR"], let sample = environment["STUDIO_SAMPLE_PATH"] else {
            throw XCTSkip("Set STUDIO_SCREENSHOT_DIR and STUDIO_SAMPLE_PATH (scripts/screenshots.sh)")
        }
        directory = URL(fileURLWithPath: dir)
        samplePath = sample
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() async throws {
        // The simulator is shared; leave it the way it was found.
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private func launchSample(theme: String, density: String = "pointer", _ extra: [String]) {
        app.launchArguments = ["-StudioResetState", "YES",
                               "-StudioSampleProject", "amdgpu_mtopg=\(samplePath!)", "-StudioOpenProject", "amdgpu_mtopg",
                               "-themeID", theme, "-matchSystemAppearance", "NO", "-StudioDensity", density,
                               "-codeFontSize", "14", "-showActivityBar", "YES"] + extra
        app.launch()
        XCTAssertTrue(element("toolbar.workspaceMenu").waitForExistence(timeout: 15))
    }

    /// The Studio's window is frontmost (another app's window may share
    /// the foreground on iPadOS 26 and cover it).
    private var studioIsInFront: Bool {
        guard app.state == .runningForeground else { return false }
        let marker = element("toolbar.workspaceMenu").exists ? element("toolbar.workspaceMenu") : element("welcome.openFolder")
        return marker.exists && marker.isHittable
    }

    /// Captures the screen while the Studio is in front. Other apps share
    /// the simulator, so a capture taken while one of them came forward is
    /// retried.
    private func capture(_ name: String, settle: UInt32 = 2) throws {
        sleep(settle)
        for _ in 0..<5 {
            ensureForeground()
            sleep(1)
            guard studioIsInFront else { continue }
            let shot = XCUIScreen.main.screenshot()
            if studioIsInFront {
                try shot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
                return
            }
        }
        XCTFail("the Studio did not stay in front long enough to capture \(name)")
    }

    func testWorkspaceDark() throws {
        launchSample(theme: "lemon-dark", [
            "-StudioOpenFiles", "Sources/LinuxViews.swift;README.md|Sources/LinuxDriver.swift",
            "-StudioReveal", "Sources/LinuxViews.swift", "-StudioPanel", "terminal",
            "-StudioTerminalCommand", "ls -l Sources",
        ])
        expect("terminal.view")
        try capture("workspace-dark", settle: 4)
    }

    func testWorkspaceLight() throws {
        launchSample(theme: "lemon-light", [
            "-StudioOpenFiles", "Sources/LinuxModel.swift;Sources/MonitorModel.swift",
            "-StudioSearch", "GPUSampler", "-StudioPanel", "problems",
        ])
        expect("search.summary")
        try capture("workspace-light", settle: 3)
    }

    func testQuickOpen() throws {
        launchSample(theme: "lemon-dark", [
            "-StudioOpenFiles", "Sources/App.swift", "-StudioPalette", "files", "-StudioPaletteQuery", "lnxdrv",
        ])
        expect("palette")
        try capture("quick-open-dark")
    }

    func testCommandPaletteLight() throws {
        launchSample(theme: "lemon-light", [
            "-StudioOpenFiles", "README.md", "-StudioPalette", "commands", "-StudioPaletteQuery", ">split",
            "-StudioHardwareKeyboard", "YES",
        ])
        expect("palette")
        try capture("command-palette-light")
    }

    func testOrchardWithGPU() throws {
        launchSample(theme: "orchard", [
            "-StudioOpenFiles", "Sources/GPUMetricsLayout.swift", "-StudioSidebar", "gpu",
        ])
        expect("engine.status")
        try capture("gpu-orchard")
    }

    func testPaperTouchDensity() throws {
        launchSample(theme: "paper", density: "touch", [
            "-StudioOpenFiles", "Sources/Views.swift|README.md", "-StudioReveal", "Sources/Views.swift",
        ])
        try capture("workspace-paper-touch")
    }

    func testSettings() throws {
        launchSample(theme: "lemon-dark", ["-StudioOpenFiles", "README.md", "-StudioShowSettings", "YES"])
        expect("settings")
        try capture("settings-dark")
    }

    func testWelcome() throws {
        app.launchArguments = ["-StudioResetState", "YES", "-StudioSampleProject", "amdgpu_mtopg=\(samplePath!)",
                               "-themeID", "lemon-dark", "-matchSystemAppearance", "NO", "-StudioDensity", "pointer"]
        app.launch()
        XCTAssertTrue(element("welcome.openFolder").waitForExistence(timeout: 15))
        try capture("welcome-dark")
    }

    func testOnScreenKeyboard() throws {
        launchSample(theme: "lemon-dark", density: "touch", ["-StudioOpenFiles", "Sources/App.swift"])
        guard element("editor.keyboardButton").waitForExistence(timeout: 5) else {
            throw XCTSkip("The simulator has a hardware keyboard connected")
        }
        try capture("keyboard-button")
        tap("editor.keyboardButton")
        guard app.keyboards.firstMatch.waitForExistence(timeout: 5) else { return }
        expect("keybar")
        try capture("keyboard-keybar")
    }
}
