import Foundation

/// The set of folded regions in a document, kept in step with edits.
public struct FoldState: Hashable, Sendable {
    /// Folded ranges, sorted by start line. Nested folds are allowed.
    public private(set) var folded: [FoldingRange] = []

    public init() {}

    public func isFolded(startingAt line: Int) -> Bool {
        folded.contains { $0.startLine == line }
    }

    /// The outermost fold whose hidden lines contain `line`.
    public func fold(hiding line: Int) -> FoldingRange? {
        folded.filter { $0.hiddenLines.contains(line) }.max { $0.endLine - $0.startLine < $1.endLine - $1.startLine }
    }

    public mutating func fold(_ range: FoldingRange) {
        guard range.endLine > range.startLine, !folded.contains(range) else {
            return
        }
        folded.removeAll { $0.startLine == range.startLine }
        folded.append(range)
        folded.sort()
    }

    @discardableResult
    public mutating func unfold(startingAt line: Int) -> FoldingRange? {
        guard let index = folded.firstIndex(where: { $0.startLine == line }) else {
            return nil
        }
        return folded.remove(at: index)
    }

    /// Removes every fold that hides `line` and returns them.
    @discardableResult
    public mutating func unfoldAll(hiding line: Int) -> [FoldingRange] {
        let removed = folded.filter { $0.hiddenLines.contains(line) }
        folded.removeAll { $0.hiddenLines.contains(line) }
        return removed
    }

    public mutating func removeAll() {
        folded.removeAll()
    }

    /// Lines hidden by the current folds, merged into disjoint ranges.
    public var hiddenLineRanges: [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for range in folded.map(\.hiddenLines).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Updates folds for an edit that replaced lines `editStartLine ... editEndLine` (in the old text) and changed
    /// the line count by `lineDelta`. Folds after the edit shift; folds the edit touches are dropped.
    /// - Returns: Folds that were dropped, so the view can show their lines again.
    @discardableResult
    public mutating func applyEdit(editStartLine: Int, editEndLine: Int, lineDelta: Int) -> [FoldingRange] {
        var kept: [FoldingRange] = []
        var dropped: [FoldingRange] = []
        for range in folded {
            if range.endLine < editStartLine {
                kept.append(range)
            } else if range.startLine > editEndLine {
                kept.append(FoldingRange(startLine: range.startLine + lineDelta, endLine: range.endLine + lineDelta))
            } else if range.startLine == editStartLine && editStartLine == editEndLine && lineDelta == 0 {
                // Typing on the visible start line of a fold leaves the fold in place.
                kept.append(range)
            } else {
                dropped.append(range)
            }
        }
        folded = kept.sorted()
        return dropped
    }
}
