import Foundation

/// Computes how many indentation guides each line shows.
///
/// A line with indentation `n` columns shows `n / indentWidth` guides. Blank lines take the smaller
/// level of the nearest non-blank lines above and below, so guides run unbroken through blank lines
/// inside a block and stop where the block ends.
public enum IndentGuides {
    /// - Parameters:
    ///   - indentColumns: Indentation in columns per line; `nil` for blank lines.
    ///   - indentWidth: Columns per indentation level.
    public static func levels(indentColumns: [Int?], indentWidth: Int) -> [Int] {
        let width = max(indentWidth, 1)
        var levels = [Int](repeating: 0, count: indentColumns.count)
        var nextNonBlank = [Int?](repeating: nil, count: indentColumns.count)
        var upcoming: Int?
        for index in stride(from: indentColumns.count - 1, through: 0, by: -1) {
            nextNonBlank[index] = upcoming
            if let columns = indentColumns[index] {
                upcoming = columns
            }
        }
        var previous: Int?
        for (index, columns) in indentColumns.enumerated() {
            if let columns {
                levels[index] = columns / width
                previous = columns
            } else {
                let above = previous ?? 0
                let below = nextNonBlank[index] ?? 0
                levels[index] = min(above, below) / width
            }
        }
        return levels
    }

    /// The guide to emphasise for a caret on `caretLine`: the innermost block containing that line.
    /// - Returns: The guide level (1-based) and the lines it spans, or nil at the top level.
    public static func activeGuide(levels: [Int], caretLine: Int) -> (level: Int, lines: ClosedRange<Int>)? {
        guard caretLine >= 0 && caretLine < levels.count else {
            return nil
        }
        // A line that opens a block (the next line is deeper) highlights the guide of that block.
        var level = levels[caretLine]
        if caretLine + 1 < levels.count && levels[caretLine + 1] > level {
            level = levels[caretLine + 1]
        }
        guard level > 0 else {
            return nil
        }
        var start = caretLine
        while start > 0 && levels[start - 1] >= level {
            start -= 1
        }
        var end = caretLine
        while end + 1 < levels.count && levels[end + 1] >= level {
            end += 1
        }
        if levels[caretLine] < level {
            start = caretLine + 1
        }
        return (level, start ... end)
    }
}
