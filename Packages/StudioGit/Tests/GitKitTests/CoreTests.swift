import Foundation
import Testing
@testable import GitKit

@Suite struct CoreTests {
    @Test func libgit2IsLinkedWithTransports() {
        GitRuntime.ensureInitialized()
        #expect(GitRuntime.libgit2Version == "1.9.7")
        let features = GitRuntime.features
        #expect(features.https)
        #expect(features.ssh)
        #expect(features.threads)
    }

    @Test func initCommitAndStatus() async throws {
        let (dir, repo) = try await makeRepo()
        let head = try await repo.head()
        #expect(head.branch == "main")
        #expect(head.commit != nil)
        #expect(try await repo.status().isEmpty)

        try dir.write("README.md", "hello\nworld\n")
        try dir.write("new.txt", "new\n")
        var status = try await repo.status()
        #expect(status.count == 2)
        #expect(status.first { $0.path == "README.md" }?.unstaged == .modified)
        #expect(status.first { $0.path == "new.txt" }?.unstaged == .untracked)

        try await repo.stage(["new.txt"])
        status = try await repo.status()
        #expect(status.first { $0.path == "new.txt" }?.staged == .added)

        let id = try await repo.commit(message: "Add new.txt")
        let info = try await repo.commitInfo(id)
        #expect(info.summary == "Add new.txt")
        #expect(info.author.email == testAuthor.email)
        #expect(info.parents == [head.commit!])
        let log = try await repo.log()
        #expect(log.map(\.summary) == ["Add new.txt", "Initial commit"])
    }

    @Test func emptyCommitIsRefused() async throws {
        let (_, repo) = try await makeRepo()
        await #expect(throws: GitError.self) { try await repo.commit(message: "nothing") }
    }
}
