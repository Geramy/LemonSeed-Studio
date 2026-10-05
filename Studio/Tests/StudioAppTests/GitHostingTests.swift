import XCTest
import StudioCore
import StudioAgent
import GitKit
import Forge
import StudioGitUI
@testable import LemonSeedStudio

/// The agent's Git tools and the Git screens' launch values.
@MainActor
final class GitHostingTests: XCTestCase {
    private func tempRepo() async throws -> (URL, GitRepository) {
        let url = FileManager.default.temporaryDirectory.appending(path: "studio-git-\(UUID().uuidString.prefix(8))")
        let repo = try await SampleRepository.make(at: url)
        return (url, repo)
    }

    private func context() -> ToolContext {
        ToolContext(fileSystem: WorkspaceFileSystem(workspace: LocalWorkspace(rootURL: FileManager.default.temporaryDirectory)), shell: InProcessShell())
    }

    func testToolsAreGatedLikeTheCommandsTheyStandFor() {
        let root = FileManager.default.temporaryDirectory
        let branch = GitCreateBranchTool(root: root)
        let pr = GitOpenPullRequestDraftTool(root: root, services: GitServices.inMemory())
        let branchEffect = branch.effect(of: ["name": "fix/x", "start_point": "main"], context: context())
        XCTAssertEqual(branchEffect, .shell(command: "git switch -c fix/x main", commandClass: .mutating))
        let prEffect = pr.effect(of: ["title": "Fix"], context: context())
        guard case .shell(_, let prClass) = prEffect else { return XCTFail("expected a shell effect") }
        XCTAssertEqual(prClass, .network)

        // Read-only refuses both; Ask asks for both; Autopilot creates
        // branches but still asks before reaching the network.
        XCTAssertNotEqual(PermissionPolicy(mode: .readOnly).decide(branchEffect), .allow)
        XCTAssertNotEqual(PermissionPolicy(mode: .readOnly).decide(prEffect), .allow)
        XCTAssertEqual(PermissionPolicy(mode: .ask).decide(branchEffect), .ask)
        XCTAssertEqual(PermissionPolicy(mode: .review).decide(branchEffect), .ask)
        XCTAssertEqual(PermissionPolicy(mode: .autopilot).decide(branchEffect), .allow)
        XCTAssertEqual(PermissionPolicy(mode: .autopilot).decide(prEffect), .ask)
    }

    func testCreateBranchToolCreatesAndSwitches() async throws {
        let (url, repo) = try await tempRepo()
        let tool = GitCreateBranchTool(root: url)
        let output = try await tool.execute(["name": "agent/topic"], context: context())
        XCTAssertTrue(output.text.hasPrefix("Created and switched to agent/topic"), output.text)
        let head = try await repo.head().branch
        XCTAssertEqual(head, "agent/topic")
        // The sample's uncommitted edits conflict with fix/fan-curve.
        do {
            _ = try await tool.execute(["name": "agent/fan", "start_point": "fix/fan-curve"], context: context())
            XCTFail("a conflicting switch must fail")
        } catch let error as ToolError {
            XCTAssertTrue(error.message.contains("Created agent/fan"), error.message)
            XCTAssertTrue(error.message.contains("did not switch"), error.message)
        }
        let stillHead = try await repo.head().branch
        XCTAssertEqual(stillHead, "agent/topic")
        do {
            _ = try await tool.execute(["name": "bad name"], context: context())
            XCTFail("an invalid name must fail")
        } catch let error as ToolError {
            XCTAssertTrue(error.message.contains("not a valid branch name"))
        }
    }

    func testOpenDraftToolExplainsWhatIsMissing() async throws {
        let (url, repo) = try await tempRepo()
        let services = GitServices.inMemory(defaults: UserDefaults(suiteName: "git-hosting-\(UUID())")!)
        // The sample has uncommitted work.
        do {
            _ = try await GitOpenPullRequestDraftTool.open(repository: repo, services: services, title: "T", body: "", base: nil)
            XCTFail("uncommitted changes must stop it")
        } catch let error as ToolError {
            XCTAssertTrue(error.message.contains("uncommitted changes"), error.message)
        }
        try await repo.stash(StashOptions(includeUntracked: true))
        try await repo.addRemote("origin", url: "https://github.com/lemonade-sdk/amdgpu_mtopg.git")
        do {
            _ = try await GitOpenPullRequestDraftTool.open(repository: repo, services: services, title: "T", body: "", base: nil)
            XCTFail("no account must stop it")
        } catch let error as ToolError {
            XCTAssertTrue(error.message.contains("No account is signed in for github.com"), error.message)
        }
        _ = url
    }

    func testOpenDraftToolOpensADraftWithTheSignedInAccount() async throws {
        let (_, repo) = try await tempRepo()
        try await repo.stash(StashOptions(includeUntracked: true))
        try await repo.createBranch("feature/agent", checkout: true)
        // Pushes go to a bare repository standing in for GitHub's Git server;
        // the remote is renamed to the forge URL only while resolving.
        let bare = FileManager.default.temporaryDirectory.appending(path: "studio-git-bare-\(UUID().uuidString.prefix(8))")
        _ = try GitRepository.create(at: bare, bare: true)
        try await repo.addRemote("origin", url: bare.path)
        try await repo.push(branch: "main", options: PushOptions(remote: "origin", lfs: false))
        try await repo.push(branch: "feature/agent", options: PushOptions(remote: "origin", setUpstream: true, lfs: false))
        try await repo.setRemoteURL("origin", url: "https://github.com/lemonade-sdk/amdgpu_mtopg.git")
        let services = GitServices.inMemory(defaults: UserDefaults(suiteName: "git-hosting-\(UUID())")!)
        let client = SampleForgeClient()
        services.sampleForge = ([SampleForgeClient.sampleAccount], { _ in client })
        let output = try await GitOpenPullRequestDraftTool.open(repository: repo, services: services, title: "Agent change",
                                                               body: "Body", base: "main")
        XCTAssertTrue(output.text.hasPrefix("Opened draft pull request #43"), output.text)
        let draft = try XCTUnwrap(client.createdDrafts.first)
        XCTAssertTrue(draft.isDraft)
        XCTAssertEqual(draft.sourceBranch, "feature/agent")
        XCTAssertEqual(draft.targetBranch, "main")
    }

    func testGitSheetLaunchValues() {
        XCTAssertEqual(GitSheetRequest(launchValue: "clone"), .clone)
        XCTAssertEqual(GitSheetRequest(launchValue: "history"), .workbench(.history))
        XCTAssertEqual(GitSheetRequest(launchValue: "compose"), .workbench(.pullRequests, compose: true))
        XCTAssertNil(GitSheetRequest(launchValue: "nope"))
    }

    func testGitCommandsAreRegistered() {
        let registry = CommandRegistry()
        StudioCommands.register(into: registry)
        let ids = Set(registry.commands.map(\.id))
        for id in ["git.clone", "git.history", "git.branches", "git.pullRequests", "git.createPullRequest", "git.changes"] {
            XCTAssertTrue(ids.contains(id), id)
        }
    }
}
