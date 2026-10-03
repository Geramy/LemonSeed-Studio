import Foundation

/// Glob patterns over '/'-separated relative paths.
///
/// Supports `*` and `?` (never crossing '/'), `**` (any number of whole
/// segments), character classes `[abc]`, `[a-z]`, `[!x]`, and brace
/// alternatives `{c,h,cpp}`. A pattern without '/' matches the file name at
/// any depth, as `rg --glob` and pi's find tool do.
public struct Glob: Sendable, Hashable {
    public let pattern: String
    private let alternatives: [[String]]
    private let basenameOnly: Bool

    public init(_ pattern: String) {
        self.pattern = pattern
        var p = pattern
        while p.hasPrefix("./") { p.removeFirst(2) }
        basenameOnly = !p.contains("/")
        alternatives = Self.expandBraces(p).map { $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init) }
    }

    public func matches(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if basenameOnly, let last = segments.last {
            return alternatives.contains { $0.count == 1 && Self.matchSegment(Array($0[0]), Array(last)) }
        }
        return alternatives.contains { Self.matchSegments($0[...], segments[...]) }
    }

    /// True when the string contains glob metacharacters.
    public static func isPattern(_ s: String) -> Bool {
        s.contains(where: { "*?[{".contains($0) })
    }

    // MARK: Implementation

    static func expandBraces(_ p: String) -> [String] {
        guard let open = p.firstIndex(of: "{") else { return [p] }
        var depth = 0
        var close: String.Index?
        var idx = open
        while idx < p.endIndex {
            if p[idx] == "{" { depth += 1 }
            if p[idx] == "}" { depth -= 1; if depth == 0 { close = idx; break } }
            idx = p.index(after: idx)
        }
        guard let close else { return [p] }
        let head = String(p[..<open])
        let tail = String(p[p.index(after: close)...])
        let inner = p[p.index(after: open)..<close]
        var parts: [String] = []
        var current = ""
        depth = 0
        for ch in inner {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
            if ch == ",", depth == 0 { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        return parts.flatMap { expandBraces(head + $0 + tail) }
    }

    private static func matchSegments(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let first = pattern.first else { return path.isEmpty }
        if first == "**" {
            let rest = pattern.dropFirst()
            var p = path
            while true {
                if matchSegments(rest, p) { return true }
                if p.isEmpty { return false }
                p = p.dropFirst()
            }
        }
        guard let seg = path.first, matchSegment(Array(first), Array(seg)) else { return false }
        return matchSegments(pattern.dropFirst(), path.dropFirst())
    }

    static func matchSegment(_ p: [Character], _ s: [Character]) -> Bool {
        var pi = 0, si = 0
        var starP = -1, starS = 0
        while si < s.count {
            if pi < p.count {
                switch p[pi] {
                case "*":
                    starP = pi; starS = si; pi += 1
                    continue
                case "?":
                    pi += 1; si += 1
                    continue
                case "[":
                    if let (ok, next) = matchClass(p, pi, s[si]) {
                        if ok { pi = next; si += 1; continue }
                    } else if s[si] == "[" {
                        pi += 1; si += 1; continue
                    }
                default:
                    if p[pi] == s[si] { pi += 1; si += 1; continue }
                }
            }
            if starP >= 0 {
                pi = starP + 1; starS += 1; si = starS
                continue
            }
            return false
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Matches `c` against the class starting at `p[i] == "["`. Returns nil
    /// for an unterminated class (then '[' is literal).
    private static func matchClass(_ p: [Character], _ i: Int, _ c: Character) -> (Bool, Int)? {
        var j = i + 1
        var negate = false
        if j < p.count, p[j] == "!" || p[j] == "^" { negate = true; j += 1 }
        var matched = false
        var first = true
        while j < p.count, p[j] != "]" || first {
            first = false
            if j + 2 < p.count, p[j + 1] == "-", p[j + 2] != "]" {
                if p[j] <= c && c <= p[j + 2] { matched = true }
                j += 3
            } else {
                if p[j] == c { matched = true }
                j += 1
            }
        }
        guard j < p.count else { return nil }
        return (matched != negate, j + 1)
    }
}
