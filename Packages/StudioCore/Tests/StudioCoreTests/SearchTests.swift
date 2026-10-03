import XCTest
@testable import StudioCore

final class GlobTests: XCTestCase {
    func testStar() {
        XCTAssertTrue(Glob("*.swift").matches("main.swift"))
        XCTAssertFalse(Glob("*.swift").matches("src/main.swift"))
        XCTAssertTrue(Glob("src/*.c").matches("src/a.c"))
        XCTAssertFalse(Glob("src/*.c").matches("src/x/a.c"))
        XCTAssertTrue(Glob("*").matches(""))
    }

    func testDoubleStar() {
        XCTAssertTrue(Glob("**/*.c").matches("a.c"))
        XCTAssertTrue(Glob("**/*.c").matches("x/y/a.c"))
        XCTAssertTrue(Glob("src/**").matches("src/a/b/c"))
        XCTAssertTrue(Glob("a/**/b").matches("a/b"))
        XCTAssertTrue(Glob("a/**/b").matches("a/x/y/b"))
        XCTAssertFalse(Glob("a/**/b").matches("a/x/y/c"))
    }

    func testQuestionAndClasses() {
        XCTAssertTrue(Glob("file?.txt").matches("file1.txt"))
        XCTAssertFalse(Glob("file?.txt").matches("file10.txt"))
        XCTAssertTrue(Glob("[abc].o").matches("b.o"))
        XCTAssertFalse(Glob("[abc].o").matches("d.o"))
        XCTAssertTrue(Glob("[a-c]x").matches("bx"))
        XCTAssertTrue(Glob("[!a-c]x").matches("dx"))
        XCTAssertFalse(Glob("[!a-c]x").matches("ax"))
        XCTAssertTrue(Glob("[unterminated").matches("[unterminated"))
    }

    func testEscapes() {
        XCTAssertTrue(Glob("\\*.txt").matches("*.txt"))
        XCTAssertFalse(Glob("\\*.txt").matches("a.txt"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(Glob("*.SWIFT", caseInsensitive: true).matches("Main.swift"))
    }
}

final class IgnoreRulesTests: XCTestCase {
    func testBasicRules() {
        let rules = IgnoreRules(text: """
        # build products
        build/
        *.o
        /TODO
        docs/*.pdf
        !keep.o
        """)
        XCTAssertTrue(rules.isIgnored(path: "build", isDirectory: true))
        XCTAssertFalse(rules.isIgnored(path: "build", isDirectory: false), "directory-only rule")
        XCTAssertTrue(rules.isIgnored(path: "src/build", isDirectory: true))
        XCTAssertTrue(rules.isIgnored(path: "a/b/c.o", isDirectory: false))
        XCTAssertFalse(rules.isIgnored(path: "keep.o", isDirectory: false), "negation re-includes")
        XCTAssertTrue(rules.isIgnored(path: "TODO", isDirectory: false))
        XCTAssertFalse(rules.isIgnored(path: "src/TODO", isDirectory: false), "anchored to the root")
        XCTAssertTrue(rules.isIgnored(path: "docs/a.pdf", isDirectory: false))
        XCTAssertFalse(rules.isIgnored(path: "x/docs/a.pdf", isDirectory: false))
    }

    func testNestedBase() {
        let rules = IgnoreRules(text: "/generated\n*.tmp", base: "sub")
        XCTAssertTrue(rules.isIgnored(path: "sub/generated", isDirectory: true))
        XCTAssertFalse(rules.isIgnored(path: "generated", isDirectory: true))
        XCTAssertTrue(rules.isIgnored(path: "sub/x/y.tmp", isDirectory: false))
        XCTAssertFalse(rules.isIgnored(path: "y.tmp", isDirectory: false))
    }

    func testLeadingDoubleStar() {
        let rules = IgnoreRules(text: "**/cache")
        XCTAssertTrue(rules.isIgnored(path: "cache", isDirectory: true))
        XCTAssertTrue(rules.isIgnored(path: "a/b/cache", isDirectory: true))
    }

    func testCommentsAndBlanks() {
        let rules = IgnoreRules(text: "\n# comment\n   \n\\#notcomment\n")
        XCTAssertEqual(rules.rules.count, 1)
        XCTAssertTrue(rules.isIgnored(path: "#notcomment", isDirectory: false))
    }
}

final class FileWalkerTests: XCTestCase {
    func testWalkHonorsIgnoreFilesAndExcludes() throws {
        let tree = try TemporaryTree([
            ".gitignore": "*.log\nbuild/\n",
            "src/main.c": "int main() {}",
            "src/.gitignore": "generated.c\n",
            "src/generated.c": "",
            "src/util.h": "",
            "build/out.o": "",
            "debug.log": "",
            ".git/HEAD": "ref: refs/heads/main\n",
            "node_modules/x/index.js": "",
            ".env": "A=1",
        ])
        let files = Set(FileWalker.files(in: tree.url))
        XCTAssertEqual(files, [".gitignore", "src/main.c", "src/.gitignore", "src/util.h", ".env"])

        var options = WalkOptions()
        options.respectIgnoreFiles = false
        options.includeHidden = false
        let unfiltered = Set(FileWalker.files(in: tree.url, options: options))
        XCTAssertTrue(unfiltered.contains("build/out.o"))
        XCTAssertTrue(unfiltered.contains("debug.log"))
        XCTAssertFalse(unfiltered.contains(".env"))
        XCTAssertFalse(unfiltered.contains { $0.hasPrefix(".git/") })
    }

    func testGitInfoExclude() throws {
        let tree = try TemporaryTree([".git/info/exclude": "secret.txt\n", "secret.txt": "x", "public.txt": "y"])
        XCTAssertEqual(FileWalker.files(in: tree.url), ["public.txt"])
    }

    func testLimitStopsEarly() throws {
        var files: [String: String] = [:]
        for i in 0..<50 { files["f\(i).txt"] = "" }
        let tree = try TemporaryTree(files)
        XCTAssertEqual(FileWalker.files(in: tree.url, limit: 10).count, 10)
    }
}

final class SearchMatcherTests: XCTestCase {
    func testLiteralLinesAndColumns() throws {
        let text = "alpha\nbeta gamma\n  gamma delta gamma\n"
        let matches = try SearchMatcher(SearchQuery("gamma")).matches(in: text)
        XCTAssertEqual(matches.map(\.line), [2, 3, 3])
        XCTAssertEqual(matches.map(\.column), [6, 3, 15])
        XCTAssertEqual(matches[1].preview, "gamma delta gamma", "leading indentation trimmed")
        XCTAssertEqual(matches[1].previewRange, 0..<5)
        XCTAssertEqual(matches[2].previewRange, 12..<17)
    }

    func testSmartCase() throws {
        let text = "Foo foo FOO"
        XCTAssertEqual(try SearchMatcher(SearchQuery("foo")).matches(in: text).count, 3)
        XCTAssertEqual(try SearchMatcher(SearchQuery("Foo")).matches(in: text).count, 1)
        XCTAssertEqual(try SearchMatcher(SearchQuery("foo", caseSensitivity: .sensitive)).matches(in: text).count, 1)
        XCTAssertEqual(try SearchMatcher(SearchQuery("FOO", caseSensitivity: .insensitive)).matches(in: text).count, 3)
    }

    func testWholeWord() throws {
        let text = "init initialize reinit init_x init"
        let matches = try SearchMatcher(SearchQuery("init", wholeWord: true)).matches(in: text)
        XCTAssertEqual(matches.map(\.column), [1, 31])
        let regex = try SearchMatcher(SearchQuery("ini.", isRegex: true, wholeWord: true)).matches(in: text)
        XCTAssertEqual(regex.map(\.column), [1, 31])
    }

    func testRegex() throws {
        let text = "let x = 42\nvar y = 7\nlet z = 1000\n"
        let matches = try SearchMatcher(SearchQuery(#"^let \w+ = (\d+)"#, isRegex: true)).matches(in: text)
        XCTAssertEqual(matches.map(\.line), [1, 3])
        XCTAssertEqual(matches[1].length, 12)
    }

    func testInvalidRegexThrows() {
        XCTAssertThrowsError(try SearchMatcher(SearchQuery("(unclosed", isRegex: true))) { error in
            guard case SearchError.invalidRegex = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try SearchMatcher(SearchQuery("")))
    }

    func testUnicodeColumnsAndCaseFolding() throws {
        let text = "naïve café CAFÉ\n"
        let matches = try SearchMatcher(SearchQuery("café")).matches(in: text)
        XCTAssertEqual(matches.map(\.column), [7, 12], "non-ASCII smart-case goes through the regex path")
        let literal = try SearchMatcher(SearchQuery("CAFÉ")).matches(in: text)
        XCTAssertEqual(literal.map(\.column), [12])
    }

    func testCRLF() throws {
        let matches = try SearchMatcher(SearchQuery("two")).matches(in: "one\r\ntwo\r\nthree")
        XCTAssertEqual(matches.first?.line, 2)
        XCTAssertEqual(matches.first?.preview, "two")
    }

    func testBinarySkipped() throws {
        var data = Data("needle".utf8)
        data.append(0)
        data.append(contentsOf: Array("needle".utf8))
        XCTAssertTrue(try SearchMatcher(SearchQuery("needle")).matches(in: data).isEmpty)
    }

    func testLongLinesAreClipped() throws {
        let line = String(repeating: "a", count: 500) + "NEEDLE" + String(repeating: "b", count: 500)
        let match = try XCTUnwrap(try SearchMatcher(SearchQuery("NEEDLE")).matches(in: line).first)
        XCTAssertEqual(match.column, 501)
        XCTAssertLessThanOrEqual(match.preview.count, SearchMatcher.previewMaxLength + 2)
        let chars = Array(match.preview)
        XCTAssertEqual(String(chars[match.previewRange]), "NEEDLE")
        XCTAssertTrue(match.preview.hasPrefix("…"))
        XCTAssertTrue(match.preview.hasSuffix("…"))
    }

    func testMatchLimitPerFile() throws {
        let text = String(repeating: "x ", count: 100)
        var query = SearchQuery("x")
        query.maxMatchesPerFile = 10
        XCTAssertEqual(try SearchMatcher(query).matches(in: text).count, 10)
    }
}

final class WorkspaceSearchTests: XCTestCase {
    func testSearchAcrossWorkspace() async throws {
        let tree = try TemporaryTree([
            ".gitignore": "ignored/\n",
            "Sources/App.swift": "struct App {\n  let sampler = GPUSampler()\n}\n",
            "Sources/GPUSampler.swift": "final class GPUSampler {}\n// GPUSampler samples\n",
            "README.md": "Run the GPUSampler.\n",
            "ignored/copy.swift": "GPUSampler",
            "image.bin": "GPUSampler\u{0}binary",
        ])
        let (results, summary) = try await WorkspaceSearch.collect(SearchQuery("GPUSampler"), in: tree.url)
        XCTAssertEqual(results.map(\.relativePath), ["README.md", "Sources/App.swift", "Sources/GPUSampler.swift"])
        XCTAssertEqual(summary.totalMatches, 4)
        XCTAssertEqual(summary.filesMatched, 3)
        XCTAssertFalse(summary.truncated)
    }

    func testIncludeAndExcludeGlobs() async throws {
        let tree = try TemporaryTree([
            "a/x.swift": "token", "a/y.c": "token", "b/z.swift": "token", "b/w.md": "token",
        ])
        var query = SearchQuery("token", includeGlobs: ["*.swift"])
        var (results, _) = try await WorkspaceSearch.collect(query, in: tree.url)
        XCTAssertEqual(results.map(\.relativePath), ["a/x.swift", "b/z.swift"])

        query = SearchQuery("token", excludeGlobs: ["b/"])
        (results, _) = try await WorkspaceSearch.collect(query, in: tree.url)
        XCTAssertEqual(results.map(\.relativePath), ["a/x.swift", "a/y.c"])

        query = SearchQuery("token", includeGlobs: ["b"])
        (results, _) = try await WorkspaceSearch.collect(query, in: tree.url)
        XCTAssertEqual(results.map(\.relativePath), ["b/w.md", "b/z.swift"])
    }

    func testTotalLimitTruncates() async throws {
        var files: [String: String] = [:]
        for i in 0..<20 { files["f\(i).txt"] = String(repeating: "hit\n", count: 10) }
        let tree = try TemporaryTree(files)
        var query = SearchQuery("hit")
        query.maxTotalMatches = 35
        let (_, summary) = try await WorkspaceSearch.collect(query, in: tree.url)
        XCTAssertTrue(summary.truncated)
        XCTAssertEqual(summary.totalMatches, 35)
    }

    func testStreamDeliversFilesThenSummary() async throws {
        let tree = try TemporaryTree(["a.txt": "find me", "b.txt": "and me: find", "c.txt": "nothing"])
        var files = 0
        var finished: SearchSummary?
        for try await event in WorkspaceSearch.search(SearchQuery("find"), in: tree.url) {
            switch event {
            case .file: files += 1
            case .finished(let summary): finished = summary
            }
        }
        XCTAssertEqual(files, 2)
        XCTAssertEqual(finished?.filesSearched, 3)
    }

    func testSearchSpeed() async throws {
        // 600 files of 200 lines each: ~1.2M lines must search in well under a second.
        var files: [String: String] = [:]
        let body = (0..<200).map { "    let value\($0) = compute(\($0)) // some ordinary source line" }.joined(separator: "\n")
        for i in 0..<600 { files["dir\(i % 12)/file\(i).swift"] = body + (i % 50 == 0 ? "\nneedleToken" : "") }
        let tree = try TemporaryTree(files)
        let started = Date()
        let (results, summary) = try await WorkspaceSearch.collect(SearchQuery("needleToken"), in: tree.url)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(results.count, 12)
        XCTAssertEqual(summary.filesSearched, 600)
        XCTAssertLessThan(elapsed, 3.0, "search took \(elapsed) s")
    }
}
