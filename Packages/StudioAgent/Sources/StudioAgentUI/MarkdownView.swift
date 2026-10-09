import SwiftUI

/// Block-level Markdown for streaming replies: headings, paragraphs, nested
/// bulleted, numbered and task lists, quotes (with blocks inside), rules,
/// fenced code and tables. Inline styles (bold, italics, strikethrough, code,
/// links) use Foundation's Markdown parser.
///
/// Streamed text comes as `ChunkedText` sealed at blank lines outside code
/// fences: each sealed chunk is whole blocks, parsed and laid out once, and
/// only the tail is parsed again as it grows. While `streaming`, the tail is
/// parsed as unfinished text so it does not flicker between forms: an open
/// fence is a code block that grows, a table shows its header before the
/// delimiter row arrives, a lone list marker or `#` waits for its text, and
/// an unclosed `**` or backtick at the end is closed for display.
///
/// The text is not selectable: on iPadOS 26, selectable text in the panel
/// (backed by TextKit) went into a main-thread layout loop at 100% CPU
/// while a reply streamed. A finished message has a Copy button for its
/// Markdown source and each code block its own.
public struct MarkdownView: View {
    let chunks: ChunkedText
    let streaming: Bool

    public init(_ text: String, streaming: Bool = false) {
        chunks = ChunkedText(.markdownBlocks, text)
        self.streaming = streaming
    }

    public init(chunks: ChunkedText, streaming: Bool = false) {
        self.chunks = chunks
        self.streaming = streaming
    }

    public var body: some View {
        // Lazy: in a long reply only the chunks on screen are laid out.
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(chunks.chunks) { chunk in
                MarkdownChunkView(text: chunk.text, partial: false).equatable()
            }
            if !chunks.tail.isEmpty {
                MarkdownChunkView(text: chunks.tail, partial: streaming)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The blocks of one chunk of Markdown.
struct MarkdownChunkView: View, Equatable {
    let text: String
    /// Still streaming: parse it as unfinished text.
    var partial = false

    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text && a.partial == b.partial }

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownBlock.parse(text, partial: partial))
    }
}

/// A list of parsed blocks; quotes nest it.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    /// Text color; the theme's primary text when nil.
    var color: Color?
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            MarkdownInline.text(text, theme: theme, color: color)
                .font(.system(size: Self.headingSize(level), weight: level <= 3 ? .semibold : .medium))
                .padding(.top, level <= 2 ? 4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            MarkdownInline.text(text, theme: theme, color: color).font(theme.bodyFont).lineSpacing(3)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(item)
                        MarkdownInline.text(item.text, theme: theme, color: color).font(theme.bodyFont).lineSpacing(3)
                            .strikethrough(item.marker == .task(done: true), color: theme.tertiaryText)
                            .opacity(item.marker == .task(done: true) ? 0.7 : 1)
                    }
                    .padding(.leading, CGFloat(item.depth) * 20)
                }
            }
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(theme.accent.opacity(0.6)).frame(width: 3)
                MarkdownBlocksView(blocks: inner, color: theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            CodeBlockView(code: code, language: language)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownListItem) -> some View {
        switch item.marker {
        case .bullet:
            Text(["•", "◦", "▪︎"][min(item.depth, 2)])
                .font(theme.bodyFont)
                .foregroundStyle(theme.secondaryText)
                .frame(minWidth: 14, alignment: .trailing)
        case .number(let n):
            Text("\(n).")
                .font(theme.bodyFont.monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .frame(minWidth: 14, alignment: .trailing)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(done ? theme.accent : theme.tertiaryText)
                .frame(minWidth: 14, alignment: .trailing)
                .accessibilityLabel(done ? "Done" : "To do")
        }
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 21
        case 2: 18
        case 3: 16
        default: 15
        }
    }
}

/// A table: a grid with a bold header row, column alignment from the
/// delimiter row and a hairline between rows. A wide table scrolls
/// sideways; long cells wrap at a fixed width.
struct MarkdownTableView: View {
    let table: MarkdownTable
    @Environment(\.agentTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<table.columns, id: \.self) { c in
                        cell(table.header[c], column: c)
                            .font(theme.bodyFont.weight(.semibold))
                            .background(theme.codeBackground)
                            .gridColumnAlignment(table.alignments[c].horizontal)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(theme.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<table.columns, id: \.self) { c in
                            cell(row[c], column: c).font(theme.bodyFont)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).strokeBorder(theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
            .padding(1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func cell(_ text: String, column: Int) -> some View {
        CappedWidth(max: 300) {
            MarkdownInline.text(text, theme: theme)
                .lineSpacing(2)
                .multilineTextAlignment(table.alignments[column].text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: table.alignments[column].frame)
    }
}

/// Lays its content out at its natural width up to `max`, wrapping beyond
/// it, even when offered unlimited width (as inside a horizontal scroll).
struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let width = Swift.min(proposal.width ?? max, max)
        return first.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Inline Markdown in one `Text`: Foundation's parser, then the theme's code
/// font and link color.
enum MarkdownInline {
    static func text(_ s: String, theme: AgentTheme, color: Color? = nil) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var attributed = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = theme.codeFont
            attributed[run.range].backgroundColor = theme.codeBackground
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = theme.accent
            attributed[run.range].underlineStyle = .single
        }
        return Text(attributed).foregroundColor(color ?? theme.primaryText)
    }
}

// MARK: - Parsing

struct MarkdownListItem: Equatable {
    enum Marker: Equatable {
        case bullet
        case number(Int)
        case task(done: Bool)

        var isNumber: Bool { if case .number = self { true } else { false } }
    }

    var marker: Marker
    var text: String
    /// Nesting level from the indentation, 0 at the left.
    var depth: Int
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading, center, trailing

        var horizontal: HorizontalAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var frame: SwiftUI.Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var text: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
    }

    var header: [String]
    var alignments: [Alignment]
    /// Every row has exactly `columns` cells (short rows are padded).
    var rows: [[String]]

    var columns: Int { header.count }
}

indirect enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case list([MarkdownListItem])
    case quote([MarkdownBlock])
    case code(language: String?, String)
    case table(MarkdownTable)
    case rule

    /// Parses `text` into blocks. `partial` is for text that is still
    /// streaming: its last line may be cut short.
    static func parse(_ text: String, partial: Bool = false) -> [MarkdownBlock] {
        var lines = text.components(separatedBy: "\n")
        if partial, let last = lines.last, isPendingMarker(last.trimmingCharacters(in: .whitespaces)) {
            // "#", "-", "1." or "``" alone at the end: wait for the rest of the line.
            lines.removeLast()
        }
        var parser = Parser(lines: lines, partial: partial)
        return parser.run()
    }

    /// A line that is only the start of a block marker.
    static func isPendingMarker(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        if line.count <= 6, line.allSatisfy({ $0 == "#" }) { return true }
        if ["|", "-", "*", "+", "--", "`", "``", "~", "~~", "- [", "- [ ", "- [x", "- [ ]", "* [", "* [ ]"].contains(line) {
            return true
        }
        let digits = line.prefix(while: \.isNumber)
        return !digits.isEmpty && digits.count <= 3
            && (line.dropFirst(digits.count) == "." || line.dropFirst(digits.count) == ")")
    }

    private struct Parser {
        let lines: [String]
        let partial: Bool
        var i = 0
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [MarkdownListItem] = []
        /// A blank line came after the list: the next line continues it only
        /// if it is an item or indented.
        var listGap = false
        var quote: [String] = []
        /// Indentation of each open nesting level of the list.
        var indents: [Int] = []

        init(lines: [String], partial: Bool) {
            self.lines = lines
            self.partial = partial
        }

        var atEnd: Bool { i >= lines.count }

        mutating func run() -> [MarkdownBlock] {
            while !atEnd {
                let raw = lines[i]
                let line = raw.trimmingCharacters(in: .whitespaces)

                if let fence = Self.fenceOpening(line) {
                    flushAll()
                    code(fence: fence, indent: Self.indent(of: raw))
                    continue
                }
                if line.isEmpty {
                    flushParagraph(); flushQuote()
                    if !items.isEmpty { listGap = true }
                    i += 1
                    continue
                }
                if line.hasPrefix(">") {
                    flushParagraph(); flushList()
                    var content = line.dropFirst()
                    if content.first == " " { content = content.dropFirst() }
                    quote.append(String(content))
                    i += 1
                    continue
                }
                flushQuote()
                if let (level, title) = Self.heading(line) {
                    flushAll()
                    blocks.append(.heading(level, closeInline(title)))
                    i += 1
                    continue
                }
                if Self.isRule(line) {
                    flushAll()
                    blocks.append(.rule)
                    i += 1
                    continue
                }
                if Self.looksLikeRow(line), let table = table() {
                    flushAll()
                    blocks.append(.table(table))
                    continue
                }
                if let (marker, text) = Self.listItem(line) {
                    flushParagraph()
                    if listGap, let first = items.first, Self.indent(of: raw) < 2,
                       first.marker.isNumber != marker.isNumber {
                        // Bullets after numbers (or the reverse) past a blank line: a new list.
                        flushList()
                    }
                    addItem(marker: marker, text: text, indent: Self.indent(of: raw))
                    i += 1
                    continue
                }
                if !items.isEmpty, Self.indent(of: raw) >= 2 {
                    // A continuation line of the last item (after a blank line, too).
                    let joiner = listGap ? "\n" : " "
                    items[items.count - 1].text += joiner + line
                    listGap = false
                    i += 1
                    continue
                }
                flushList()
                paragraph.append(line)
                i += 1
            }
            flushAll()
            return blocks
        }

        // MARK: Blocks

        mutating func code(fence: (char: Character, length: Int, language: String?), indent: Int) {
            i += 1
            var body: [String] = []
            while !atEnd {
                let raw = lines[i]
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.first == fence.char, line.allSatisfy({ $0 == fence.char }), line.count >= fence.length {
                    i += 1
                    break
                }
                body.append(Self.dropIndent(raw, upTo: indent))
                i += 1
            }
            // An open fence at the end (mid-stream) is a block that grows.
            blocks.append(.code(language: fence.language, body.joined(separator: "\n")))
        }

        /// A table at line `i` (header, delimiter, rows), or nil if it is not one.
        mutating func table() -> MarkdownTable? {
            let header = Self.cells(lines[i])
            guard !header.isEmpty else { return nil }
            let next = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : nil
            var alignments: [MarkdownTable.Alignment]
            if let next, let parsed = Self.delimiter(next), parsed.count == header.count {
                alignments = parsed
                i += 2
            } else if partial, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|"),
                      next == nil || (i + 2 == lines.count && Self.isDelimiterPrefix(next!)) {
                // Streaming: the header, maybe with half of its delimiter row.
                alignments = Self.delimiter(next ?? "").map { a in
                    (0..<header.count).map { $0 < a.count ? a[$0] : .leading }
                } ?? Array(repeating: .leading, count: header.count)
                i = lines.count
                return MarkdownTable(header: header.map(closeInline), alignments: alignments, rows: [])
            } else {
                return nil
            }
            var rows: [[String]] = []
            while !atEnd {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, line.contains("|") else { break }
                var row = Self.cells(lines[i])
                if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                rows.append(Array(row.prefix(header.count)).map(closeInline))
                i += 1
            }
            alignments = Array(alignments.prefix(header.count))
            return MarkdownTable(header: header, alignments: alignments, rows: rows)
        }

        mutating func addItem(marker: MarkdownListItem.Marker, text: String, indent: Int) {
            if items.isEmpty { indents = [] }
            listGap = false
            // The level is the number of open levels indented less than this item.
            // Two or more spaces past the open level nest one deeper.
            while let last = indents.last, indent < last { indents.removeLast() }
            if indents.isEmpty || indent >= indents.last! + 2 { indents.append(indent) }
            let depth = min(indents.count - 1, 5)
            items.append(MarkdownListItem(marker: marker, text: text, depth: depth))
        }

        // MARK: Flushing

        /// Closes an unfinished inline style on the last line while streaming.
        func closeInline(_ s: String) -> String {
            guard partial, i >= lines.count - 1 else { return s }
            return MarkdownBlock.closeOpenInline(s)
        }

        mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(closeInline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }

        mutating func flushList() {
            guard !items.isEmpty else { return }
            if partial, i >= lines.count - 1 {
                items[items.count - 1].text = MarkdownBlock.closeOpenInline(items[items.count - 1].text)
            }
            blocks.append(.list(items))
            items = []
            listGap = false
        }

        mutating func flushQuote() {
            guard !quote.isEmpty else { return }
            var inner = Parser(lines: quote, partial: partial && i >= lines.count - 1)
            blocks.append(.quote(inner.run()))
            quote = []
        }

        mutating func flushAll() { flushParagraph(); flushList(); flushQuote() }

        // MARK: Lines

        static func indent(of raw: String) -> Int {
            var n = 0
            for c in raw {
                if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break }
            }
            return n
        }

        static func dropIndent(_ raw: String, upTo n: Int) -> String {
            var s = Substring(raw)
            var left = n
            while left > 0, s.first == " " { s = s.dropFirst(); left -= 1 }
            return String(s)
        }

        static func fenceOpening(_ line: String) -> (char: Character, length: Int, language: String?)? {
            guard let c = line.first, c == "`" || c == "~" else { return nil }
            let run = line.prefix(while: { $0 == c }).count
            guard run >= 3 else { return nil }
            let info = line.dropFirst(run).trimmingCharacters(in: .whitespaces)
            if c == "`", info.contains("`") { return nil }
            let language = info.split(separator: " ").first.map(String.init)
            return (c, run, language)
        }

        static func heading(_ line: String) -> (Int, String)? {
            guard line.hasPrefix("#") else { return nil }
            let level = line.prefix(while: { $0 == "#" }).count
            guard level <= 6 else { return nil }
            let rest = line.dropFirst(level)
            guard rest.isEmpty || rest.first == " " else { return nil }
            var title = rest.trimmingCharacters(in: .whitespaces)
            // A closing run of #s.
            if let r = title.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
                title = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return (level, title)
        }

        static func isRule(_ line: String) -> Bool {
            let compact = line.filter { $0 != " " }
            guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
            return compact.allSatisfy { $0 == c }
        }

        static func listItem(_ line: String) -> (MarkdownListItem.Marker, String)? {
            for p in ["- ", "* ", "+ "] where line.hasPrefix(p) {
                let text = String(line.dropFirst(2))
                for (box, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(box) {
                    return (.task(done: done), String(text.dropFirst(box.count)))
                }
                if ["[ ]", "[x]", "[X]"].contains(text) { return (.task(done: text != "[ ]"), "") }
                return (.bullet, text)
            }
            let digits = line.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let rest = line.dropFirst(digits.count)
            guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
            return (.number(Int(digits) ?? 1), String(rest.dropFirst(2)))
        }

        static func looksLikeRow(_ line: String) -> Bool { line.contains("|") }

        /// The cells of a table row: split on `|` outside code spans, `\|` kept.
        static func cells(_ raw: String) -> [String] {
            var line = Substring(raw.trimmingCharacters(in: .whitespaces))
            if line.hasPrefix("|") { line = line.dropFirst() }
            if line.hasSuffix("|") && !line.hasSuffix("\\|") { line = line.dropLast() }
            var cells: [String] = []
            var current = ""
            var inCode = false
            var escaped = false
            for c in line {
                if escaped {
                    current.append(c == "|" ? "|" : "\\")
                    if c != "|" { current.append(c) }
                    escaped = false
                    continue
                }
                switch c {
                case "\\": escaped = true
                case "`": inCode.toggle(); current.append(c)
                case "|" where !inCode:
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                default: current.append(c)
                }
            }
            if escaped { current.append("\\") }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }

        /// The alignments of a delimiter row (`| :--- | ---: |`), or nil.
        static func delimiter(_ line: String) -> [MarkdownTable.Alignment]? {
            guard line.contains("-") else { return nil }
            var alignments: [MarkdownTable.Alignment] = []
            for cell in cells(line) {
                let c = cell.filter { $0 != " " }
                guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
                let left = c.hasPrefix(":"), right = c.hasSuffix(":") && c.count > 1
                guard !c.dropFirst().dropLast().contains(":") else { return nil }
                alignments.append(left && right ? .center : right ? .trailing : .leading)
            }
            return alignments
        }

        /// The start of a delimiter row, cut off mid-stream.
        static func isDelimiterPrefix(_ line: String) -> Bool {
            !line.isEmpty && line.allSatisfy { " |:-".contains($0) } && (line.hasPrefix("|") || line.hasPrefix("-") || line.hasPrefix(":"))
        }
    }

    /// Closes a code span or `**` left open at the end of streamed text, so
    /// it shows styled rather than as markers until its closing half arrives.
    static func closeOpenInline(_ s: String) -> String {
        var out = s
        var ticks = 0
        var stars = 0
        var inCode = false
        var previous: Character = " "
        for c in s {
            if c == "`" { ticks += 1; inCode.toggle() }
            if c == "*", previous == "*", !inCode { stars += 1; previous = " "; continue }
            previous = c
        }
        if ticks % 2 == 1 { out += "`" }
        if stars % 2 == 1, !out.hasSuffix("*") { out += "**" }
        return out
    }
}

#if DEBUG
/// A reply with every Markdown element the chat renders, for previews and
/// the debug "Markdown sample" stream.
public enum MarkdownSample {
    public static let text = """
    # Heading one
    ## Heading two
    ### Heading three

    A paragraph with **bold**, *italic*, ***both***, ~~struck~~, `inline code` and a [link](https://example.com).
    A second line in the same paragraph.

    - First bullet
    - Second bullet with `code`
      - Nested bullet
        - Third level
    - [x] A finished task
    - [ ] An open task

    1. Step one
    2. Step two
       1. Sub-step
    3. Step three

    > A quote with **emphasis**.
    >
    > - and a list inside it

    ```swift
    // Fenced code scrolls sideways when a line is too long for the panel to show it whole.
    func greet(_ name: String) -> String {
        return "Hello, \\(name)!"
    }
    ```

    | Model | Precision | Decode tok/s | Notes |
    |:------|:---------:|-------------:|-------|
    | Qwen3.8-27B | Q4 | 60.2 | DFlash2 |
    | Qwen3.8-27B | Q4 | 41.0 | baseline, a longer note that wraps inside its cell |
    | `code` in a cell | — | 1 | a \\| pipe |

    ---

    That is all.
    """
}

/// Streams `MarkdownSample.text` a few characters at a time, as a reply does.
struct MarkdownStreamPreview: View {
    @State private var text = ChunkedText(.markdownBlocks)
    @State private var streaming = true

    var body: some View {
        ScrollView {
            MarkdownView(chunks: text, streaming: streaming).padding()
        }
        .task {
            let all = Array(MarkdownSample.text)
            var i = 0
            while i < all.count {
                let n = min(4, all.count - i)
                text.append(String(all[i..<(i + n)]))
                i += n
                try? await Task.sleep(for: .milliseconds(30))
            }
            streaming = false
        }
    }
}

#Preview("Markdown") {
    ScrollView { MarkdownView(MarkdownSample.text).padding() }
}

#Preview("Markdown, streaming") {
    MarkdownStreamPreview()
}
#endif
