import XCTest
@testable import StudioCore

final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceRequired() {
        let matcher = FuzzyMatcher("abc")
        XCTAssertNotNil(matcher.match("a_b_c"))
        XCTAssertNotNil(matcher.match("ABC"))
        XCTAssertNil(matcher.match("acb"))
        XCTAssertNil(matcher.match("ab"))
    }

    func testEmptyQueryMatchesEverything() {
        let match = FuzzyMatcher("").match("anything")
        XCTAssertEqual(match?.score, 0)
        XCTAssertEqual(match?.positions, [])
        XCTAssertTrue(FuzzyMatcher("  ").isEmpty)
    }

    func testPositionsAreInOrderAndCorrect() throws {
        let candidate = "Sources/StudioCore/Search/FuzzyMatcher.swift"
        let match = try XCTUnwrap(FuzzyMatcher("fzm").match(candidate))
        let chars = Array(candidate)
        XCTAssertEqual(match.positions, match.positions.sorted())
        XCTAssertEqual(match.positions.map { Character(chars[$0].lowercased()) }, ["f", "z", "m"])
        // It should pick the file name's F, not an earlier letter.
        XCTAssertEqual(chars[match.positions[0]], "F")
        XCTAssertEqual(chars[match.positions[2]], "M")
    }

    func testPrefersWordBoundaries() throws {
        let matcher = FuzzyMatcher("fm")
        let boundary = try XCTUnwrap(matcher.match("FuzzyMatcher.swift"))
        let middle = try XCTUnwrap(matcher.match("affirmation.txt"))
        XCTAssertGreaterThan(boundary.score, middle.score)
    }

    func testPrefersConsecutiveRuns() throws {
        let matcher = FuzzyMatcher("main")
        let consecutive = try XCTUnwrap(matcher.match("src/main.c"))
        let scattered = try XCTUnwrap(matcher.match("src/my_app_init.c"))
        XCTAssertGreaterThan(consecutive.score, scattered.score)
    }

    func testPrefersFileNameOverDirectory() throws {
        let matcher = FuzzyMatcher("view")
        let inName = try XCTUnwrap(matcher.match("Sources/App/ContentView.swift"))
        let inDirectory = try XCTUnwrap(matcher.match("view/models/data.swift"))
        XCTAssertGreaterThan(inName.score, inDirectory.score)
    }

    func testCamelCaseHumps() throws {
        let matcher = FuzzyMatcher("wss")
        let humps = try XCTUnwrap(matcher.match("WorkspaceSearchService.swift"))
        let flat = try XCTUnwrap(matcher.match("aws_sessions.txt"))
        XCTAssertGreaterThan(humps.score, flat.score)
    }

    func testRankingOrder() {
        let files = [
            "docs/README.md",
            "Sources/LinuxDriver.swift",
            "Sources/LinuxViews.swift",
            "Sources/LinuxModel.swift",
            "scripts/link_driver.sh",
            "third_party/linux/drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c",
        ]
        let ranked = FuzzyMatcher("lindrv").rank(files, key: { $0 }).map(\.element)
        XCTAssertEqual(Set(ranked.prefix(2)), ["Sources/LinuxDriver.swift", "scripts/link_driver.sh"])
        XCTAssertEqual(ranked.last, "third_party/linux/drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c")
        XCTAssertFalse(ranked.contains("docs/README.md"))
        XCTAssertFalse(ranked.contains("Sources/LinuxViews.swift"))
        let exact = FuzzyMatcher("linuxdriver").rank(files, key: { $0 }).map(\.element)
        XCTAssertEqual(exact.first, "Sources/LinuxDriver.swift")
    }

    func testExactNameBeatsLongerPath() {
        let files = ["a/b/c/d/e/f/main.swift", "main.swift", "Sources/main.swift"]
        let ranked = FuzzyMatcher("main.swift").rank(files, key: { $0 }).map(\.element)
        XCTAssertEqual(ranked.first, "main.swift")
    }

    func testSpacesInQueryAreIgnored() {
        XCTAssertNotNil(FuzzyMatcher("fuzzy matcher").match("FuzzyMatcher.swift"))
    }

    func testUnicode() throws {
        let match = try XCTUnwrap(FuzzyMatcher("cafe").match("Café/menu.txt"))
        XCTAssertEqual(match.positions.count, 4)
        XCTAssertNotNil(FuzzyMatcher("café").match("Café/menu.txt"))
    }

    func testRankLimit() {
        let candidates = (0..<500).map { "file\($0).txt" }
        XCTAssertEqual(FuzzyMatcher("file").rank(candidates, limit: 25, key: { $0 }).count, 25)
    }

    func testPerformanceOnLargeIndex() {
        let candidates = (0..<20_000).map { "src/module\($0 % 97)/component\($0)/Source\($0).swift" }
        let matcher = FuzzyMatcher("cmp42src")
        measure {
            _ = matcher.rank(candidates, limit: 50, key: { $0 })
        }
    }
}
