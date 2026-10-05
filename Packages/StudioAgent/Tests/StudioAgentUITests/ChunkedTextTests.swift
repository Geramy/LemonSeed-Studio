import Testing
@testable import StudioAgentUI

@Suite("Chunked streamed text")
struct ChunkedTextTests {
    static func reply(_ n: Int) -> String {
        var s = ""
        for i in 0..<n {
            if i % 400 == 399 { s += "\n\n```swift\nlet x = \(i)\n\nlet y = 2\n```\n\n"; continue }
            if i % 90 == 89 { s += ".\n\n"; continue }
            if i % 30 == 29 { s += ",\n"; continue }
            s += ["the ", "model ", "thinks ", "é ", "about ", "🍋 ", "it "][i % 7]
        }
        return s
    }

    @Test(arguments: [ChunkedText.Boundary.lines, .markdownBlocks])
    func streamedOrAtOnceGiveTheSameChunksAndText(_ boundary: ChunkedText.Boundary) {
        let text = Self.reply(5000)
        var streamed = ChunkedText(boundary)
        var i = text.startIndex
        var step = 1
        while i < text.endIndex {
            let j = text.index(i, offsetBy: step, limitedBy: text.endIndex) ?? text.endIndex
            streamed.append(String(text[i..<j]))
            i = j
            step = step % 13 + 1
        }
        let atOnce = ChunkedText(boundary, text)
        #expect(streamed == atOnce)
        #expect(streamed.string == text)
        #expect(streamed.utf8Count == text.utf8.count)
        #expect(streamed.chunks.count > 10)
        // The tail stays small: what an update redraws does not grow.
        #expect(streamed.tail.utf8.count < 2 * ChunkedText.sealAt)
        #expect(streamed.chunks.map(\.id) == Array(0..<streamed.chunks.count))
    }

    @Test func markdownChunksAreWholeBlocks() {
        let text = Self.reply(5000)
        let chunked = ChunkedText(.markdownBlocks, text)
        let pieces = chunked.chunks.map(\.text) + [chunked.tail]
        #expect(pieces.flatMap(MarkdownBlock.parse) == MarkdownBlock.parse(text))
    }

    @Test func aLineWithNoBreakIsStillSealed() {
        var t = ChunkedText(.lines)
        t.append(String(repeating: "x", count: 10_000))
        #expect(t.chunks.count >= 2 && t.tail.utf8.count < ChunkedText.hardLimit)
        #expect(t.string.count == 10_000)
    }

    @Test func droppingTheFrontKeepsTheEnd() {
        var t = ChunkedText(.lines)
        for i in 0..<20_000 { t.append("line \(i)\n") }
        let all = t.utf8Count
        t.dropFront(keepingUTF8: 48_000)
        #expect(t.utf8Count >= 48_000 && t.utf8Count < 48_000 + 2 * ChunkedText.sealAt)
        #expect(t.utf8Count + t.droppedUTF8 == all)
        #expect(t.string.hasSuffix("line 19999\n"))
    }
}
