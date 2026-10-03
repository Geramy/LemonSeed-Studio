import XCTest
@testable import StudioCore

final class LineEditorTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testTypingAndSubmit() {
        var editor = LineEditor()
        XCTAssertEqual(editor.feed(bytes("ls")), [.redraw, .redraw])
        XCTAssertEqual(editor.line, "ls")
        XCTAssertEqual(editor.feed([0x0D]), [.submit("ls")])
        XCTAssertEqual(editor.line, "")
        XCTAssertEqual(editor.history, ["ls"])
    }

    func testUTF8AcrossFeeds() {
        var editor = LineEditor()
        let snowman = Array("☃".utf8)
        XCTAssertEqual(editor.feed(snowman.prefix(1)), [])
        XCTAssertEqual(editor.feed(snowman.dropFirst()), [.redraw])
        XCTAssertEqual(editor.line, "☃")
    }

    func testCursorMovementAndEditing() {
        var editor = LineEditor()
        _ = editor.feed(bytes("echo wrld"))
        _ = editor.feed(bytes("\u{1B}[D\u{1B}[D\u{1B}[D"))
        _ = editor.feed(bytes("o"))
        XCTAssertEqual(editor.line, "echo world")
        _ = editor.feed([0x01]) // ⌃A
        XCTAssertEqual(editor.cursor, 0)
        _ = editor.feed(bytes("\u{1B}[3~")) // Delete
        XCTAssertEqual(editor.line, "cho world")
        _ = editor.feed([0x05, 0x7F]) // ⌃E, Backspace
        XCTAssertEqual(editor.line, "cho worl")
        _ = editor.feed([0x17]) // ⌃W
        XCTAssertEqual(editor.line, "cho ")
        _ = editor.feed([0x15]) // ⌃U
        XCTAssertEqual(editor.line, "")
        XCTAssertEqual(editor.feed([0x7F]), [.bell])
    }

    func testWordMotion() {
        var editor = LineEditor()
        _ = editor.feed(bytes("cp alpha beta"))
        _ = editor.feed(bytes("\u{1B}b"))
        XCTAssertEqual(editor.cursor, 9)
        _ = editor.feed(bytes("\u{1B}[1;3D"))
        XCTAssertEqual(editor.cursor, 3)
        _ = editor.feed(bytes("\u{1B}f"))
        XCTAssertEqual(editor.cursor, 8)
    }

    func testHistoryNavigation() {
        var editor = LineEditor(history: ["first", "second"])
        _ = editor.feed(bytes("draft"))
        _ = editor.feed(bytes("\u{1B}[A"))
        XCTAssertEqual(editor.line, "second")
        _ = editor.feed(bytes("\u{1B}[A"))
        XCTAssertEqual(editor.line, "first")
        XCTAssertEqual(editor.feed(bytes("\u{1B}[A")), [.bell])
        _ = editor.feed(bytes("\u{1B}[B\u{1B}[B"))
        XCTAssertEqual(editor.line, "draft", "the draft comes back")
        _ = editor.feed([0x0D])
        _ = editor.feed([0x0D])
        XCTAssertEqual(editor.history, ["first", "second", "draft"], "blank lines are not recorded")
    }

    func testControlEvents() {
        var editor = LineEditor()
        XCTAssertEqual(editor.feed([0x04]), [.endOfInput])
        _ = editor.feed(bytes("abc"))
        XCTAssertEqual(editor.feed([0x03]), [.interrupt])
        XCTAssertEqual(editor.line, "")
        XCTAssertEqual(editor.feed([0x0C]), [.clearScreen])
        XCTAssertEqual(editor.feed([0x09]), [.complete])
    }

    func testCompletionHelpers() {
        var editor = LineEditor()
        _ = editor.feed(bytes("cat Sou"))
        XCTAssertEqual(editor.wordBeforeCursor.text, "Sou")
        XCTAssertFalse(editor.wordBeforeCursor.isCommand)
        editor.completeWord(with: "Sources/")
        XCTAssertEqual(editor.line, "cat Sources/")
        var command = LineEditor()
        _ = command.feed(bytes("mk"))
        XCTAssertTrue(command.wordBeforeCursor.isCommand)
        XCTAssertEqual(LineEditor.commonPrefix(["LinuxDriver", "LinuxModel", "LinuxViews"]), "Linux")
        XCTAssertEqual(LineEditor.commonPrefix([]), "")
    }

    func testRender() {
        var editor = LineEditor()
        _ = editor.feed(bytes("abcd\u{1B}[D\u{1B}[D"))
        XCTAssertEqual(editor.render(prompt: "$ "), "\r$ abcd\u{1B}[K\u{1B}[2D")
    }
}
