import Foundation
import Testing
@testable import GitKit

/// Fetch, push, pull, clone and submodules against local bare repositories
/// (libgit2's local transport, no network needed).
@Suite struct RemoteTests {
    /// A bare "server" repository seeded with one commit on main.
    func makeServer() async throws -> (server: TempDir, seed: GitRepository) {
        let server = TempDir("server")
        _ = try GitRepository.create(at: server.url, bare: true)
        let (_, seed) = try await makeRepo(["README.md": "hello\n", "src/main.c": "int main(void) { return 0; }\n"])
        try await seed.addRemote("origin", url: server.url.path)
        try await seed.push(options: PushOptions(setUpstream: true))
        return (server, seed)
    }

    func clone(_ server: TempDir, progress: TransferProgressHandler? = nil) async throws -> (TempDir, GitRepository) {
        let dir = TempDir("clone")
        let repo = try await GitRepository.clone(CloneOptions(url: server.url.path, destination: dir.url),
                                                 network: NetworkContext(progress: progress))
        try await repo.setConfigValue("user.name", testAuthor.name)
        try await repo.setConfigValue("user.email", testAuthor.email)
        return (dir, repo)
    }

    @Test func remoteConfiguration() async throws {
        let (_, repo) = try await makeRepo()
        try await repo.addRemote("origin", url: "https://example.com/a.git")
        try await repo.addRemote("upstream", url: "https://example.com/b.git")
        #expect(try await repo.remotes().map(\.name) == ["origin", "upstream"])
        try await repo.setRemoteURL("origin", url: "git@example.com:a.git")
        try await repo.setRemoteURL("origin", url: "git@example.com:push.git", push: true)
        let origin = try await repo.remote(named: "origin")
        #expect(origin.url == "git@example.com:a.git")
        #expect(origin.pushURL == "git@example.com:push.git")
        #expect(origin.fetchRefspecs == ["+refs/heads/*:refs/remotes/origin/*"])
        try await repo.renameRemote("upstream", to: "fork")
        try await repo.removeRemote("origin")
        #expect(try await repo.remotes().map(\.name) == ["fork"])
    }

    @Test func cloneReportsProgressAndTracksUpstream() async throws {
        let (server, _) = try await makeServer()
        let phases = PhaseRecorder()
        let (dir, repo) = try await clone(server) { phases.add($0.phase) }
        #expect(try dir.read("src/main.c").contains("main"))
        let branch = try #require(try await repo.currentBranch())
        #expect(branch.name == "main")
        #expect(branch.upstream == "origin/main")
        #expect(branch.ahead == 0 && branch.behind == 0)
        #expect(phases.all.contains(.done))
        #expect(GitRepository.pendingClone(at: dir.url) == nil)
    }

    @Test func pushFetchPullAndAheadBehind() async throws {
        let (server, seed) = try await makeServer()
        let (dirA, a) = try await clone(server)
        let (_, b) = try await clone(server)

        try dirA.write("a.txt", "from a\n")
        let pushed = try await a.commitAll("From A")
        #expect(try await a.currentBranch()?.ahead == 1)
        try await a.push()
        #expect(try await a.currentBranch()?.ahead == 0)

        let summary = try await b.fetch()
        #expect(summary.updates.contains { $0.reference == "refs/remotes/origin/main" && $0.new == pushed })
        #expect(try await b.currentBranch()?.behind == 1)
        #expect(try await b.pull() == .fastForwarded(pushed))
        #expect(try await b.pull() == .upToDate)

        // Diverged: B commits, A pushes again; B's push is rejected until it pulls.
        try dirA.write("a2.txt", "a2\n")
        try await a.commitAll("A2")
        try await a.push()
        try TempDirWriter(b).write("b.txt", "from b\n")
        try await b.commitAll("From B")
        await #expect(throws: GitError.self) { try await b.push() }
        let pulled = try await b.pull()
        guard case .merged = pulled else { Issue.record("expected merge, got \(pulled)"); return }
        try await b.push()
        _ = try await seed.fetch()
        let log = try await seed.log(LogOptions.including("origin/main"))
        #expect(log.first?.isMerge == true)
    }

    @Test func pullWithRebase() async throws {
        let (server, _) = try await makeServer()
        let (dirA, a) = try await clone(server)
        let (dirB, b) = try await clone(server)
        try dirA.write("a.txt", "a\n")
        try await a.commitAll("A")
        try await a.push()
        try dirB.write("b.txt", "b\n")
        try await b.commitAll("B")
        let result = try await b.pull(strategy: .rebase)
        guard case .rebased = result else { Issue.record("\(result)"); return }
        #expect(try await b.log().map(\.summary).prefix(2) == ["B", "A"])
        try await b.push()
    }

    @Test func forcePushNewBranchAndDelete() async throws {
        let (server, _) = try await makeServer()
        let (dir, a) = try await clone(server)
        try await a.createBranch("feature", checkout: true)
        try dir.write("f.txt", "1\n")
        try await a.commitAll("F1")
        try await a.push(options: PushOptions(setUpstream: true))
        #expect(try await a.currentBranch()?.upstream == "origin/feature")
        try await a.reset(to: "HEAD~1", mode: .hard)
        try dir.write("f.txt", "2\n")
        try await a.commitAll("F2")
        await #expect(throws: GitError.self) { try await a.push() }
        try await a.push(options: PushOptions(force: true))
        let server2 = try GitRepository.open(at: server.url)
        #expect(try await server2.commitInfo(try await server2.resolveCommit("feature")).summary == "F2")

        try await a.createTag("v1", message: "v1", tagger: testAuthor)
        try await a.push(branch: "feature", options: PushOptions(extraRefspecs: ["refs/tags/v1:refs/tags/v1"]))
        #expect(try await server2.tags().map(\.name) == ["v1"])

        try await a.deleteRemoteBranch("feature")
        #expect(try await server2.branches().map(\.name) == ["main"])
    }

    @Test func submodulesAddCloneAndUpdate() async throws {
        let (libServer, _) = try await makeServer()
        let (appServer, app) = try await makeServer()
        let appDir = try #require(app.workingDirectory)
        try await app.addSubmodule(url: libServer.url.path, path: "vendor/lib")
        try await app.commitAll("Add lib submodule")
        try await app.push()
        #expect(try await app.submodules().map(\.path) == ["vendor/lib"])
        #expect(FileManager.default.fileExists(atPath: appDir.appending(path: "vendor/lib/README.md").path))

        let dest = TempDir("super")
        let cloned = try await GitRepository.clone(
            CloneOptions(url: appServer.url.path, destination: dest.url, recurseSubmodules: true))
        let subs = try await cloned.submodules()
        #expect(subs.count == 1)
        #expect(subs[0].isInitialized)
        #expect(subs[0].isCloned)
        #expect(!subs[0].isOutOfDate)
        #expect(try dest.read("vendor/lib/src/main.c").contains("main"))

        // A plain clone leaves the submodule empty until updated.
        let plain = TempDir("plain")
        let p = try await GitRepository.clone(CloneOptions(url: appServer.url.path, destination: plain.url))
        #expect(try await p.submodules().first?.isCloned == false)
        try await p.updateSubmodules()
        #expect(try await p.submodules().first?.isCloned == true)
    }

    @Test func cancelledFetchThrowsCancelled() async throws {
        let (server, _) = try await makeServer()
        let (_, repo) = try await clone(server)
        let task = Task { try await repo.fetch() }
        task.cancel()
        do {
            _ = try await task.value
        } catch let error as GitError {
            #expect(error.code == .cancelled)
        }
    }

    @Test func resumeAfterInterruptedClone() async throws {
        let (server, _) = try await makeServer()
        let dir = TempDir("resume")
        // Simulate an interruption after `init`: the marker is written, no fetch yet.
        let repo = try GitRepository.create(at: dir.url)
        try await repo.addRemote("origin", url: server.url.path)
        let pending = PendingClone(options: CloneOptions(url: server.url.path, destination: dir.url), stage: .initialized, defaultBranch: nil)
        try JSONEncoder().encode(pending).write(to: dir.url.appending(path: ".git/studio-clone.json"))
        #expect(GitRepository.pendingClone(at: dir.url)?.stage == .initialized)
        // Cloning into the same place resumes instead of failing.
        let resumed = try await GitRepository.clone(CloneOptions(url: server.url.path, destination: dir.url))
        #expect(try await resumed.head().branch == "main")
        #expect(try dir.read("README.md") == "hello\n")
        #expect(GitRepository.pendingClone(at: dir.url) == nil)
    }
}

final class PhaseRecorder: @unchecked Sendable {
    private var phases: [TransferProgress.Phase] = []
    private let lock = NSLock()
    func add(_ p: TransferProgress.Phase) { lock.withLock { phases.append(p) } }
    var all: [TransferProgress.Phase] { lock.withLock { phases } }
}

/// Writes into a repository's working directory.
struct TempDirWriter {
    let url: URL
    init(_ repo: GitRepository) { url = repo.workingDirectory! }
    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: url.appending(path: path))
    }
}

extension LogOptions {
    static func including(_ rev: String) -> LogOptions {
        var o = LogOptions()
        o.include = [rev]
        return o
    }
}
