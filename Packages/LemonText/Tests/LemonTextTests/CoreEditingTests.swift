import Foundation
@testable import LemonText
@testable import LemonTextCore
import Testing
import UIKit

/// Tests of the engine's editing paths that the keyboard relies on.
@MainActor
@Suite("Core editing")
struct CoreEditingTests {
    private func makeTextView(_ text: String, language: LemonLanguage = .c) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        if let treeSitterLanguage = LanguageRegistry.shared.treeSitterLanguage(for: language) {
            textView.setState(TextViewState(text: text, language: treeSitterLanguage, languageProvider: LanguageRegistry.shared))
        } else {
            textView.setState(TextViewState(text: text))
        }
        textView.indentStrategy = .space(length: 4)
        return textView
    }

    @Test func deleteBackwardWithACollapsedSelectionDeletesThePreviousCharacter() {
        let textView = makeTextView("int x;")
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.deleteBackward()
        #expect(textView.text == "int ;")
        #expect(textView.selectedRange == NSRange(location: 4, length: 0))
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.deleteBackward()
        #expect(textView.text == "int ;")
    }

    @Test func deleteBackwardRemovesWholeComposedCharacters() {
        let textView = makeTextView("a🍋b")
        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.deleteBackward()
        #expect(textView.text == "ab")
    }

    @Test func returnKeepsIndentationWhenTheTreeIsIncomplete() {
        let textView = makeTextView("void f(void) {")
        textView.selectedRange = NSRange(location: 14, length: 0)
        textView.insertText("\n")
        #expect(textView.text == "void f(void) {\n    ")
        textView.insertText("g();")
        textView.insertText("\n")
        #expect(textView.text.hasSuffix("g();\n    "))
    }

    @Test func incrementalBatchReplaceIsOneUndoStep() {
        let textView = makeTextView("a = 1;\nb = 1;\n")
        let replacements = [BatchReplaceSet.Replacement(range: NSRange(location: 0, length: 1), text: "x"),
                            BatchReplaceSet.Replacement(range: NSRange(location: 7, length: 1), text: "y")]
        textView.replaceTextIncrementally(in: BatchReplaceSet(replacements: replacements), selectedRange: NSRange(location: 1, length: 0))
        #expect(textView.text == "x = 1;\ny = 1;\n")
        textView.undoManager?.undo()
        #expect(textView.text == "a = 1;\nb = 1;\n")
    }

    @Test func hiddenLinesTakeNoSpaceAndCanBeShownAgain() {
        let textView = makeTextView((1 ... 20).map { "line \($0)" }.joined(separator: "\n"), language: .plainText)
        let before = textView.verticalExtent(ofLine: 10)!.minY
        textView.setLinesHidden(true, in: 2 ... 5)
        #expect(textView.isLineHidden(3))
        #expect(textView.verticalExtent(ofLine: 4)!.height == 0)
        let lineHeight = textView.verticalExtent(ofLine: 1)!.height
        #expect(abs(textView.verticalExtent(ofLine: 10)!.minY - (before - 4 * lineHeight)) < 0.5)
        textView.showAllLines()
        #expect(!textView.isLineHidden(3))
    }

    /// Large documents parse edits in the background; the tree must catch up with the text.
    @Test func largeDocumentsReparseInTheBackground() async throws {
        let function = "static int f(int a) {\n    return a + 1;\n}\n"
        let text = String(repeating: function, count: 600_000 / function.utf16.count)
        let textView = makeTextView(text)
        let languageMode = try #require(textView.textInputView.languageMode as? TreeSitterInternalLanguageMode)
        #expect(textView.textLength * 2 >= 1_000_000)
        // Comment out the first function's body line.
        textView.selectedRange = NSRange(location: 22, length: 0)
        textView.insertText("/")
        textView.insertText("/")
        #expect(languageMode.hasPendingParse)
        let deadline = Date().addingTimeInterval(20)
        while languageMode.hasPendingParse && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!languageMode.hasPendingParse)
        let captures = textView.syntaxHighlightCaptures(in: NSRange(location: 26, length: 10))
        #expect(captures.contains { $0.name.hasPrefix("comment") }, "\(captures.map(\.name))")
    }
}
