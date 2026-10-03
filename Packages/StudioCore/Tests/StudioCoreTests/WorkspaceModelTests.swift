import XCTest
@testable import StudioCore

final class FileOperationsTests: XCTestCase {
    func testValidateNames() {
        XCTAssertNoThrow(try FileOperations.validate(name: "main.swift"))
        XCTAssertNoThrow(try FileOperations.validate(name: ".gitignore"))
        for bad in ["", "  ", ".", "..", "a/b", "nul\0"] {
            XCTAssertThrowsError(try FileOperations.validate(name: bad), bad)
        }
    }

    func testUniqueNames() throws {
        let tree = try TemporaryTree(["a.txt": "", "a 2.txt": "", "Makefile": "", ".env": "", "dir/": ""])
        XCTAssertEqual(FileOperations.uniqueURL(for: "a.txt", in: tree.url).lastPathComponent, "a 3.txt")
        XCTAssertEqual(FileOperations.uniqueURL(for: "a 2.txt", in: tree.url).lastPathComponent, "a 3.txt")
        XCTAssertEqual(FileOperations.uniqueURL(for: "Makefile", in: tree.url).lastPathComponent, "Makefile 2")
        XCTAssertEqual(FileOperations.uniqueURL(for: ".env", in: tree.url).lastPathComponent, ".env 2")
        XCTAssertEqual(FileOperations.uniqueURL(for: "dir", in: tree.url).lastPathComponent, "dir 2")
        XCTAssertEqual(FileOperations.uniqueURL(for: "new.txt", in: tree.url).lastPathComponent, "new.txt")
    }

    func testCreateRenameMoveCopyDelete() throws {
        let tree = try TemporaryTree(["src/": "", "docs/": ""])
        let file = try FileOperations.createFile(named: "main.c", in: tree.child("src"), contents: Data("int x;".utf8))
        XCTAssertEqual(try tree.read("src/main.c"), "int x;")
        XCTAssertThrowsError(try FileOperations.createFile(named: "main.c", in: tree.child("src"))) { error in
            XCTAssertEqual(error as? FileOperationError, .alreadyExists("main.c"))
        }
        let folder = try FileOperations.createFolder(named: "include", in: tree.child("src"))
        XCTAssertTrue(FileOperations.isDirectory(folder))

        let renamed = try FileOperations.rename(file, to: "app.c")
        XCTAssertEqual(renamed.lastPathComponent, "app.c")
        XCTAssertFalse(tree.exists("src/main.c"))

        let moved = try FileOperations.move(renamed, into: tree.child("docs"))
        XCTAssertEqual(moved.path, tree.child("docs/app.c").standardizedFileURL.path)

        let copy = try FileOperations.copy(moved, into: tree.child("docs"))
        XCTAssertEqual(copy.lastPathComponent, "app 2.c")

        let duplicate = try FileOperations.duplicate(moved)
        XCTAssertEqual(duplicate.lastPathComponent, "app 3.c")

        try FileOperations.delete(copy)
        XCTAssertFalse(tree.exists("docs/app 2.c"))
        XCTAssertThrowsError(try FileOperations.delete(copy))
    }

    func testMoveCollisionsAndCycles() throws {
        let tree = try TemporaryTree(["a/x.txt": "1", "b/x.txt": "2", "a/inner/": ""])
        let moved = try FileOperations.move(tree.child("a/x.txt"), into: tree.child("b"))
        XCTAssertEqual(moved.lastPathComponent, "x 2.txt", "a collision picks a free name")
        XCTAssertEqual(try tree.read("b/x.txt"), "2", "existing file untouched")
        XCTAssertThrowsError(try FileOperations.move(tree.child("a"), into: tree.child("a/inner"))) { error in
            XCTAssertEqual(error as? FileOperationError, .moveIntoItself("a"))
        }
        // Moving into the same folder is a no-op.
        XCTAssertEqual(try FileOperations.move(tree.child("b/x.txt"), into: tree.child("b")).lastPathComponent, "x.txt")
    }

    func testCaseOnlyRename() throws {
        let tree = try TemporaryTree(["readme.md": "x"])
        let renamed = try FileOperations.rename(tree.child("readme.md"), to: "README.md")
        XCTAssertEqual(renamed.lastPathComponent, "README.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: tree.url.path)
        XCTAssertEqual(names, ["README.md"])
    }

    func testRelativePath() {
        let root = URL(fileURLWithPath: "/tmp/ws")
        XCTAssertEqual(FileOperations.relativePath(of: URL(fileURLWithPath: "/tmp/ws/a/b.c"), to: root), "a/b.c")
        XCTAssertEqual(FileOperations.relativePath(of: root, to: root), "")
        XCTAssertNil(FileOperations.relativePath(of: URL(fileURLWithPath: "/tmp/wsx/a"), to: root))
    }
}

@MainActor
final class FileTreeTests: XCTestCase {
    func testLazyLoadingSortingAndRows() async throws {
        let tree = try TemporaryTree([
            "b.txt": "", "a.txt": "", "file10.c": "", "file2.c": "", "Zeta/": "", "alpha/one.swift": "",
            ".git/HEAD": "", ".DS_Store": "",
        ])
        let fileTree = FileTree(rootURL: tree.url)
        await fileTree.load(fileTree.root)
        XCTAssertEqual(fileTree.rows.map(\.node.name), ["alpha", "Zeta", "a.txt", "b.txt", "file2.c", "file10.c"])
        let alpha = try XCTUnwrap(fileTree.rows.first?.node)
        XCTAssertNil(alpha.children, "children load lazily")
        await fileTree.expand(alpha)
        XCTAssertEqual(fileTree.rows.map(\.node.name), ["alpha", "one.swift", "Zeta", "a.txt", "b.txt", "file2.c", "file10.c"])
        XCTAssertEqual(fileTree.rows[1].depth, 1)
        XCTAssertEqual(fileTree.rows[1].node.relativePath, "alpha/one.swift")
        fileTree.collapse(alpha)
        XCTAssertEqual(fileTree.rows.count, 6)
    }

    func testRevealExpandsAncestors() async throws {
        let tree = try TemporaryTree(["a/b/c/deep.txt": ""])
        let fileTree = FileTree(rootURL: tree.url)
        let node = await fileTree.reveal(tree.child("a/b/c/deep.txt"))
        XCTAssertEqual(node?.name, "deep.txt")
        XCTAssertEqual(fileTree.rows.map(\.node.name), ["a", "b", "c", "deep.txt"])
        XCTAssertEqual(fileTree.expandedRelativePaths, ["a", "a/b", "a/b/c"])
    }

    func testReloadKeepsNodeIdentity() async throws {
        let tree = try TemporaryTree(["dir/x.txt": "", "y.txt": ""])
        let fileTree = FileTree(rootURL: tree.url)
        await fileTree.load(fileTree.root)
        let dir = try XCTUnwrap(fileTree.node(for: tree.child("dir")))
        await fileTree.expand(dir)
        try tree.write("z.txt", "")
        await fileTree.reload(directory: tree.url)
        XCTAssertTrue(fileTree.node(for: tree.child("dir")) === dir)
        XCTAssertTrue(fileTree.isExpanded(dir))
        XCTAssertEqual(fileTree.rows.map(\.node.name), ["dir", "x.txt", "y.txt", "z.txt"])
    }

    func testRestoreExpansion() async throws {
        let tree = try TemporaryTree(["a/b/file.txt": "", "c/d.txt": ""])
        let fileTree = FileTree(rootURL: tree.url)
        await fileTree.load(fileTree.root)
        await fileTree.restoreExpansion(["a/b", "a", "missing"])
        XCTAssertEqual(fileTree.rows.map(\.node.name), ["a", "b", "file.txt", "c"])
    }
}

@MainActor
final class WorkspaceTests: XCTestCase {
    func testOpenIndexesAndTracksDocuments() async throws {
        let tree = try TemporaryTree(["src/main.c": "int main(void) { return 0; }\n", "README.md": "# Hi\n", ".gitignore": "*.o\n", "x.o": ""])
        let workspace = Workspace(rootURL: tree.url)
        defer { workspace.close() }
        await workspace.open()
        await workspace.waitForIndex()
        XCTAssertEqual(Set(workspace.fileIndex), ["src/main.c", "README.md", ".gitignore"])

        let document = workspace.document(for: tree.child("src/main.c"))
        XCTAssertTrue(workspace.document(for: tree.child("src/main.c")) === document, "one document per file")
        let loaded = await eventually { document.loadState == .loaded }
        XCTAssertTrue(loaded)
        XCTAssertEqual(document.language.id, "c")
        XCTAssertFalse(document.isDirty)
    }

    func testRenameAndMoveFollowOpenDocuments() async throws {
        let tree = try TemporaryTree(["src/util.c": "x", "lib/": ""])
        let workspace = Workspace(rootURL: tree.url)
        defer { workspace.close() }
        await workspace.open()
        let document = workspace.document(for: tree.child("src/util.c"))
        _ = await eventually { document.loadState == .loaded }

        let renamed = try await workspace.rename(tree.child("src/util.c"), to: "helpers.c")
        XCTAssertEqual(document.url, renamed.standardizedFileURL)
        XCTAssertEqual(document.name, "helpers.c")

        // Moving the folder carries the document along.
        let movedFolder = try await workspace.move(tree.child("src"), into: tree.child("lib"))
        XCTAssertEqual(document.url.path, movedFolder.appendingPathComponent("helpers.c").standardizedFileURL.path)
        XCTAssertTrue(tree.exists("lib/src/helpers.c"))
    }

    func testDeleteReportsAffectedDocuments() async throws {
        let tree = try TemporaryTree(["dir/a.txt": "a", "dir/b.txt": "b", "c.txt": "c"])
        let workspace = Workspace(rootURL: tree.url)
        defer { workspace.close() }
        await workspace.open()
        let a = workspace.document(for: tree.child("dir/a.txt"))
        _ = workspace.document(for: tree.child("c.txt"))
        let affected = try await workspace.delete(tree.child("dir"))
        XCTAssertEqual(affected.map(\.name), [a.name])
        XCTAssertFalse(tree.exists("dir"))
    }

    func testCreateUpdatesTreeAndIndex() async throws {
        let tree = try TemporaryTree(["keep.txt": ""])
        let workspace = Workspace(rootURL: tree.url)
        defer { workspace.close() }
        await workspace.open()
        try await workspace.createFolder(named: "src", in: tree.url)
        try await workspace.createFile(named: "new.swift", in: tree.child("src"))
        XCTAssertEqual(workspace.tree.rows.map(\.node.name), ["src", "keep.txt"])
        let indexed = await eventually(timeout: 4) { workspace.fileIndex.contains("src/new.swift") }
        XCTAssertTrue(indexed)
    }

    func testWatcherPicksUpExternalChanges() async throws {
        let tree = try TemporaryTree(["a.txt": "one"])
        let workspace = Workspace(rootURL: tree.url)
        defer { workspace.close() }
        await workspace.open()
        let document = workspace.document(for: tree.child("a.txt"))
        _ = await eventually { document.loadState == .loaded }

        // A file created by another process appears in the tree.
        try tree.write("b.txt", "")
        let appeared = await eventually { workspace.tree.rows.contains { $0.node.name == "b.txt" } }
        XCTAssertTrue(appeared)

        // An external edit reloads a clean document.
        try await Task.sleep(for: .milliseconds(1100)) // modification dates have 1 s granularity on some volumes
        try Data("two".utf8).write(to: tree.child("a.txt"))
        let reloaded = await eventually(timeout: 4) { document.text == "two" }
        XCTAssertTrue(reloaded)
    }
}

@MainActor
final class EditorDocumentTests: XCTestCase {
    func testLoadEditSaveRoundTrip() async throws {
        let tree = try TemporaryTree(["a.txt": "hello\n"])
        let document = EditorDocument(url: tree.child("a.txt"))
        await document.load()
        XCTAssertEqual(document.text, "hello\n")
        XCTAssertEqual(document.lineCount, 2)
        document.setText("hello world\n")
        XCTAssertTrue(document.isDirty)
        try await document.save()
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try tree.read("a.txt"), "hello world\n")
    }

    func testCRLFAndBOMArePreserved() async throws {
        let tree = try TemporaryTree()
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("a\r\nb\r\n".utf8))
        try tree.writeData("win.txt", data)
        let document = EditorDocument(url: tree.child("win.txt"))
        await document.load()
        XCTAssertEqual(document.text, "a\nb\n")
        XCTAssertEqual(document.lineEnding, .crlf)
        XCTAssertTrue(document.hasByteOrderMark)
        document.setText("a\nb\nc\n")
        try await document.save()
        var expected = Data([0xEF, 0xBB, 0xBF])
        expected.append(Data("a\r\nb\r\nc\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: tree.child("win.txt")), expected)
    }

    func testBinaryAndLatin1() async throws {
        let tree = try TemporaryTree()
        try tree.writeData("blob.bin", Data([0x00, 0x01, 0x02]))
        try tree.writeData("latin.txt", Data([0x63, 0x61, 0x66, 0xE9]))
        let binary = EditorDocument(url: tree.child("blob.bin"))
        await binary.load()
        XCTAssertEqual(binary.loadState, .binary(bytes: 3))
        let latin = EditorDocument(url: tree.child("latin.txt"))
        await latin.load()
        XCTAssertEqual(latin.text, "café")
    }

    func testExternalChangeWhileDirtyIsFlagged() async throws {
        let tree = try TemporaryTree(["a.txt": "one"])
        let document = EditorDocument(url: tree.child("a.txt"))
        await document.load()
        document.setText("local edit")
        try await Task.sleep(for: .milliseconds(1100))
        try Data("remote".utf8).write(to: tree.child("a.txt"))
        await document.fileDidChangeOnDisk()
        XCTAssertTrue(document.hasExternalChanges)
        XCTAssertEqual(document.text, "local edit")
    }
}

@MainActor
final class WorkspaceLibraryTests: XCTestCase {
    func testProjectsAndPersistence() throws {
        let tree = try TemporaryTree(["Projects/": "", "Support/": ""])
        let storage = tree.child("Support/Workspaces.json")
        let library = WorkspaceLibrary(storageURL: storage, projectsFolder: tree.child("Projects"))
        let created = try library.createProject(named: "Demo")
        XCTAssertEqual(library.projects().map(\.lastPathComponent), ["Demo"])
        XCTAssertTrue(created.isProject)
        let resolved = try library.resolve(created)
        XCTAssertEqual(resolved.url.lastPathComponent, "Demo")
        resolved.close()

        let reopened = WorkspaceLibrary(storageURL: storage, projectsFolder: tree.child("Projects"))
        XCTAssertEqual(reopened.recents.map(\.displayName), ["Demo"])
        XCTAssertEqual(reopened.reference(forProject: "Demo").id, created.id, "no duplicate entry")
    }

    func testBookmarkedFolderResolvesAfterMove() throws {
        let tree = try TemporaryTree(["Projects/": "", "elsewhere/repo/file.txt": "x"])
        let library = WorkspaceLibrary(storageURL: tree.child("w.json"), projectsFolder: tree.child("Projects"))
        let reference = try library.addFolder(tree.child("elsewhere/repo"))
        XCTAssertFalse(reference.isProject)
        XCTAssertEqual(reference.displayName, "repo")
        let resolved = try library.resolve(reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.url.appendingPathComponent("file.txt").path))
        resolved.close()

        // Adding the same folder again updates the entry instead of duplicating it.
        _ = try library.addFolder(tree.child("elsewhere/repo"))
        XCTAssertEqual(library.recents.count, 1)

        // A folder in the Projects folder is recorded as a project.
        try tree.write("Projects/Inside/", "")
        XCTAssertTrue(try library.addFolder(tree.child("Projects/Inside")).isProject)
    }

    func testMissingProjectThrows() throws {
        let tree = try TemporaryTree(["Projects/Gone/": ""])
        let library = WorkspaceLibrary(storageURL: tree.child("w.json"), projectsFolder: tree.child("Projects"))
        let reference = library.reference(forProject: "Gone")
        try FileManager.default.removeItem(at: tree.child("Projects/Gone"))
        XCTAssertThrowsError(try library.resolve(reference)) { error in
            XCTAssertEqual(error as? WorkspaceLibraryError, .notFound("Gone"))
        }
        library.remove(reference.id)
        XCTAssertTrue(library.recents.isEmpty)
    }

    func testRecentsAreCapped() throws {
        let tree = try TemporaryTree(["Projects/": ""])
        let library = WorkspaceLibrary(storageURL: tree.child("w.json"), projectsFolder: tree.child("Projects"))
        library.maximumRecents = 3
        for name in ["a", "b", "c", "d"] { _ = library.reference(forProject: name) }
        XCTAssertEqual(library.recents.count, 3)
    }
}

final class FileWatcherTests: XCTestCase {
    func testReportsDirectoryChangesDebounced() throws {
        let tree = try TemporaryTree(["dir/": ""])
        let expectation = expectation(description: "change")
        expectation.assertForOverFulfill = false
        let received = LockedBox<Set<URL>>([])
        let watcher = FileWatcher(debounce: .milliseconds(50)) { urls in
            received.mutate { $0.formUnion(urls) }
            expectation.fulfill()
        }
        XCTAssertTrue(watcher.watch(tree.child("dir")))
        XCTAssertFalse(watcher.watch(tree.child("missing")))
        try tree.write("dir/a.txt", "")
        try tree.write("dir/b.txt", "")
        wait(for: [expectation], timeout: 3)
        XCTAssertTrue(received.value.contains { $0.path == tree.child("dir").standardizedFileURL.path })
        watcher.unwatchAll()
        XCTAssertTrue(watcher.watchedPaths.isEmpty)
    }

    func testDeletionReportsParentAndStopsWatching() throws {
        let tree = try TemporaryTree(["file.txt": "x"])
        let expectation = expectation(description: "deleted")
        expectation.assertForOverFulfill = false
        let received = LockedBox<Set<String>>([])
        let watcher = FileWatcher(debounce: .milliseconds(30)) { urls in
            received.mutate { $0.formUnion(urls.map(\.path)) }
            expectation.fulfill()
        }
        watcher.watch(tree.child("file.txt"))
        try FileManager.default.removeItem(at: tree.child("file.txt"))
        wait(for: [expectation], timeout: 3)
        XCTAssertTrue(received.value.contains(tree.url.standardizedFileURL.path))
        XCTAssertTrue(watcher.watchedPaths.isEmpty)
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

final class RepositoryInfoTests: XCTestCase {
    func testBranchAndOrigin() throws {
        let tree = try TemporaryTree([
            ".git/HEAD": "ref: refs/heads/feature/shell\n",
            ".git/config": "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://github.com/example/repo.git\n",
            "src/a.c": "",
        ])
        let info = try XCTUnwrap(RepositoryInfo.find(containing: tree.child("src")))
        XCTAssertEqual(info.head.branch, "feature/shell")
        XCTAssertEqual(info.originURL, "https://github.com/example/repo.git")
        XCTAssertEqual(info.workTree.standardizedFileURL.path, tree.url.standardizedFileURL.path)
    }

    func testWorktreeGitFileAndDetachedHead() throws {
        let tree = try TemporaryTree([
            "main/.git/worktrees/wt/HEAD": "0123456789abcdef0123456789abcdef01234567\n",
            "main/.git/worktrees/wt/commondir": "../..\n",
            "main/.git/config": "[remote \"origin\"]\n  url = git@example.com:x/y.git\n",
            "wt/.git": "gitdir: ../main/.git/worktrees/wt\n",
        ])
        let info = try XCTUnwrap(RepositoryInfo.find(containing: tree.child("wt")))
        XCTAssertNil(info.head.branch)
        XCTAssertEqual(info.head.detachedAt, "0123456")
        XCTAssertEqual(info.head.headDescription, "(0123456)")
        XCTAssertEqual(info.originURL, "git@example.com:x/y.git")
    }
}

@MainActor
final class CentersTests: XCTestCase {
    func testDiagnosticsBySource() {
        let center = DiagnosticsCenter()
        let file = URL(fileURLWithPath: "/w/a.c")
        center.set([Diagnostic(url: file, at: TextPosition(line: 3), severity: .error, message: "e", source: "clang"),
                    Diagnostic(url: file, at: TextPosition(line: 1), severity: .warning, message: "w", source: "clang")],
                   for: file, source: "clang")
        center.set([Diagnostic(url: file, at: TextPosition(line: 2), severity: .warning, message: "lint", source: "lint")],
                   for: file, source: "lint")
        XCTAssertEqual(center.errorCount, 1)
        XCTAssertEqual(center.warningCount, 2)
        XCTAssertEqual(center.diagnostics(for: file).map(\.range.lowerBound.line), [1, 2, 3])
        center.clear(source: "clang")
        XCTAssertEqual(center.all.map(\.message), ["lint"])
        center.move(from: URL(fileURLWithPath: "/w"), to: URL(fileURLWithPath: "/v"))
        XCTAssertEqual(center.diagnostics(for: URL(fileURLWithPath: "/v/a.c")).count, 1)
    }

    func testOutputChannels() {
        let output = OutputCenter()
        output.limit = 3
        output.append("one\ntwo", channel: "Build")
        output.append("three\nfour", channel: "Build")
        output.append("hello", channel: "Studio")
        XCTAssertEqual(output.lines("Build").map(\.text), ["two", "three", "four"])
        XCTAssertEqual(output.channelOrder, ["Build", "Studio"])
    }

    func testTextPositionParsing() {
        XCTAssertEqual(TextPosition(parsing: "42"), TextPosition(line: 42))
        XCTAssertEqual(TextPosition(parsing: "42:7"), TextPosition(line: 42, column: 7))
        XCTAssertEqual(TextPosition(parsing: "3,2"), TextPosition(line: 3, column: 2))
        XCTAssertNil(TextPosition(parsing: "x"))
        XCTAssertNil(TextPosition(parsing: "0"))
    }

    func testLanguageDetection() {
        XCTAssertEqual(Language.forFile(named: "main.swift").name, "Swift")
        XCTAssertEqual(Language.forFile(named: "CMakeLists.txt").id, "cmake")
        XCTAssertEqual(Language.forFile(named: "kernel.hip").id, "hip")
        XCTAssertEqual(Language.forFile(named: "notes"), .plainText)
    }

    func testModelListingParse() throws {
        let data = Data(#"{"object":"list","data":[{"id":"qwen3.8-27b-q4","object":"model"}]}"#.utf8)
        XCTAssertEqual(try ModelEndpointProbe.parseModels(data), ["qwen3.8-27b-q4"])
    }
}
