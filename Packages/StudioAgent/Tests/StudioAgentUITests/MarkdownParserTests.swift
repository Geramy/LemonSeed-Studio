import Testing
@testable import StudioAgentUI

@Suite("Markdown blocks")
struct MarkdownParserTests {
    @Test func everyElementOfTheSample() {
        let blocks = MarkdownBlock.parse(MarkdownSample.text)
        #expect(blocks.first == .heading(1, "Heading one"))
        #expect(blocks.contains(.heading(3, "Heading three")))
        #expect(blocks.contains { if case .paragraph(let p) = $0 { p.contains("**bold**") } else { false } })
        #expect(blocks.contains { if case .code(let lang, let code) = $0 { lang == "swift" && code.contains("func greet") } else { false } })
        #expect(blocks.contains(.rule))
        guard case .table(let table)? = blocks.first(where: { if case .table = $0 { true } else { false } }) else {
            Issue.record("no table"); return
        }
        #expect(table.header == ["Model", "Precision", "Decode tok/s", "Notes"])
        #expect(table.alignments == [.leading, .center, .trailing, .leading])
        #expect(table.rows.count == 3)
        #expect(table.rows[2] == ["`code` in a cell", "—", "1", "a | pipe"])
        guard case .quote(let inner)? = blocks.first(where: { if case .quote = $0 { true } else { false } }) else {
            Issue.record("no quote"); return
        }
        #expect(inner.first == .paragraph("A quote with **emphasis**."))
        #expect(inner.contains { if case .list = $0 { true } else { false } })
    }

    @Test func nestedListsKeepTheirDepthAndNumbers() {
        let blocks = MarkdownBlock.parse("""
        - a
          - b
            - c
        - [x] done
        - [ ] open

        3. three
        4. four
           1. sub
        """)
        #expect(blocks == [
            .list([
                .init(marker: .bullet, text: "a", depth: 0),
                .init(marker: .bullet, text: "b", depth: 1),
                .init(marker: .bullet, text: "c", depth: 2),
                .init(marker: .task(done: true), text: "done", depth: 0),
                .init(marker: .task(done: false), text: "open", depth: 0),
            ]),
            .list([
                .init(marker: .number(3), text: "three", depth: 0),
                .init(marker: .number(4), text: "four", depth: 0),
                .init(marker: .number(1), text: "sub", depth: 1),
            ]),
        ])
    }

    @Test func aLooseListStaysOneList() {
        let blocks = MarkdownBlock.parse("1. one\n\n2. two\n\n   more about two\n\nAfter.")
        #expect(blocks == [
            .list([.init(marker: .number(1), text: "one", depth: 0),
                   .init(marker: .number(2), text: "two\nmore about two", depth: 0)]),
            .paragraph("After."),
        ])
    }

    @Test func prosePipesAreNotATable() {
        #expect(MarkdownBlock.parse("Use a | b here.\nAnd more.") == [.paragraph("Use a | b here.\nAnd more.")])
    }

    @Test func tildeFencesAndLongerFences() {
        let blocks = MarkdownBlock.parse("~~~\na\n```\nb\n~~~\n````md\n```\nx\n```\n````")
        #expect(blocks == [.code(language: nil, "a\n```\nb"), .code(language: "md", "```\nx\n```")])
    }

    // MARK: Streaming

    @Test func anOpenFenceIsAGrowingCodeBlock() {
        #expect(MarkdownBlock.parse("Look:\n\n```c\nint x;", partial: true)
            == [.paragraph("Look:"), .code(language: "c", "int x;")])
    }

    @Test func aTableHeaderShowsBeforeItsDelimiterRow() {
        let header = MarkdownTable(header: ["A", "B"], alignments: [.leading, .leading], rows: [])
        #expect(MarkdownBlock.parse("| A | B |", partial: true) == [.table(header)])
        #expect(MarkdownBlock.parse("| A | B |\n|:--", partial: true) == [.table(header)])
        #expect(MarkdownBlock.parse("| A | B |\n|---|--:|\n| 1 | 2", partial: true)
            == [.table(MarkdownTable(header: ["A", "B"], alignments: [.leading, .trailing], rows: [["1", "2"]]))])
        // Finished, a lone header row is just text.
        #expect(MarkdownBlock.parse("| A | B |") == [.paragraph("| A | B |")])
    }

    @Test func aLoneMarkerWaitsForItsText() {
        #expect(MarkdownBlock.parse("Text\n##", partial: true) == [.paragraph("Text")])
        #expect(MarkdownBlock.parse("- a\n-", partial: true) == [.list([.init(marker: .bullet, text: "a", depth: 0)])])
        #expect(MarkdownBlock.parse("Text\n``", partial: true) == [.paragraph("Text")])
        #expect(MarkdownBlock.parse("Text\n2.", partial: true) == [.paragraph("Text")])
    }

    @Test func openInlineStylesCloseWhileStreaming() {
        #expect(MarkdownBlock.parse("some **bold", partial: true) == [.paragraph("some **bold**")])
        #expect(MarkdownBlock.parse("call `foo(", partial: true) == [.paragraph("call `foo(`")])
        #expect(MarkdownBlock.parse("a `**` b", partial: true) == [.paragraph("a `**` b")])
        #expect(MarkdownBlock.parse("some **bold") == [.paragraph("some **bold")])
    }

    /// Every prefix of the sample, as the stream delivers it, parses, and the
    /// last one equals the finished parse.
    @Test func everyPrefixParses() {
        let all = Array(MarkdownSample.text)
        var last: [MarkdownBlock] = []
        for n in 1...all.count {
            last = MarkdownBlock.parse(String(all[..<n]), partial: true)
            #expect(!last.isEmpty || n < 3)
        }
        let finished = MarkdownBlock.parse(MarkdownSample.text)
        #expect(finished.count == last.count)
    }

    @Test func streamedChunksRenderTheSameBlocks() {
        var chunks = ChunkedText(.markdownBlocks)
        let text = String(repeating: MarkdownSample.text + "\n\n", count: 6)
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 7, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[i..<j]))
            i = j
        }
        let pieces = chunks.chunks.flatMap { MarkdownBlock.parse($0.text) } + MarkdownBlock.parse(chunks.tail)
        #expect(pieces.filter { if case .table = $0 { true } else { false } }.count == 6)
        #expect(pieces.filter { if case .code = $0 { true } else { false } }.count == 6)
    }
}
