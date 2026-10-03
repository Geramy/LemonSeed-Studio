import Foundation
import Observation

/// One open text file. Every editor provider edits the same document
/// object, so the tab strip, status bar, Problems panel and agent all see
/// one source of truth for its text, dirty state, caret and diagnostics.
@MainActor
@Observable
public final class EditorDocument: Identifiable {
    public enum LoadState: Equatable, Sendable {
        case loading
        case loaded
        case binary(bytes: Int)
        case tooLarge(bytes: Int)
        case failed(String)
    }

    public enum LineEnding: String, Sendable {
        case lf = "\n"
        case crlf = "\r\n"

        public var label: String { self == .lf ? "LF" : "CRLF" }
    }

    /// Files above this size are not loaded into a String.
    public nonisolated static let maximumBytes = 64 * 1024 * 1024

    public let id = UUID()
    public private(set) var url: URL
    public private(set) var language: Language
    public private(set) var loadState: LoadState = .loading

    /// The text with line endings normalized to "\n".
    public private(set) var text: String = ""
    /// Increments on every edit; editors use it to skip redundant updates.
    public private(set) var revision = 0
    private var savedRevision = 0
    public var isDirty: Bool { revision != savedRevision }

    public private(set) var lineEnding: LineEnding = .lf
    public private(set) var encoding: String.Encoding = .utf8
    public private(set) var hasByteOrderMark = false
    public private(set) var lastSavedDate: Date?
    /// The file changed on disk while this document had unsaved edits.
    public private(set) var hasExternalChanges = false

    /// The caret, as the editor reports it.
    public var cursor: TextPosition = .start
    /// Length of the selection in characters (0 for a bare caret).
    public var selectionLength = 0
    /// A request for the editor to reveal a position and place the caret
    /// there. The editor clears it once handled.
    public var pendingReveal: TextPosition?

    private var diskModificationDate: Date?

    public init(url: URL) {
        self.url = url.standardizedFileURL
        self.language = Language.forFile(named: url.lastPathComponent)
    }

    public var name: String { url.lastPathComponent }

    public var lineCount: Int {
        text.utf8.reduce(into: 1) { count, byte in if byte == 0x0A { count += 1 } }
    }

    // MARK: Editing

    /// Replaces the text; editors call this as the user types.
    public func setText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        revision += 1
    }

    /// Replaces the text without marking the document dirty (for editors
    /// that normalize content on load, e.g. tabs to spaces).
    public func replaceTextPreservingSavedState(_ newText: String) {
        let wasClean = !isDirty
        setText(newText)
        if wasClean { savedRevision = revision }
    }

    // MARK: Disk

    public func load() async {
        loadState = .loading
        let url = url
        let result = await Task.detached(priority: .userInitiated) { () -> Result<DecodedFile, Error> in
            Result { try DecodedFile.read(url) }
        }.value
        apply(result)
    }

    private func apply(_ result: Result<DecodedFile, Error>) {
        switch result {
        case .success(let file):
            diskModificationDate = file.modificationDate
            switch file.content {
            case .text(let string, let ending, let encoding, let bom):
                text = string
                lineEnding = ending
                self.encoding = encoding
                hasByteOrderMark = bom
                revision += 1
                savedRevision = revision
                hasExternalChanges = false
                loadState = .loaded
            case .binary(let bytes):
                loadState = .binary(bytes: bytes)
            case .tooLarge(let bytes):
                loadState = .tooLarge(bytes: bytes)
            }
        case .failure(let error):
            loadState = .failed(error.localizedDescription)
        }
    }

    public func save() async throws {
        guard loadState == .loaded else { return }
        let output = lineEnding == .crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        guard var data = output.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if hasByteOrderMark, encoding == .utf8 {
            data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
        }
        let url = url
        let savingRevision = revision
        let date = try await Task.detached(priority: .userInitiated) { () -> Date? in
            try FileOperations.coordinatedWrite(data, to: url)
            return FileOperations.modificationDate(of: url)
        }.value
        savedRevision = savingRevision
        diskModificationDate = date
        lastSavedDate = Date()
        hasExternalChanges = false
    }

    /// Discards edits and reloads from disk.
    public func revert() async {
        await load()
    }

    /// Called when the file watcher reports a change. Reloads silently when
    /// there are no unsaved edits; otherwise flags the conflict.
    public func fileDidChangeOnDisk() async {
        let url = url
        let date = await Task.detached { FileOperations.modificationDate(of: url) }.value
        guard date != diskModificationDate else { return }
        if isDirty {
            hasExternalChanges = true
        } else {
            let cursor = cursor
            await load()
            self.cursor = cursor
        }
    }

    /// Follows a rename or move made in the file tree.
    public func didMove(to newURL: URL) {
        url = newURL.standardizedFileURL
        language = Language.forFile(named: newURL.lastPathComponent)
    }
}

/// A file read from disk and decoded.
struct DecodedFile: Sendable {
    enum Content: Sendable {
        case text(String, EditorDocument.LineEnding, String.Encoding, bom: Bool)
        case binary(Int)
        case tooLarge(Int)
    }

    var content: Content
    var modificationDate: Date?

    static func read(_ url: URL) throws -> DecodedFile {
        // FileManager rather than URL resource values: those are cached per
        // URL object and would hide external changes.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int) ?? 0
        let date = attributes[.modificationDate] as? Date
        if size > EditorDocument.maximumBytes {
            return DecodedFile(content: .tooLarge(size), modificationDate: date)
        }
        let data = try FileOperations.coordinatedRead(url)
        return DecodedFile(content: decode(data), modificationDate: date)
    }

    static func decode(_ data: Data) -> Content {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let string = String(data: data, encoding: .utf16) {
                return normalized(string, encoding: .utf16, bom: false)
            }
        }
        if FileSniffer.looksBinary(data) { return .binary(data.count) }
        var bytes = data
        var bom = false
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
            bom = true
        }
        if let string = String(data: bytes, encoding: .utf8) {
            return normalized(string, encoding: .utf8, bom: bom)
        }
        if let string = String(data: bytes, encoding: .windowsCP1252) {
            return normalized(string, encoding: .windowsCP1252, bom: false)
        }
        return .binary(data.count)
    }

    private static func normalized(_ string: String, encoding: String.Encoding, bom: Bool) -> Content {
        if string.contains("\r\n") {
            return .text(string.replacingOccurrences(of: "\r\n", with: "\n"), .crlf, encoding, bom: bom)
        }
        return .text(string, .lf, encoding, bom: bom)
    }
}

/// Binary detection, as Git and ripgrep do it: a NUL byte in the first 8 KB.
public enum FileSniffer {
    public static let sniffLength = 8192

    public static func looksBinary(_ data: Data) -> Bool {
        data.prefix(sniffLength).contains(0)
    }

    public static func looksBinary(_ buffer: UnsafeRawBufferPointer) -> Bool {
        let count = min(buffer.count, sniffLength)
        guard count > 0, let base = buffer.baseAddress else { return false }
        return memchr(base, 0, count) != nil
    }
}
