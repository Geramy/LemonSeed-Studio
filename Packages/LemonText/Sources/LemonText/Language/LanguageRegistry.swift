import Foundation
import LemonTextCore
import TreeSitterBash
import TreeSitterBashQueries
import TreeSitterC
import TreeSitterCMake
import TreeSitterCPP
import TreeSitterCPPQueries
import TreeSitterCQueries
import TreeSitterCSS
import TreeSitterCSSQueries
import TreeSitterGo
import TreeSitterGoQueries
import TreeSitterHTML
import TreeSitterHTMLQueries
import TreeSitterJavaScript
import TreeSitterJavaScriptQueries
import TreeSitterJSON
import TreeSitterJSONQueries
import TreeSitterMake
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterMarkdownInlineQueries
import TreeSitterMarkdownQueries
import TreeSitterObjC
import TreeSitterPython
import TreeSitterPythonQueries
import TreeSitterRust
import TreeSitterRustQueries
import TreeSitterSwift
import TreeSitterSwiftQueries
import TreeSitterTSX
import TreeSitterTSXQueries
import TreeSitterTypeScript
import TreeSitterTypeScriptQueries
import TreeSitterYAML
import TreeSitterYAMLQueries

/// Builds and caches the tree-sitter grammars and queries for each ``LemonLanguage``.
///
/// Grammars are created lazily and are safe to request from any thread, so a document's
/// `TextViewState` can be prepared on a background queue.
public final class LanguageRegistry: TreeSitterLanguageProvider, @unchecked Sendable {
    public static let shared = LanguageRegistry()

    private let lock = NSLock()
    private var cache: [LemonLanguage: TreeSitterLanguage] = [:]
    private var injectionCache: [String: TreeSitterLanguage] = [:]

    public init() {}

    /// The tree-sitter language for `language`, or nil for plain text.
    public func treeSitterLanguage(for language: LemonLanguage) -> TreeSitterLanguage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language] {
            return cached
        }
        guard let created = Self.makeLanguage(language) else {
            return nil
        }
        cache[language] = created
        return created
    }

    /// Resolves languages named by injection queries, e.g. a fenced code block in Markdown or `<script>` in HTML.
    public func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
        let name = languageName.lowercased()
        if name == "markdown_inline" {
            lock.lock()
            defer { lock.unlock() }
            if let cached = injectionCache[name] {
                return cached
            }
            let inline = TreeSitterLanguage(
                tree_sitter_markdown_inline(),
                highlightsQuery: Self.query(TreeSitterMarkdownInlineQueries.Query.highlightsFileURL),
                injectionsQuery: Self.query(TreeSitterMarkdownInlineQueries.Query.injectionsFileURL))
            injectionCache[name] = inline
            return inline
        }
        guard let language = Self.language(forInjectionName: name) else {
            return nil
        }
        return treeSitterLanguage(for: language)
    }

    static func language(forInjectionName name: String) -> LemonLanguage? {
        switch name {
        case "c", "h": .c
        case "cpp", "c++", "cc", "cxx", "hpp": .cpp
        case "objc", "objective-c", "objectivec", "m", "mm": .objectiveC
        case "swift": .swift
        case "python", "py", "python3": .python
        case "javascript", "js", "jsx", "node", "mjs": .javascript
        case "typescript", "ts": .typescript
        case "tsx": .tsx
        case "rust", "rs": .rust
        case "go", "golang": .go
        case "cmake": .cmake
        case "make", "makefile": .make
        case "markdown", "md": .markdown
        case "json", "jsonc": .json
        case "yaml", "yml": .yaml
        case "html", "htm": .html
        case "css": .css
        case "bash", "sh", "shell", "zsh", "console": .shell
        default: nil
        }
    }

    // MARK: - Construction

    private static func makeLanguage(_ language: LemonLanguage) -> TreeSitterLanguage? {
        switch language {
        case .c:
            TreeSitterLanguage(tree_sitter_c(),
                               highlightsQuery: query(TreeSitterCQueries.Query.highlightsFileURL),
                               indentationScopes: IndentationScopes.c)
        case .cpp:
            TreeSitterLanguage(tree_sitter_cpp(),
                               highlightsQuery: query([TreeSitterCQueries.Query.highlightsFileURL,
                                                       TreeSitterCPPQueries.Query.highlightsFileURL]),
                               indentationScopes: IndentationScopes.cpp)
        case .objectiveC:
            TreeSitterLanguage(tree_sitter_objc(),
                               highlightsQuery: query([TreeSitterCQueries.Query.highlightsFileURL,
                                                       bundledQueryURL(language: "objc", name: "highlights")]),
                               indentationScopes: IndentationScopes.objectiveC)
        case .swift:
            TreeSitterLanguage(tree_sitter_swift(),
                               highlightsQuery: query(TreeSitterSwiftQueries.Query.highlightsFileURL),
                               indentationScopes: IndentationScopes.swift)
        case .python:
            TreeSitterLanguage(tree_sitter_python(),
                               highlightsQuery: query(TreeSitterPythonQueries.Query.highlightsFileURL),
                               indentationScopes: IndentationScopes.python)
        case .javascript:
            TreeSitterLanguage(tree_sitter_javascript(),
                               highlightsQuery: query([TreeSitterJavaScriptQueries.Query.highlightsFileURL,
                                                       TreeSitterJavaScriptQueries.Query.highlightsJSXFileURL]),
                               injectionsQuery: query(TreeSitterJavaScriptQueries.Query.injectionsFileURL),
                               indentationScopes: IndentationScopes.javaScript)
        case .typescript:
            TreeSitterLanguage(tree_sitter_typescript(),
                               highlightsQuery: query([TreeSitterJavaScriptQueries.Query.highlightsFileURL,
                                                       TreeSitterTypeScriptQueries.Query.highlightsFileURL]),
                               indentationScopes: IndentationScopes.javaScript)
        case .tsx:
            TreeSitterLanguage(tree_sitter_tsx(),
                               highlightsQuery: query([TreeSitterJavaScriptQueries.Query.highlightsFileURL,
                                                       TreeSitterJavaScriptQueries.Query.highlightsJSXFileURL,
                                                       TreeSitterTSXQueries.Query.highlightsFileURL]),
                               indentationScopes: IndentationScopes.javaScript)
        case .rust:
            TreeSitterLanguage(tree_sitter_rust(),
                               highlightsQuery: query(TreeSitterRustQueries.Query.highlightsFileURL),
                               injectionsQuery: query(TreeSitterRustQueries.Query.injectionsFileURL),
                               indentationScopes: IndentationScopes.rust)
        case .go:
            TreeSitterLanguage(tree_sitter_go(),
                               highlightsQuery: query(TreeSitterGoQueries.Query.highlightsFileURL),
                               indentationScopes: IndentationScopes.go)
        case .cmake:
            TreeSitterLanguage(tree_sitter_cmake(),
                               highlightsQuery: query(bundledQueryURL(language: "cmake", name: "highlights")),
                               indentationScopes: IndentationScopes.cmake)
        case .make:
            TreeSitterLanguage(tree_sitter_make(),
                               highlightsQuery: query(bundledQueryURL(language: "make", name: "highlights")))
        case .markdown:
            TreeSitterLanguage(tree_sitter_markdown(),
                               highlightsQuery: query(TreeSitterMarkdownQueries.Query.highlightsFileURL),
                               injectionsQuery: query(TreeSitterMarkdownQueries.Query.injectionsFileURL))
        case .json:
            TreeSitterLanguage(tree_sitter_json(),
                               highlightsQuery: query(TreeSitterJSONQueries.Query.highlightsFileURL),
                               indentationScopes: IndentationScopes.json)
        case .yaml:
            TreeSitterLanguage(tree_sitter_yaml(),
                               highlightsQuery: query(TreeSitterYAMLQueries.Query.highlightsFileURL))
        case .html:
            TreeSitterLanguage(tree_sitter_html(),
                               highlightsQuery: query(TreeSitterHTMLQueries.Query.highlightsFileURL),
                               injectionsQuery: query(TreeSitterHTMLQueries.Query.injectionsFileURL),
                               indentationScopes: IndentationScopes.html)
        case .css:
            TreeSitterLanguage(tree_sitter_css(),
                               highlightsQuery: query(TreeSitterCSSQueries.Query.highlightsFileURL),
                               indentationScopes: IndentationScopes.css)
        case .shell:
            TreeSitterLanguage(tree_sitter_bash(),
                               highlightsQuery: query(TreeSitterBashQueries.Query.highlightsFileURL),
                               indentationScopes: IndentationScopes.bash)
        case .plainText:
            nil
        }
    }

    static func bundledQueryURL(language: String, name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "scm", subdirectory: "Queries/\(language)") else {
            preconditionFailure("Missing bundled query \(language)/\(name).scm")
        }
        return url
    }

    private static func query(_ url: URL) -> TreeSitterLanguage.Query? {
        query([url])
    }

    /// Concatenates several query files. Later files can refine captures of earlier ones,
    /// which is how C++ builds on C and TypeScript on JavaScript.
    private static func query(_ urls: [URL]) -> TreeSitterLanguage.Query? {
        let source = urls
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        return source.isEmpty ? nil : TreeSitterLanguage.Query(string: source)
    }
}

/// Node types that open and close indentation scopes, used when inserting line breaks.
enum IndentationScopes {
    static var c: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["compound_statement", "field_declaration_list", "enumerator_list", "parameter_list", "initializer_list",
                     "argument_list", "case_statement"],
            outdent: ["}", ")"])
    }

    static var cpp: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["compound_statement", "field_declaration_list", "enumerator_list", "declaration_list", "parameter_list",
                     "initializer_list", "argument_list", "case_statement", "lambda_expression", "template_parameter_list"],
            outdent: ["}", ")", ">"])
    }

    static var objectiveC: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["compound_statement", "field_declaration_list", "enumerator_list", "parameter_list", "initializer_list",
                     "argument_list", "block_literal", "case_statement"],
            outdent: ["}", ")"])
    }

    static var swift: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["protocol_body", "class_body", "enum_class_body", "computed_property", "computed_getter", "computed_setter",
                     "function_body", "if_statement", "guard_statement", "lambda_literal", "array_literal",
                     "dictionary_literal", "switch_entry", "value_arguments", "statements"],
            outdent: ["else", "}", "]", ")"])
    }

    static var python: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["function_definition", "for_statement", "class_definition", "elif_clause", "else_clause",
                     "except_clause", "finally_clause", "while_statement", "if_statement", "try_statement", "with_statement",
                     "match_statement", "case_clause"],
            whitespaceDenotesBlocks: true)
    }

    static var javaScript: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["array", "object", "arguments", "statement_block", "class_body", "parenthesized_expression",
                     "jsx_element", "jsx_opening_element", "jsx_expression", "switch_body", "interface_body",
                     "object_type", "enum_body"],
            outdent: ["else", "}", "]", ")"])
    }

    static var rust: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["mod_item", "struct_item", "enum_item", "impl_item", "for_expression", "struct_expression",
                     "match_expression", "tuple_expression", "match_arm", "match_block", "if_let_expression",
                     "call_expression", "assignment_expression", "arguments", "block", "where_clause", "use_list",
                     "field_declaration_list", "enum_variant_list", "declaration_list"],
            outdent: ["}", ")", "]"])
    }

    static var go: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["block", "field_declaration_list", "interface_type", "literal_value", "argument_list",
                     "parameter_list", "expression_switch_statement", "type_switch_statement", "select_statement",
                     "import_spec_list", "const_declaration", "var_declaration"],
            outdent: ["}", ")"])
    }

    static var cmake: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["if_condition", "foreach_loop", "while_loop", "function_def", "macro_def", "block_def", "argument_list"],
            outdent: ["endif", "endforeach", "endwhile", "endfunction", "endmacro", "endblock", ")"])
    }

    static var json: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(indent: ["object", "array"], outdent: ["}", "]"])
    }

    static var html: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(indent: ["element"], outdent: ["end_tag"])
    }

    static var css: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(indent: ["block", "declaration_list"], outdent: ["}"])
    }

    static var bash: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: ["if_statement", "else", "while_statement", "for_statement", "function_definition", "do_group",
                     "case_statement", "compound_statement"],
            outdent: ["fi", "done", "esac", "}"])
    }
}
