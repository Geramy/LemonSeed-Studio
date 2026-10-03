import Foundation
import Testing
@testable import StudioAgent

@Suite("Edit tool semantics")
struct EditToolTests {
    typealias R = EditEngine.Replacement

    @Test func replacesAUniqueExactMatch() throws {
        let r = try EditEngine.apply([R(oldText: "b = 2", newText: "b = 3")], to: "a = 1\nb = 2\nc = 3\n")
        #expect(r.content == "a = 1\nb = 3\nc = 3\n")
        #expect(r.firstChangedLine == 2)
        #expect(!r.usedFuzzyMatch)
    }

    @Test func matchesEveryEditAgainstTheOriginal() throws {
        // The second oldText only exists in the original, not after the first edit.
        let r = try EditEngine.apply([R(oldText: "x", newText: "yy"), R(oldText: "yz", newText: "Q")], to: "x\nyz\n")
        #expect(r.content == "yy\nQ\n")
    }

    @Test func rejectsMissingText() {
        #expect(throws: EditEngine.Failure.self) {
            try EditEngine.apply([R(oldText: "nope", newText: "")], to: "hello\n")
        }
    }

    @Test func notFoundOffersClosestCandidates() {
        let file = "int add(int a, int b) {\n    return a + b;\n}\n\nint sub(int a, int b) {\n    return a - b;\n}\n"
        do {
            _ = try EditEngine.apply([R(oldText: "int add(int a, int c) {\n    return a + b;", newText: "")], to: file)
            Issue.record("expected failure")
        } catch let EditEngine.Failure.notFound(_, _, candidates) {
            #expect(!candidates.isEmpty)
            #expect(candidates[0].contains("1\tint add(int a, int b) {"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func rejectsAmbiguousText() {
        #expect(throws: EditEngine.Failure.ambiguous(index: 0, total: 1, occurrences: 2)) {
            try EditEngine.apply([R(oldText: "return 0;", newText: "return 1;")], to: "return 0;\nreturn 0;\n")
        }
    }

    @Test func rejectsOverlappingEdits() {
        #expect(throws: EditEngine.Failure.overlap(first: 0, second: 1)) {
            try EditEngine.apply([R(oldText: "abc", newText: "1"), R(oldText: "bcd", newText: "2")], to: "abcd\n")
        }
    }

    @Test func rejectsEmptyOldTextAndNoOps() {
        #expect(throws: EditEngine.Failure.emptyOldText(index: 0, total: 1)) {
            try EditEngine.apply([R(oldText: "", newText: "x")], to: "a")
        }
        #expect(throws: EditEngine.Failure.noChange) {
            try EditEngine.apply([R(oldText: "a", newText: "a")], to: "a")
        }
        #expect(throws: EditEngine.Failure.noEdits) { try EditEngine.apply([], to: "a") }
    }

    @Test func preservesCRLFAndByteOrderMark() throws {
        let r = try EditEngine.apply([R(oldText: "two\nthree", newText: "2\n3")], to: "\u{FEFF}one\r\ntwo\r\nthree\r\n")
        #expect(r.content == "\u{FEFF}one\r\n2\r\n3\r\n")
    }

    @Test func fuzzyMatchRewritesOnlyTouchedLines() throws {
        // Smart quotes and trailing spaces in the file; the model sends ASCII.
        let file = "let a = “x”   \nlet b = 1\t\nlet c = ‘y’\n"
        let r = try EditEngine.apply([R(oldText: "let c = 'y'", newText: "let c = 'z'")], to: file)
        #expect(r.usedFuzzyMatch)
        // Untouched lines keep their original bytes (smart quotes, trailing whitespace).
        #expect(r.content == "let a = “x”   \nlet b = 1\t\nlet c = 'z'\n")
    }

    @Test func toolAcceptsPiArgumentShapes() throws {
        let single = try EditTool.replacements(from: ["path": "f", "edits": ["oldText": "a", "newText": "b"]])
        #expect(single == [R(oldText: "a", newText: "b")])
        let asString = try EditTool.replacements(from: ["path": "f", "edits": #"[{"oldText":"a","newText":"b"}]"#])
        #expect(asString == [R(oldText: "a", newText: "b")])
        let legacy = try EditTool.replacements(from: ["path": "f", "oldText": "a", "newText": "b"])
        #expect(legacy == [R(oldText: "a", newText: "b")])
        #expect(throws: ToolError.self) { try EditTool.replacements(from: ["path": "f"]) }
    }

    @Test func toolEditsAtomicallyAndCheckpointsTheOriginal() async throws {
        let ws = try TempWorkspace(["src/a.c": "int x = 1;\nint y = 2;\n"])
        let store = CheckpointStore(workspace: ws.workspace, storage: .clone)
        store.begin()
        let ctx = ws.context(observer: store)
        let out = try await EditTool().execute(
            ["path": "src/a.c", "edits": [["oldText": "x = 1", "newText": "x = 10"], ["oldText": "y = 2", "newText": "y = 20"]]],
            context: ctx)
        #expect(out.text.contains("Applied 2 edits"))
        #expect(ws.read("src/a.c") == "int x = 10;\nint y = 20;\n")
        // A failing call changes nothing.
        await #expect(throws: ToolError.self) {
            try await EditTool().execute(
                ["path": "src/a.c", "edits": [["oldText": "x = 10", "newText": "x = 0"], ["oldText": "missing", "newText": ""]]],
                context: ctx)
        }
        #expect(ws.read("src/a.c") == "int x = 10;\nint y = 20;\n")
        let cp = try #require(store.end())
        #expect(cp.files == [CheckpointFile(path: "src/a.c", existed: true)])
        #expect(store.originalData(cp, path: "src/a.c") == Data("int x = 1;\nint y = 2;\n".utf8))
        try store.restore(cp)
        #expect(ws.read("src/a.c") == "int x = 1;\nint y = 2;\n")
    }

    @Test func toolRefusesPathsOutsideTheWorkspace() async throws {
        let ws = try TempWorkspace(["a.txt": "a"])
        let ctx = ws.context()
        for path in ["../escape.txt", "/../outside.txt", "~/x", ".lemonseed/sessions/x.jsonl"] {
            await #expect(throws: WorkspaceError.self) {
                try await WriteTool().execute(["path": .string(path), "content": "x"], context: ctx)
            }
        }
        // A symlink inside the workspace that points outside is caught too.
        try FileManager.default.createSymbolicLink(at: ws.root.appending(path: "link"),
                                                   withDestinationURL: FileManager.default.temporaryDirectory)
        await #expect(throws: WorkspaceError.self) {
            try await WriteTool().execute(["path": "link/evil.txt", "content": "x"], context: ctx)
        }
        // "/a.txt" means the workspace root, as the prompt presents it.
        let out = try await ReadTool().execute(["path": "/a.txt"], context: ctx)
        #expect(out.text.contains("1\ta"))
    }

    @Test func readToolPagesLargeFiles() async throws {
        let text = (1...1000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let ws = try TempWorkspace(["big.txt": text])
        let first = try await ReadTool().execute(["path": "big.txt"], context: ws.context())
        #expect(first.text.contains("Use offset=401 to continue"))
        let range = try await ReadTool().execute(["path": "big.txt", "offset": "995", "limit": 3], context: ws.context())
        #expect(range.text == "995\tline 995\n996\tline 996\n997\tline 997\n\n[Showing lines 995-997 of 1000. Use offset=998 to continue.]")
    }
}
