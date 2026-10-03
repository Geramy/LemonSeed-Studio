import LemonTextCore
import UIKit

// MARK: - Chrome layout
extension LemonTextViewController {
    func setUpChrome() {
        findBar.delegate = self
        findBar.isHidden = true
        view.addSubview(findBar)
        goToLinePanel.isHidden = true
        goToLinePanel.onGo = { [weak self] line, column in
            self?.hideGoToLine()
            self?.goToLine(line, column: column)
        }
        goToLinePanel.onClose = { [weak self] in
            self?.hideGoToLine()
            _ = self?.codeTextView.becomeFirstResponder()
        }
        view.addSubview(goToLinePanel)
        completionPopup.isHidden = true
        completionPopup.onAccept = { [weak self] item in self?.acceptCompletion(item) }
        view.addSubview(completionPopup)
        diagnosticCard.isHidden = true
        view.addSubview(diagnosticCard)
        ghostTextLabel.numberOfLines = 0
        ghostTextLabel.isHidden = true
        ghostTextLabel.isUserInteractionEnabled = false
        codeTextView.overlayView.addSubview(ghostTextLabel)
        hoverCaretLayer.isHidden = true
        hoverCaretLayer.cornerRadius = 1
        hoverCaretLayer.actions = DecorationController.noActions
        codeTextView.overlayView.layer.addSublayer(hoverCaretLayer)
    }

    func layoutChrome() {
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        let trailingInset = (minimapView.isHidden ? 0 : minimapView.bounds.width) + 12
        if !findBar.isHidden {
            let width = min(560, bounds.width - 24)
            let size = findBar.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                       withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            findBar.frame = CGRect(x: max(bounds.width - trailingInset - width, 12), y: safe.top + 10, width: width, height: size.height)
        }
        if !goToLinePanel.isHidden {
            let width = min(340, bounds.width - 24)
            let size = goToLinePanel.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                             withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            goToLinePanel.frame = CGRect(x: (bounds.width - width) / 2, y: safe.top + 10, width: width, height: size.height)
        }
    }
}

// MARK: - Find and replace
public extension LemonTextViewController {
    /// Shows the find bar, seeded with the selection when it is a single line. ⌘F, ⌥⌘F
    func showFind(replace: Bool = false) {
        loadViewIfNeeded()
        hideGoToLine()
        let selection = codeTextView.selectedRange
        if selection.length > 0, selection.length < 200, let selected = codeTextView.text(in: selection), !selected.contains("\n") {
            findBar.findField.text = selected
        }
        let wasHidden = findBar.isHidden
        findBar.isHidden = false
        findBar.setReplaceVisible(replace, animated: !wasHidden)
        layoutChrome()
        if wasHidden {
            findBar.alpha = 0
            findBar.transform = CGAffineTransform(translationX: 0, y: -8).scaledBy(x: 0.98, y: 0.98)
            UIView.animate(springDuration: 0.32, bounce: 0.18) {
                self.findBar.alpha = 1
                self.findBar.transform = .identity
            }
        }
        findBar.focus()
        scheduleFind(debounce: .zero, keepCurrent: false)
    }

    func hideFind() {
        guard !findBar.isHidden else {
            return
        }
        findTask?.cancel()
        UIView.animate(springDuration: 0.25, bounce: 0) {
            self.findBar.alpha = 0
            self.findBar.transform = CGAffineTransform(translationX: 0, y: -8)
        } completion: { _ in
            self.findBar.isHidden = true
            self.findBar.transform = .identity
        }
        findMatches = []
        currentFindIndex = nil
        codeTextView.highlightedRanges = []
        updateMinimapMarkers()
        _ = codeTextView.becomeFirstResponder()
    }

    /// Selects the next match. ⌘G
    func findNext() {
        if findMatches.isEmpty {
            if findBar.isHidden {
                showFind()
            }
            return
        }
        let selection = codeTextView.selectedRange
        let next = FindEngine.next(in: findMatches, from: selection.location + max(selection.length, 1), wraps: true)
        select(match: next)
    }

    /// Selects the previous match. ⇧⌘G
    func findPrevious() {
        guard !findMatches.isEmpty else {
            return
        }
        let previous = FindEngine.previous(in: findMatches, before: codeTextView.selectedRange.location, wraps: true)
        select(match: previous)
    }

    /// Puts the selection in the find field without showing the bar. ⌘E
    func useSelectionForFind() {
        let selection = codeTextView.selectedRange
        guard selection.length > 0, let selected = codeTextView.text(in: selection) else {
            return
        }
        findBar.findField.text = selected
        scheduleFind(debounce: .zero, keepCurrent: true)
    }

    /// Runs a search programmatically (e.g. from a "find in files" result).
    func find(_ query: FindQuery) {
        findBar.findField.text = query.text
        showFind()
    }

    /// Shows the go-to-line field. ⌃G
    func showGoToLine() {
        loadViewIfNeeded()
        goToLinePanel.lineCount = codeTextView.lineCount
        goToLinePanel.field.text = ""
        goToLinePanel.isHidden = false
        layoutChrome()
        goToLinePanel.alpha = 0
        goToLinePanel.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(springDuration: 0.3, bounce: 0.2) {
            self.goToLinePanel.alpha = 1
            self.goToLinePanel.transform = .identity
        }
        goToLinePanel.field.becomeFirstResponder()
    }

    func hideGoToLine() {
        guard !goToLinePanel.isHidden else {
            return
        }
        goToLinePanel.field.resignFirstResponder()
        goToLinePanel.isHidden = true
    }
}

extension LemonTextViewController: FindBarDelegate {
    func findBar(_ findBar: FindBar, didChange query: FindQuery) {
        scheduleFind(debounce: .milliseconds(120), keepCurrent: false)
    }

    func findBarFindNext(_ findBar: FindBar) {
        findNext()
    }

    func findBarFindPrevious(_ findBar: FindBar) {
        findPrevious()
    }

    func findBar(_ findBar: FindBar, replaceCurrentWith template: String) {
        guard let index = currentFindIndex, findMatches.indices.contains(index) else {
            findNext()
            return
        }
        let match = findMatches[index]
        let engine = FindEngine(query: findBar.query)
        let snapshot = textSnapshot()
        guard let replacement = try? engine.replacementText(for: match, in: snapshot, template: template) else {
            return
        }
        secondarySelections = []
        codeTextView.replace(match.range, withText: replacement)
        // Search again and continue from after the replacement.
        let resumeLocation = match.range.location + (replacement as NSString).length
        runFindNow(selectingFrom: resumeLocation)
    }

    func findBar(_ findBar: FindBar, replaceAllWith template: String) {
        let engine = FindEngine(query: findBar.query)
        guard let edits = try? engine.replaceAllEdits(in: textSnapshot(), template: template), !edits.isEmpty else {
            return
        }
        let count = edits.count
        apply(EditResult(edits: edits, selections: [NSRange(location: TextEdit.map(codeTextView.selectedRange.location, through: edits), length: 0)]),
              actionName: "Replace All")
        runFindNow(selectingFrom: nil)
        findBar.setResult(current: nil, total: 0)
        UIAccessibility.post(notification: .announcement, argument: "Replaced \(count) occurrences")
    }

    func findBarDidClose(_ findBar: FindBar) {
        hideFind()
    }
}

extension LemonTextViewController {
    /// The most matches highlighted at once; counting continues beyond it.
    static let findHighlightLimit = 20_000

    func scheduleFind(debounce: Duration, keepCurrent: Bool) {
        findTask?.cancel()
        let query = findBar.query
        guard !query.text.isEmpty else {
            findMatches = []
            currentFindIndex = nil
            codeTextView.highlightedRanges = []
            findBar.setResult(current: nil, total: 0)
            updateMinimapMarkers()
            return
        }
        let snapshot = UncheckedSendableBox(textSnapshot())
        let anchor = codeTextView.selectedRange.location
        findTask = Task { [weak self] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else {
                return
            }
            let result: Result<[FindMatch], Error> = await Task.detached(priority: .userInitiated) {
                Result { try FindEngine(query: query).matches(in: snapshot.value, limit: 1_000_000) }
            }.value
            guard let self, !Task.isCancelled else {
                return
            }
            switch result {
            case .success(let matches):
                self.findMatches = matches
                if keepCurrent, let current = self.currentFindIndex, matches.indices.contains(current) {
                    self.currentFindIndex = current
                } else {
                    self.currentFindIndex = matches.firstIndex { $0.range.location >= anchor } ?? (matches.isEmpty ? nil : 0)
                }
                self.refreshFindHighlights()
                if !keepCurrent, let index = self.currentFindIndex {
                    // Like VS Code, typing a query moves to the nearest match and selects it.
                    self.select(match: self.findMatches[index])
                }
                self.findBar.setResult(current: self.currentFindIndex, total: matches.count)
            case .failure(let error):
                self.findMatches = []
                self.currentFindIndex = nil
                self.codeTextView.highlightedRanges = []
                let message = (error as? FindError).map { if case let .invalidRegularExpression(text) = $0 { text } else { "" } } ?? "Error"
                self.findBar.setResult(current: nil, total: 0, error: message)
            }
            self.updateMinimapMarkers()
        }
    }

    private func runFindNow(selectingFrom location: Int?) {
        let query = findBar.query
        guard let matches = try? FindEngine(query: query).matches(in: textSnapshot(), limit: 1_000_000) else {
            return
        }
        findMatches = matches
        if let location {
            currentFindIndex = matches.firstIndex { $0.range.location >= location } ?? (matches.isEmpty ? nil : 0)
            if let index = currentFindIndex {
                select(match: matches[index])
            }
        } else {
            currentFindIndex = nil
        }
        refreshFindHighlights()
        findBar.setResult(current: currentFindIndex, total: matches.count)
        updateMinimapMarkers()
    }

    private func select(match: FindMatch?) {
        guard let match else {
            return
        }
        currentFindIndex = findMatches.firstIndex(of: match)
        secondarySelections = []
        codeTextView.selectedRange = match.range
        reveal(match.range)
        refreshFindHighlights()
        findBar.setResult(current: currentFindIndex, total: findMatches.count)
    }

    func reveal(_ range: NSRange) {
        if let line = codeTextView.lineIndex(containing: range.location), codeTextView.isLineHidden(line) {
            unfoldLines(containing: line)
        }
        codeTextView.scrollRangeToVisible(range)
    }

    func refreshFindHighlights() {
        guard isFindVisible, !findMatches.isEmpty else {
            if !codeTextView.highlightedRanges.isEmpty {
                codeTextView.highlightedRanges = []
            }
            return
        }
        // Highlight matches near the viewport plus the current one; a document can have many thousands.
        let visible = codeTextView.visibleLineIndices ?? 0 ... 0
        let firstLine = max(visible.lowerBound - 200, 0)
        let lastLine = min(visible.upperBound + 200, max(codeTextView.lineCount - 1, 0))
        let start = codeTextView.range(ofLine: firstLine)?.location ?? 0
        let endRange = codeTextView.range(ofLine: lastLine, includingLineBreak: true)
        let end = endRange.map { $0.location + $0.length } ?? codeTextView.textLength
        let firstIndex = findMatches.partitioningIndex { $0.range.location >= start }
        var ranges: [HighlightedRange] = []
        let findColor = theme.findMatch.uiColor
        let currentColor = theme.currentFindMatch.uiColor
        var index = firstIndex
        while index < findMatches.count && findMatches[index].range.location <= end && ranges.count < Self.findHighlightLimit {
            let isCurrent = index == currentFindIndex
            ranges.append(HighlightedRange(id: "find-\(index)", range: findMatches[index].range,
                                           color: isCurrent ? currentColor : findColor, cornerRadius: 3))
            index += 1
        }
        codeTextView.highlightedRanges = ranges
        findHighlightWindow = start ... end
    }
}
