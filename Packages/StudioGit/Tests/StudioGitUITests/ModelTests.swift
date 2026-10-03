import Foundation
import Testing
import GitKit
import Forge
@testable import StudioGitUI

func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "studiogitui-\(name)-\(UUID().uuidString.prefix(8))")
}

@MainActor
@Suite struct SourceControlModelTests {
    func services() -> GitServices {
        let defaults = UserDefaults(suiteName: "studiogitui.\(UUID().uuidString)")!
        let s = GitServices.inMemory(defaults: defaults)
        s.authorName = "Tester"
        s.authorEmail = "tester@example.com"
        return s
    }

    @Test func sampleRepositoryHasHistoryAndWork() async throws {
        let repo = try await SampleRepository.make(at: tempURL("sample"))
        let model = SourceControlModel(repository: repo, services: services())
        await model.refresh()
        #expect(model.head?.branch == "main")
        #expect(model.staged.map(\.path) == ["CHANGELOG.md"])
        #expect(Set(model.unstaged.map(\.path)) == ["Sources/Monitor/QueueRow.swift", "Sources/Monitor/Theme.swift"])
        #expect(model.branches.map(\.name).contains("feature/sparkline"))
        let log = try await repo.log(LogOptions())
        #expect(log.contains { $0.isMerge })
        #expect(try await repo.tags().map(\.name) == ["v0.2.0", "v0.1.0"])
    }

    @Test func hunkAndLineStagingThenCommit() async throws {
        let repo = try await SampleRepository.make(at: tempURL("stage"))
        let model = SourceControlModel(repository: repo, services: services())
        await model.refresh()
        let file = try #require(model.unstaged.first { $0.path.hasSuffix("QueueRow.swift") })
        await model.select(file, staged: false)
        let diff = try #require(model.selectedDiff)
        #expect(diff.hunks.count == 2)

        await model.toggleHunk(diff.hunks[0])
        #expect(model.staged.contains { $0.path == file.path })
        #expect(model.selectedDiff?.hunks.count == 1)

        // Select one added line of the remaining hunk and stage it.
        let hunk = try #require(model.selectedDiff?.hunks.first)
        let added = try #require(hunk.lines.first { $0.kind == .addition })
        model.toggleLine(added, in: hunk)
        #expect(model.selectedLines.count == 1)
        await model.applySelectedLines()
        #expect(model.selectedLines.isEmpty)

        model.commitMessage = "Polish QueueRow"
        #expect(model.canCommit)
        await model.commit()
        #expect(model.errorMessage == nil)
        #expect(model.commitMessage.isEmpty)
        let head = try await repo.log(LogOptions()).first
        #expect(head?.summary == "Polish QueueRow")
        #expect(head?.author.name == "Tester")
    }

    @Test func branchSwitchAndCreate() async throws {
        let repo = try await SampleRepository.make(at: tempURL("branch"))
        let model = SourceControlModel(repository: repo, services: services())
        await model.refresh()
        await model.stash()
        #expect(model.stashes.count == 1)
        let fix = try #require(model.branches.first { $0.name == "fix/fan-curve" })
        await model.checkout(fix)
        #expect(model.head?.branch == "fix/fan-curve")
        await model.createBranch("topic")
        #expect(model.head?.branch == "topic")
        #expect(model.errorMessage == nil)
    }

    @Test func conflictResolutionFlow() async throws {
        let repo = try await SampleRepository.make(at: tempURL("conflict"), withConflict: true)
        let model = SourceControlModel(repository: repo, services: services())
        await model.refresh()
        #expect(model.state == .merge)
        #expect(model.conflicted.map(\.path) == ["README.md"])
        #expect(model.commitMessage.hasPrefix("Merge branch 'conflict'"))
        #expect(!model.canCommit)
        await model.resolve("README.md", with: .theirs)
        #expect(model.conflicted.isEmpty)
        #expect(model.canCommit)
        await model.commit()
        #expect(model.state == .none)
        #expect(try await repo.log(LogOptions()).first?.isMerge == true)
    }

    @Test func abortConflictedMerge() async throws {
        let repo = try await SampleRepository.make(at: tempURL("abort"), withConflict: true)
        let model = SourceControlModel(repository: repo, services: services())
        await model.refresh()
        await model.abortOperation()
        #expect(model.state == .none)
        #expect(model.conflicted.isEmpty)
    }

    @Test func historyModelLaysOutGraph() async throws {
        let repo = try await SampleRepository.make(at: tempURL("history"))
        let model = HistoryModel(repository: repo)
        await model.load()
        #expect(model.rows.count == 7)
        #expect(model.maxWidth >= 2)
        let merge = try #require(model.rows.first { $0.commit.isMerge })
        await model.select(merge.commit.id)
        #expect(model.selectedDiff.map(\.path) == ["Sources/Monitor/Sparkline.swift"])
        #expect(model.labels.values.flatMap { $0 }.contains { $0.name == "v0.1.0" })
        model.pathFilter = "Sources/Monitor/Sparkline.swift"
        await model.load()
        #expect(model.rows.map(\.commit.summary) == ["Sparkline: document the view", "Add Sparkline view"])
    }
}

@MainActor
@Suite struct ForgeModelTests {
    @Test func pullRequestListAndDetail() async throws {
        let client = SampleForgeClient()
        let list = PullRequestListModel(client: client, filter: .repository("lemonade-sdk/amdgpu_mtopg"))
        await list.load()
        #expect(list.requests.map(\.number) == [42, 41, 37])
        #expect(list.ciStates["lemonade-sdk/amdgpu_mtopg#42"] == .success)
        #expect(list.ciStates["lemonade-sdk/amdgpu_mtopg#37"] == .failure)

        let detail = PullRequestDetailModel(client: client, repository: "lemonade-sdk/amdgpu_mtopg", number: 42)
        await detail.load()
        #expect(detail.files.count == 2)
        #expect(detail.selectedFile == "Sources/MtopgComponents/QueueRow.swift")
        #expect(detail.selectedHunks.first?.lines.contains { $0.kind == .addition && $0.text.contains("Sparkline") } == true)
        #expect(detail.comments(onLine: 20, path: "Sources/MtopgComponents/QueueRow.swift").count == 1)
        #expect(detail.ci?.runs.count == 3)

        detail.draftComment = "Looks good"
        await detail.postComment()
        #expect(detail.comments.last?.body == "Looks good")
        await detail.review(.approve)
        await detail.merge(.squash)
        #expect(client.reviews == [.approve])
        #expect(client.merged == [42])
        #expect(detail.notice == "Merged")
    }

    @Test func unifiedDiffParsing() {
        let hunks = UnifiedDiff.parseHunks("@@ -1,3 +1,4 @@ func x()\n a\n-b\n+B\n+C\n c\n\\ No newline at end of file\n@@ -10 +11 @@\n-x\n+y")
        #expect(hunks.count == 2)
        #expect(hunks[0].oldStart == 1 && hunks[0].newCount == 4)
        #expect(hunks[0].lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context])
        #expect(hunks[0].lines[3].newLineNumber == 3)
        #expect(hunks[0].lines.last?.hasNewline == false)
        #expect(hunks[1].oldCount == 1 && hunks[1].newStart == 11)
        #expect(hunks[1].lines.map(\.text) == ["x", "y"])
    }

    @Test func signInModelHosts() {
        let defaults = UserDefaults(suiteName: "studiogitui.\(UUID().uuidString)")!
        let model = SignInModel(accounts: AccountStore(file: nil, secrets: InMemorySecretStore()), defaults: defaults)
        #expect(model.host == .github)
        #expect(model.clientID == nil)
        model.clientIDDraft = "Iv1.demo"
        model.saveClientID()
        #expect(model.clientID == "Iv1.demo")
        model.target = .selfHostedGitLab
        #expect(model.host == nil)
        model.serverURL = "gitlab.example.com"
        #expect(model.host?.apiURL.absoluteString == "https://gitlab.example.com/api/v4")
        model.startDeviceFlow()
        if case .failed(let message) = model.phase {
            #expect(message.contains("client ID"))
        } else {
            Issue.record("expected a missing client ID failure")
        }
        let sample = DeviceAuthorization(deviceCode: "d", userCode: "WDJB-MJHT", verificationURI: URL(string: "https://github.com/login/device")!,
                                         verificationURIComplete: nil, expiresAt: Date().addingTimeInterval(900), interval: 5)
        model.showSampleCode(sample)
        #expect(model.phase == .waitingForApproval(sample))
        model.cancel()
        #expect(model.phase == .choosing)
    }

    @Test func browserClonesIntoSavedFolder() async throws {
        // A local "remote" stands in for the forge's clone URL.
        let remote = try await SampleRepository.make(at: tempURL("remote"))
        let remotePath = remote.workingDirectory!.path
        let defaults = UserDefaults(suiteName: "studiogitui.\(UUID().uuidString)")!
        let services = GitServices.inMemory(defaults: defaults)
        let folders = SavedFolderStore(defaults: defaults)
        let parent = tempURL("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = try folders.add(parent)
        #expect(folders.folders.map(\.name) == [parent.lastPathComponent])

        let model = RepositoryBrowserModel(services: services, folders: folders) { _ in SampleForgeClient() }
        var repo = SampleForgeClient.sampleRepositories[0]
        repo.httpsCloneURL = remotePath
        var request = RepositoryBrowserModel.CloneRequest(repository: repo)
        request.location = .folder(folder)
        request.folderName = "cloned"
        let cloned = try #require(await model.clone(request))
        #expect(model.cloneJob?.finished == true)
        #expect(cloned.workingDirectory?.standardizedFileURL.path == parent.appending(path: "cloned").standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: parent.appending(path: "cloned/README.md").path))
    }

    @Test func identityFallsBackToAccount() async throws {
        let defaults = UserDefaults(suiteName: "studiogitui.\(UUID().uuidString)")!
        let services = GitServices.inMemory(defaults: defaults)
        #expect(await services.identity(for: nil) == nil)
        services.authorName = "N"
        services.authorEmail = "n@example.com"
        #expect(await services.identity(for: nil)?.email == "n@example.com")
        #expect(await services.commitSigner() == nil)
        let key = try await services.sshKeys.generate(.ed25519, label: "k")
        services.defaultSSHKeyID = key.id
        services.signCommits = true
        #expect(await services.commitSigner() != nil)
    }
}
