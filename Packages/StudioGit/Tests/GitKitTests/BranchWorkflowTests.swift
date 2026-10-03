import Foundation
import Testing
@testable import GitKit

@Suite struct BranchWorkflowTests {
    @Test func branchLifecycle() async throws {
        let (dir, repo) = try await makeRepo()
        let feature = try await repo.createBranch("feature", checkout: true)
        #expect(feature.isHead)
        try dir.write("f.txt", "feature\n")
        try await repo.commitAll("Feature work")
        var names = try await repo.branches().map(\.name)
        #expect(names == ["feature", "main"])

        try await repo.checkout(branch: "main")
        #expect(try await repo.head().branch == "main")
        #expect(!FileManager.default.fileExists(atPath: dir.url.appending(path: "f.txt").path))

        // Unmerged branches are protected unless forced.
        await #expect(throws: GitError.self) { try await repo.deleteBranch("feature") }
        try await repo.renameBranch("feature", to: "topic")
        names = try await repo.branches().map(\.name)
        #expect(names == ["main", "topic"])
        try await repo.deleteBranch("topic", force: true)
        #expect(try await repo.branches().map(\.name) == ["main"])
    }

    @Test func checkoutRefusesToClobberLocalChanges() async throws {
        let (dir, repo) = try await makeRepo()
        try await repo.createBranch("other", checkout: true)
        try dir.write("README.md", "other\n")
        try await repo.commitAll("Other")
        try await repo.checkout(branch: "main")
        try dir.write("README.md", "local edit\n")
        await #expect(throws: GitError.self) { try await repo.checkout(branch: "other") }
        try await repo.checkout(branch: "other", options: CheckoutOptions(force: true))
        #expect(try dir.read("README.md") == "other\n")
    }

    @Test func detachedCheckoutAndReset() async throws {
        let (dir, repo) = try await makeRepo()
        let first = try #require(try await repo.head().commit)
        try dir.write("README.md", "second\n")
        try await repo.commitAll("Second")
        try await repo.checkout(commit: first)
        let head = try await repo.head()
        #expect(head.isDetached)
        #expect(head.commit == first)
        try await repo.checkout(branch: "main")
        try await repo.reset(to: "HEAD~1", mode: .hard)
        #expect(try await repo.head().commit == first)
        #expect(try dir.read("README.md") == "hello\n")
    }

    @Test func tags() async throws {
        let (_, repo) = try await makeRepo()
        let head = try #require(try await repo.head().commit)
        try await repo.createTag("v1.0")
        let annotated = try await repo.createTag("v1.1", message: "Release 1.1\n", tagger: testAuthor)
        #expect(annotated.isAnnotated)
        #expect(annotated.target == head)
        #expect(annotated.message == "Release 1.1\n")
        let all = try await repo.tags()
        #expect(all.map(\.name) == ["v1.1", "v1.0"])
        #expect(all.allSatisfy { $0.target == head })
        let labels = try await repo.referenceLabels()
        #expect(Set(labels[head]?.map(\.name) ?? []) == ["main", "v1.0", "v1.1"])
        try await repo.deleteTag("v1.0")
        #expect(try await repo.tags().map(\.name) == ["v1.1"])
    }

    @Test func fastForwardAndMergeCommit() async throws {
        let (dir, repo) = try await makeRepo()
        try await repo.createBranch("ff", checkout: true)
        try dir.write("ff.txt", "ff\n")
        let ffCommit = try await repo.commitAll("FF")
        try await repo.checkout(branch: "main")
        #expect(try await repo.merge("ff") == .fastForward(ffCommit))
        #expect(try await repo.merge("ff") == .upToDate)

        try await repo.createBranch("side", checkout: true)
        try dir.write("side.txt", "side\n")
        try await repo.commitAll("Side")
        try await repo.checkout(branch: "main")
        try dir.write("main.txt", "main\n")
        try await repo.commitAll("Main")
        let result = try await repo.merge("side")
        guard case .merged(let id) = result else {
            Issue.record("expected a merge commit, got \(result)"); return
        }
        let info = try await repo.commitInfo(id)
        #expect(info.parents.count == 2)
        #expect(info.summary == "Merge branch 'side'")
        #expect(FileManager.default.fileExists(atPath: dir.url.appending(path: "side.txt").path))
        #expect(try await repo.state() == .none)
    }

    /// main and topic both change README.md.
    func conflictingBranches() async throws -> (TempDir, GitRepository) {
        let (dir, repo) = try await makeRepo(["README.md": "base\n", "other.txt": "x\n"])
        try await repo.createBranch("topic", checkout: true)
        try dir.write("README.md", "topic\n")
        try await repo.commitAll("Topic edit")
        try await repo.checkout(branch: "main")
        try dir.write("README.md", "main\n")
        try await repo.commitAll("Main edit")
        return (dir, repo)
    }

    @Test func mergeConflictResolveAndCommit() async throws {
        let (dir, repo) = try await conflictingBranches()
        #expect(try await repo.merge("topic") == .conflicts(["README.md"]))
        #expect(try await repo.state() == .merge)
        let conflicts = try await repo.conflicts()
        #expect(conflicts.count == 1)
        #expect(conflicts[0].kind == .bothModified)
        let versions = try await repo.conflictVersions("README.md")
        #expect(versions.base == Data("base\n".utf8))
        #expect(versions.ours == Data("main\n".utf8))
        #expect(versions.theirs == Data("topic\n".utf8))
        let merged = String(decoding: versions.merged, as: UTF8.self)
        #expect(merged.contains("<<<<<<< main"))
        #expect(merged.contains(">>>>>>> theirs"))
        #expect(!versions.isAutomergeable)
        await #expect(throws: GitError.self) { try await repo.commit(message: "too early") }

        try await repo.resolveConflict("README.md", with: .content(Data("main and topic\n".utf8)))
        #expect(try await repo.conflicts().isEmpty)
        let message = try #require(await repo.preparedMessage())
        let id = try await repo.commit(message: message)
        #expect(try await repo.commitInfo(id).parents.count == 2)
        #expect(try await repo.state() == .none)
        #expect(try dir.read("README.md") == "main and topic\n")
    }

    @Test func abortMerge() async throws {
        let (dir, repo) = try await conflictingBranches()
        _ = try await repo.merge("topic")
        try await repo.abortMerge()
        #expect(try await repo.state() == .none)
        #expect(try dir.read("README.md") == "main\n")
        #expect(try await repo.status().isEmpty)
    }

    @Test func rebaseCleanly() async throws {
        let (dir, repo) = try await makeRepo()
        try await repo.createBranch("topic", checkout: true)
        try dir.write("t1.txt", "1\n")
        try await repo.commitAll("T1")
        try dir.write("t2.txt", "2\n")
        try await repo.commitAll("T2")
        try await repo.checkout(branch: "main")
        try dir.write("m.txt", "m\n")
        let mainHead = try await repo.commitAll("M")
        try await repo.checkout(branch: "topic")
        let result = try await repo.rebase(onto: "main")
        guard case .completed(let newHead) = result else { Issue.record("\(result)"); return }
        let log = try await repo.log()
        #expect(log.map(\.summary) == ["T2", "T1", "M", "Initial commit"])
        #expect(log[2].id == mainHead)
        #expect(log[0].id == newHead)
        #expect(try await repo.head().branch == "topic")
        #expect(try await repo.rebase(onto: "main") == .upToDate)
    }

    @Test func rebaseStopsOnConflictThenContinues() async throws {
        let (_, repo) = try await conflictingBranches()
        try await repo.checkout(branch: "topic")
        let result = try await repo.rebase(onto: "main")
        guard case .stopped(let progress) = result else { Issue.record("\(result)"); return }
        #expect(progress.conflicts == ["README.md"])
        #expect(progress.current == 1)
        #expect(progress.total == 1)
        #expect(try await repo.state() == .rebaseMerge)
        #expect(try await repo.rebaseProgress()?.conflicts == ["README.md"])

        try await repo.resolveConflict("README.md", with: .theirs)
        let finished = try await repo.continueRebase()
        guard case .completed = finished else { Issue.record("\(finished)"); return }
        #expect(try await repo.state() == .none)
        #expect(try await repo.log().map(\.summary) == ["Topic edit", "Main edit", "Initial commit"])
        #expect(try await repo.head().branch == "topic")
    }

    @Test func rebaseAbortRestoresBranch() async throws {
        let (dir, repo) = try await conflictingBranches()
        try await repo.checkout(branch: "topic")
        let before = try await repo.head().commit
        _ = try await repo.rebase(onto: "main")
        try await repo.abortRebase()
        #expect(try await repo.state() == .none)
        #expect(try await repo.head().commit == before)
        #expect(try await repo.head().branch == "topic")
        #expect(try dir.read("README.md") == "topic\n")
    }

    @Test func stashSaveApplyPopDrop() async throws {
        let (dir, repo) = try await makeRepo()
        #expect(try await repo.stash() == nil)
        try dir.write("README.md", "work in progress\n")
        try dir.write("untracked.txt", "u\n")
        try await repo.stash(StashOptions(message: "wip", includeUntracked: true))
        #expect(try await repo.status().isEmpty)
        var list = try await repo.stashes()
        #expect(list.count == 1)
        #expect(list[0].message.contains("wip"))

        #expect(try await repo.applyStash(0) == .applied)
        #expect(try dir.read("README.md") == "work in progress\n")
        #expect(try dir.read("untracked.txt") == "u\n")
        #expect(try await repo.stashes().count == 1)
        try await repo.discard(["README.md", "untracked.txt"])

        #expect(try await repo.popStash() == .applied)
        list = try await repo.stashes()
        #expect(list.isEmpty)
        try await repo.stash()
        try await repo.dropStash()
        #expect(try await repo.stashes().isEmpty)
    }

    @Test func stashPopWithConflict() async throws {
        let (dir, repo) = try await makeRepo(["README.md": "base\n"])
        try dir.write("README.md", "stashed\n")
        try await repo.stash()
        try dir.write("README.md", "committed\n")
        try await repo.commitAll("Committed")
        let result = try await repo.popStash()
        #expect(result == .conflicts(["README.md"]))
        #expect(try await repo.stashes().count == 1)
    }

    @Test func cherryPickAndRevert() async throws {
        let (dir, repo) = try await makeRepo()
        try await repo.createBranch("topic", checkout: true)
        try dir.write("pick.txt", "pick me\n")
        var author = testAuthor
        author.name = "Original Author"
        try await repo.stageAll()
        let picked = try await repo.commit(message: "Pickable", options: CommitOptions(author: author))
        try await repo.checkout(branch: "main")
        let result = try await repo.cherryPick(picked)
        guard case .committed(let id) = result else { Issue.record("\(result)"); return }
        let info = try await repo.commitInfo(id)
        #expect(info.summary == "Pickable")
        #expect(info.author.name == "Original Author")
        #expect(info.committer.name == testAuthor.name)
        #expect(try dir.read("pick.txt") == "pick me\n")

        let reverted = try await repo.revert(id)
        guard case .committed(let revertID) = reverted else { Issue.record("\(reverted)"); return }
        #expect(try await repo.commitInfo(revertID).summary == "Revert \"Pickable\"")
        #expect(!FileManager.default.fileExists(atPath: dir.url.appending(path: "pick.txt").path))
    }

    @Test func cherryPickConflict() async throws {
        let (_, repo) = try await conflictingBranches()
        let topic = try await repo.resolveCommit("topic")
        #expect(try await repo.cherryPick(topic) == .conflicts(["README.md"]))
        #expect(try await repo.state() == .cherryPick)
        try await repo.abortMerge()
        #expect(try await repo.state() == .none)
    }

    @Test func blameAttributesLines() async throws {
        let (dir, repo) = try await makeRepo(["code.c": "int a;\nint b;\n"])
        let first = try #require(try await repo.head().commit)
        try dir.write("code.c", "int a;\nint b;\nint c;\n")
        let second = try await repo.commitAll("Add c")
        let hunks = try await repo.blame("code.c")
        #expect(hunks.count == 2)
        #expect(hunks[0].commit == first)
        #expect(hunks[0].lines == 1...2)
        #expect(hunks[1].commit == second)
        #expect(hunks[1].startLine == 3)
        #expect(hunks[1].summary == "Add c")
        #expect(hunks[1].author?.name == testAuthor.name)
    }

    @Test func logFiltersAndGraph() async throws {
        let (dir, repo) = try await makeRepo()
        try await repo.createBranch("side", checkout: true)
        try dir.write("side.txt", "s\n")
        try await repo.commitAll("Side", date: Date(timeIntervalSince1970: 1_700_000_100))
        try await repo.checkout(branch: "main")
        try dir.write("main.txt", "m\n")
        try await repo.commitAll("Main", date: Date(timeIntervalSince1970: 1_700_000_200))
        _ = try await repo.merge("side")

        var options = LogOptions()
        options.path = "side.txt"
        #expect(try await repo.log(options).map(\.summary) == ["Side"])
        options = LogOptions()
        options.limit = 2
        #expect(try await repo.log(options).count == 2)

        let commits = try await repo.log()
        #expect(commits.count == 4)
        let rows = HistoryGraph.layout(commits)
        #expect(rows.count == 4)
        // The merge commit opens a second lane, which closes at the root.
        #expect(rows[0].commit.isMerge)
        #expect(rows[0].lower.count == 2)
        #expect(rows.map(\.width).max() == 2)
        #expect(rows.last?.column == 0)
        #expect(rows.last?.upper.allSatisfy { $0.toColumn == 0 } == true)
    }

    @Test func graphLayoutKeepsLanesStable() {
        func c(_ n: UInt8, _ parents: [UInt8]) -> CommitInfo {
            func id(_ x: UInt8) -> ObjectID { ObjectID(hex: String(repeating: String(format: "%02x", x), count: 20))! }
            return CommitInfo(id: id(n), parents: parents.map(id), author: testAuthor, committer: testAuthor, message: "c\(n)", isSigned: false)
        }
        // 5 merges 4 and 3; 4 -> 2; 3 -> 2; 2 -> 1
        let rows = HistoryGraph.layout([c(5, [4, 3]), c(4, [2]), c(3, [2]), c(2, [1]), c(1, [])])
        #expect(rows.map(\.column) == [0, 0, 1, 0, 0])
        #expect(rows[2].lower == [GraphRow.Segment(fromColumn: 0, toColumn: 0, color: rows[0].color),
                                  GraphRow.Segment(fromColumn: 1, toColumn: 0, color: rows[0].color)])
        #expect(rows[3].upper.count == 1)
    }
}
