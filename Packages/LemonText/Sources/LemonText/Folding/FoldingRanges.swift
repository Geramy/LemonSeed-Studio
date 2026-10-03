import Foundation

/// A foldable region. Folding hides lines `startLine + 1 ... endLine`; the start line stays visible
/// and shows a placeholder.
public struct FoldingRange: Hashable, Sendable, Comparable {
    public var startLine: Int
    public var endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = endLine
    }

    public var hiddenLines: ClosedRange<Int> {
        (startLine + 1) ... endLine
    }

    public static func < (lhs: FoldingRange, rhs: FoldingRange) -> Bool {
        lhs.startLine == rhs.startLine ? lhs.endLine > rhs.endLine : lhs.startLine < rhs.startLine
    }
}

/// Computes folding ranges without a parser: matching braces for brace languages, indentation for the rest.
///
/// It skips brackets inside comments and strings with a small lexer. An LSP `foldingRange` response
/// can replace its output later through ``LemonTextViewController/foldingRanges``.
public enum FoldingRangeCalculator {
    public static func ranges(in string: NSString, language: LemonLanguage, tabWidth: Int = 4) -> [FoldingRange] {
        switch language {
        case .python, .yaml, .make, .markdown, .plainText:
            return indentationRanges(in: string, tabWidth: tabWidth)
        default:
            return bracketRanges(in: string, language: language)
        }
    }

    /// Ranges from `{}`, `[]` and `()` that span at least two lines. The line holding the closing bracket stays visible.
    public static func bracketRanges(in string: NSString, language: LemonLanguage) -> [FoldingRange] {
        let length = string.length
        guard length > 0 else {
            return []
        }
        var ranges: [FoldingRange] = []
        var stack: [(character: unichar, line: Int)] = []
        let lexer = CommentAndStringLexer(language: language)
        var state = CommentAndStringLexer.State.code
        var line = 0
        var lineHasCodeBeforeBlockComment = false
        var blockCommentStartLine = -1
        let chunkSize = 16_384
        var buffer = [unichar](repeating: 0, count: chunkSize + 4)
        var location = 0
        while location < length {
            let chunkLength = min(chunkSize, length - location)
            // Read a few characters past the chunk so two- and three-character delimiters are seen whole.
            let readLength = min(chunkLength + 3, length - location)
            string.getCharacters(&buffer, range: NSRange(location: location, length: readLength))
            var index = 0
            while index < chunkLength {
                let character = buffer[index]
                if character == 0x0A {
                    line += 1
                    lineHasCodeBeforeBlockComment = false
                    if state == .lineComment {
                        state = .code
                    } else if case let .string(quote) = state, quote != 0x60 {
                        state = .code
                    }
                    index += 1
                    continue
                }
                let previousState = state
                let consumed = lexer.advance(&state, buffer: buffer, index: index, available: readLength)
                if previousState == .code && state == .blockComment {
                    blockCommentStartLine = lineHasCodeBeforeBlockComment ? -1 : line
                } else if previousState == .blockComment && state == .code {
                    if blockCommentStartLine >= 0 && line - blockCommentStartLine >= 2 {
                        ranges.append(FoldingRange(startLine: blockCommentStartLine, endLine: line))
                    }
                    blockCommentStartLine = -1
                }
                if consumed > 0 {
                    index += consumed
                    continue
                }
                if state == .code {
                    switch character {
                    case 0x7B, 0x5B, 0x28: // { [ (
                        stack.append((character, line))
                    case 0x7D, 0x5D, 0x29: // } ] )
                        let open: unichar = character == 0x7D ? 0x7B : (character == 0x5D ? 0x5B : 0x28)
                        if let matchIndex = stack.lastIndex(where: { $0.character == open }) {
                            let startLine = stack[matchIndex].line
                            stack.removeSubrange(matchIndex...)
                            if line - startLine >= 2 {
                                ranges.append(FoldingRange(startLine: startLine, endLine: line - 1))
                            }
                        }
                    case 0x20, 0x09, 0x0D:
                        break
                    default:
                        lineHasCodeBeforeBlockComment = true
                    }
                }
                index += 1
            }
            // A delimiter may have been consumed past the end of the chunk.
            location += index
        }
        return deduplicated(ranges)
    }

    /// Ranges from indentation: a line followed by more-indented lines folds those lines.
    public static func indentationRanges(in string: NSString, tabWidth: Int) -> [FoldingRange] {
        let lines = TextLines(string)
        var indents: [Int?] = []
        var location = 0
        while location <= string.length {
            let fullLine = lines.fullLineRange(containing: location)
            let line = lines.lineRange(containing: location)
            indents.append(lines.isBlank(line) ? nil : lines.indentationColumns(of: line, tabWidth: tabWidth))
            if fullLine.length == line.length {
                break
            }
            location = fullLine.location + fullLine.length
            if location == string.length {
                indents.append(nil)
                break
            }
        }
        var ranges: [FoldingRange] = []
        var stack: [(line: Int, indent: Int)] = []
        var lastContentLine = -1
        for (lineIndex, indent) in indents.enumerated() {
            guard let indent else {
                continue
            }
            while let top = stack.last, top.indent >= indent {
                stack.removeLast()
                if lastContentLine - top.line >= 1 {
                    ranges.append(FoldingRange(startLine: top.line, endLine: lastContentLine))
                }
            }
            stack.append((lineIndex, indent))
            lastContentLine = lineIndex
        }
        while let top = stack.popLast() {
            if lastContentLine - top.line >= 1 {
                ranges.append(FoldingRange(startLine: top.line, endLine: lastContentLine))
            }
        }
        return deduplicated(ranges)
    }

    /// One range per start line (the outermost), sorted by start line.
    static func deduplicated(_ ranges: [FoldingRange]) -> [FoldingRange] {
        var byStart: [Int: FoldingRange] = [:]
        for range in ranges where range.endLine > range.startLine {
            if let existing = byStart[range.startLine], existing.endLine >= range.endLine {
                continue
            }
            byStart[range.startLine] = range
        }
        return byStart.values.sorted()
    }
}

/// A tiny lexer that tracks whether a position is in code, a comment or a string. Enough to keep
/// brackets in comments and strings out of folding and bracket matching.
struct CommentAndStringLexer {
    enum State: Equatable {
        case code
        case lineComment
        case blockComment
        case string(unichar)
    }

    private let lineComment: [unichar]
    private let blockStart: [unichar]
    private let blockEnd: [unichar]
    private let quotes: Set<unichar>

    init(language: LemonLanguage) {
        lineComment = language.lineCommentPrefix.map { Array($0.utf16) } ?? []
        if let block = language.blockComment {
            blockStart = Array(block.start.utf16)
            blockEnd = Array(block.end.utf16)
        } else {
            blockStart = []
            blockEnd = []
        }
        var quotes: Set<unichar> = [0x22] // "
        switch language {
        case .rust:
            break
        case .javascript, .typescript, .tsx, .go:
            quotes.formUnion([0x27, 0x60]) // ' `
        case .markdown, .plainText, .html:
            quotes = []
        default:
            quotes.insert(0x27)
        }
        self.quotes = quotes
    }

    /// Advances the state at `index`. Returns how many characters were consumed as a delimiter or escape,
    /// or 0 when the character should be processed as ordinary content in the current state.
    func advance(_ state: inout State, buffer: [unichar], index: Int, available: Int) -> Int {
        let character = buffer[index]
        switch state {
        case .code:
            if !lineComment.isEmpty && matches(lineComment, buffer: buffer, at: index, available: available) {
                state = .lineComment
                return lineComment.count
            }
            if !blockStart.isEmpty && matches(blockStart, buffer: buffer, at: index, available: available) {
                state = .blockComment
                return blockStart.count
            }
            if quotes.contains(character) {
                state = .string(character)
                return 1
            }
            return 0
        case .lineComment:
            return 1
        case .blockComment:
            if matches(blockEnd, buffer: buffer, at: index, available: available) {
                state = .code
                return blockEnd.count
            }
            return 1
        case .string(let quote):
            if character == 0x5C { // backslash escapes the next character, except a line break
                return index + 1 < available && buffer[index + 1] != 0x0A ? 2 : 1
            }
            if character == quote {
                state = .code
                return 1
            }
            // Ordinary strings end at a line break; template literals (`) do not.
            if character == 0x0A && quote != 0x60 {
                state = .code
            }
            return 1
        }
    }

    private func matches(_ pattern: [unichar], buffer: [unichar], at index: Int, available: Int) -> Bool {
        guard index + pattern.count <= available else {
            return false
        }
        for offset in 0 ..< pattern.count where buffer[index + offset] != pattern[offset] {
            return false
        }
        return true
    }
}
