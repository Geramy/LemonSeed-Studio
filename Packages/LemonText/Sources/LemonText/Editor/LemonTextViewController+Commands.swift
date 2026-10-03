import LemonTextCore
import UIKit

// MARK: - Public commands
public extension LemonTextViewController {
    /// The primary selection.
    var selectedRange: NSRange {
        get { codeTextView.selectedRange }
        set {
            secondarySelections = []
            codeTextView.selectedRange = newValue
        }
    }

    /// All selections, primary first. Setting more than one creates extra carets.
    var selections: [NSRange] {
        get { allSelections }
        set {
            guard let first = newValue.first else {
                return
            }
            setPrimarySelection(first)
            secondarySelections = EditCommands.normalizedSelections(Array(newValue.dropFirst())).filter { $0 != first }
        }
    }

    /// One-based line and column (in UTF-16 units) of the primary caret.
    var caretPosition: (line: Int, column: Int) {
        let location = codeTextView.selectedRange.location
        guard let textLocation = codeTextView.textLocation(at: location) else {
            return (1, 1)
        }
        return (textLocation.lineNumber + 1, textLocation.column + 1)
    }

    var lineCount: Int {
        codeTextView.lineCount
    }

    /// Toggles line comments (or block comments) on the selected lines. ⌘/
    func toggleComment() {
        let result = EditCommands.toggleComment(in: textSnapshot(), selections: allSelections, language: language,
                                                tabWidth: configuration.tabWidth)
        apply(result, actionName: "Toggle Comment")
    }

    /// Indents the selected lines. ⌘]
    func indentLines() {
        if secondarySelections.isEmpty {
            codeTextView.shiftRight()
        } else {
            apply(EditCommands.indent(in: textSnapshot(), selections: allSelections, indentUnit: indentUnit), actionName: "Indent")
        }
    }

    /// Outdents the selected lines. ⌘[
    func outdentLines() {
        if secondarySelections.isEmpty {
            codeTextView.shiftLeft()
        } else {
            apply(EditCommands.outdent(in: textSnapshot(), selections: allSelections, tabWidth: configuration.tabWidth), actionName: "Outdent")
        }
    }

    /// Moves the selected lines up. ⌥↑
    func moveLinesUp() {
        secondarySelections = []
        unfoldAll()
        codeTextView.moveSelectedLinesUp()
    }

    /// Moves the selected lines down. ⌥↓
    func moveLinesDown() {
        secondarySelections = []
        unfoldAll()
        codeTextView.moveSelectedLinesDown()
    }

    /// Selects the word at the caret, then adds the next occurrence of the selection as another caret. ⌘D
    func selectNextOccurrence() {
        let current = allSelections
        // Keep document order but make the newest selection primary so it scrolls into view.
        let ordered = Array(current.dropFirst()) + [current[0]]
        let result = EditCommands.selectNextOccurrence(in: textSnapshot(), selections: ordered)
        guard let newest = result.last else {
            return
        }
        setPrimarySelection(newest)
        secondarySelections = EditCommands.normalizedSelections(Array(result.dropLast())).filter { $0 != newest }
        codeTextView.scrollRangeToVisible(newest)
    }

    /// Selects every occurrence of the selection or the word at the caret. ⇧⌘L
    func selectAllOccurrences() {
        let all = EditCommands.selectAllOccurrences(in: textSnapshot(), selection: codeTextView.selectedRange)
        guard !all.isEmpty else {
            return
        }
        let primary = all.first { $0.location >= codeTextView.selectedRange.location } ?? all[0]
        setPrimarySelection(primary)
        secondarySelections = all.filter { $0 != primary }
    }

    /// Removes the extra carets.
    func clearExtraCarets() {
        secondarySelections = []
    }

    /// Scrolls to and places the caret on a one-based line (and optional one-based column).
    func goToLine(_ line: Int, column: Int? = nil) {
        let lineIndex = min(max(line - 1, 0), max(codeTextView.lineCount - 1, 0))
        if codeTextView.isLineHidden(lineIndex) {
            unfoldLines(containing: lineIndex)
        }
        secondarySelections = []
        _ = codeTextView.goToLine(lineIndex)
        if let column, let range = codeTextView.range(ofLine: lineIndex) {
            codeTextView.selectedRange = NSRange(location: range.location + min(max(column - 1, 0), range.length), length: 0)
        }
        // Centre the target line rather than leaving it at an edge.
        if let extent = codeTextView.verticalExtent(ofLine: lineIndex) {
            let target = extent.minY - codeTextView.bounds.height / 3
            let maxOffset = max(codeTextView.contentSize.height - codeTextView.bounds.height, 0)
            codeTextView.setContentOffset(CGPoint(x: 0, y: min(max(target, 0), maxOffset)), animated: false)
        }
        _ = codeTextView.becomeFirstResponder()
    }

    // MARK: Folding

    /// Folds the innermost region starting on or containing `line` (zero-based).
    func fold(atLine line: Int) {
        let candidates = decorations.foldingRanges.filter { $0.startLine <= line && $0.endLine >= line }
        guard let range = decorations.foldingRangesByStart[line] ?? candidates.max(by: { $0.startLine < $1.startLine }) else {
            return
        }
        var state = decorations.foldState
        state.fold(range)
        decorations.foldState = state
        codeTextView.setLinesHidden(true, in: range.hiddenLines)
        let selection = codeTextView.selectedRange
        if let caretLine = codeTextView.lineIndex(containing: selection.location), range.hiddenLines.contains(caretLine),
           let headerRange = codeTextView.range(ofLine: range.startLine) {
            setPrimarySelection(NSRange(location: headerRange.location + headerRange.length, length: 0))
        }
        decorations.setNeedsUpdate()
        codeTextView.setNeedsLayout()
        minimapView.viewportDidChange()
    }

    /// Unfolds the region starting on `line` (zero-based).
    func unfold(atLine line: Int) {
        var state = decorations.foldState
        guard let range = state.unfold(startingAt: line) else {
            return
        }
        decorations.foldState = state
        codeTextView.setLinesHidden(false, in: range.hiddenLines)
        reapplyHiddenLines()
        decorations.setNeedsUpdate()
        codeTextView.setNeedsLayout()
    }

    func toggleFold(atLine line: Int) {
        if decorations.foldState.isFolded(startingAt: line) {
            unfold(atLine: line)
        } else {
            fold(atLine: line)
        }
    }

    /// Folds every foldable region.
    func foldAll() {
        var state = FoldState()
        for range in decorations.foldingRanges {
            state.fold(range)
        }
        decorations.foldState = state
        reapplyHiddenLines()
        if let caretLine = codeTextView.lineIndex(containing: codeTextView.selectedRange.location), codeTextView.isLineHidden(caretLine) {
            setPrimarySelection(NSRange(location: 0, length: 0))
        }
        decorations.setNeedsUpdate()
        codeTextView.setNeedsLayout()
    }

    func unfoldAll() {
        guard !decorations.foldState.folded.isEmpty else {
            return
        }
        decorations.foldState = FoldState()
        codeTextView.showAllLines()
        decorations.setNeedsUpdate()
        codeTextView.setNeedsLayout()
    }

    /// Lines currently folded away, as ranges of zero-based line indices.
    var hiddenLineRanges: [ClosedRange<Int>] {
        decorations.foldState.hiddenLineRanges
    }

    /// Whether the software keyboard appears when editing. Turn it off while a hardware keyboard is the input,
    /// or in a Pencil-only mode, to keep the whole screen for code.
    var showsSoftwareKeyboard: Bool {
        get { codeTextView.customInputView == nil }
        set {
            let replacement: UIView? = newValue ? nil : UIView(frame: .zero)
            codeTextView.customInputView = replacement
            for field in [findBar.findField, findBar.replaceField, goToLinePanel.field] {
                field.inputView = newValue ? nil : UIView(frame: .zero)
                field.reloadInputViews()
            }
        }
    }

    // MARK: Appearance shortcuts

    func toggleSoftWrap() {
        configuration.softWrap.toggle()
    }

    func toggleInvisibles() {
        configuration.showInvisibles.toggle()
    }

    func toggleMinimap() {
        configuration.showMinimap.toggle()
    }

    func increaseFontSize() {
        configuration.font.size = min(configuration.font.size + 1, 32)
    }

    func decreaseFontSize() {
        configuration.font.size = max(configuration.font.size - 1, 9)
    }
}

extension LemonTextViewController {
    var indentUnit: String {
        configuration.insertSpaces && !language.prefersTabs ? String(repeating: " ", count: configuration.tabWidth) : "\t"
    }

    func unfoldLines(containing line: Int) {
        var state = decorations.foldState
        let removed = state.unfoldAll(hiding: line)
        guard !removed.isEmpty else {
            return
        }
        decorations.foldState = state
        for range in removed {
            codeTextView.setLinesHidden(false, in: range.hiddenLines.clamped(to: 0 ... max(codeTextView.lineCount - 1, 0)))
        }
        reapplyHiddenLines()
        decorations.setNeedsUpdate()
        codeTextView.setNeedsLayout()
    }

    func scheduleFoldingRangeUpdate(delay: Duration) {
        guard !usesExternalFoldingRanges else {
            return
        }
        foldingTask?.cancel()
        let language = language
        let tabWidth = configuration.tabWidth
        let generation = loadGeneration
        foldingTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self, !Task.isCancelled else {
                return
            }
            // Snapshot only once the edits have settled; copying a large document per keystroke is wasteful.
            let snapshot = UncheckedSendableBox(self.textSnapshot())
            let ranges = await Task.detached(priority: .utility) {
                FoldingRangeCalculator.ranges(in: snapshot.value, language: language, tabWidth: tabWidth)
            }.value
            guard !Task.isCancelled, generation == self.loadGeneration, !self.usesExternalFoldingRanges else {
                return
            }
            self.decorations.foldingRanges = ranges
            self.codeTextView.setNeedsLayout()
        }
    }
}

// MARK: - Keyboard shortcuts
extension LemonTextViewController {
    override public var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            command("Find", "f", .command, #selector(handleFind)),
            command("Find and Replace", "f", [.command, .alternate], #selector(handleFindReplace)),
            command("Find Next", "g", .command, #selector(handleFindNext)),
            command("Find Previous", "g", [.command, .shift], #selector(handleFindPrevious)),
            command("Use Selection for Find", "e", .command, #selector(handleUseSelectionForFind)),
            command("Go to Line…", "g", .control, #selector(handleGoToLine)),
            command("Toggle Comment", "/", .command, #selector(handleToggleComment), priority: true),
            command("Indent", "]", .command, #selector(handleIndent), priority: true),
            command("Outdent", "[", .command, #selector(handleOutdent), priority: true),
            command("Move Line Up", UIKeyCommand.inputUpArrow, .alternate, #selector(handleMoveLinesUp), priority: true),
            command("Move Line Down", UIKeyCommand.inputDownArrow, .alternate, #selector(handleMoveLinesDown), priority: true),
            command("Add Next Occurrence", "d", .command, #selector(handleSelectNextOccurrence), priority: true),
            command("Select All Occurrences", "l", [.command, .shift], #selector(handleSelectAllOccurrences)),
            command("Fold", "[", [.command, .alternate], #selector(handleFold), priority: true),
            command("Unfold", "]", [.command, .alternate], #selector(handleUnfold), priority: true),
            command("Fold All", "[", [.command, .alternate, .shift], #selector(handleFoldAll), priority: true),
            command("Unfold All", "]", [.command, .alternate, .shift], #selector(handleUnfoldAll), priority: true),
            command("Trigger Suggestion", " ", .control, #selector(handleTriggerCompletion), priority: true),
            command("Toggle Word Wrap", "z", .alternate, #selector(handleToggleSoftWrap), priority: true),
            // Emacs-style bindings. Without priority, the text input system handles them first where it can.
            command("Move to Line Start", "a", .control, #selector(handleMoveToLineStart)),
            command("Move to Line End", "e", .control, #selector(handleMoveToLineEnd)),
            command("Delete to Line End", "k", .control, #selector(handleKillToLineEnd)),
            command("Increase Font Size", "=", .command, #selector(handleIncreaseFontSize)),
            command("Decrease Font Size", "-", .command, #selector(handleDecreaseFontSize))
        ]
        if !completionPopup.isHidden {
            commands += [
                command("Next Suggestion", UIKeyCommand.inputDownArrow, [], #selector(handleCompletionDown), priority: true),
                command("Previous Suggestion", UIKeyCommand.inputUpArrow, [], #selector(handleCompletionUp), priority: true),
                command("Accept Suggestion", "\t", [], #selector(handleAcceptCompletion), priority: true)
            ]
            if completionPopup.hasNavigated {
                commands.append(command("Accept Suggestion", "\r", [], #selector(handleAcceptCompletion), priority: true))
            }
        } else if inlineSuggestion != nil {
            commands.append(command("Accept Inline Suggestion", "\t", [], #selector(handleAcceptInlineSuggestion), priority: true))
        }
        if !secondarySelections.isEmpty {
            commands += [
                command("Move Carets Left", UIKeyCommand.inputLeftArrow, [], #selector(handleCaretsLeft), priority: true),
                command("Move Carets Right", UIKeyCommand.inputRightArrow, [], #selector(handleCaretsRight), priority: true),
                command("Move Carets Up", UIKeyCommand.inputUpArrow, [], #selector(handleCaretsUp), priority: true),
                command("Move Carets Down", UIKeyCommand.inputDownArrow, [], #selector(handleCaretsDown), priority: true)
            ]
        }
        let needsEscape = !secondarySelections.isEmpty || !completionPopup.isHidden || inlineSuggestion != nil
            || isFindVisible || !goToLinePanel.isHidden || !diagnosticCard.isHidden
        if needsEscape {
            commands.append(command("Dismiss", UIKeyCommand.inputEscape, [], #selector(handleEscape), priority: true))
        }
        return commands
    }

    private func command(_ title: String, _ input: String, _ modifiers: UIKeyModifierFlags, _ action: Selector,
                         priority: Bool = false) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        command.wantsPriorityOverSystemBehavior = priority
        return command
    }

    @objc func handleFind() { showFind(replace: false) }
    @objc func handleFindReplace() { showFind(replace: true) }
    @objc func handleFindNext() { findNext() }
    @objc func handleFindPrevious() { findPrevious() }
    @objc func handleUseSelectionForFind() { useSelectionForFind() }
    @objc func handleGoToLine() { showGoToLine() }
    @objc func handleToggleComment() { toggleComment() }
    @objc func handleIndent() { indentLines() }
    @objc func handleOutdent() { outdentLines() }
    @objc func handleMoveLinesUp() { moveLinesUp() }
    @objc func handleMoveLinesDown() { moveLinesDown() }
    @objc func handleSelectNextOccurrence() { selectNextOccurrence() }
    @objc func handleSelectAllOccurrences() { selectAllOccurrences() }
    @objc func handleTriggerCompletion() { triggerCompletion() }
    @objc func handleToggleSoftWrap() { toggleSoftWrap() }
    @objc func handleIncreaseFontSize() { increaseFontSize() }
    @objc func handleDecreaseFontSize() { decreaseFontSize() }
    @objc func handleFoldAll() { foldAll() }

    @objc func handleMoveToLineStart() {
        let caret = codeTextView.selectedRange.location
        guard let line = codeTextView.lineIndex(containing: caret), let range = codeTextView.range(ofLine: line) else { return }
        // First press goes to the first non-blank character, the next to column 0.
        let indentation = (codeTextView.text(in: range) ?? "").prefix { $0 == " " || $0 == "\t" }.utf16.count
        let target = caret == range.location + indentation ? range.location : range.location + indentation
        selectedRange = NSRange(location: target, length: 0)
    }

    @objc func handleMoveToLineEnd() {
        let caret = codeTextView.selectedRange.location
        guard let line = codeTextView.lineIndex(containing: caret), let range = codeTextView.range(ofLine: line) else { return }
        selectedRange = NSRange(location: range.location + range.length, length: 0)
    }

    @objc func handleKillToLineEnd() {
        let caret = codeTextView.selectedRange.location
        guard let line = codeTextView.lineIndex(containing: caret), let range = codeTextView.range(ofLine: line, includingLineBreak: true),
              let content = codeTextView.range(ofLine: line) else { return }
        // At the end of a line, ⌃K joins the next line, like Emacs.
        let end = caret == content.location + content.length ? range.location + range.length : content.location + content.length
        guard end > caret else { return }
        codeTextView.replace(NSRange(location: caret, length: end - caret), withText: "")
    }
    @objc func handleUnfoldAll() { unfoldAll() }

    @objc func handleFold() {
        if let line = codeTextView.lineIndex(containing: codeTextView.selectedRange.location) {
            fold(atLine: line)
        }
    }

    @objc func handleUnfold() {
        if let line = codeTextView.lineIndex(containing: codeTextView.selectedRange.location) {
            unfold(atLine: line)
        }
    }

    @objc func handleCompletionDown() { completionPopup.moveSelection(by: 1) }
    @objc func handleCompletionUp() { completionPopup.moveSelection(by: -1) }
    @objc func handleAcceptCompletion() {
        if let item = completionPopup.selectedItem {
            acceptCompletion(item)
        }
    }
    @objc func handleAcceptInlineSuggestion() { acceptInlineSuggestion() }

    @objc func handleEscape() {
        if !completionPopup.isHidden {
            dismissCompletion()
        } else if inlineSuggestion != nil {
            setInlineSuggestion(nil)
        } else if !diagnosticCard.isHidden {
            hideDiagnosticCard()
        } else if !secondarySelections.isEmpty {
            secondarySelections = []
        } else if !goToLinePanel.isHidden {
            hideGoToLine()
        } else if isFindVisible {
            hideFind()
        }
    }

    // Moving several carets at once.
    @objc func handleCaretsLeft() { moveAllCaretsHorizontally(forward: false) }
    @objc func handleCaretsRight() { moveAllCaretsHorizontally(forward: true) }
    @objc func handleCaretsUp() { moveAllCaretsVertically(by: -1) }
    @objc func handleCaretsDown() { moveAllCaretsVertically(by: 1) }

    private func moveAllCaretsHorizontally(forward: Bool) {
        let length = codeTextView.textLength
        let moved = allSelections.map { selection -> NSRange in
            if selection.length > 0 {
                // Like a single caret, an arrow collapses a selection to its edge.
                return NSRange(location: forward ? selection.location + selection.length : selection.location, length: 0)
            }
            return NSRange(location: forward ? min(selection.location + 1, length) : max(selection.location - 1, 0), length: 0)
        }
        installMovedSelections(moved)
    }

    private func moveAllCaretsVertically(by delta: Int) {
        let moved = allSelections.map { selection -> NSRange in
            let location = selection.location + (delta > 0 ? selection.length : 0)
            guard let line = codeTextView.lineIndex(containing: location), let lineRange = codeTextView.range(ofLine: line) else {
                return selection
            }
            let column = location - lineRange.location
            let targetLine = min(max(line + delta, 0), codeTextView.lineCount - 1)
            guard let target = codeTextView.range(ofLine: targetLine) else {
                return selection
            }
            return NSRange(location: target.location + min(column, target.length), length: 0)
        }
        installMovedSelections(moved)
    }

    private func installMovedSelections(_ moved: [NSRange]) {
        guard let primary = moved.first else {
            return
        }
        setPrimarySelection(primary)
        secondarySelections = EditCommands.normalizedSelections(Array(moved.dropFirst())).filter { $0 != primary }
    }
}
