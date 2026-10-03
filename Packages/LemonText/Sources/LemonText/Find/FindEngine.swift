import Foundation

/// What to search for.
public struct FindQuery: Hashable, Sendable {
    public var text: String
    public var isRegularExpression: Bool
    public var isCaseSensitive: Bool
    public var matchesWholeWord: Bool
    /// Restricts the search to this range ("find in selection"); nil searches everything.
    public var range: NSRange?

    public init(_ text: String,
                isRegularExpression: Bool = false,
                isCaseSensitive: Bool = false,
                matchesWholeWord: Bool = false,
                range: NSRange? = nil) {
        self.text = text
        self.isRegularExpression = isRegularExpression
        self.isCaseSensitive = isCaseSensitive
        self.matchesWholeWord = matchesWholeWord
        self.range = range
    }
}

/// A match and its capture groups, in UTF-16 ranges.
public struct FindMatch: Hashable, Sendable {
    public let range: NSRange
    /// Ranges of capture groups 1...n. `NSNotFound` locations mark groups that did not participate.
    public let groupRanges: [NSRange]

    public init(range: NSRange, groupRanges: [NSRange] = []) {
        self.range = range
        self.groupRanges = groupRanges
    }
}

public enum FindError: Error, Equatable, Sendable {
    case invalidRegularExpression(String)
}

/// Find and replace over an `NSString`, independent of any view so it can run off the main thread.
///
/// Plain-text queries are escaped and run through the same regular expression engine, so whole-word
/// and case options behave identically in both modes.
public struct FindEngine: Sendable {
    public let query: FindQuery
    private let pattern: String
    private let options: NSRegularExpression.Options

    public init(query: FindQuery) {
        self.query = query
        var pattern = query.isRegularExpression ? query.text : NSRegularExpression.escapedPattern(for: query.text)
        if query.matchesWholeWord {
            pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])"
        }
        self.pattern = pattern
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.isCaseSensitive {
            options.insert(.caseInsensitive)
        }
        self.options = options
    }

    /// Compiles the query. Throws for an invalid regular expression so the find bar can show the error.
    public func makeRegularExpression() throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw FindError.invalidRegularExpression(Self.describeError(error))
        }
    }

    /// All matches, in document order. Empty matches (e.g. `^`) are skipped.
    /// - Parameter limit: Stops after this many matches, to bound work in huge files.
    public func matches(in string: NSString, limit: Int = .max) throws -> [FindMatch] {
        guard !query.text.isEmpty else {
            return []
        }
        let regex = try makeRegularExpression()
        let searchRange = clampedSearchRange(in: string)
        var results: [FindMatch] = []
        regex.enumerateMatches(in: string as String, options: [], range: searchRange) { result, _, stop in
            guard let result, result.range.length > 0 else {
                return
            }
            var groups: [NSRange] = []
            if result.numberOfRanges > 1 {
                for index in 1 ..< result.numberOfRanges {
                    groups.append(result.range(at: index))
                }
            }
            results.append(FindMatch(range: result.range, groupRanges: groups))
            if results.count >= limit {
                stop.pointee = true
            }
        }
        return results
    }

    /// The first match at or after `location`, wrapping to the start when `wraps` is set.
    public func nextMatch(in string: NSString, from location: Int, wraps: Bool = true) throws -> FindMatch? {
        let all = try matches(in: string)
        return Self.next(in: all, from: location, wraps: wraps)
    }

    /// The last match that starts before `location`, wrapping to the end when `wraps` is set.
    public func previousMatch(in string: NSString, before location: Int, wraps: Bool = true) throws -> FindMatch? {
        let all = try matches(in: string)
        return Self.previous(in: all, before: location, wraps: wraps)
    }

    static func next(in matches: [FindMatch], from location: Int, wraps: Bool) -> FindMatch? {
        if let match = matches.first(where: { $0.range.location >= location }) {
            return match
        }
        return wraps ? matches.first : nil
    }

    static func previous(in matches: [FindMatch], before location: Int, wraps: Bool) -> FindMatch? {
        if let match = matches.last(where: { $0.range.location < location }) {
            return match
        }
        return wraps ? matches.last : nil
    }

    /// The text that replaces `match`. For regular expressions, `$0`...`$99` and `${name}` refer to groups and
    /// `\n`, `\t` and `\\` are unescaped. Plain-text replacements are inserted literally.
    public func replacementText(for match: FindMatch, in string: NSString, template: String) throws -> String {
        guard query.isRegularExpression else {
            return template
        }
        let regex = try makeRegularExpression()
        guard let result = regex.firstMatch(in: string as String, options: [], range: match.range) else {
            return template
        }
        let expanded = regex.replacementString(for: result, in: string as String, offset: 0, template: Self.icuTemplate(template))
        return expanded
    }

    /// Replaces every match and returns the new text and the number of replacements.
    public func replaceAll(in string: NSString, template: String) throws -> (text: String, count: Int) {
        let edits = try replaceAllEdits(in: string, template: template)
        guard !edits.isEmpty else {
            return (string as String, 0)
        }
        let result = NSMutableString(string: string)
        for edit in edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return (result as String, edits.count)
    }

    /// The individual edits that "replace all" makes, in document order, so a view can apply them as one undo step.
    public func replaceAllEdits(in string: NSString, template: String) throws -> [TextEdit] {
        guard !query.text.isEmpty else {
            return []
        }
        let regex = try makeRegularExpression()
        let searchRange = clampedSearchRange(in: string)
        let icuTemplate = query.isRegularExpression ? Self.icuTemplate(template) : nil
        var edits: [TextEdit] = []
        regex.enumerateMatches(in: string as String, options: [], range: searchRange) { result, _, _ in
            guard let result, result.range.length > 0 else {
                return
            }
            let replacement: String
            if let icuTemplate {
                replacement = regex.replacementString(for: result, in: string as String, offset: 0, template: icuTemplate)
            } else {
                replacement = template
            }
            edits.append(TextEdit(range: result.range, replacement: replacement))
        }
        return edits
    }

    private func clampedSearchRange(in string: NSString) -> NSRange {
        let fullRange = NSRange(location: 0, length: string.length)
        guard let range = query.range else {
            return fullRange
        }
        return NSIntersectionRange(range, fullRange)
    }

    /// Converts the editor's replacement syntax to ICU's: `${name}` stays, `$n` stays, and the escapes
    /// `\n` and `\t` become real characters. ICU treats a backslash as an escape, which we keep.
    static func icuTemplate(_ template: String) -> String {
        var output = ""
        let characters = Array(template)
        var index = 0
        var escapeNextDigit = false
        // ICU understands `${name}` but not `${1}`; rewrite numbered groups to `$1`, escaping a following digit.
        func nextCharacter() -> Character? {
            guard index < characters.count else {
                return nil
            }
            defer { index += 1 }
            return characters[index]
        }
        while let character = nextCharacter() {
            if escapeNextDigit {
                escapeNextDigit = false
                if character.isASCII && character.isNumber {
                    output += "\\" + String(character)
                    continue
                }
            }
            if character == "$", index < characters.count, characters[index] == "{",
               let close = characters[index...].firstIndex(of: "}") {
                let name = String(characters[(index + 1) ..< close])
                if !name.isEmpty && name.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    output += "$" + name
                    index = close + 1
                    escapeNextDigit = true
                    continue
                }
            }
            if character == "\\" {
                guard let next = nextCharacter() else {
                    output += "\\\\"
                    break
                }
                switch next {
                case "n": output += "\n"
                case "t": output += "\t"
                case "r": output += "\r"
                case "\\": output += "\\\\"
                case "$": output += "\\$"
                default: output += "\\" + String(next)
                }
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        if let reason = nsError.userInfo["NSInvalidValue"] as? String {
            return "Invalid pattern: \(reason)"
        }
        return "Invalid regular expression"
    }
}
