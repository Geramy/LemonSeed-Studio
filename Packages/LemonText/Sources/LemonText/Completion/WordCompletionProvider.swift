import Foundation

/// Completes language keywords and identifiers found near the caret. Used until a language server
/// is connected, and as a fallback when there is none.
@MainActor
public final class WordCompletionProvider: CompletionProvider {
    public var triggerCharacters: Set<String> = []
    /// Supplies the text around the caret to scan for identifiers.
    public var textProvider: (@MainActor (_ around: Int, _ radius: Int) -> String?)?

    public init() {}

    public func completions(for context: CompletionContext) async -> [CompletionItem] {
        let keywords = Self.keywords(for: context.language).map { CompletionItem(label: $0, kind: .keyword, sortText: "1\($0)") }
        guard let text = textProvider?(context.caret, 100_000) else {
            return keywords
        }
        let prefix = context.prefix
        let words = await Task.detached(priority: .userInitiated) {
            Self.identifiers(in: text, excluding: prefix)
        }.value
        let keywordSet = Set(keywords.map(\.label))
        let identifiers = words.filter { !keywordSet.contains($0) }.map { CompletionItem(label: $0, kind: .text, sortText: "2\($0)") }
        return keywords + identifiers
    }

    nonisolated static func identifiers(in text: String, excluding prefix: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var current = ""
        func flush() {
            if current.count >= 3, current != prefix, !(current.first?.isNumber ?? true), seen.insert(current).inserted {
                result.append(current)
            }
            current = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else if !current.isEmpty {
                flush()
            }
            if result.count >= 5_000 {
                break
            }
        }
        flush()
        return result
    }

    static func keywords(for language: LemonLanguage) -> [String] {
        switch language {
        case .c:
            ["auto", "break", "case", "char", "const", "continue", "default", "define", "do", "double", "else", "enum", "extern",
             "float", "for", "goto", "if", "include", "inline", "int", "long", "register", "restrict", "return", "short",
             "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while"]
        case .cpp:
            keywords(for: .c) + ["alignas", "auto", "bool", "catch", "class", "concept", "consteval", "constexpr", "constinit",
                                 "co_await", "co_return", "co_yield", "decltype", "delete", "explicit", "false", "friend",
                                 "mutable", "namespace", "new", "noexcept", "nullptr", "operator", "override", "private",
                                 "protected", "public", "requires", "static_assert", "template", "this", "throw", "true",
                                 "try", "typename", "using", "virtual"]
        case .objectiveC:
            keywords(for: .c) + ["@interface", "@implementation", "@end", "@property", "@protocol", "@selector", "@synthesize",
                                 "nil", "self", "super", "YES", "NO", "nonatomic", "strong", "weak", "copy", "instancetype"]
        case .swift:
            ["actor", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer",
             "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if",
             "import", "in", "init", "inout", "internal", "let", "nil", "nonisolated", "open", "private", "protocol", "public",
             "repeat", "return", "self", "Self", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
             "try", "typealias", "var", "where", "while"]
        case .python:
            ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
             "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
             "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
        case .javascript, .typescript, .tsx:
            ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else",
             "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new",
             "null", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
             "void", "while", "yield"] + (language == .javascript ? [] : ["interface", "type", "enum", "implements", "readonly",
                                                                          "private", "public", "protected", "keyof", "never", "unknown"])
        case .rust:
            ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for",
             "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
             "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        case .go:
            ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go",
             "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
        case .cmake:
            ["add_executable", "add_library", "add_subdirectory", "cmake_minimum_required", "else", "endif", "endforeach",
             "endfunction", "find_package", "foreach", "function", "if", "include", "install", "message", "option", "project",
             "set", "target_compile_definitions", "target_compile_options", "target_include_directories",
             "target_link_libraries", "target_sources"]
        case .shell:
            ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly",
             "return", "then", "until", "while"]
        default:
            []
        }
    }
}
