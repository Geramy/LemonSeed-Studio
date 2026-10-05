import Foundation
import Testing
import GitKit
import Forge
@testable import StudioGitUI

/// Branch, pull request and browsing workflows against local repositories:
/// a bare repository stands in for the forge's Git server, and
/// SampleForgeClient for its API. No network.
@MainActor
@Suite struct HostingModelTests {
    func services(sample client: SampleForgeClient? = nil) -> GitServices {
        let defaults = UserDefaults(suiteName: "studiogitui.\(UUID().uuidString)")!
        let s = GitServices.inMemory(defaults: defaults)
        s.authorName = "Tester"
        s.authorEmail = "tester@example.com"
        if let client { s.sampleForge = ([SampleForgeClient.sampleAccount], { _ in client }) }
        return s
    }

    /// A working repository cloned from a bare "server" repository.
    func repoWithRemote() async throws -> (work: GitRepository, bare: URL, dir: URL) {
        let source = try await SampleRepository.make(at: tempURL("source"))
        let bare = tempURL("server.git")
        _ = try GitRepository.create(at: bare, bare: true)
        try await source.addRemote("server", url: bare.path)
        for branch in try await source.branches().map(\.name) {
            try await source.push(branch: branch, options: PushOptions(remote: "server", lfs: false))
        }
        let dir = tempURL("work")
        let work = try await GitRepository.clone(CloneOptions(url: bare.path, destination: dir, branch: "main"))
        try await work.setConfigValue("user.name", "Tester")
        try await work.setConfigValue("user.email", "tester@example.com")
        return (work, bare, dir)
    }

    // MARK: Branches

    @Test func createFromCommitAndRemoteBranchRenameAndUpstream() async throws {
        let (work, _, _) = try await repoWithRemote()
        let model = SourceControlModel(repository: work, services: services())
        await model.refresh()
        let first = try #require(try await work.log(LogOptions()).last?.id)

        #expect(await model.createBranch("from-commit", from: first.hex, checkout: false))
        #expect(try await work.branch(named: "from-commit").target == first)
        #expect(model.head?.branch == "main")

        #expect(await model.createBranch("topic", from: "origin/feature/sparkline", checkout: true))
        #expect(model.head?.branch == "topic")

        #expect(await !model.createBranch("bad name..", from: "HEAD"))
        #expect(model.errorMessage?.contains("not a valid branch name") == true)
        model.errorMessage = nil

        let topic = try #require(model.localBranches.first { $0.name == "topic" })
        await model.renameBranch(topic, to: "topic-renamed")
        #expect(model.head?.branch == "topic-renamed")

        let renamed = try #require(model.localBranches.first { $0.name == "topic-renamed" })
        await model.setUpstream(renamed, to: "origin/feature/sparkline")
        #expect(model.currentBranch?.upstream == "origin/feature/sparkline")
        #expect(model.currentBranch?.ahead == 0 && model.currentBranch?.behind == 0)
        await model.setUpstream(model.currentBranch!, to: nil)
        #expect(model.currentBranch?.upstream == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func publishPushAheadBehindAndDeleteOnRemote() async throws {
        let (work, bare, dir) = try await repoWithRemote()
        let model = SourceControlModel(repository: work, services: services())
        await model.refresh()
        #expect(await model.createBranch("feature/new", from: "HEAD", checkout: true))
        try Data("x\n".utf8).write(to: dir.appending(path: "new.txt"))
        try await work.stageAll()
        try await work.commit(message: "New file")
        await model.refresh()
        let branch = try #require(model.currentBranch)
        #expect(branch.upstream == nil)

        await model.publish(branch, to: "origin")
        #expect(model.errorMessage == nil)
        #expect(model.currentBranch?.upstream == "origin/feature/new")
        let server = try GitRepository.open(at: bare)
        #expect(try await server.branches().map(\.name).contains("feature/new"))

        try Data("y\n".utf8).write(to: dir.appending(path: "new.txt"))
        try await work.stageAll()
        try await work.commit(message: "Second")
        await model.refresh()
        #expect(model.ahead == 1)
        await model.push(model.currentBranch!)
        #expect(model.ahead == 0)

        // Push to an upstream with another name.
        await model.setUpstream(model.currentBranch!, to: "origin/main")
        #expect(model.ahead > 0)

        await model.setUpstream(model.currentBranch!, to: "origin/feature/new")
        await model.deleteRemoteBranch(model.currentBranch!)
        #expect(model.errorMessage == nil)
        #expect(!(try await server.branches().map(\.name).contains("feature/new")))
        #expect(!model.remoteBranches.contains { $0.name == "origin/feature/new" })
    }

    @Test func switchCarriesOrStashesUncommittedChanges() async throws {
        let (work, _, dir) = try await repoWithRemote()
        let model = SourceControlModel(repository: work, services: services())
        await model.refresh()
        // A new untracked file comes along.
        try Data("draft\n".utf8).write(to: dir.appending(path: "draft.txt"))
        await model.refresh()
        let fix = try #require(model.remoteBranches.first { $0.name == "origin/fix/fan-curve" })
        await model.checkout(fix, strategy: .carry)
        #expect(model.head?.branch == "fix/fan-curve")
        #expect(model.currentBranch?.upstream == "origin/fix/fan-curve")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "draft.txt").path))

        // A change to a file that differs between branches is refused with
        // a clear message, then stashing works.
        let main = try #require(model.localBranches.first { $0.name == "main" })
        let mainID = try await work.resolveCommit("main")
        let fixID = try await work.resolveCommit("fix/fan-curve")
        let changed = try await work.diff(.commits(from: mainID, to: fixID)).first?.path
        let path = try #require(changed)
        try Data("local edit\n".utf8).write(to: dir.appending(path: path))
        await model.refresh()
        await model.checkout(main, strategy: .carry)
        #expect(model.head?.branch == "fix/fan-curve")
        #expect(model.errorMessage?.contains("would overwrite uncommitted changes") == true)
        model.errorMessage = nil

        await model.checkout(main, strategy: .stash)
        #expect(model.errorMessage == nil)
        #expect(model.head?.branch == "main")
        #expect(model.stashes.first?.message.contains("Stashed before switching to main") == true)
        #expect(!model.hasChanges)
    }

    @Test func branchNameValidation() {
        #expect(GitRepository.isValidBranchName("feature/x-1"))
        #expect(!GitRepository.isValidBranchName("has space"))
        #expect(!GitRepository.isValidBranchName("a..b"))
        #expect(!GitRepository.isValidBranchName("ends/"))
        #expect(!GitRepository.isValidBranchName(""))
    }

    // MARK: Pull requests

    @Test func checkOutPullRequestsFromSameRepositoryAndFork() async throws {
        let (work, bare, dir) = try await repoWithRemote()
        let server = try GitRepository.open(at: bare)
        _ = server
        let fork = try await SampleRepository.make(at: tempURL("fork"))
        try await fork.addRemote("server", url: bare.path)
        try await fork.createBranch("contrib", checkout: true)
        try Data("contrib\n".utf8).write(to: fork.workingDirectory!.appending(path: "contrib.txt"))
        try await fork.stageAll()
        let forkHead = try await fork.commit(message: "Contribution", options: CommitOptions(author: Signature(name: "F", email: "f@example.com")))
        // The forge publishes request heads under refs/pull/N/head.
        try await fork.push(branch: nil, options: PushOptions(remote: "server", extraRefspecs: ["refs/heads/contrib:refs/pull/7/head"], lfs: false))

        let same = PullRequest(number: 3, title: "Sparkline", repository: "lemonade-sdk/amdgpu_mtopg", sourceRepository: "lemonade-sdk/amdgpu_mtopg",
                               isCrossRepository: false, sourceBranch: "feature/sparkline", targetBranch: "main")
        let branch = try await PullRequestCheckout.checkOut(same, kind: .github, remote: "origin", repository: work, network: NetworkContext())
        #expect(branch == "feature/sparkline")
        #expect(try await work.head().branch == "feature/sparkline")
        #expect(try await work.currentBranch()?.upstream == "origin/feature/sparkline")

        let cross = PullRequest(number: 7, title: "Contribution", repository: "lemonade-sdk/amdgpu_mtopg", sourceRepository: "someone/amdgpu_mtopg",
                                isCrossRepository: true, sourceBranch: "contrib", targetBranch: "main")
        let local = try await PullRequestCheckout.checkOut(cross, kind: .github, remote: "origin", repository: work, network: NetworkContext())
        #expect(local == "pr/7")
        #expect(try await work.head().commit == forkHead)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "contrib.txt").path))

        // New commits on the request fast-forward the local branch.
        try Data("more\n".utf8).write(to: fork.workingDirectory!.appending(path: "contrib.txt"))
        try await fork.stageAll()
        let newer = try await fork.commit(message: "More", options: CommitOptions(author: Signature(name: "F", email: "f@example.com")))
        try await fork.push(branch: nil, options: PushOptions(remote: "server", force: true, extraRefspecs: ["+refs/heads/contrib:refs/pull/7/head"], lfs: false))
        try await work.checkout(branch: "main")
        _ = try await PullRequestCheckout.checkOut(cross, kind: .github, remote: "origin", repository: work, network: NetworkContext())
        #expect(try await work.head().commit == newer)
    }

    @Test func composerPushesThenOpensTheRequest() async throws {
        let (work, bare, dir) = try await repoWithRemote()
        // The remote reads as the forge repository while hosting resolves.
        try await work.setRemoteURL("origin", url: "https://github.com/lemonade-sdk/amdgpu_mtopg.git")
        let client = SampleForgeClient()
        let services = services(sample: client)
        let model = SourceControlModel(repository: work, services: services)
        await model.refresh()
        #expect(await model.createBranch("occupancy", from: "HEAD", checkout: true))
        try Data("chart\n".utf8).write(to: dir.appending(path: "chart.txt"))
        try await work.stageAll()
        try await work.commit(message: "Occupancy chart\n\nA sparkline per queue.")

        let hosting = RepositoryHosting(repository: work, services: services)
        await hosting.resolve()
        #expect(hosting.state == .ready)
        #expect(hosting.pullTarget?.repository == "lemonade-sdk/amdgpu_mtopg")
        #expect(hosting.settings?.allowedMergeMethods == [.merge, .squash])
        // Pushes then go to the bare repository standing in for GitHub's Git server.
        try await work.setRemoteURL("origin", url: bare.path)

        let composer = PullRequestComposerModel(sourceControl: model, hosting: hosting)
        await composer.prepare()
        #expect(composer.title == "Occupancy chart")
        #expect(composer.body == "A sparkline per queue.")
        #expect(composer.targetBranch == "main")
        #expect(composer.needsPush)
        composer.isDraft = true
        composer.reviewers = "@bob, carol"
        composer.labels = "ui"
        let submitted = await composer.submit()
        #expect(composer.errorMessage == nil)
        let pr = try #require(submitted)
        #expect(pr.sourceBranch == "occupancy")
        let draft = try #require(client.createdDrafts.first)
        #expect(draft.isDraft && draft.reviewers == ["bob", "carol"] && draft.labels == ["ui"])
        #expect(draft.sourceRepository == nil)
        let server = try GitRepository.open(at: bare)
        #expect(try await server.branches().map(\.name).contains("occupancy"))
        #expect(model.currentBranch?.upstream == "origin/occupancy")
        #expect(!composer.needsPush)
    }

    @Test func hostingAsksToSignInForUnknownHostsAndSkipsLocalRemotes() async throws {
        let (work, _, _) = try await repoWithRemote()
        let services = services()
        let hosting = RepositoryHosting(repository: work, services: services)
        await hosting.resolve()
        #expect(hosting.state == .noForgeRemote)
        try await work.addRemote("upstream", url: "git@gitlab.example.com:team/app.git")
        await hosting.resolve()
        #expect(hosting.state == .notSignedIn(hostnames: ["gitlab.example.com"]))
        #expect(RepositoryHosting.signInTarget(for: "github.com") == .github)
    }

    @Test func detailModelEnforcesPermissionsAndAllowedMethods() async throws {
        let client = SampleForgeClient()
        let readOnly = ForgeRepositorySettings(fullName: "lemonade-sdk/amdgpu_mtopg", allowedMergeMethods: [.squash], permission: .read)
        let detail = PullRequestDetailModel(client: client, repository: "lemonade-sdk/amdgpu_mtopg", number: 42, settings: readOnly,
                                            currentUser: ForgeUser(id: "2", login: "bob"))
        await detail.load()
        #expect(detail.commits.count == 2)
        #expect(detail.threads.count == 1)
        #expect(detail.conversation.count == 2)
        #expect(detail.mergeBlocker?.contains("write access") == true)
        await detail.merge(.squash)
        #expect(client.merged.isEmpty)
        #expect(detail.errorMessage?.contains("write access") == true)
        #expect(detail.stateChangeBlocker != nil)
        await detail.setOpen(false)
        #expect(client.closed.isEmpty)

        detail.settings = ForgeRepositorySettings(fullName: "lemonade-sdk/amdgpu_mtopg", allowedMergeMethods: [.squash], permission: .write)
        detail.errorMessage = nil
        await detail.merge(.rebase)
        #expect(detail.errorMessage?.contains("does not allow rebase") == true)
        await detail.merge(.squash)
        #expect(client.merged == [42])
        await detail.setOpen(false)
        #expect(client.closed == [42])

        // GitHub needs a comment to request changes.
        detail.reviewBody = ""
        await detail.review(.requestChanges)
        #expect(detail.errorMessage?.contains("requires a comment") == true)
    }

    @Test func listModelSwitchesStateAndScope() async throws {
        let client = SampleForgeClient()
        let list = PullRequestListModel(client: client, repository: "lemonade-sdk/amdgpu_mtopg")
        await list.load()
        #expect(list.requests.map(\.number) == [42, 41, 37])
        await list.set(scope: .mine)
        #expect(list.filter == .repositoryAuthoredByMe("lemonade-sdk/amdgpu_mtopg", state: .open))
        #expect(list.requests.map(\.number) == [42, 37])
        await list.set(state: .merged)
        #expect(list.requests.isEmpty)
        await list.set(scope: .reviewRequested)
        #expect(list.filter == .repositoryReviewRequested("lemonade-sdk/amdgpu_mtopg"))
    }

    // MARK: Browsing and cloning

    @Test func browserPagesFiltersScopesAndSignInState() async throws {
        let client = SampleForgeClient(pageSize: 2)
        let model = RepositoryBrowserModel(services: services(), makeClient: { _ in client }, fixedAccounts: [SampleForgeClient.sampleAccount])
        await model.load()
        #expect(model.organizations.map(\.login) == ["lemonade-sdk"])
        #expect(model.repositories.count == 2 && model.nextCursor == "2")
        await model.loadMore()
        await model.loadMore()
        #expect(model.repositories.count == 6 && model.nextCursor == nil)
        // Archived repositories are hidden until asked for.
        #expect(!model.visibleRepositories.contains { $0.isArchived })
        model.showArchived = true
        #expect(model.visibleRepositories.contains { $0.isArchived })
        model.showForks = false
        #expect(!model.visibleRepositories.contains { $0.isFork })

        await model.selectScope(.organization("lemonade-sdk"))
        #expect(client.requestedScopes.last == .organization("lemonade-sdk"))
        await model.loadMore()
        #expect(model.repositories.count == 3)
        model.showForks = true
        model.query = "site"
        #expect(model.visibleRepositories.map(\.name) == ["lemonseed-site"])
        await model.search()
        #expect(model.searchResults?.map(\.fullName) == ["lemonade-sdk/lemonseed-site"])
        #expect(model.scopeChoices.map(\.title) == ["All Repositories", "alice", "lemonade-sdk"])

        let empty = RepositoryBrowserModel(services: services(), fixedAccounts: [])
        await empty.load()
        #expect(empty.needsSignIn)
    }

    @Test func cloneByURLIntoTheAppFolderAndCancel() async throws {
        let (_, bare, _) = try await repoWithRemote()
        let appFolder = tempURL("Projects")
        let model = RepositoryBrowserModel(services: services(), appFolder: appFolder, fixedAccounts: [])
        var request = RepositoryBrowserModel.CloneRequest(url: bare.path)
        #expect(request.folderName == bare.lastPathComponent)
        request.folderName = "server-copy"
        request.lfs = false
        let cloned = try #require(await model.clone(request))
        #expect(cloned.workingDirectory?.standardizedFileURL.path == appFolder.appending(path: "server-copy").standardizedFileURL.path)
        #expect(try await cloned.head().branch == "main")

        #expect(RepositoryBrowserModel.CloneRequest(url: "git@github.com:o/name.git").useSSH)
        #expect(RepositoryBrowserModel.CloneRequest(url: "git@github.com:o/name.git").folderName == "name")
        #expect(RepositoryBrowserModel.CloneRequest(url: "").problem != nil)

        // A cancelled clone leaves no folder behind.
        var again = RepositoryBrowserModel.CloneRequest(url: bare.path)
        again.folderName = "cancelled"
        let task = Task { await model.clone(again) }
        model.cancelClone()
        task.cancel()
        _ = await task.value
        if model.errorMessage == "Clone cancelled." {
            #expect(!FileManager.default.fileExists(atPath: appFolder.appending(path: "cancelled").path))
        }
    }
}
