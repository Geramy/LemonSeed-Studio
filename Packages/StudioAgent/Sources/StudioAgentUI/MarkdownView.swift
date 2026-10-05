import SwiftUI

/// Block-level Markdown for streaming replies: headings, paragraphs, lists,
/// quotes, rules and fenced code. Inline styles (bold, italics, code, links)
/// use Foundation's Markdown parser. An unterminated fence (mid-stream)
/// renders as a code block that grows as tokens arrive.
///
/// Streamed text comes as `ChunkedText` sealed at blank lines outside code
/// fences: each sealed chunk is whole blocks, parsed and laid out once, and
/// only the tail is parsed again as it grows.
public struct MarkdownView: View {
    let chunks: ChunkedText

    public init(_ text: String) { chunks = ChunkedText(.markdownBlocks, text) }
    public init(chunks: ChunkedText) { self.chunks = chunks }

    public var body: some View {
        // Lazy: in a long reply only the chunks on screen are laid out.
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(chunks.chunks) { chunk in
                MarkdownChunkView(text: chunk.text).equatable()
            }
            if !chunks.tail.isEmpty { MarkdownChunkView(text: chunks.tail) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The blocks of one chunk of Markdown.
struct MarkdownChunkView: View, Equatable {
    let text: String
    @Environment(\.agentTheme) private var theme

    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let text):
            inline(text).font(theme.bodyFont).lineSpacing(3)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(i + 1)." : "•")
                            .font(theme.bodyFont.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                            .frame(minWidth: 14, alignment: .trailing)
                        inline(item).font(theme.bodyFont).lineSpacing(3)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(theme.accent.opacity(0.6)).frame(width: 3)
                inline(text).font(theme.bodyFont).foregroundStyle(theme.secondaryText)
            }
        case .code(let language, let code):
            CodeBlockView(code: code, language: language)
        case .rule:
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var attributed = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = theme.codeFont
            attributed[run.range].backgroundColor = theme.codeBackground
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = theme.accent
        }
        return Text(attributed).foregroundColor(theme.primaryText)
    }
}

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case list([String], ordered: Bool)
    case quote(String)
    case code(language: String?, String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [String] = []
        var ordered = false
        var quote: [String] = []
        var code: [String]?
        var language: String?

        func flushParagraph() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        func flushList() { if !list.isEmpty { blocks.append(.list(list, ordered: ordered)); list = [] } }
        func flushQuote() { if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: language, c.joined(separator: "\n")))
                    code = nil
                } else {
                    c.append(raw)
                    code = c
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                language = lang.isEmpty ? nil : lang
                code = []
                continue
            }
            if line.isEmpty { flushAll(); continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    flushAll()
                    blocks.append(.heading(level, String(line.dropFirst(level + 1))))
                    continue
                }
            }
            if line == "---" || line == "***" || line == "___" { flushAll(); blocks.append(.rule); continue }
            if line.hasPrefix("> ") || line == ">" {
                flushParagraph(); flushList()
                quote.append(String(line.dropFirst(line == ">" ? 1 : 2)))
                continue
            }
            if let item = bullet(line) {
                flushParagraph(); flushQuote()
                if !list.isEmpty && ordered { flushList() }
                ordered = false
                list.append(item)
                continue
            }
            if let item = numbered(line) {
                flushParagraph(); flushQuote()
                if !list.isEmpty && !ordered { flushList() }
                ordered = true
                list.append(item)
                continue
            }
            if !list.isEmpty, raw.hasPrefix("  ") {
                list[list.count - 1] += " " + line
                continue
            }
            flushList(); flushQuote()
            paragraph.append(line)
        }
        if let c = code { blocks.append(.code(language: language, c.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    private static func bullet(_ line: String) -> String? {
        for p in ["- ", "* ", "+ "] where line.hasPrefix(p) { return String(line.dropFirst(2)) }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}
