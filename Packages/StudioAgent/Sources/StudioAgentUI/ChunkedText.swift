import Foundation

/// Text that grows at its end while it streams, kept as sealed chunks and an
/// open tail.
///
/// A streamed reply is appended to many times a second. As one `String`, every
/// append copied it and every update laid out, measured and counted all of it,
/// so an update cost what had streamed so far and a long reply slowed the
/// whole app down. Here an append touches only the tail; once the tail is
/// long enough it is sealed at a boundary into a chunk that never changes
/// again, so views draw sealed chunks once and redraw only the tail.
public struct ChunkedText: Sendable, Equatable {
    /// Where the tail may be sealed.
    public enum Boundary: Sendable, Equatable {
        /// After a line break (reasoning, tool output). A tail with no line
        /// break is sealed at its last space once it reaches `hardLimit`.
        case lines
        /// After a blank line outside a fenced code block, so each chunk is
        /// whole Markdown blocks that parse on their own.
        case markdownBlocks
    }

    /// A sealed piece; `id` is its position, stable while the text grows.
    public struct Chunk: Sendable, Equatable, Identifiable {
        public let id: Int
        public let text: String
    }

    public let boundary: Boundary
    public private(set) var chunks: [Chunk] = []
    public private(set) var tail = ""
    /// UTF-8 bytes in all of it, kept as it grows (String.count is O(n)).
    public private(set) var utf8Count = 0
    /// Chunks dropped from the front by `dropFront(keepingUTF8:)`.
    public private(set) var droppedUTF8 = 0

    /// The tail is sealed once it holds this many bytes and has a boundary.
    static let sealAt = 1024
    /// `.lines` only: a tail this long with no line break is sealed anyway.
    static let hardLimit = 4096

    public init(_ boundary: Boundary, _ text: String = "") {
        self.boundary = boundary
        if !text.isEmpty { append(text) }
    }

    public var isEmpty: Bool { utf8Count == 0 }

    /// All of it, as one string: O(n), for persistence and tests, not views.
    public var string: String { chunks.map(\.text).joined() + tail }

    public mutating func append(_ s: String) {
        guard !s.isEmpty else { return }
        tail += s
        utf8Count += s.utf8.count
        while tail.utf8.count >= Self.sealAt, let cut = sealPoint() {
            chunks.append(Chunk(id: (chunks.last?.id ?? -1) + 1, text: String(tail[..<cut])))
            tail = String(tail[cut...])
        }
    }

    /// Keeps about the last `bytes` (whole chunks plus the tail), for output
    /// that is shown only in part, such as a running command's.
    public mutating func dropFront(keepingUTF8 bytes: Int) {
        var kept = utf8Count
        var drop = 0
        while drop < chunks.count, kept - chunks[drop].text.utf8.count >= bytes {
            kept -= chunks[drop].text.utf8.count
            drop += 1
        }
        guard drop > 0 else { return }
        droppedUTF8 += utf8Count - kept
        utf8Count = kept
        chunks.removeFirst(drop)
    }

    /// Where to seal the tail: the first boundary at least `sealAt` bytes
    /// in, or nil to keep growing it. The first, not the last, so that the
    /// same text gives the same chunks however it arrived (streamed in pieces
    /// or set at once), and a finished message is not drawn again.
    private func sealPoint() -> String.Index? {
        let bytes = tail.utf8
        guard bytes.count >= Self.sealAt else { return nil }
        let from = bytes.index(bytes.startIndex, offsetBy: Self.sealAt - 1)
        switch boundary {
        case .lines:
            if let nl = bytes[from...].firstIndex(of: UInt8(ascii: "\n")) { return bytes.index(after: nl) }
            guard bytes.count >= Self.hardLimit else { return nil }
            if let space = bytes[from...].firstIndex(of: UInt8(ascii: " ")) { return bytes.index(after: space) }
            // No space either: cut on the first character boundary past the limit.
            var i = bytes.index(bytes.startIndex, offsetBy: Self.hardLimit)
            while String.Index(i, within: tail) == nil { i = bytes.index(after: i) }
            return i
        case .markdownBlocks:
            // The first blank line past `sealAt` at which no fence is open.
            var inFence = false
            var previousBlank = false
            var lineStart = bytes.startIndex
            while let nl = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = tail[lineStart..<nl].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("```") { inFence.toggle() }
                let blank = line.isEmpty
                let next = bytes.index(after: nl)
                if blank, !inFence, !previousBlank, lineStart != bytes.startIndex,
                   bytes.distance(from: bytes.startIndex, to: next) >= Self.sealAt {
                    return next
                }
                previousBlank = blank
                lineStart = next
            }
            return nil
        }
    }
}

import SwiftUI

/// One sealed chunk of plain text. Equatable, so a chunk that did not change
/// is neither evaluated nor laid out again while the tail grows.
struct PlainChunkView: View, Equatable {
    let text: String
    let font: Font
    let color: Color
    let lineSpacing: CGFloat

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.text == b.text && a.font == b.font && a.color == b.color && a.lineSpacing == b.lineSpacing
    }

    var body: some View {
        // A chunk sealed after a line break ends with it; the stack is the break.
        Text(text.hasSuffix("\n") ? String(text.dropLast()) : text)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Plain chunked text, top to bottom: the sealed chunks (all of them, or the
/// last `lastChunks`), then the tail. `lazy` lays out only what is on screen.
struct ChunkedTextView: View {
    let text: ChunkedText
    var lastChunks: Int?
    var lazy = false
    let font: Font
    let color: Color
    var lineSpacing: CGFloat = 2

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0) { rows }
        } else {
            VStack(alignment: .leading, spacing: 0) { rows }
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(shown) { chunk in
            PlainChunkView(text: chunk.text, font: font, color: color, lineSpacing: lineSpacing).equatable()
        }
        if !text.tail.isEmpty {
            PlainChunkView(text: text.tail, font: font, color: color, lineSpacing: lineSpacing)
        }
    }

    private var shown: ArraySlice<ChunkedText.Chunk> {
        guard let lastChunks else { return text.chunks[...] }
        return text.chunks.suffix(lastChunks)
    }
}
