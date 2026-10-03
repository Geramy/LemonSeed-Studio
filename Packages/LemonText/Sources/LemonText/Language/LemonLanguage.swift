import Foundation

/// A language LemonText can highlight. Plain text is the fallback for anything unrecognised.
public enum LemonLanguage: String, CaseIterable, Sendable, Codable, Identifiable {
    case c
    case cpp
    case objectiveC = "objc"
    case swift
    case python
    case javascript
    case typescript
    case tsx
    case rust
    case go
    case cmake
    case make
    case markdown
    case json
    case yaml
    case html
    case css
    case shell
    case plainText = "text"

    public var id: String { rawValue }

    /// Human-readable name, as shown in a status bar or language picker.
    public var displayName: String {
        switch self {
        case .c: "C"
        case .cpp: "C++"
        case .objectiveC: "Objective-C"
        case .swift: "Swift"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .tsx: "TypeScript JSX"
        case .rust: "Rust"
        case .go: "Go"
        case .cmake: "CMake"
        case .make: "Makefile"
        case .markdown: "Markdown"
        case .json: "JSON"
        case .yaml: "YAML"
        case .html: "HTML"
        case .css: "CSS"
        case .shell: "Shell"
        case .plainText: "Plain Text"
        }
    }

    /// Prefix used by "toggle line comment", or nil when the language only has block comments.
    public var lineCommentPrefix: String? {
        switch self {
        case .c, .cpp, .objectiveC, .swift, .javascript, .typescript, .tsx, .rust, .go, .json:
            "//"
        case .python, .cmake, .make, .yaml, .shell:
            "#"
        case .markdown, .html, .css, .plainText:
            nil
        }
    }

    /// Delimiters used by "toggle comment" when there is no line comment, and for folding block comments.
    public var blockComment: (start: String, end: String)? {
        switch self {
        case .c, .cpp, .objectiveC, .swift, .javascript, .typescript, .tsx, .rust, .go, .css:
            ("/*", "*/")
        case .html, .markdown:
            ("<!--", "-->")
        case .cmake:
            ("#[[", "]]")
        case .python, .make, .yaml, .shell, .json, .plainText:
            nil
        }
    }

    /// Bracket pairs that are auto-closed and matched in this language.
    public var bracketPairs: [BracketPair] {
        switch self {
        case .plainText:
            [BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}")]
        case .html:
            [BracketPair("<", ">"), BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}")]
        default:
            [BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}")]
        }
    }

    /// Quote characters that are auto-closed.
    public var quotePairs: [BracketPair] {
        switch self {
        case .plainText, .markdown:
            [BracketPair("\"", "\"")]
        case .rust:
            // A single quote starts a lifetime as often as a character literal.
            [BracketPair("\"", "\"")]
        case .javascript, .typescript, .tsx, .go, .shell, .python:
            [BracketPair("\"", "\""), BracketPair("'", "'"), BracketPair("`", "`")]
        default:
            [BracketPair("\"", "\""), BracketPair("'", "'")]
        }
    }

    /// Whether code in this language is conventionally indented with tabs.
    public var prefersTabs: Bool {
        self == .go || self == .make
    }
}

/// An opening and closing delimiter, such as `(` and `)`.
public struct BracketPair: Hashable, Sendable {
    public let open: String
    public let close: String

    public init(_ open: String, _ close: String) {
        self.open = open
        self.close = close
    }
}
