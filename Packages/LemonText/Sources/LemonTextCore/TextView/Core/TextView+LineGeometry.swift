import UIKit

/// A highlight capture produced by the tree-sitter highlights query, e.g. `keyword` or `string.special`.
public struct SyntaxHighlightCapture: Equatable {
    /// Range of the captured text, in UTF-16 code units.
    public let range: NSRange
    /// Name of the capture without the leading `@`.
    public let name: String

    public init(range: NSRange, name: String) {
        self.range = range
        self.name = name
    }
}

// MARK: - Lines and geometry
//
// These additions expose the line manager and layout state that decoration layers (diagnostics,
// indentation guides, minimap, folding) need. All geometry is in the text view's content coordinates.
public extension TextView {
    /// Number of lines in the text.
    var lineCount: Int {
        textInputView.lineManager.lineCount
    }

    /// Length of the text in UTF-16 code units. Cheaper than `text.utf16.count`.
    var textLength: Int {
        textInputView.stringView.string.length
    }

    /// An immutable copy of the text as an `NSString`. Cheaper than ``text`` for large documents.
    func textSnapshot() -> NSString {
        // swiftlint:disable:next force_cast
        textInputView.stringView.string.copy() as! NSString
    }

    /// The range of the line at the given index. The range excludes the line break unless requested.
    func range(ofLine lineIndex: Int, includingLineBreak: Bool = false) -> NSRange? {
        let lineManager = textInputView.lineManager
        guard lineIndex >= 0 && lineIndex < lineManager.lineCount else {
            return nil
        }
        let line = lineManager.line(atRow: lineIndex)
        let length = includingLineBreak ? line.data.totalLength : line.data.length
        return NSRange(location: line.location, length: length)
    }

    /// The index of the line containing the character at the given location.
    func lineIndex(containing location: Int) -> Int? {
        textInputView.lineManager.line(containingCharacterAt: location)?.index
    }

    /// The index of the line at the given vertical offset in content coordinates. Clamped to the document.
    func lineIndex(atYOffset yOffset: CGFloat) -> Int {
        let lineManager = textInputView.lineManager
        let localY = yOffset - textContainerInset.top
        if localY <= 0 {
            return 0
        }
        if let line = lineManager.line(containingYOffset: localY) {
            return line.index
        }
        return max(lineManager.lineCount - 1, 0)
    }

    /// The vertical extent of the line at the given index in content coordinates.
    ///
    /// Lines that have not been laid out yet report an estimated height. Hidden (folded) lines have a height of zero.
    func verticalExtent(ofLine lineIndex: Int) -> (minY: CGFloat, height: CGFloat)? {
        let lineManager = textInputView.lineManager
        guard lineIndex >= 0 && lineIndex < lineManager.lineCount else {
            return nil
        }
        let line = lineManager.line(atRow: lineIndex)
        return (textContainerInset.top + line.yPosition, line.data.lineHeight)
    }

    /// The x-coordinate at which text starts, i.e. after the gutter and the leading text container inset.
    var textOriginX: CGFloat {
        (showLineNumbers ? gutterWidth : 0) + textContainerInset.left
    }

    /// The range of line indices laid out in the viewport during the latest layout pass.
    var visibleLineIndices: ClosedRange<Int>? {
        textInputView.layoutManager.visibleLineRows
    }

    /// Total height of all lines, excluding insets. Useful for mapping scroll positions to a document overview.
    var linesContentHeight: CGFloat {
        textInputView.lineManager.contentHeight
    }

    /// Syntax highlight captures intersecting the given range. Returns an empty array for plain text
    /// or while the document is still being parsed.
    func syntaxHighlightCaptures(in range: NSRange) -> [SyntaxHighlightCapture] {
        guard let languageMode = textInputView.languageMode as? TreeSitterInternalLanguageMode, languageMode.canHighlight else {
            return []
        }
        let byteRange = ByteRange(utf16Range: range)
        return languageMode.captures(in: byteRange).map { capture in
            SyntaxHighlightCapture(range: NSRange(capture.byteRange), name: capture.name)
        }
    }
}

// MARK: - Folding
public extension TextView {
    /// Hides or shows lines. Hidden lines keep their text but take no vertical space; this is the primitive behind code folding.
    func setLinesHidden(_ isHidden: Bool, in lineIndices: ClosedRange<Int>) {
        let changedLines = textInputView.lineManager.setHidden(isHidden, forLinesIn: lineIndices)
        guard !changedLines.isEmpty else {
            return
        }
        textInputView.invalidateLayoutAfterChangingLineVisibility()
        setNeedsLayout()
    }

    /// Whether the line at the given index is hidden.
    func isLineHidden(_ lineIndex: Int) -> Bool {
        let lineManager = textInputView.lineManager
        guard lineIndex >= 0 && lineIndex < lineManager.lineCount else {
            return false
        }
        return lineManager.line(atRow: lineIndex).data.isHidden
    }

    /// Shows every hidden line.
    func showAllLines() {
        let lineCount = textInputView.lineManager.lineCount
        guard lineCount > 0 else {
            return
        }
        setLinesHidden(false, in: 0 ... lineCount - 1)
    }
}

extension TextInputView {
    func invalidateLayoutAfterChangingLineVisibility() {
        contentSizeService.invalidateContentSize()
        layoutManager.setNeedsLayout()
        layoutManager.layoutIfNeeded()
    }
}
