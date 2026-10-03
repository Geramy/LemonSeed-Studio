import Foundation
@testable import LemonText
import Testing

@Suite("Edit model")
struct EditModelTests {
    private func apply(_ result: EditResult, to text: String) -> String {
        TextEdit.apply(result.edits, to: text)
    }

    // MARK: TextEdit

    @Test func appliesEditsAgainstTheOriginalText() {
        let edits = [TextEdit.insert("X", at: 0), TextEdit(range: NSRange(location: 2, length: 1), replacement: "YY"), .delete(NSRange(location: 4, length: 2))]
        #expect(TextEdit.apply(edits, to: "abcdefg") == "XabYYdg")
    }

    @Test func mapsLocationsThroughEdits() {
        let edits = [TextEdit.insert("123", at: 2), TextEdit.delete(NSRange(location: 5, length: 2))]
        #expect(TextEdit.map(0, through: edits) == 0)
        #expect(TextEdit.map(2, through: edits) == 5)
        #expect(TextEdit.map(2, through: edits, insertionsShiftLocation: false) == 2)
        #expect(TextEdit.map(4, through: edits) == 7)
        #expect(TextEdit.map(6, through: edits) == 8) // inside the deleted range
        #expect(TextEdit.map(9, through: edits) == 10)
    }

    // MARK: Multiple carets

    @Test func normalizesSelections() {
        let input = [NSRange(location: 10, length: 0), NSRange(location: 2, length: 3), NSRange(location: 4, length: 2), NSRange(location: 10, length: 0), NSRange(location: 20, length: 1)]
        #expect(EditCommands.normalizedSelections(input) == [NSRange(location: 2, length: 4), NSRange(location: 10, length: 0), NSRange(location: 20, length: 1)])
    }

    @Test func typesAtEveryCaret() {
        let text = "a\nb\nc"
        let result = EditCommands.insert("!", at: [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0), NSRange(location: 5, length: 0)])
        #expect(apply(result, to: text) == "a!\nb!\nc!")
        #expect(result.selections == [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0), NSRange(location: 8, length: 0)])
    }

    @Test func typingReplacesSelections() {
        let text = "foo bar foo"
        let result = EditCommands.insert("baz", at: [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
        #expect(apply(result, to: text) == "baz bar baz")
        #expect(result.selections == [NSRange(location: 3, length: 0), NSRange(location: 11, length: 0)])
    }

    @Test func deletesBackwardAtEveryCaret() {
        let text = "ab\ncd\nef" as NSString
        let result = EditCommands.deleteBackward(in: text, selections: [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0), NSRange(location: 0, length: 0)])
        #expect(apply(result, to: text as String) == "a\nc\nef")
        #expect(result.selections == [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
    }

    @Test func deleteBackwardRemovesWholeComposedCharacters() {
        let text = "x🍋y" as NSString
        let result = EditCommands.deleteBackward(in: text, selections: [NSRange(location: 3, length: 0)])
        #expect(apply(result, to: text as String) == "xy")
        #expect(result.selections == [NSRange(location: 1, length: 0)])
    }

    @Test func deletesForward() {
        let text = "abc" as NSString
        let result = EditCommands.deleteForward(in: text, selections: [NSRange(location: 0, length: 0), NSRange(location: 3, length: 0)])
        #expect(apply(result, to: text as String) == "bc")
    }

    // MARK: Select next occurrence

    @Test func firstSelectNextSelectsTheWord() {
        let text = "let value = value + 1" as NSString
        let result = EditCommands.selectNextOccurrence(in: text, selections: [NSRange(location: 6, length: 0)])
        #expect(result == [NSRange(location: 4, length: 5)])
    }

    @Test func selectNextAddsOccurrencesAndWraps() {
        let text = "value = value + value" as NSString
        var selections = [NSRange(location: 8, length: 5)]
        selections = EditCommands.selectNextOccurrence(in: text, selections: selections)
        #expect(selections == [NSRange(location: 8, length: 5), NSRange(location: 16, length: 5)])
        selections = EditCommands.selectNextOccurrence(in: text, selections: selections)
        #expect(selections.last == NSRange(location: 0, length: 5))
        #expect(EditCommands.selectNextOccurrence(in: text, selections: selections) == selections)
    }

    @Test func selectAllOccurrences() {
        let text = "a b a c a" as NSString
        #expect(EditCommands.selectAllOccurrences(in: text, selection: NSRange(location: 0, length: 0)).count == 3)
    }

    // MARK: Toggle comment

    @Test func commentsLinesAtTheirCommonIndentation() {
        let text = "    int a;\n        int b;\n\n    int c;"
        let ns = text as NSString
        let result = EditCommands.toggleComment(in: ns, selections: [NSRange(location: 0, length: ns.length)], language: .c)
        #expect(apply(result, to: text) == "    // int a;\n    //     int b;\n\n    // int c;")
    }

    @Test func uncommentsWhenEveryLineIsCommented() {
        let text = "  // a\n  //b\n"
        let ns = text as NSString
        let result = EditCommands.toggleComment(in: ns, selections: [NSRange(location: 0, length: ns.length)], language: .swift)
        #expect(apply(result, to: text) == "  a\n  b\n")
    }

    @Test func mixedLinesAreCommented() {
        let text = "# a\nb"
        let ns = text as NSString
        let result = EditCommands.toggleComment(in: ns, selections: [NSRange(location: 0, length: ns.length)], language: .python)
        #expect(apply(result, to: text) == "# # a\n# b")
    }

    @Test func selectionEndingAtLineStartExcludesThatLine() {
        let text = "a\nb\nc"
        let ns = text as NSString
        let result = EditCommands.toggleComment(in: ns, selections: [NSRange(location: 0, length: 2)], language: .shell)
        #expect(apply(result, to: text) == "# a\nb\nc")
    }

    @Test func caretMovesWithTheComment() {
        let text = "x = 1"
        let result = EditCommands.toggleComment(in: text as NSString, selections: [NSRange(location: 2, length: 0)], language: .python)
        #expect(result.selections == [NSRange(location: 4, length: 0)])
    }

    @Test func blockCommentLanguagesWrapAndUnwrap() {
        let text = "  <div>hi</div>"
        let wrapped = EditCommands.toggleComment(in: text as NSString, selections: [NSRange(location: 3, length: 0)], language: .html)
        let wrappedText = apply(wrapped, to: text)
        #expect(wrappedText == "  <!-- <div>hi</div> -->")
        let unwrapped = EditCommands.toggleComment(in: wrappedText as NSString, selections: [NSRange(location: 5, length: 0)], language: .html)
        #expect(apply(unwrapped, to: wrappedText) == text)
    }

    // MARK: Indentation

    @Test func indentsAndOutdentsTouchedLines() {
        let text = "a\n  b\n\tc"
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let indented = EditCommands.indent(in: ns, selections: [all], indentUnit: "    ")
        #expect(apply(indented, to: text) == "    a\n      b\n    \tc")
        let outdented = EditCommands.outdent(in: ns, selections: [all], tabWidth: 4)
        #expect(apply(outdented, to: text) == "a\nb\nc")
    }
}

@Suite("Brackets, guides and folding")
struct StructureTests {
    @Test func matchesBracketsAroundTheCaret() {
        let text = "f(a[1], {b: (c)})" as NSString
        let matcher = BracketMatcher(pairs: LemonLanguage.javascript.bracketPairs)
        #expect(matcher.match(in: text, caret: 1) == BracketMatch(open: NSRange(location: 1, length: 1), close: NSRange(location: 16, length: 1)))
        #expect(matcher.match(in: text, caret: 16)?.open == NSRange(location: 1, length: 1))
        #expect(matcher.match(in: text, caret: 6)?.open == NSRange(location: 3, length: 1))
        #expect(matcher.match(in: "abc" as NSString, caret: 1) == nil)
        #expect(matcher.match(in: "(((" as NSString, caret: 0) == nil)
    }

    @Test func bracketMatchingSkipsExcludedLocations() {
        let text = "{ \"}\" }" as NSString
        let matcher = BracketMatcher(pairs: [BracketPair("{", "}")])
        let match = matcher.match(in: text, caret: 0) { $0 == 3 }
        #expect(match?.close == NSRange(location: 6, length: 1))
    }

    @Test func indentGuideLevelsBridgeBlankLines() {
        let levels = IndentGuides.levels(indentColumns: [0, 4, 8, nil, 8, nil, 4, 0], indentWidth: 4)
        #expect(levels == [0, 1, 2, 2, 2, 1, 1, 0])
    }

    @Test func activeIndentGuide() {
        let levels = [0, 1, 2, 2, 1, 0]
        let guide = IndentGuides.activeGuide(levels: levels, caretLine: 2)
        #expect(guide?.level == 2)
        #expect(guide?.lines == 2 ... 3)
        let header = IndentGuides.activeGuide(levels: levels, caretLine: 0)
        #expect(header?.level == 1)
        #expect(header?.lines == 1 ... 4)
    }

    @Test func bracketFoldingRanges() {
        let text = """
        int main(void) {
            if (x) {
                y();
            }
            /* a
               long
               comment */
            return "}{";
        }
        """ as NSString
        let ranges = FoldingRangeCalculator.ranges(in: text, language: .c)
        // The braces inside the string on line 7 are ignored.
        #expect(ranges == [FoldingRange(startLine: 0, endLine: 7), FoldingRange(startLine: 1, endLine: 2), FoldingRange(startLine: 4, endLine: 6)])
    }

    @Test func indentationFoldingRanges() {
        let text = """
        def f():
            a = 1

            if a:
                b()
        x = 2
        """ as NSString
        let ranges = FoldingRangeCalculator.ranges(in: text, language: .python)
        #expect(ranges == [FoldingRange(startLine: 0, endLine: 4), FoldingRange(startLine: 3, endLine: 4)])
    }

    @Test func foldingLargeFilesIsFast() {
        let function = "static int f(int a) {\n  if (a) {\n    return 1;\n  }\n  return 0;\n}\n"
        let text = String(repeating: function, count: 40_000) as NSString
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure {
            count = FoldingRangeCalculator.ranges(in: text, language: .c).count
        }
        #expect(count == 80_000)
        #expect(elapsed < .seconds(2))
    }

    @Test func foldStateTracksEdits() {
        var state = FoldState()
        state.fold(FoldingRange(startLine: 2, endLine: 5))
        state.fold(FoldingRange(startLine: 10, endLine: 20))
        state.fold(FoldingRange(startLine: 12, endLine: 14))
        #expect(state.hiddenLineRanges == [3 ... 5, 11 ... 20])
        #expect(state.fold(hiding: 13) == FoldingRange(startLine: 10, endLine: 20))
        // Two lines inserted at line 7 shift the later folds.
        state.applyEdit(editStartLine: 7, editEndLine: 7, lineDelta: 2)
        #expect(state.folded.map(\.startLine) == [2, 12, 14])
        // An edit inside a fold drops it.
        let dropped = state.applyEdit(editStartLine: 4, editEndLine: 4, lineDelta: 0)
        #expect(dropped == [FoldingRange(startLine: 2, endLine: 5)])
        #expect(state.unfold(startingAt: 14) == FoldingRange(startLine: 14, endLine: 16))
        #expect(state.unfoldAll(hiding: 13).count == 1)
        #expect(state.folded.isEmpty)
    }

    @Test func typingOnAFoldHeaderKeepsTheFold() {
        var state = FoldState()
        state.fold(FoldingRange(startLine: 3, endLine: 9))
        #expect(state.applyEdit(editStartLine: 3, editEndLine: 3, lineDelta: 0).isEmpty)
        #expect(state.isFolded(startingAt: 3))
    }
}

@Suite("Diagnostics and completion")
struct DiagnosticsAndCompletionTests {
    @Test func lineStartTableHandlesAllLineEndings() {
        let table = LineStartTable("a\nbb\r\nccc\rd" as NSString)
        #expect(table.starts == [0, 2, 6, 10])
        #expect(table.offset(line: 1, character: 1) == 3)
        #expect(table.offset(line: 2, character: 99) == 10)
        #expect(table.line(containing: 7) == 2)
        #expect(table.offset(line: 9, character: 0) == nil)
    }

    @Test func diagnosticsFromLSPPositions() throws {
        let text = "int main() {\n  retur 0;\n}\n" as NSString
        let diagnostic = try #require(Diagnostic(startLine: 1, startCharacter: 2, endLine: 1, endCharacter: 7, in: LineStartTable(text),
                                                 severity: .error, message: "use of undeclared identifier 'retur'", source: "clangd"))
        #expect(text.substring(with: diagnostic.range) == "retur")
        #expect(DiagnosticSeverity.error < .warning)
    }

    @Test func completionFilterRanksPrefixMatchesFirst() {
        let items = ["sqlite3_open", "sqlite3_close", "open_file", "SQLITE_OK", "sqlite3_open_v2"].map { CompletionItem(label: $0, kind: .function) }
        let ranked = CompletionFilter.filter(items, prefix: "sqlite3_op").map(\.label)
        #expect(ranked == ["sqlite3_open", "sqlite3_open_v2"])
        let fuzzy = CompletionFilter.filter(items, prefix: "sqo").map(\.label)
        #expect(fuzzy.first == "SQLITE_OK" || fuzzy.contains("sqlite3_open"))
        #expect(CompletionFilter.filter(items, prefix: "zzz").isEmpty)
    }
}
