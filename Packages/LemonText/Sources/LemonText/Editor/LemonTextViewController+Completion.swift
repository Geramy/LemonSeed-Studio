import LemonTextCore
import UIKit

// MARK: - Completion
public extension LemonTextViewController {
    /// Asks the completion provider for suggestions at the caret. ⌃Space
    func triggerCompletion() {
        requestCompletions(trigger: .invoked)
    }

    /// Shows a list of completions at the caret, e.g. pushed by a language server.
    func showCompletions(_ items: [CompletionItem]) {
        let caret = codeTextView.selectedRange.location
        let prefixRange = wordPrefixRange(endingAt: caret)
        let prefix = codeTextView.text(in: prefixRange) ?? ""
        presentCompletions(CompletionFilter.filter(items, prefix: prefix), prefix: prefix, prefixRange: prefixRange)
    }

    func dismissCompletion() {
        completionTask?.cancel()
        completionPrefixRange = nil
        guard !completionPopup.isHidden else {
            return
        }
        completionPopup.isHidden = true
    }

    /// Shows ghost text after the caret, e.g. a suggestion from the inline agent. Tab accepts, Escape dismisses,
    /// and typing the suggested characters consumes them. Pass nil to clear.
    func setInlineSuggestion(_ text: String?) {
        guard let text, !text.isEmpty else {
            inlineSuggestion = nil
            ghostTextLabel.isHidden = true
            return
        }
        inlineSuggestion = (text, codeTextView.selectedRange.location)
        ghostTextLabel.font = configuration.font.uiFont
        ghostTextLabel.text = text
        ghostTextLabel.isHidden = false
        positionGhostText()
    }

    /// Inserts the inline suggestion.
    func acceptInlineSuggestion() {
        guard let suggestion = inlineSuggestion else {
            return
        }
        setInlineSuggestion(nil)
        codeTextView.insertText(suggestion.text)
    }
}

extension LemonTextViewController {
    var effectiveCompletionProvider: CompletionProvider {
        if let completionProvider {
            return completionProvider
        }
        return defaultCompletionProvider
    }

    func wordPrefixRange(endingAt caret: Int) -> NSRange {
        let start = max(0, caret - 128)
        guard caret > start, let text = codeTextView.text(in: NSRange(location: start, length: caret - start)) else {
            return NSRange(location: caret, length: 0)
        }
        var length = 0
        for scalar in text.unicodeScalars.reversed() {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || (scalar == "@" && language == .objectiveC) {
                length += scalar.utf16.count
            } else {
                break
            }
        }
        return NSRange(location: caret - length, length: length)
    }

    func updateCompletionAfterEdit() {
        let selection = codeTextView.selectedRange
        guard selection.length == 0, secondarySelections.isEmpty else {
            dismissCompletion()
            return
        }
        let caret = selection.location
        let previous = caret > 0 ? (codeTextView.text(in: NSRange(location: caret - 1, length: 1)) ?? "") : ""
        let provider = effectiveCompletionProvider
        let prefixRange = wordPrefixRange(endingAt: caret)
        if provider.triggerCharacters.contains(previous) {
            requestCompletions(trigger: .character(previous))
        } else if prefixRange.length >= 2 {
            requestCompletions(trigger: .character(previous))
        } else if !completionPopup.isHidden && prefixRange.length == 0 {
            dismissCompletion()
        }
    }

    func requestCompletions(trigger: CompletionContext.Trigger) {
        completionTask?.cancel()
        let caret = codeTextView.selectedRange.location
        let prefixRange = wordPrefixRange(endingAt: caret)
        let prefix = codeTextView.text(in: prefixRange) ?? ""
        let position = caretPosition
        let context = CompletionContext(caret: caret, prefix: prefix, prefixRange: prefixRange, line: position.line - 1,
                                        column: position.column - 1, language: language, trigger: trigger)
        let provider = effectiveCompletionProvider
        completionTask = Task { [weak self] in
            // Let fast typing settle before asking.
            if case .character = trigger {
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard !Task.isCancelled else {
                return
            }
            let items = await provider.completions(for: context)
            guard let self, !Task.isCancelled, self.codeTextView.selectedRange.location == caret else {
                return
            }
            let ranked = CompletionFilter.filter(items, prefix: prefix).filter { $0.label != prefix }
            self.presentCompletions(Array(ranked.prefix(200)), prefix: prefix, prefixRange: prefixRange)
        }
    }

    func presentCompletions(_ items: [CompletionItem], prefix: String, prefixRange: NSRange) {
        guard !items.isEmpty else {
            dismissCompletion()
            return
        }
        completionPrefixRange = prefixRange
        completionPopup.show(items: items, prefix: prefix)
        let anchor = codeTextView.caretRect(at: prefixRange.location)
        let anchorInView = codeTextView.convert(anchor, to: view)
        let width: CGFloat = min(420, view.bounds.width - 24)
        let height = completionPopup.preferredHeight
        var origin = CGPoint(x: anchorInView.minX - 30, y: anchorInView.maxY + 4)
        if origin.y + height > view.bounds.height - view.safeAreaInsets.bottom - 8 {
            origin.y = anchorInView.minY - height - 4
        }
        origin.x = min(max(origin.x, 8), view.bounds.width - width - 8)
        let wasHidden = completionPopup.isHidden
        completionPopup.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        completionPopup.isHidden = false
        if wasHidden {
            completionPopup.alpha = 0
            UIView.animate(withDuration: 0.12) {
                self.completionPopup.alpha = 1
            }
        }
    }

    func acceptCompletion(_ item: CompletionItem) {
        let range = item.replacementRange ?? completionPrefixRange ?? wordPrefixRange(endingAt: codeTextView.selectedRange.location)
        dismissCompletion()
        codeTextView.replace(range, withText: item.insertText)
        let caret = range.location + (item.insertText as NSString).length
        codeTextView.selectedRange = NSRange(location: caret, length: 0)
        dismissCompletion()
    }

    // MARK: Ghost text

    func positionGhostText() {
        guard let suggestion = inlineSuggestion, !ghostTextLabel.isHidden else {
            return
        }
        let caret = codeTextView.caretRect(at: suggestion.location)
        let maxWidth = max(codeTextView.contentSize.width - caret.minX, 200)
        let size = ghostTextLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        ghostTextLabel.frame = CGRect(x: caret.maxX + 1, y: caret.minY + (caret.height - (ghostTextLabel.font?.lineHeight ?? caret.height)) / 2,
                                      width: size.width, height: size.height)
    }

    func trimInlineSuggestionAfterEdit() {
        guard let suggestion = inlineSuggestion else {
            return
        }
        let caret = codeTextView.selectedRange.location
        let typedLength = caret - suggestion.location
        guard typedLength > 0, typedLength <= (suggestion.text as NSString).length,
              let typed = codeTextView.text(in: NSRange(location: suggestion.location, length: typedLength)),
              suggestion.text.hasPrefix(typed) else {
            setInlineSuggestion(nil)
            return
        }
        let remaining = String((suggestion.text as NSString).substring(from: typedLength))
        if remaining.isEmpty {
            setInlineSuggestion(nil)
        } else {
            inlineSuggestion = (remaining, caret)
            ghostTextLabel.text = remaining
            positionGhostText()
        }
    }
}
