import Foundation

/// A small readline: it turns the bytes a terminal view sends (keys, UTF-8
/// text, escape sequences) into edits of one input line, keeps history, and
/// renders the line back as terminal output.
///
/// Supported keys: printable text, Return, Backspace, Delete, ←/→, Home/End,
/// ↑/↓ history, Tab (completion request), ⌃A ⌃E ⌃U ⌃K ⌃W ⌃L ⌃C ⌃D, and
/// ⌥←/⌥→ (or ESC b / ESC f) by word.
public struct LineEditor: Sendable {
    public enum Event: Equatable, Sendable {
        /// The line changed or the caret moved; redraw.
        case redraw
        case submit(String)
        case interrupt
        case clearScreen
        case complete
        /// ⌃D on an empty line.
        case endOfInput
        case bell
    }

    public private(set) var buffer: [Character] = []
    public private(set) var cursor = 0
    public private(set) var history: [String] = []
    private var historyIndex: Int?
    private var stash: [Character] = []
    private var pending: [UInt8] = []

    public init(history: [String] = []) {
        self.history = history
    }

    public var line: String { String(buffer) }

    // MARK: Input

    public mutating func feed<S: Sequence>(_ bytes: S) -> [Event] where S.Element == UInt8 {
        var events: [Event] = []
        for byte in bytes {
            pending.append(byte)
            if let event = consume() {
                events.append(event)
            }
        }
        return events
    }

    /// Tries to interpret `pending` as one complete key; returns its event,
    /// or nil when more bytes are needed (or the key was ignored).
    private mutating func consume() -> Event? {
        guard let first = pending.first else { return nil }
        if first == 0x1B {
            return consumeEscape()
        }
        if first < 0x20 || first == 0x7F {
            pending.removeAll()
            return control(first)
        }
        // UTF-8: wait for the whole scalar.
        let needed: Int
        switch first {
        case 0x00..<0x80: needed = 1
        case 0xC0..<0xE0: needed = 2
        case 0xE0..<0xF0: needed = 3
        case 0xF0..<0xF8: needed = 4
        default:
            pending.removeAll()
            return nil
        }
        guard pending.count >= needed else { return nil }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        insert(text)
        return .redraw
    }

    private mutating func consumeEscape() -> Event? {
        guard pending.count >= 2 else { return nil }
        let second = pending[1]
        if second == UInt8(ascii: "[") || second == UInt8(ascii: "O") {
            // CSI / SS3: parameters then a final byte in 0x40...0x7E.
            guard pending.count >= 3, let last = pending.last, (0x40...0x7E).contains(last) else {
                if pending.count > 16 { pending.removeAll() }
                return nil
            }
            let parameters = String(decoding: pending[2..<(pending.count - 1)], as: UTF8.self)
            pending.removeAll()
            return csi(final: last, parameters: parameters)
        }
        pending.removeAll()
        switch second {
        case UInt8(ascii: "b"): return moveWord(-1)
        case UInt8(ascii: "f"): return moveWord(1)
        case 0x7F: return deleteWordBackward()
        default: return nil
        }
    }

    private mutating func csi(final: UInt8, parameters: String) -> Event? {
        let modified = parameters.contains(";3") || parameters.contains(";5") || parameters.contains(";9")
        switch final {
        case UInt8(ascii: "A"): return historyStep(-1)
        case UInt8(ascii: "B"): return historyStep(1)
        case UInt8(ascii: "C"): return modified ? moveWord(1) : move(1)
        case UInt8(ascii: "D"): return modified ? moveWord(-1) : move(-1)
        case UInt8(ascii: "H"): return moveTo(0)
        case UInt8(ascii: "F"): return moveTo(buffer.count)
        case UInt8(ascii: "~"):
            switch parameters {
            case "3": return deleteForward()
            case "1", "7": return moveTo(0)
            case "4", "8": return moveTo(buffer.count)
            default: return nil
            }
        default: return nil
        }
    }

    private mutating func control(_ byte: UInt8) -> Event? {
        switch byte {
        case 0x0D, 0x0A:
            let submitted = line
            if !submitted.trimmingCharacters(in: .whitespaces).isEmpty, history.last != submitted {
                history.append(submitted)
            }
            buffer = []
            cursor = 0
            historyIndex = nil
            return .submit(submitted)
        case 0x7F, 0x08:
            guard cursor > 0 else { return .bell }
            buffer.remove(at: cursor - 1)
            cursor -= 1
            return .redraw
        case 0x03:
            buffer = []
            cursor = 0
            historyIndex = nil
            return .interrupt
        case 0x04:
            if buffer.isEmpty { return .endOfInput }
            return deleteForward()
        case 0x09: return .complete
        case 0x0C: return .clearScreen
        case 0x01: return moveTo(0)
        case 0x05: return moveTo(buffer.count)
        case 0x02: return move(-1)
        case 0x06: return move(1)
        case 0x10: return historyStep(-1)
        case 0x0E: return historyStep(1)
        case 0x15:
            buffer.removeFirst(cursor)
            cursor = 0
            return .redraw
        case 0x0B:
            buffer.removeLast(buffer.count - cursor)
            return .redraw
        case 0x17: return deleteWordBackward()
        default: return nil
        }
    }

    // MARK: Editing

    public mutating func insert(_ text: String) {
        let characters = Array(text.filter { $0 != "\r" && $0 != "\n" })
        buffer.insert(contentsOf: characters, at: cursor)
        cursor += characters.count
    }

    /// Replaces the whole line (used by history and tests).
    public mutating func setLine(_ text: String) {
        buffer = Array(text)
        cursor = buffer.count
    }

    private mutating func move(_ delta: Int) -> Event {
        let next = cursor + delta
        guard next >= 0, next <= buffer.count else { return .bell }
        cursor = next
        return .redraw
    }

    private mutating func moveTo(_ position: Int) -> Event {
        cursor = position
        return .redraw
    }

    private mutating func moveWord(_ direction: Int) -> Event {
        if direction < 0 {
            var i = cursor
            while i > 0, buffer[i - 1] == " " { i -= 1 }
            while i > 0, buffer[i - 1] != " " { i -= 1 }
            cursor = i
        } else {
            var i = cursor
            while i < buffer.count, buffer[i] == " " { i += 1 }
            while i < buffer.count, buffer[i] != " " { i += 1 }
            cursor = i
        }
        return .redraw
    }

    private mutating func deleteForward() -> Event {
        guard cursor < buffer.count else { return .bell }
        buffer.remove(at: cursor)
        return .redraw
    }

    private mutating func deleteWordBackward() -> Event {
        var start = cursor
        while start > 0, buffer[start - 1] == " " { start -= 1 }
        while start > 0, buffer[start - 1] != " " { start -= 1 }
        buffer.removeSubrange(start..<cursor)
        cursor = start
        return .redraw
    }

    private mutating func historyStep(_ delta: Int) -> Event {
        guard !history.isEmpty else { return .bell }
        if historyIndex == nil {
            guard delta < 0 else { return .bell }
            stash = buffer
            historyIndex = history.count
        }
        let next = historyIndex! + delta
        if next < 0 { return .bell }
        if next >= history.count {
            historyIndex = nil
            buffer = stash
        } else {
            historyIndex = next
            buffer = Array(history[next])
        }
        cursor = buffer.count
        return .redraw
    }

    // MARK: Completion

    /// The word under the caret (from the previous space to the caret) and
    /// whether it is the command word.
    public var wordBeforeCursor: (text: String, isCommand: Bool) {
        var start = cursor
        while start > 0, buffer[start - 1] != " " { start -= 1 }
        let isCommand = buffer[..<start].allSatisfy { $0 == " " }
        return (String(buffer[start..<cursor]), isCommand)
    }

    /// Applies a completion: replaces the word before the caret.
    public mutating func completeWord(with replacement: String) {
        var start = cursor
        while start > 0, buffer[start - 1] != " " { start -= 1 }
        buffer.replaceSubrange(start..<cursor, with: Array(replacement))
        cursor = start + replacement.count
    }

    /// The longest common prefix of `candidates`.
    public static func commonPrefix(_ candidates: [String]) -> String {
        guard var prefix = candidates.first else { return "" }
        for candidate in candidates.dropFirst() {
            while !candidate.hasPrefix(prefix) { prefix.removeLast() }
        }
        return prefix
    }

    // MARK: Rendering

    /// Terminal output that redraws the line: return to column 0, prompt,
    /// text, clear to end of line, then move the caret back into place.
    public func render(prompt: String) -> String {
        var output = "\r" + prompt + line + "\u{1B}[K"
        let back = buffer.count - cursor
        if back > 0 {
            output += "\u{1B}[\(back)D"
        }
        return output
    }
}
