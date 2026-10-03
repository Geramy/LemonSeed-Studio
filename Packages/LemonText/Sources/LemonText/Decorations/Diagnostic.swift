import Foundation

/// Severity levels, matching LSP `DiagnosticSeverity`.
public enum DiagnosticSeverity: Int, Comparable, Sendable, CaseIterable, Codable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4

    /// Errors sort first.
    public static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A problem reported for a range of text, drawn as a squiggle with a gutter marker.
///
/// The shape follows LSP so a language server client can convert one to one; positions are UTF-16
/// offsets like LSP's default `positionEncoding`.
public struct Diagnostic: Hashable, Sendable, Identifiable {
    public var id: String
    public var range: NSRange
    public var severity: DiagnosticSeverity
    public var message: String
    /// The producer, e.g. "clangd" or "LemonSeed".
    public var source: String?
    public var code: String?

    public init(id: String = UUID().uuidString,
                range: NSRange,
                severity: DiagnosticSeverity,
                message: String,
                source: String? = nil,
                code: String? = nil) {
        self.id = id
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
        self.code = code
    }

    /// Creates a diagnostic from zero-based line and UTF-16 column positions, as LSP sends them.
    public init?(id: String = UUID().uuidString,
                 startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int,
                 in lineStarts: LineStartTable,
                 severity: DiagnosticSeverity,
                 message: String,
                 source: String? = nil,
                 code: String? = nil) {
        guard let start = lineStarts.offset(line: startLine, character: startCharacter),
              let end = lineStarts.offset(line: endLine, character: endCharacter), end >= start else {
            return nil
        }
        self.init(id: id, range: NSRange(location: start, length: end - start), severity: severity,
                  message: message, source: source, code: code)
    }
}

/// Line start offsets of a text, for converting line/column positions to offsets.
public struct LineStartTable: Sendable {
    public let starts: [Int]
    public let length: Int

    public init(_ string: NSString) {
        var starts = [0]
        let length = string.length
        let chunkSize = 16_384
        var buffer = [unichar](repeating: 0, count: chunkSize + 1)
        var location = 0
        var previousWasCarriageReturn = false
        while location < length {
            let chunkLength = min(chunkSize, length - location)
            string.getCharacters(&buffer, range: NSRange(location: location, length: chunkLength))
            for offset in 0 ..< chunkLength {
                let character = buffer[offset]
                if character == 0x0A {
                    if previousWasCarriageReturn {
                        // CRLF: the line start recorded after the CR moves past the LF.
                        starts[starts.count - 1] = location + offset + 1
                    } else {
                        starts.append(location + offset + 1)
                    }
                    previousWasCarriageReturn = false
                } else if character == 0x0D {
                    starts.append(location + offset + 1)
                    previousWasCarriageReturn = true
                } else {
                    previousWasCarriageReturn = false
                }
            }
            location += chunkLength
        }
        self.starts = starts
        self.length = length
    }

    public func offset(line: Int, character: Int) -> Int? {
        guard line >= 0 && line < starts.count && character >= 0 else {
            return nil
        }
        let lineEnd = line + 1 < starts.count ? starts[line + 1] : length
        return min(starts[line] + character, lineEnd)
    }

    public func line(containing offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}

/// A marker in the gutter for a line, e.g. a breakpoint, a Git change or a bookmark.
public struct GutterMarker: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// A dot in the given color.
        case dot
        /// A vertical bar at the gutter's trailing edge (Git added/modified).
        case bar
        /// A small triangle at the trailing edge (Git deleted lines below).
        case deletion
        /// An SF Symbol.
        case symbol(String)
    }

    public var id: String
    public var line: Int
    public var kind: Kind
    public var color: ThemeColor
    public var toolTip: String?

    public init(id: String = UUID().uuidString, line: Int, kind: Kind, color: ThemeColor, toolTip: String? = nil) {
        self.id = id
        self.line = line
        self.kind = kind
        self.color = color
        self.toolTip = toolTip
    }
}
