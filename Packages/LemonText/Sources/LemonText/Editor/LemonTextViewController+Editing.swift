import LemonTextCore
import UIKit

// MARK: - Text view delegate
extension LemonTextViewController: @preconcurrency TextViewDelegate {
    public func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if !secondarySelections.isEmpty {
            applyEditAtAllCarets(primaryRange: range, text: text)
            return false
        }
        recordPendingEdit(range: range, replacement: text)
        return true
    }

    public func textViewDidChange(_ textView: TextView) {
        documentDidChange()
        delegate?.editorDidChangeText(self)
    }

    public func textViewDidChangeSelection(_ textView: TextView) {
        let selection = textView.selectedRange
        if !isChangingSelectionInternally && !secondarySelections.isEmpty && selection != previousPrimarySelection {
            // A tap or arrow key moved the caret: drop the extra carets (⌥-click re-adds them).
            secondarySelections = []
        }
        selectionDidChange()
        previousPrimarySelection = selection
        delegate?.editorDidChangeSelection(self)
    }

    public func textViewDidChangeGutterWidth(_ textView: TextView) {
        decorations.setNeedsUpdate()
        textView.setNeedsLayout()
    }
}

// MARK: - Scroll view delegate
extension LemonTextViewController: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        hideDiagnosticCard()
    }
}

// MARK: - Reacting to edits
extension LemonTextViewController {
    /// Remembers which lines an edit touches so folds and diagnostics can follow it.
    func recordPendingEdit(range: NSRange, replacement: String) {
        guard let startLine = codeTextView.lineIndex(containing: range.location) ?? (range.location >= codeTextView.textLength ? max(codeTextView.lineCount - 1, 0) : nil) else {
            pendingEdit = nil
            return
        }
        let endLine = codeTextView.lineIndex(containing: range.location + range.length) ?? max(codeTextView.lineCount - 1, 0)
        let removedText = range.length > 0 ? (codeTextView.text(in: range) ?? "") : ""
        pendingEdit = (startLine, endLine, Self.lineBreakCount(in: replacement), Self.lineBreakCount(in: removedText),
                       range, (replacement as NSString).length)
    }

    static func lineBreakCount(in string: String) -> Int {
        var count = 0
        var previous: UInt16 = 0
        for unit in string.utf16 {
            if unit == 0x0A {
                if previous != 0x0D {
                    count += 1
                }
            } else if unit == 0x0D {
                count += 1
            }
            previous = unit
        }
        return count
    }

    func documentDidChange() {
        if let edit = pendingEdit {
            pendingEdit = nil
            let lineDelta = edit.insertedLineBreaks - edit.removedLineBreaks
            var foldState = decorations.foldState
            let dropped = foldState.applyEdit(editStartLine: edit.startLine, editEndLine: edit.endLine, lineDelta: lineDelta)
            if !dropped.isEmpty || lineDelta != 0 {
                for range in dropped {
                    codeTextView.setLinesHidden(false, in: range.hiddenLines.clamped(to: 0 ... max(codeTextView.lineCount - 1, 0)))
                }
                // Re-apply the remaining folds; inserted lines inside the window must stay visible.
                decorations.foldState = foldState
                reapplyHiddenLines()
            }
            shiftDiagnostics(editRange: edit.range, replacementLength: edit.replacementLength)
        } else if !(isApplyingBatchEdit && batchPreservesLineCount) {
            // A change we could not track (undo, replace all): drop folds rather than hide the wrong lines.
            if !decorations.foldState.folded.isEmpty {
                decorations.foldState = FoldState()
                codeTextView.showAllLines()
            }
        }
        decorations.textDidChange()
        minimapChunks.removeAll(keepingCapacity: true)
        scheduleMinimapRefresh()
        scheduleFoldingRangeUpdate(delay: .milliseconds(350))
        updateBracketMatch()
        if isFindVisible {
            scheduleFind(debounce: .milliseconds(200), keepCurrent: true)
        }
        updateCompletionAfterEdit()
        trimInlineSuggestionAfterEdit()
    }

    func shiftDiagnostics(editRange: NSRange, replacementLength: Int) {
        guard !decorations.diagnostics.isEmpty else {
            return
        }
        let edit = [TextEdit(range: editRange, replacement: String(repeating: " ", count: replacementLength))]
        decorations.diagnostics = decorations.diagnostics.compactMap { diagnostic in
            var diagnostic = diagnostic
            let start = TextEdit.map(diagnostic.range.location, through: edit, insertionsShiftLocation: diagnostic.range.length > 0)
            let end = TextEdit.map(diagnostic.range.location + diagnostic.range.length, through: edit, insertionsShiftLocation: false)
            diagnostic.range = NSRange(location: start, length: max(end - start, 0))
            return diagnostic
        }
    }

    func reapplyHiddenLines() {
        let lineCount = codeTextView.lineCount
        guard lineCount > 0 else {
            return
        }
        var hidden = IndexSet()
        for range in decorations.foldState.hiddenLineRanges {
            let clamped = range.clamped(to: 0 ... lineCount - 1)
            hidden.insert(integersIn: clamped.lowerBound ... clamped.upperBound)
        }
        // Show lines that should not be hidden any more, then hide the folded ones.
        for range in hidden.rangeView {
            codeTextView.setLinesHidden(true, in: range.lowerBound ... range.upperBound - 1)
        }
    }

    func selectionDidChange() {
        let selection = codeTextView.selectedRange
        let caretLine = codeTextView.lineIndex(containing: min(selection.location, max(codeTextView.textLength - 1, 0))) ?? 0
        // A caret inside folded lines unfolds them, so it is never invisible.
        if codeTextView.isLineHidden(caretLine) {
            unfoldLines(containing: caretLine)
        }
        decorations.caretLine = caretLine
        minimapView.currentLine = caretLine
        updateBracketMatch()
        if let prefixRange = completionPrefixRange, !completionPopup.isHidden {
            let caret = selection.location
            if selection.length > 0 || caret < prefixRange.location || caret > prefixRange.location + prefixRange.length + 1 {
                dismissCompletion()
            }
        }
        if let suggestion = inlineSuggestion, suggestion.location != selection.location || selection.length > 0 {
            setInlineSuggestion(nil)
        }
        hideDiagnosticCard()
    }

    // MARK: Bracket matching

    func updateBracketMatch() {
        guard configuration.matchBrackets else {
            decorations.bracketMatch = nil
            return
        }
        let selection = codeTextView.selectedRange
        guard selection.length == 0 else {
            decorations.bracketMatch = nil
            return
        }
        // Scan a bounded window around the caret rather than the whole document.
        let radius = 50_000
        let length = codeTextView.textLength
        let windowStart = max(0, selection.location - radius)
        let windowEnd = min(length, selection.location + radius)
        guard windowEnd > windowStart, let window = codeTextView.text(in: NSRange(location: windowStart, length: windowEnd - windowStart)) else {
            decorations.bracketMatch = nil
            return
        }
        let matcher = BracketMatcher(pairs: language.bracketPairs, scanLimit: radius)
        if let match = matcher.match(in: window as NSString, caret: selection.location - windowStart) {
            decorations.bracketMatch = BracketMatch(open: NSRange(location: match.open.location + windowStart, length: 1),
                                                    close: NSRange(location: match.close.location + windowStart, length: 1))
        } else {
            decorations.bracketMatch = nil
        }
    }

    // MARK: Several carets

    /// Applies typing or deletion at the primary caret and every extra caret as one undo step.
    func applyEditAtAllCarets(primaryRange: NSRange, text: String) {
        let primarySelection = codeTextView.selectedRange
        var edits: [(selectionIndex: Int, edit: TextEdit)] = [(0, TextEdit(range: primaryRange, replacement: text))]
        for (index, selection) in secondarySelections.enumerated() {
            let range: NSRange
            if text.isEmpty && selection.length == 0 {
                guard selection.location > 0 else {
                    continue
                }
                range = composedCharacterRange(before: selection.location)
            } else {
                range = selection
            }
            edits.append((index + 1, TextEdit(range: range, replacement: text)))
        }
        // Drop edits that overlap an earlier one (two carets on the same character).
        edits.sort { $0.edit.range.location < $1.edit.range.location }
        var accepted: [(selectionIndex: Int, edit: TextEdit)] = []
        for item in edits {
            if let last = accepted.last, item.edit.range.location < last.edit.range.location + last.edit.range.length
                || (item.edit.range.location == last.edit.range.location && item.edit.range.length == last.edit.range.length) {
                continue
            }
            accepted.append(item)
        }
        var delta = 0
        var newSelections: [Int: NSRange] = [:]
        for item in accepted {
            let replacementLength = (item.edit.replacement as NSString).length
            newSelections[item.selectionIndex] = NSRange(location: item.edit.range.location + delta + replacementLength, length: 0)
            delta += replacementLength - item.edit.range.length
        }
        let primary = newSelections[0] ?? NSRange(location: TextEdit.map(primarySelection.location, through: accepted.map(\.edit)), length: 0)
        let secondaries = newSelections.filter { $0.key != 0 }.sorted { $0.key < $1.key }.map(\.value)
        let replacements = accepted.map { BatchReplaceSet.Replacement(range: $0.edit.range, text: $0.edit.replacement) }
        isChangingSelectionInternally = true
        pendingEdit = nil
        isApplyingBatchEdit = true
        batchPreservesLineCount = !text.contains(where: \.isNewline) && accepted.allSatisfy { item in
            item.edit.range.length == 0 || Self.lineBreakCount(in: codeTextView.text(in: item.edit.range) ?? "") == 0
        }
        defer {
            isApplyingBatchEdit = false
            batchPreservesLineCount = false
        }
        codeTextView.replaceTextIncrementally(in: BatchReplaceSet(replacements: replacements), selectedRange: primary,
                                              actionName: text.isEmpty ? "Delete" : "Typing")
        secondarySelections = EditCommands.normalizedSelections(secondaries).filter { $0 != primary }
        previousPrimarySelection = codeTextView.selectedRange
        isChangingSelectionInternally = false
    }

    func composedCharacterRange(before location: Int) -> NSRange {
        let start = max(0, location - 8)
        guard let window = codeTextView.text(in: NSRange(location: start, length: location - start)) as NSString?, window.length > 0 else {
            return NSRange(location: max(location - 1, 0), length: location > 0 ? 1 : 0)
        }
        let range = window.rangeOfComposedCharacterSequence(at: window.length - 1)
        return NSRange(location: start + range.location, length: range.length)
    }

    /// Sets the primary selection without clearing extra carets.
    func setPrimarySelection(_ range: NSRange) {
        isChangingSelectionInternally = true
        codeTextView.selectedRange = range
        previousPrimarySelection = codeTextView.selectedRange
        isChangingSelectionInternally = false
    }

    /// Applies an `EditResult` as one undo step and installs its selections.
    func apply(_ result: EditResult, actionName: String) {
        guard !result.edits.isEmpty else {
            if let first = result.selections.first {
                setPrimarySelection(first)
                secondarySelections = Array(result.selections.dropFirst())
            }
            return
        }
        let replacements = result.edits.map { BatchReplaceSet.Replacement(range: $0.range, text: $0.replacement) }
        isChangingSelectionInternally = true
        pendingEdit = nil
        isApplyingBatchEdit = true
        batchPreservesLineCount = result.edits.allSatisfy { edit in
            let removed = edit.range.length > 0 ? (codeTextView.text(in: edit.range) ?? "") : ""
            return Self.lineBreakCount(in: removed) == Self.lineBreakCount(in: edit.replacement)
        }
        defer {
            isApplyingBatchEdit = false
            batchPreservesLineCount = false
        }
        if result.edits.count > 200 {
            codeTextView.replaceText(in: BatchReplaceSet(replacements: replacements))
            if let first = result.selections.first {
                codeTextView.selectedRange = first
            }
        } else {
            codeTextView.replaceTextIncrementally(in: BatchReplaceSet(replacements: replacements),
                                                  selectedRange: result.selections.first, actionName: actionName)
        }
        secondarySelections = Array(result.selections.dropFirst())
        previousPrimarySelection = codeTextView.selectedRange
        isChangingSelectionInternally = false
    }

    /// All selections, primary first.
    var allSelections: [NSRange] {
        [codeTextView.selectedRange] + secondarySelections
    }
}
