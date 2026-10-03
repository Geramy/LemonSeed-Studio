import Foundation
import SwiftUI

/// A 1-based line and column in a text document. Columns count Unicode
/// scalars' grapheme clusters (Swift `Character`s), as editors display them.
public struct TextPosition: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int = 1) {
        self.line = max(1, line)
        self.column = max(1, column)
    }

    public static let start = TextPosition(line: 1, column: 1)

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }

    public var description: String { "Ln \(line), Col \(column)" }

    /// Parses "42", "42:7" or "42,7".
    public init?(parsing text: String) {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let line = Int(first), line > 0 else { return nil }
        let column = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        self.init(line: line, column: column)
    }
}

/// A diagnostic from any source: a compiler, a language server, a linter or
/// the agent.
public struct Diagnostic: Hashable, Sendable, Identifiable, Codable {
    public enum Severity: Int, Sendable, Codable, Comparable, CaseIterable {
        case error = 1, warning, info, hint

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: UUID
    public var url: URL
    public var range: ClosedRange<TextPosition>
    public var severity: Severity
    public var message: String
    /// Who produced it ("clang", "clangd", "build", ...).
    public var source: String
    public var code: String?

    public init(id: UUID = UUID(), url: URL, range: ClosedRange<TextPosition>, severity: Severity,
                message: String, source: String, code: String? = nil) {
        self.id = id
        self.url = url
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
        self.code = code
    }

    public init(url: URL, at position: TextPosition, severity: Severity, message: String, source: String) {
        self.init(url: url, range: position...position, severity: severity, message: message, source: source)
    }
}

/// A language, identified by the file's name. Identifiers follow VS Code /
/// LSP language IDs so they pass straight through to language servers.
public struct Language: Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let plainText = Language(id: "plaintext", name: "Plain Text")

    public static func forFile(named name: String) -> Language {
        let lower = name.lowercased()
        if let special = byName[lower] { return special }
        let ext = (lower as NSString).pathExtension
        return byExtension[ext] ?? .plainText
    }

    private static let byName: [String: Language] = [
        "makefile": Language(id: "makefile", name: "Makefile"),
        "gnumakefile": Language(id: "makefile", name: "Makefile"),
        "cmakelists.txt": Language(id: "cmake", name: "CMake"),
        "dockerfile": Language(id: "dockerfile", name: "Dockerfile"),
        ".gitignore": Language(id: "ignore", name: "Ignore"),
        ".gitmodules": Language(id: "properties", name: "Git Config"),
    ]

    private static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        func add(_ id: String, _ name: String, _ exts: [String]) {
            for ext in exts { map[ext] = Language(id: id, name: name) }
        }
        add("c", "C", ["c"])
        add("cpp", "C++", ["cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "inl", "ipp"])
        add("c", "C Header", ["h"])
        add("objective-c", "Objective-C", ["m"])
        add("objective-cpp", "Objective-C++", ["mm"])
        add("cpp", "IIG", ["iig"])
        add("swift", "Swift", ["swift"])
        add("rust", "Rust", ["rs"])
        add("python", "Python", ["py", "pyi"])
        add("javascript", "JavaScript", ["js", "mjs", "cjs"])
        add("typescript", "TypeScript", ["ts", "tsx"])
        add("go", "Go", ["go"])
        add("java", "Java", ["java"])
        add("loom", "Loom", ["loom"])
        add("opencl", "OpenCL C", ["cl"])
        add("hip", "HIP", ["hip", "cu"])
        add("metal", "Metal", ["metal"])
        add("glsl", "GLSL", ["glsl", "vert", "frag", "comp"])
        add("json", "JSON", ["json", "jsonc"])
        add("yaml", "YAML", ["yml", "yaml"])
        add("toml", "TOML", ["toml"])
        add("xml", "XML", ["xml", "plist", "entitlements", "svg"])
        add("markdown", "Markdown", ["md", "markdown"])
        add("restructuredtext", "reStructuredText", ["rst"])
        add("html", "HTML", ["html", "htm"])
        add("css", "CSS", ["css", "scss"])
        add("shellscript", "Shell", ["sh", "bash", "zsh", "command"])
        add("makefile", "Makefile", ["mk"])
        add("cmake", "CMake", ["cmake"])
        add("diff", "Diff", ["diff", "patch"])
        add("ini", "INI", ["ini", "cfg", "conf", "xcconfig"])
        add("plaintext", "Plain Text", ["txt", "text", "log"])
        return map
    }()
}

/// Editor options the user sets once; every editor provider honors them.
public struct EditorSettings: Hashable, Sendable, Codable {
    public var tabWidth: Int = 4
    public var insertSpaces: Bool = true
    public var wordWrap: Bool = false
    public var showLineNumbers: Bool = true
    public var showInvisibles: Bool = false
    public var showMinimap: Bool = true
    public var highlightCurrentLine: Bool = true
    public var ligatures: Bool = false
    public var autosave: Bool = true
    public var trimTrailingWhitespace: Bool = false

    public init() {}
}

public extension EnvironmentValues {
    @Entry var editorSettings: EditorSettings = EditorSettings()
}
