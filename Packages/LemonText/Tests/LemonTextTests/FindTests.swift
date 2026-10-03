import Foundation
@testable import LemonText
import Testing

@Suite("Find and replace")
struct FindTests {
    let text: NSString = """
    int count = 0;
    int counter = Count + 1;
    // count the counts
    return count;
    """ as NSString

    private func found(_ query: FindQuery) throws -> [String] {
        try FindEngine(query: query).matches(in: text).map { text.substring(with: $0.range) }
    }

    @Test func plainTextIsCaseInsensitiveByDefault() throws {
        #expect(try found(FindQuery("count")) == ["count", "count", "Count", "count", "count", "count"])
    }

    @Test func caseSensitive() throws {
        #expect(try found(FindQuery("Count", isCaseSensitive: true)) == ["Count"])
    }

    @Test func wholeWord() throws {
        let matches = try FindEngine(query: FindQuery("count", matchesWholeWord: true)).matches(in: text)
        #expect(matches.count == 4) // count, Count, count (comment), count (return)
        #expect(matches.allSatisfy { text.substring(with: $0.range).lowercased() == "count" })
    }

    @Test func plainTextEscapesRegexMetacharacters() throws {
        let source: NSString = "a+b (a+b) a.b"
        #expect(try FindEngine(query: FindQuery("a+b")).matches(in: source).count == 2)
        #expect(try FindEngine(query: FindQuery("a.b")).matches(in: source).map(\.range) == [NSRange(location: 10, length: 3)])
    }

    @Test func regularExpressionWithGroups() throws {
        let engine = FindEngine(query: FindQuery("int (\\w+) =", isRegularExpression: true, isCaseSensitive: true))
        let matches = try engine.matches(in: text)
        #expect(matches.count == 2)
        #expect(text.substring(with: matches[1].groupRanges[0]) == "counter")
    }

    @Test func regexAnchorsMatchLines() throws {
        let engine = FindEngine(query: FindQuery("^int", isRegularExpression: true))
        #expect(try engine.matches(in: text).count == 2)
    }

    @Test func invalidRegexThrows() {
        #expect(throws: FindError.self) {
            try FindEngine(query: FindQuery("(unclosed", isRegularExpression: true)).matches(in: text)
        }
    }

    @Test func emptyQueryFindsNothing() throws {
        #expect(try FindEngine(query: FindQuery("")).matches(in: text).isEmpty)
        #expect(try FindEngine(query: FindQuery("^", isRegularExpression: true)).matches(in: text).isEmpty)
    }

    @Test func searchCanBeLimitedToARange() throws {
        let secondLine = (text as NSString).lineRange(for: NSRange(location: 16, length: 0))
        let engine = FindEngine(query: FindQuery("count", range: secondLine))
        #expect(try engine.matches(in: text).count == 2)
    }

    @Test func nextAndPreviousWrap() throws {
        let engine = FindEngine(query: FindQuery("return"))
        let location = text.range(of: "return").location
        #expect(try engine.nextMatch(in: text, from: location + 1)?.range.location == location)
        #expect(try engine.nextMatch(in: text, from: location + 1, wraps: false) == nil)
        #expect(try engine.previousMatch(in: text, before: 0)?.range.location == location)
    }

    @Test func replaceAllPlainTextIsLiteral() throws {
        let engine = FindEngine(query: FindQuery("count", isCaseSensitive: true, matchesWholeWord: true))
        let result = try engine.replaceAll(in: text, template: "$total")
        #expect(result.count == 3)
        #expect(result.text.contains("int $total = 0;"))
        #expect(result.text.contains("Count + 1"))
    }

    @Test func replaceAllRegexExpandsGroupsAndEscapes() throws {
        let engine = FindEngine(query: FindQuery("int (\\w+) = (\\w+)", isRegularExpression: true))
        let result = try engine.replaceAll(in: "int a = b;" as NSString, template: "auto $1 =\\t$2 /* \\$1 */")
        #expect(result.text == "auto a =\tb /* $1 */;")
    }

    @Test func replaceAllEditsAreOrderedAndApplyCleanly() throws {
        let engine = FindEngine(query: FindQuery("o"))
        let source: NSString = "foo boo"
        let edits = try engine.replaceAllEdits(in: source, template: "0")
        #expect(edits.map(\.range.location) == [1, 2, 5, 6])
        #expect(TextEdit.apply(edits, to: source as String) == "f00 b00")
    }

    @Test func singleReplacementUsesTheMatchGroups() throws {
        let engine = FindEngine(query: FindQuery("(\\d+)px", isRegularExpression: true))
        let source: NSString = "width: 12px; height: 7px;"
        let matches = try engine.matches(in: source)
        #expect(try engine.replacementText(for: matches[1], in: source, template: "${1}pt") == "7pt")
        #expect(try engine.replacementText(for: matches[0], in: source, template: "${1}0") == "120")
    }

    @Test func handlesUnicodeAsUTF16Ranges() throws {
        let source: NSString = "let 🍋 = \"lemon\"; let lemon = 🍋"
        let matches = try FindEngine(query: FindQuery("lemon", matchesWholeWord: true)).matches(in: source)
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { source.substring(with: $0.range) == "lemon" })
    }

    @Test func findsInALargeDocumentQuickly() throws {
        let line = "static int sqlite3VdbeExec(Vdbe *p){ return p->rc; }\n"
        let source = String(repeating: line, count: 50_000) as NSString
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let matches = try FindEngine(query: FindQuery("Vdbe", isCaseSensitive: true)).matches(in: source)
            #expect(matches.count == 100_000)
        }
        #expect(elapsed < .seconds(2))
    }
}
