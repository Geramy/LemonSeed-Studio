import Foundation
import UIKit
import Observation
@preconcurrency import SwiftTerm
import StudioCore
import StudioDesign

/// One terminal tab: a SwiftTerm view, a line editor, and an in-process
/// `BuiltinShell` rooted at the workspace. The session owns its terminal
/// view, so scrollback survives the panel being hidden and shown again.
@MainActor
@Observable
public final class ShellTerminalSession: TerminalSession {
    public let id = UUID()
    public private(set) var title: String
    public private(set) var workingDirectory: URL
    public private(set) var isRunning = false

    public let shell: BuiltinShell
    @ObservationIgnored private var editor = LineEditor()
    @ObservationIgnored private var promptPath = "~"
    @ObservationIgnored private var started = false
    @ObservationIgnored private var appliedStyle: String?
    @ObservationIgnored private weak var context: (any WorkspaceContext)?
    @ObservationIgnored public private(set) lazy var terminalView: TerminalView = makeTerminalView()

    public init(root: URL, workingDirectory: URL? = nil, context: (any WorkspaceContext)?) {
        self.shell = BuiltinShell(root: root, workingDirectory: workingDirectory)
        self.workingDirectory = workingDirectory ?? root
        self.title = "lsh"
        self.context = context
    }

    public func terminate() {
        terminalView.terminalDelegate = nil
        terminalView.removeFromSuperview()
    }

    // MARK: View

    private func makeTerminalView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 240))
        view.terminalDelegate = self
        view.optionAsMetaKey = true
        view.allowMouseReporting = false
        view.backgroundColor = .clear
        return view
    }

    /// Applies the theme and code font (only when they change, since
    /// SwiftTerm re-lays out on every font or palette change).
    public func apply(theme: Theme, font: CodeFont) {
        let key = "\(theme.id)|\(font.family.rawValue)|\(font.size)"
        guard key != appliedStyle else { return }
        appliedStyle = key
        let view = terminalView
        let palette = theme.terminal
        view.installColors(palette.ansi.map(Self.swiftTermColor))
        view.nativeForegroundColor = palette.foreground.uiColor
        view.nativeBackgroundColor = palette.background.uiColor
        view.caretColor = palette.caret.uiColor
        view.selectedTextBackgroundColor = palette.selection.uiColor
        view.keyboardAppearance = theme.appearance == .dark ? .dark : .light
        view.font = font.uiFont()
    }

    static func swiftTermColor(_ color: RGBA) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(color.red * 65535), green: UInt16(color.green * 65535), blue: UInt16(color.blue * 65535))
    }

    /// Prints the banner and first prompt, once.
    public func startIfNeeded() {
        guard !started else { return }
        started = true
        let name = context?.displayName ?? workingDirectory.lastPathComponent
        write("\u{1B}[1;33mLemonSeed\u{1B}[0m shell \u{1B}[2m· in-process, confined to \(name)\u{1B}[0m\r\n")
        write("\u{1B}[2mType \u{1B}[0m\u{1B}[1mhelp\u{1B}[0m\u{1B}[2m for the built-in commands.\u{1B}[0m\r\n\r\n")
        Task { await refreshPrompt() }
    }

    private func write(_ text: String) {
        terminalView.feed(text: text)
    }

    private var prompt: String {
        "\u{1B}[1m\(promptPath)\u{1B}[0m \u{1B}[33m❯\u{1B}[0m "
    }

    private func refreshPrompt() async {
        promptPath = await shell.promptPath
        workingDirectory = await shell.workingDirectory
        title = promptPath == "~" ? (context?.displayName ?? "lsh") : (promptPath as NSString).lastPathComponent
        write(editor.render(prompt: prompt))
    }

    // MARK: Input

    fileprivate func receive(_ bytes: ArraySlice<UInt8>) {
        guard !isRunning else { return }
        for event in editor.feed(bytes) {
            handle(event)
        }
    }

    private func handle(_ event: LineEditor.Event) {
        switch event {
        case .redraw:
            write(editor.render(prompt: prompt))
        case .submit(let line):
            write("\r\n")
            run(line)
        case .interrupt:
            write("^C\r\n")
            write(editor.render(prompt: prompt))
        case .clearScreen:
            write("\u{1B}[2J\u{1B}[3J\u{1B}[H")
            write(editor.render(prompt: prompt))
        case .complete:
            Task { await complete() }
        case .endOfInput, .bell:
            break
        }
    }

    /// Runs a line as if typed (used by "Run in Terminal" actions).
    public func send(line: String) {
        guard !isRunning else { return }
        editor.setLine(line)
        write(editor.render(prompt: prompt))
        handle(editor.feed([0x0D]).first ?? .redraw)
    }

    private func run(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            write(editor.render(prompt: prompt))
            return
        }
        isRunning = true
        let columns = max(20, terminalView.getTerminal().cols)
        Task {
            let output = await shell.run(line, columns: columns, isTerminal: true)
            if output.clearScreen { write("\u{1B}[2J\u{1B}[3J\u{1B}[H") }
            if !output.stdout.isEmpty { write(Self.crlf(output.stdout)) }
            if !output.stderr.isEmpty { write("\u{1B}[31m" + Self.crlf(output.stderr) + "\u{1B}[0m") }
            isRunning = false
            await refreshPrompt()
        }
    }

    static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    // MARK: Completion

    private func complete() async {
        let (word, isCommand) = editor.wordBeforeCursor
        var candidates: [String]
        if isCommand && !word.contains("/") {
            candidates = await shell.commandNames.filter { $0.hasPrefix(word) }.map { $0 + " " }
        } else {
            let cwd = await shell.workingDirectory
            let slash = word.lastIndex(of: "/")
            let directoryPart = slash.map { String(word[...$0]) } ?? ""
            let prefix = slash.map { String(word[word.index(after: $0)...]) } ?? word
            let base = directoryPart.hasPrefix("/") ? URL(fileURLWithPath: directoryPart)
                : cwd.appendingPathComponent(directoryPart)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            candidates = names
                .filter { $0.hasPrefix(prefix) && (prefix.hasPrefix(".") || !$0.hasPrefix(".")) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { name in
                    directoryPart + name + (FileOperations.isDirectory(base.appendingPathComponent(name)) ? "/" : " ")
                }
        }
        guard !candidates.isEmpty else { return }
        if candidates.count == 1 {
            editor.completeWord(with: candidates[0])
        } else {
            let common = LineEditor.commonPrefix(candidates)
            if common.count > word.count {
                editor.completeWord(with: common)
            } else {
                let shown = candidates.map { ($0 as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces) + ($0.hasSuffix("/") ? "/" : "") }
                write("\r\n" + Self.columns(shown, width: max(20, terminalView.getTerminal().cols)) + "\r\n")
            }
        }
        write(editor.render(prompt: prompt))
    }

    static func columns(_ items: [String], width: Int) -> String {
        let cell = (items.map(\.count).max() ?? 1) + 2
        let perRow = max(1, width / cell)
        var lines: [String] = []
        for start in stride(from: 0, to: items.count, by: perRow) {
            let row = items[start..<min(start + perRow, items.count)]
            lines.append(row.map { $0.padding(toLength: cell, withPad: " ", startingAt: 0) }.joined())
        }
        return lines.joined(separator: "\r\n")
    }
}

extension ShellTerminalSession: @preconcurrency TerminalViewDelegate {
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        receive(data)
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.scheme == "https" || url.scheme == "http" {
            UIApplication.shared.open(url)
        }
    }
    public func bell(source: TerminalView) {}
    public func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
    public func clipboardRead(source: TerminalView) -> Data? { nil }
    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
