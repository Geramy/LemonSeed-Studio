import XCTest

/// Cloning, branches and pull requests in the app, with offline sample
/// data (-StudioGitSample, Debug builds only).
final class GitHostingUITests: StudioUITestCase {
    func testWelcomeCloneAsksToSignInWithoutAnAccount() {
        launchWelcome()
        tap("welcome.clone")
        expect("git.browser.signInPrompt", timeout: 10)
        expect("git.browser.signIn")
        tap("git.cloneByURL")
        expect("git.clone.url")
    }

    private func launchSample(sheet: String, expecting identifier: String = "git.workbench", extra: [String] = []) {
        app.launchArguments = ["-StudioResetState", "YES", "-StudioGitSample", "YES", "-StudioGitSampleProject", "gpu-monitor",
                               "-StudioOpenProject", "gpu-monitor", "-StudioSidebar", "sourceControl", "-StudioGitSheet", sheet]
            + Self.fixedSettings + extra
        app.launch()
        expect(identifier, timeout: 20)
    }

    func testBrowserListsSampleRepositoriesWithFilters() {
        launchSample(sheet: "clone", expecting: "git.cloneSheet")
        expect("git.browser.list", timeout: 10)
        expect("git.clone.lemonade-sdk/amdgpu_mtopg", timeout: 10)
        expect("git.browser.owner")
        // Archived repositories are hidden until the filter shows them.
        expect("git.clone.alice/gpu-notes-2024", exists: false, timeout: 2)
    }

    /// A clone started from an open workspace opens in a window of its own
    /// (the sample repository clones offline from the sample project).
    func testCloneFromAWorkspaceOpensInANewWindow() {
        launchSample(sheet: "clone", expecting: "git.cloneSheet",
                     extra: ["-StudioGitSampleLocalClone", "YES", "-StudioExposeWindows", "YES"])
        // The row and its Clone button share the identifier; the button opens the options.
        let clone = app.buttons.matching(identifier: "git.clone.lemonade-sdk/amdgpu_mtopg")
            .matching(NSPredicate(format: "label == 'Clone'")).firstMatch
        XCTAssertTrue(clone.waitForExistence(timeout: 10))
        clone.tap()
        // A folder name of its own: Projects keeps clones from earlier runs.
        let name = "clone-\(Int(Date().timeIntervalSince1970))"
        let folder = element("git.clone.folderName")
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.tap()
        let current = (folder.value as? String) ?? ""
        folder.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + name)
        tap("git.clone.start")
        let workspace = element("toolbar.workspaceMenu")
        let showsClone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", name), object: workspace)
        XCTAssertEqual(XCTWaiter.wait(for: [showsClone], timeout: 20), .completed, "the clone's window is in front")
        expect("clone.openHere", exists: false)
        // The workspace the clone started from is still open in its window.
        let windows = element("app.windows")
        let both = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "\(name),gpu-monitor"), object: windows)
        XCTAssertEqual(XCTWaiter.wait(for: [both], timeout: 5), .completed, "windows: \(windows.label)")
    }

    func testPullRequestsListAndDetail() {
        launchSample(sheet: "pullRequests")
        expect("git.pull.42", timeout: 15)
        tap("git.pull.42")
        expect("git.pull.merge", timeout: 10)
        expect("git.pull.checkout")
        expect("git.pulls.new")
    }

    func testBranchesCreateAndSwitch() {
        launchSample(sheet: "branches")
        tap("git.branches.new")
        let name = element("git.newBranch.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("ui-test-branch")
        tap("git.newBranch.create")
        expect("git.branch.ui-test-branch", timeout: 10)
    }
}
