import Foundation

/// The kind of a completion item, matching LSP `CompletionItemKind`.
public enum CompletionItemKind: Int, Sendable, CaseIterable, Codable {
    case text = 1, method, function, constructor, field, variable, `class`, interface, module, property, unit, value
    case `enum`, keyword, snippet, color, file, reference, folder, enumMember, constant, `struct`, event, `operator`
    case typeParameter

    /// SF Symbol shown in the completion list.
    public var symbolName: String {
        switch self {
        case .method, .function, .constructor: "f.cursive"
        case .field, .property: "p.square"
        case .variable, .value: "v.square"
        case .class, .struct: "c.square"
        case .interface: "i.square"
        case .module, .folder: "shippingbox"
        case .enum, .enumMember: "e.square"
        case .keyword: "k.square"
        case .snippet: "text.badge.plus"
        case .constant: "number.square"
        case .file: "doc"
        case .typeParameter: "t.square"
        case .operator: "plus.forwardslash.minus"
        case .text, .unit, .color, .reference, .event: "textformat"
        }
    }
}

/// One entry in the completion popup.
public struct CompletionItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var kind: CompletionItemKind
    /// Secondary text, e.g. a signature or type.
    public var detail: String?
    /// Inserted when the item is accepted; defaults to `label`.
    public var insertText: String
    /// Text the typed prefix is matched against; defaults to `label`.
    public var filterText: String
    /// Sort key; items sort by match quality first, then by this.
    public var sortText: String
    /// Replaces this range instead of the word before the caret, like an LSP `textEdit`.
    public var replacementRange: NSRange?

    public init(id: String = UUID().uuidString,
                label: String,
                kind: CompletionItemKind = .text,
                detail: String? = nil,
                insertText: String? = nil,
                filterText: String? = nil,
                sortText: String? = nil,
                replacementRange: NSRange? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.detail = detail
        self.insertText = insertText ?? label
        self.filterText = filterText ?? label
        self.sortText = sortText ?? label
        self.replacementRange = replacementRange
    }
}

/// What the editor knows when it asks for completions.
public struct CompletionContext: Sendable {
    public enum Trigger: Sendable, Equatable {
        /// The user asked explicitly (⌃Space or ⌥Esc).
        case invoked
        /// A character was typed.
        case character(String)
    }

    public var caret: Int
    /// The identifier being typed, ending at the caret.
    public var prefix: String
    public var prefixRange: NSRange
    public var line: Int
    public var column: Int
    public var language: LemonLanguage
    public var trigger: Trigger
}

/// Supplies completions, e.g. from clangd or the inline agent.
@MainActor
public protocol CompletionProvider: AnyObject {
    /// Characters that open the popup without an explicit request, e.g. `.` and `->`.
    var triggerCharacters: Set<String> { get }
    func completions(for context: CompletionContext) async -> [CompletionItem]
}

/// Ranks completion items against a typed prefix: exact prefix matches first, then camel-case and
/// subsequence matches. Case-insensitive.
public enum CompletionFilter {
    public static func filter(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        guard !prefix.isEmpty else {
            return items.sorted { $0.sortText < $1.sortText }
        }
        let scored = items.compactMap { item -> (CompletionItem, Int)? in
            guard let score = score(candidate: item.filterText, query: prefix) else {
                return nil
            }
            return (item, score)
        }
        return scored.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.sortText < rhs.0.sortText : lhs.1 > rhs.1
        }.map(\.0)
    }

    /// A match score, or nil when `query` is not a subsequence of `candidate`.
    public static func score(candidate: String, query: String) -> Int? {
        let candidateCharacters = Array(candidate)
        let lowerCandidate = candidateCharacters.map { Character($0.lowercased()) }
        let lowerQuery = Array(query.lowercased())
        if candidate.hasPrefix(query) {
            return 1000 - candidateCharacters.count
        }
        if candidate.lowercased().hasPrefix(query.lowercased()) {
            return 900 - candidateCharacters.count
        }
        var score = 0
        var queryIndex = 0
        var previousMatched = false
        for (index, character) in lowerCandidate.enumerated() where queryIndex < lowerQuery.count {
            if character == lowerQuery[queryIndex] {
                let original = candidateCharacters[index]
                let isWordStart = index == 0 || original.isUppercase || candidateCharacters[index - 1] == "_"
                score += isWordStart ? 30 : (previousMatched ? 15 : 5)
                queryIndex += 1
                previousMatched = true
            } else {
                previousMatched = false
            }
        }
        return queryIndex == lowerQuery.count ? score : nil
    }
}
