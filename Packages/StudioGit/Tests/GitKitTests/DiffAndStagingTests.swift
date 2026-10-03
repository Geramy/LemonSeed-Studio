import Foundation
import Testing
@testable import GitKit

@Suite struct DiffAndStagingTests {
    static let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"

    /// Two separate hunks: line 2 changed, line 18 changed.
    func twoHunkRepo() async throws -> (TempDir, GitRepository) {
        let (dir, repo) = try await makeRepo(["file.txt": Self.original])
        var lines = Self.original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[1] = "line 2 changed"
        lines[17] = "line 18 changed"
        try dir.write("file.txt", lines.joined(separator: "\n"))
        return (dir, repo)
    }

    @Test func unstagedDiffHasHunksAndLines() async throws {
        let (_, repo) = try await twoHunkRepo()
        let diffs = try await repo.diff(.unstaged)
        #expect(diffs.count == 1)
        let file = try #require(diffs.first)
        #expect(file.path == "file.txt")
        #expect(file.change == .modified)
        #expect(file.hunks.count == 2)
        #expect(file.additions == 2)
        #expect(file.deletions == 2)
        let first = file.hunks[0]
        #expect(first.header.hasPrefix("@@ -1,5 +1,5 @@"))
        let deleted = try #require(first.lines.first { $0.kind == .deletion })
        #expect(deleted.text == "line 2")
        #expect(deleted.oldLineNumber == 2)
        let added = try #require(first.lines.first { $0.kind == .addition })
        #expect(added.text == "line 2 changed")
        #expect(added.newLineNumber == 2)
        #expect(try await repo.diff(.staged).isEmpty)
        let patch = try await repo.patchText(.unstaged)
        #expect(patch.contains("+line 18 changed"))
    }

    @Test func stageOneHunk() async throws {
        let (_, repo) = try await twoHunkRepo()
        try await repo.stage(path: "file.txt", hunks: [1])
        let staged = try await repo.diff(.staged)
        #expect(staged.first?.hunks.count == 1)
        #expect(staged.first?.hunks.first?.lines.contains { $0.text == "line 18 changed" } == true)
        let unstaged = try await repo.diff(.unstaged)
        #expect(unstaged.first?.hunks.count == 1)
        #expect(unstaged.first?.hunks.first?.lines.contains { $0.text == "line 2 changed" } == true)
        let status = try await repo.status()
        #expect(status.first?.staged == .modified)
        #expect(status.first?.unstaged == .modified)
    }

    @Test func stageSingleLines() async throws {
        let (dir, repo) = try await makeRepo(["list.txt": "a\nb\nc\n"])
        try dir.write("list.txt", "a\nb\nB2\nB3\nc\n")
        let file = try #require(try await repo.diff(file: "list.txt", .unstaged))
        let hunk = file.hunks[0]
        let b2 = try #require(hunk.lines.first { $0.text == "B2" })
        try await repo.stage(path: "list.txt", lines: [LineSelection(hunk: hunk.id, line: b2.id)])
        let index = try #require(try await repo.indexContents("list.txt"))
        #expect(String(decoding: index, as: UTF8.self) == "a\nb\nB2\nc\n")
        // Working tree is untouched.
        #expect(try dir.read("list.txt") == "a\nb\nB2\nB3\nc\n")
    }

    @Test func stageLinesOfUntrackedFile() async throws {
        let (dir, repo) = try await makeRepo()
        try dir.write("new.txt", "one\ntwo\nthree\n")
        let file = try #require(try await repo.diff(file: "new.txt", .unstaged))
        #expect(file.change == .untracked || file.change == .added)
        let lines = Set(file.hunks[0].lines.filter { $0.text != "two" }.map { LineSelection(hunk: 0, line: $0.id) })
        try await repo.stage(path: "new.txt", lines: lines)
        let index = try #require(try await repo.indexContents("new.txt"))
        #expect(String(decoding: index, as: UTF8.self) == "one\nthree\n")
    }

    @Test func unstageHunkAndLines() async throws {
        let (_, repo) = try await twoHunkRepo()
        try await repo.stage(["file.txt"])
        try await repo.unstage(path: "file.txt", hunks: [0])
        let staged = try await repo.diff(.staged)
        #expect(staged.first?.hunks.count == 1)
        #expect(staged.first?.hunks.first?.lines.contains { $0.text == "line 18 changed" } == true)

        // Unstage just the added line of the remaining hunk: the deletion stays staged.
        let hunk = try #require(staged.first?.hunks.first)
        let added = try #require(hunk.lines.first { $0.kind == .addition })
        try await repo.unstage(path: "file.txt", lines: [LineSelection(hunk: hunk.id, line: added.id)])
        let index = String(decoding: try #require(try await repo.indexContents("file.txt")), as: UTF8.self)
        #expect(!index.contains("line 18\n"))
        #expect(!index.contains("line 18 changed"))
        #expect(index.contains("line 2\n"))
    }

    @Test func unstageWholeFiles() async throws {
        let (dir, repo) = try await makeRepo()
        try dir.write("a.txt", "a\n")
        try dir.write("README.md", "changed\n")
        try await repo.stageAll()
        #expect(try await repo.diff(.staged).count == 2)
        try await repo.unstage(["a.txt", "README.md"])
        #expect(try await repo.diff(.staged).isEmpty)
        let status = try await repo.status()
        #expect(status.first { $0.path == "a.txt" }?.unstaged == .untracked)
    }

    @Test func discardHunkAndFiles() async throws {
        let (dir, repo) = try await twoHunkRepo()
        try await repo.discard(path: "file.txt", hunks: [0])
        let text = try dir.read("file.txt")
        #expect(text.contains("line 2\n"))
        #expect(text.contains("line 18 changed"))
        try dir.write("junk.txt", "junk")
        try await repo.discard(["file.txt", "junk.txt"])
        #expect(try dir.read("file.txt") == Self.original)
        #expect(!FileManager.default.fileExists(atPath: dir.url.appending(path: "junk.txt").path))
        #expect(try await repo.status().isEmpty)
    }

    @Test func noNewlineAtEndOfFile() async throws {
        let (dir, repo) = try await makeRepo(["f.txt": "a\nb"])
        try dir.write("f.txt", "a\nb\nc")
        let file = try #require(try await repo.diff(file: "f.txt", .unstaged))
        let lines = file.hunks[0].lines
        #expect(lines.contains { $0.kind == .deletion && $0.text == "b" && !$0.hasNewline })
        #expect(lines.contains { $0.kind == .addition && $0.text == "c" && !$0.hasNewline })
        try await repo.stage(path: "f.txt", hunks: [0])
        let index = String(decoding: try #require(try await repo.indexContents("f.txt")), as: UTF8.self)
        #expect(index == "a\nb\nc")
    }

    @Test func commitDiffAndStats() async throws {
        let (dir, repo) = try await makeRepo()
        try dir.write("README.md", "hello\nthere\n")
        try dir.write("docs/guide.md", "# Guide\n")
        let id = try await repo.commitAll("Docs")
        let diff = try await repo.diff(.commit(id))
        #expect(Set(diff.map(\.path)) == ["README.md", "docs/guide.md"])
        #expect(diff.first { $0.path == "docs/guide.md" }?.change == .added)
        let root = try #require(try await repo.log().last)
        let rootDiff = try await repo.diff(.commit(root.id))
        #expect(rootDiff.map(\.path) == ["README.md"])
        let stats = try await repo.diffStats(.commits(from: root.id, to: id))
        #expect(stats.files == 2)
        #expect(stats.insertions == 2)
    }

    @Test func renamedFileIsDetected() async throws {
        let (dir, repo) = try await makeRepo(["old.txt": String(repeating: "content line\n", count: 20)])
        try FileManager.default.moveItem(at: dir.url.appending(path: "old.txt"), to: dir.url.appending(path: "new.txt"))
        try await repo.stageAll()
        let status = try await repo.status()
        let entry = try #require(status.first)
        #expect(entry.staged == .renamed)
        #expect(entry.path == "new.txt")
        #expect(entry.oldPath == "old.txt")
    }

    @Test func applySelectionKeepsUnselectedChanges() {
        let old = Data("a\nb\nc\n".utf8)
        let hunk = DiffHunk(id: 0, header: "", oldStart: 2, oldCount: 1, newStart: 2, newCount: 2, lines: [
            DiffLine(id: 0, kind: .deletion, oldLineNumber: 2, newLineNumber: nil, text: "b"),
            DiffLine(id: 1, kind: .addition, oldLineNumber: nil, newLineNumber: 2, text: "B"),
            DiffLine(id: 2, kind: .addition, oldLineNumber: nil, newLineNumber: 3, text: "BB"),
        ])
        let raws = [Data("b\n".utf8), Data("B\n".utf8), Data("BB\n".utf8)]
        let all = GitRepository.apply([(hunk, raws)], to: old) { _, _ in true }
        #expect(String(decoding: all, as: UTF8.self) == "a\nB\nBB\nc\n")
        let none = GitRepository.apply([(hunk, raws)], to: old) { _, _ in false }
        #expect(String(decoding: none, as: UTF8.self) == "a\nb\nc\n")
        let onlyAdd = GitRepository.apply([(hunk, raws)], to: old) { _, l in l == 2 }
        #expect(String(decoding: onlyAdd, as: UTF8.self) == "a\nb\nBB\nc\n")
    }
}
