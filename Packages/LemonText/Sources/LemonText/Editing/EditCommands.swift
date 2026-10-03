import Foundation

/// Editing commands as pure functions from text and selections to edits and new selections.
///
/// The view controller applies the returned edits as a single undo step, so every command
/// works the same for one caret or many.
public enum EditCommands {
    // MARK: - Selections

    /// Sorts selections and merges ones that overlap or touch. Carets at the same location collapse into one.
    public static func normalizedSelections(_ selections: [NSRange]) -> [NSRange] {
        let sorted = selections.sorted { lhs, rhs in
            lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
        }
        var result: [NSRange] = []
        for selection in sorted {
            if let last = result.last {
                let lastEnd = last.location + last.length
                // Overlapping ranges merge, and so does a caret touching another selection.
                let overlaps = selection.location < lastEnd
                let caretTouches = selection.location == lastEnd && (selection.length == 0 || last.length == 0)
                if overlaps || caretTouches {
                    let end = max(lastEnd, selection.location + selection.length)
                    result[result.count - 1] = NSRange(location: last.location, length: end - last.location)
                    continue
                }
            }
            result.append(selection)
        }
        return result
    }

    // MARK: - Typing with several carets

    /// Replaces every selection with `text` and places a caret after each insertion.
    public static func insert(_ text: String, at selections: [NSRange]) -> EditResult {
        let normalized = normalizedSelections(selections)
        let insertedLength = (text as NSString).length
        var edits: [TextEdit] = []
        var newSelections: [NSRange] = []
        var delta = 0
        for selection in normalized {
            edits.append(TextEdit(range: selection, replacement: text))
            let caret = selection.location + delta + insertedLength
            newSelections.append(NSRange(location: caret, length: 0))
            delta += insertedLength - selection.length
        }
        return EditResult(edits: edits, selections: newSelections)
    }

    /// Deletes each selection, or the composed character before each caret.
    public static func deleteBackward(in string: NSString, selections: [NSRange]) -> EditResult {
        delete(in: string, selections: selections, forward: false)
    }

    /// Deletes each selection, or the composed character after each caret.
    public static func deleteForward(in string: NSString, selections: [NSRange]) -> EditResult {
        delete(in: string, selections: selections, forward: true)
    }

    private static func delete(in string: NSString, selections: [NSRange], forward: Bool) -> EditResult {
        var ranges: [NSRange] = []
        for selection in normalizedSelections(selections) {
            if selection.length > 0 {
                ranges.append(selection)
            } else if forward, selection.location < string.length {
                ranges.append(string.rangeOfComposedCharacterSequence(at: selection.location))
            } else if !forward, selection.location > 0 {
                ranges.append(string.rangeOfComposedCharacterSequence(at: selection.location - 1))
            } else {
                ranges.append(selection)
            }
        }
        let merged = normalizedSelections(ranges)
        var edits: [TextEdit] = []
        var newSelections: [NSRange] = []
        var delta = 0
        for range in merged {
            if range.length > 0 {
                edits.append(.delete(range))
            }
            newSelections.append(NSRange(location: range.location + delta, length: 0))
            delta -= range.length
        }
        return EditResult(edits: edits, selections: normalizedSelections(newSelections))
    }

    // MARK: - Select next occurrence (⌘D)

    /// VS Code's "add selection to next find match": with an empty primary selection, selects the word at the
    /// caret; otherwise adds the next occurrence of the selected text after the last selection, wrapping around.
    /// - Returns: The new selections, or the input unchanged when there is nothing more to add.
    public static func selectNextOccurrence(in string: NSString, selections: [NSRange]) -> [NSRange] {
        guard let last = selections.last else {
            return selections
        }
        let lines = TextLines(string)
        if last.length == 0 {
            guard let word = lines.wordRange(at: last.location) else {
                return selections
            }
            return Array(selections.dropLast()) + [word]
        }
        let needle = string.substring(with: last)
        let searchStart = last.location + last.length
        let existing = Set(selections.map { NSValue(range: $0) })
        var candidate = string.range(of: needle, options: [.literal], range: NSRange(location: searchStart, length: string.length - searchStart))
        if candidate.location == NSNotFound || existing.contains(NSValue(range: candidate)) {
            candidate = string.range(of: needle, options: [.literal], range: NSRange(location: 0, length: min(last.location + last.length, string.length)))
        }
        guard candidate.location != NSNotFound, !existing.contains(NSValue(range: candidate)) else {
            return selections
        }
        return selections + [candidate]
    }

    /// Every occurrence of the primary selection (or the word at the caret), for "select all occurrences".
    public static func selectAllOccurrences(in string: NSString, selection: NSRange) -> [NSRange] {
        let lines = TextLines(string)
        let target = selection.length > 0 ? selection : (lines.wordRange(at: selection.location) ?? selection)
        guard target.length > 0 else {
            return [selection]
        }
        let needle = string.substring(with: target)
        var results: [NSRange] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: needle, options: [.literal], range: searchRange)
            if found.location == NSNotFound {
                break
            }
            results.append(found)
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return results
    }

    // MARK: - Toggle comment (⌘/)

    /// Comments or uncomments the lines touched by the selections. Uses line comments when the language has
    /// them and wraps the lines in a block comment otherwise.
    public static func toggleComment(in string: NSString, selections: [NSRange], language: LemonLanguage, tabWidth: Int = 4) -> EditResult {
        if let prefix = language.lineCommentPrefix {
            return toggleLineComment(in: string, selections: selections, prefix: prefix, tabWidth: tabWidth)
        } else if let block = language.blockComment {
            return toggleBlockComment(in: string, selections: selections, start: block.start, end: block.end)
        }
        return EditResult(edits: [], selections: selections)
    }

    static func toggleLineComment(in string: NSString, selections: [NSRange], prefix: String, tabWidth: Int) -> EditResult {
        let lines = TextLines(string)
        var lineSet: [Int: NSRange] = [:]
        for selection in selections {
            for line in lines.lineRanges(coveredBy: selection) {
                lineSet[line.location] = line
            }
        }
        let allLines = lineSet.values.sorted { $0.location < $1.location }
        let contentLines = allLines.filter { !lines.isBlank($0) }
        let targetLines = contentLines.isEmpty ? allLines : contentLines
        guard !targetLines.isEmpty else {
            return EditResult(edits: [], selections: selections)
        }
        let prefixLength = (prefix as NSString).length
        let isCommented = !contentLines.isEmpty && contentLines.allSatisfy { line in
            let indentation = lines.indentationLength(of: line)
            let start = line.location + indentation
            let remaining = line.length - indentation
            return remaining >= prefixLength && string.substring(with: NSRange(location: start, length: prefixLength)) == prefix
        }
        var edits: [TextEdit] = []
        if isCommented {
            for line in contentLines {
                let indentation = lines.indentationLength(of: line)
                let start = line.location + indentation
                var length = prefixLength
                let afterPrefix = start + prefixLength
                if afterPrefix < line.location + line.length && string.character(at: afterPrefix) == 0x20 {
                    length += 1
                }
                edits.append(.delete(NSRange(location: start, length: length)))
            }
        } else {
            // Align the comment markers at the smallest indentation, like VS Code.
            let minimumIndentation = targetLines.map { lines.indentationLength(of: $0) }.min() ?? 0
            for line in targetLines {
                let column = min(minimumIndentation, line.length)
                edits.append(.insert(prefix + " ", at: line.location + column))
            }
        }
        let newSelections = selections.map { selection in
            mapSelection(selection, through: edits)
        }
        return EditResult(edits: edits, selections: newSelections)
    }

    static func toggleBlockComment(in string: NSString, selections: [NSRange], start: String, end: String) -> EditResult {
        let lines = TextLines(string)
        var edits: [TextEdit] = []
        for selection in normalizedSelections(selections) {
            let covered = lines.lineRanges(coveredBy: selection)
            guard let first = covered.first, let last = covered.last else {
                continue
            }
            let firstIndentation = lines.indentationLength(of: first)
            let contentStart = first.location + firstIndentation
            var contentEnd = last.location + last.length
            while contentEnd > contentStart, let scalar = Unicode.Scalar(string.character(at: contentEnd - 1)),
                  CharacterSet.whitespaces.contains(scalar) {
                contentEnd -= 1
            }
            let content = string.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
            if content.hasPrefix(start) && content.hasSuffix(end) && content.count >= start.count + end.count {
                var startLength = (start as NSString).length
                if contentStart + startLength < contentEnd && string.character(at: contentStart + startLength) == 0x20 {
                    startLength += 1
                }
                var endLength = (end as NSString).length
                let endLocation = contentEnd - endLength
                var endStart = endLocation
                if endStart - 1 >= contentStart + startLength && string.character(at: endStart - 1) == 0x20 {
                    endStart -= 1
                    endLength += 1
                }
                edits.append(.delete(NSRange(location: contentStart, length: startLength)))
                edits.append(.delete(NSRange(location: endStart, length: endLength)))
            } else {
                edits.append(.insert(start + " ", at: contentStart))
                edits.append(.insert(" " + end, at: contentEnd))
            }
        }
        let newSelections = selections.map { mapSelection($0, through: edits) }
        return EditResult(edits: edits.sorted { $0.range.location < $1.range.location }, selections: newSelections)
    }

    // MARK: - Indentation for several carets

    /// Indents the lines touched by the selections by one level.
    public static func indent(in string: NSString, selections: [NSRange], indentUnit: String) -> EditResult {
        let lines = TextLines(string)
        var starts = Set<Int>()
        for selection in selections {
            for line in lines.lineRanges(coveredBy: selection) where !(lines.isBlank(line) && selections.count > 1 && line.length == 0) {
                starts.insert(line.location)
            }
        }
        let edits = starts.sorted().map { TextEdit.insert(indentUnit, at: $0) }
        return EditResult(edits: edits, selections: selections.map { mapSelection($0, through: edits) })
    }

    /// Removes one level of indentation from the lines touched by the selections.
    public static func outdent(in string: NSString, selections: [NSRange], tabWidth: Int) -> EditResult {
        let lines = TextLines(string)
        var lineSet: [Int: NSRange] = [:]
        for selection in selections {
            for line in lines.lineRanges(coveredBy: selection) {
                lineSet[line.location] = line
            }
        }
        var edits: [TextEdit] = []
        for line in lineSet.values.sorted(by: { $0.location < $1.location }) {
            guard line.length > 0 else {
                continue
            }
            if string.character(at: line.location) == 0x09 {
                edits.append(.delete(NSRange(location: line.location, length: 1)))
                continue
            }
            var count = 0
            while count < tabWidth && count < line.length && string.character(at: line.location + count) == 0x20 {
                count += 1
            }
            if count > 0 {
                edits.append(.delete(NSRange(location: line.location, length: count)))
            }
        }
        return EditResult(edits: edits, selections: selections.map { mapSelection($0, through: edits) })
    }

    // MARK: - Helpers

    static func mapSelection(_ selection: NSRange, through edits: [TextEdit]) -> NSRange {
        let start = TextEdit.map(selection.location, through: edits, insertionsShiftLocation: selection.length == 0 ? true : false)
        let end = TextEdit.map(selection.location + selection.length, through: edits, insertionsShiftLocation: true)
        return NSRange(location: start, length: max(end - start, 0))
    }
}
