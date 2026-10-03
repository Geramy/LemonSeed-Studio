import Foundation

/// One line of a .gitignore (or .ignore) file.
public struct IgnoreRule: Hashable, Sendable {
    /// Directory of the ignore file, relative to the walk root ("" at the root).
    public let base: String
    public let glob: Glob
    public let negated: Bool
    public let directoryOnly: Bool
    /// Contains a slash before its end, so it matches the path from `base`
    /// rather than a name at any depth.
    public let anchored: Bool

    /// Parses one line; nil for blanks and comments.
    public init?(line rawLine: String, base: String = "") {
        var line = Substring(rawLine)
        if line.hasSuffix("\r") { line = line.dropLast() }
        // Trailing spaces are ignored unless escaped.
        while line.hasSuffix(" "), !line.hasSuffix("\\ ") { line = line.dropLast() }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line = line.dropFirst()
        } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
            line = line.dropFirst()
        }
        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line = line.dropLast()
        }
        guard !line.isEmpty else { return nil }
        var anchored = line.dropLast().contains("/")
        if line.hasPrefix("/") {
            line = line.dropFirst()
            anchored = true
        }
        if line.hasPrefix("**/") {
            // "**/foo" matches "foo" at any depth: same as an unanchored name
            // when the rest has no slash.
            let rest = line.dropFirst(3)
            if !rest.contains("/") {
                line = rest
                anchored = false
            }
        }
        self.base = base
        self.glob = Glob(String(line))
        self.negated = negated
        self.directoryOnly = directoryOnly
        self.anchored = anchored
    }

    /// Whether the rule matches `path` (relative to the walk root).
    public func matches(path: String, name: String, isDirectory: Bool) -> Bool {
        if directoryOnly && !isDirectory { return false }
        var subject = Substring(path)
        if !base.isEmpty {
            guard path.hasPrefix(base + "/") else { return false }
            subject = path.dropFirst(base.count + 1)
        }
        return anchored ? glob.matches(String(subject)) : glob.matches(name)
    }
}

/// The ignore rules in effect for one directory: its own ignore files'
/// rules after its ancestors'. The last matching rule wins, so a later
/// `!pattern` re-includes.
public struct IgnoreRules: Sendable {
    public private(set) var rules: [IgnoreRule] = []

    public init(rules: [IgnoreRule] = []) {
        self.rules = rules
    }

    public init(text: String, base: String = "") {
        rules = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .compactMap { IgnoreRule(line: String($0), base: base) }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// These rules followed by `other`'s (deeper directories go last).
    public func appending(_ other: IgnoreRules) -> IgnoreRules {
        other.isEmpty ? self : IgnoreRules(rules: rules + other.rules)
    }

    public func isIgnored(path: String, isDirectory: Bool) -> Bool {
        guard !rules.isEmpty else { return false }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        for rule in rules.reversed() where rule.matches(path: path, name: name, isDirectory: isDirectory) {
            return !rule.negated
        }
        return false
    }

    /// Reads `.gitignore` and `.ignore` from `directory`.
    public static func load(from directory: URL, base: String) -> IgnoreRules {
        var result = IgnoreRules()
        for file in [".gitignore", ".ignore"] {
            let url = directory.appendingPathComponent(file)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                result = result.appending(IgnoreRules(text: text, base: base))
            }
        }
        return result
    }
}
