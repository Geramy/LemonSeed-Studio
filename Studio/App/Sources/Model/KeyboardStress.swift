import SwiftUI
import UIKit
import StudioCore

/// Replays hardware-keyboard input inside the full shell, the way UIKit
/// delivers a Magic Keyboard's keys to the focused editor's UITextInput
/// (characters through `insertText`, Delete as "select the previous
/// character, `deleteBackward()`", arrows through `position(from:in:offset:)`,
/// held keys repeating every 33 ms), and checks the document after every
/// burst, through the same bridge saving uses.
///
/// Launch with `-StudioKeyboardStress YES`; the result is published as the
/// `stress.result` accessibility element ("done;failed=0;..." when every
/// case passed). XCUITest cannot hold Delete or Space on a simulator
/// without a hardware keyboard, which is why the replay runs in process.
@MainActor
@Observable
final class KeyboardStress {
    private(set) var status = "idle"
    private(set) var failures: [String] = []

    private let controller: WorkspaceController
    private var expected: [Character] = []
    private var caret = 0
    private var input: (UIResponder & UITextInput)?
    private var document: EditorDocument?

    init(controller: WorkspaceController) {
        self.controller = controller
    }

    func run() async {
        status = "running"
        do {
            try await prepare()
            try await runCases()
        } catch {
            failures.append("setup: \(error.localizedDescription)")
        }
        status = "done;failed=\(failures.count);cases=\(caseCount);" + failures.joined(separator: "|")
    }

    private var caseCount = 0

    // MARK: Setup

    private struct SetupError: LocalizedError {
        var errorDescription: String?
    }

    private func prepare() async throws {
        let url = controller.rootURL.appendingPathComponent("stress.txt")
        try? FileManager.default.removeItem(at: url)
        try Data().write(to: url)
        controller.open(url, preview: false)
        guard let document = controller.activeDocument else { throw SetupError(errorDescription: "no document") }
        self.document = document
        let id = TextInputCoordinator.editorID(for: document)
        for _ in 0..<200 where TextInputCoordinator.shared.targets[id] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Let the editor finish loading before focusing it.
        try await Task.sleep(for: .milliseconds(400))
        guard TextInputCoordinator.shared.focus(id: id) else { throw SetupError(errorDescription: "editor did not take focus") }
        try await Task.sleep(for: .milliseconds(200))
        guard let responder = UIResponder.currentFirstResponder as? (UIResponder & UITextInput) else {
            throw SetupError(errorDescription: "no UITextInput first responder")
        }
        input = responder
    }

    // MARK: Cases

    private func runCases() async throws {
        await check("type characters") { await self.type("hello world") }
        await check("held space") { await self.type(String(repeating: " ", count: 60)) }
        await check("held character") { await self.type(String(repeating: "x", count: 80)) }
        await check("held delete") { await self.delete(times: 70) }
        await check("return and type") {
            await self.type("\n")
            await self.type("second line")
        }
        await check("arrows then insert") {
            await self.arrowLeft(times: 5)
            await self.type("ZZ")
            await self.arrowRight(times: 5)
        }
        await check("delete across a line break") { await self.delete(times: 20) }
        await check("fast burst") { await self.type(String(repeating: "ab c", count: 50), interval: .milliseconds(4)) }
        await check("delete burst") { await self.delete(times: 120, interval: .milliseconds(4)) }
        await check("typing while the chrome changes") {
            let typing = Task { await self.type(String(repeating: "q ", count: 40)) }
            for _ in 0..<6 {
                self.controller.toggleSidebar()
                self.controller.togglePanel()
                try? await Task.sleep(for: .milliseconds(90))
            }
            await typing.value
        }
        await check("held space then delete") {
            await self.type(String(repeating: " ", count: 30))
            await self.delete(times: 30)
        }
    }

    private func check(_ name: String, _ body: () async -> Void) async {
        caseCount += 1
        await body()
        try? await Task.sleep(for: .milliseconds(150))
        let actual = document?.currentText ?? "<no document>"
        let wanted = String(expected)
        if actual != wanted {
            failures.append("\(name): expected \(wanted.count) chars, got \(actual.count) [\(String(actual.suffix(24)).debugDescription) vs \(String(wanted.suffix(24)).debugDescription)]")
            // Resynchronize so later cases are judged on their own.
            expected = Array(actual)
            caret = min(caret, expected.count)
        }
    }

    // MARK: Keys, as UIKit sends them

    private func type(_ text: String, interval: Duration = .milliseconds(33)) async {
        for character in text {
            input?.insertText(String(character))
            expected.insert(character, at: caret)
            caret += 1
            try? await Task.sleep(for: interval)
        }
    }

    private func delete(times: Int, interval: Duration = .milliseconds(33)) async {
        for _ in 0..<times {
            guard let input else { return }
            if let range = input.selectedTextRange, range.isEmpty,
               let previous = input.position(from: range.start, offset: -1),
               let selection = input.textRange(from: previous, to: range.start) {
                input.selectedTextRange = selection
            }
            input.deleteBackward()
            if caret > 0 {
                expected.remove(at: caret - 1)
                caret -= 1
            }
            try? await Task.sleep(for: interval)
        }
    }

    private func arrowLeft(times: Int) async { await move(-1, times: times) }
    private func arrowRight(times: Int) async { await move(1, times: times) }

    private func move(_ direction: Int, times: Int) async {
        for _ in 0..<times {
            guard let input, let range = input.selectedTextRange,
                  let target = input.position(from: direction < 0 ? range.start : range.end,
                                              in: direction < 0 ? .left : .right, offset: 1) else { continue }
            input.selectedTextRange = input.textRange(from: target, to: target)
            caret = min(max(0, caret + direction), expected.count)
            try? await Task.sleep(for: .milliseconds(33))
        }
    }
}

/// Shows the stress result for UI tests (tiny, at the bottom of the window).
struct KeyboardStressStatus: View {
    let stress: KeyboardStress

    var body: some View {
        Text(stress.status)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("stress.result")
            .accessibilityLabel(stress.status)
    }
}

/// The active document's text as an accessibility element, refreshed on
/// every edit (UI tests only: `-StudioExposeEditorText YES`).
struct EditorContentsProbe: View {
    let document: EditorDocument

    var body: some View {
        let _ = document.revision
        Text(document.currentText.isEmpty ? "<empty>" : document.currentText)
            .font(.system(size: 6))
            .lineLimit(1)
            .frame(height: 8)
            .accessibilityIdentifier("editor.contents")
    }
}
