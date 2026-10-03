import Foundation
import Testing
@testable import StudioAgent

@Suite("In-process shell")
struct ShellTests {
    func run(_ cmd: String, _ ws: TempWorkspace) async -> ShellResult {
        await InProcessShell().run(cmd, fileSystem: ws.fileSystem(), timeout: .seconds(10), output: { _ in })
    }

    @Test func pipelinesListsAndRedirections() async throws {
        let ws = try TempWorkspace(["src/a.c": "int main() {}\n// TODO a\n", "src/b.c": "// TODO b\n// TODO c\n", "README.md": "x\n"])
        #expect(await run("grep -rn TODO src | wc -l", ws).output.trimmingCharacters(in: .whitespaces) == "3\n")
        #expect(await run("ls src", ws).output == "a.c\nb.c\n")
        #expect(await run("cat src/*.c | grep -c TODO", ws).output == "3\n")
        #expect(await run("false && echo no || echo yes", ws).output == "yes\n")
        #expect(await run("echo 'a  b' \"c\\\"d\" e\\ f", ws).output == "a  b c\"d e f\n")
        _ = await run("echo one > out.txt; echo two >> out.txt", ws)
        #expect(ws.read("out.txt") == "one\ntwo\n")
        #expect(await run("sort -r < out.txt | head -n 1", ws).output == "two\n")
        #expect(await run("cd src && pwd", ws).output == "/src\n")
        #expect(await run("find . -name '*.c'", ws).output == "./src/a.c\n./src/b.c\n")
    }

    @Test func mutatingCommandsStayInTheJailAndNotifyCheckpoints() async throws {
        let ws = try TempWorkspace(["a.txt": "A\n"])
        let store = CheckpointStore(workspace: ws.workspace, storage: .memory)
        store.begin()
        let fs = ws.fileSystem(observer: store)
        let sh = InProcessShell()
        _ = await sh.run("mkdir -p d && mv a.txt d/b.txt && touch c.txt", fileSystem: fs, timeout: .seconds(5)) { _ in }
        #expect(ws.read("d/b.txt") == "A\n")
        let r = await sh.run("rm ../../etc/passwd", fileSystem: fs, timeout: .seconds(5)) { _ in }
        #expect(r.exitCode != 0)
        #expect(r.output.contains("outside the workspace"))
        let cp = try #require(store.end())
        #expect(Set(cp.files.map(\.path)) == ["a.txt", "d/b.txt", "c.txt"])
        try store.restore(cp)
        #expect(ws.read("a.txt") == "A\n")
        #expect(!ws.exists("d/b.txt"))
    }

    @Test func unknownCommandsAndUnsupportedSyntaxFailClearly() async throws {
        let ws = try TempWorkspace()
        let r = await run("python3 -c 'print(1)'", ws)
        #expect(r.exitCode == 127)
        #expect(r.output.contains("command not found"))
        #expect(await run("echo $HOME", ws).output.contains("not supported"))
        #expect(await run("sleep 1 &", ws).output.contains("background"))
    }
}

@Suite("Glob")
struct GlobTests {
    @Test func patterns() {
        #expect(Glob("*.c").matches("src/deep/a.c"))
        #expect(!Glob("src/*.c").matches("src/deep/a.c"))
        #expect(Glob("src/**/*.c").matches("src/deep/a.c"))
        #expect(Glob("src/**/*.c").matches("src/a.c"))
        #expect(Glob("**/*.{h,hpp}").matches("include/x.hpp"))
        #expect(!Glob("**/*.{h,hpp}").matches("include/x.c"))
        #expect(Glob("file[0-9].txt").matches("file7.txt"))
        #expect(!Glob("file[!0-9].txt").matches("file7.txt"))
        #expect(Glob("*Test*").matches("Tests/MathTests.swift"))
        #expect(Glob("a?c").matches("abc"))
    }
}

@Suite("Line diff and hunk review")
struct DiffTests {
    @Test func hunksAndUnifiedOutput() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n"
        let new = "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\n"
        let hunks = LineDiff.hunks(old: old, new: new)
        #expect(hunks.count == 3)
        #expect(hunks[0].oldLines == ["b"] && hunks[0].newLines == ["B"])
        #expect(hunks[2].newLines == ["m"])
        let u = LineDiff.unified(old: old, new: new, oldName: "a/x", newName: "b/x")
        #expect(u.hasPrefix("--- a/x\n+++ b/x\n@@ -1,5 +1,5 @@\n a\n-b\n+B\n c\n"))
    }

    @Test func mergeKeepsAcceptedHunksOnly() {
        let old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n"
        let new = "1\nTWO\n3\n4\n5\n6\n7\nEIGHT\n9\nTEN\n"
        #expect(LineDiff.merge(old: old, new: new) { _ in true } == new)
        #expect(LineDiff.merge(old: old, new: new) { _ in false } == old)
        #expect(LineDiff.merge(old: old, new: new) { $0 == 1 } == "1\n2\n3\n4\n5\n6\n7\nEIGHT\n9\n")
    }

    @Test func diffIsMinimal() {
        let a = LineDiff.lines("x\na\nb\nc\ny\n"), b = LineDiff.lines("a\nb\nz\nc\n")
        let ops = LineDiff.diff(a, b)
        let changes = ops.filter { if case .equal = $0 { false } else { true } }
        #expect(changes.count == 3)  // -x, +z, -y
    }
}
