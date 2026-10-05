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
