import Foundation

/// Git-style glob matching over '/'-separated paths.
///
/// - `*` matches any run of characters except '/'.
/// - `?` matches one character except '/'.
/// - `[abc]`, `[a-z]`, `[!a-z]` / `[^a-z]` match one character from a class.
/// - `**/` matches zero or more whole directories; a trailing `/**` matches
///   everything inside; `**` elsewhere matches anything.
/// - `\x` matches `x` literally.
public struct Glob: Hashable, Sendable {
    public let pattern: String
    private let bytes: [UInt8]
    private let caseInsensitive: Bool

    public init(_ pattern: String, caseInsensitive: Bool = false) {
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
        self.bytes = Array((caseInsensitive ? pattern.lowercased() : pattern).utf8)
    }

    public func matches(_ path: String) -> Bool {
        let subject = Array((caseInsensitive ? path.lowercased() : path).utf8)
        return Glob.match(bytes, 0, subject, 0)
    }

    public func matches(_ path: [UInt8]) -> Bool {
        Glob.match(bytes, 0, path, 0)
    }

    /// True when the pattern has no wildcard characters.
    public var isLiteral: Bool {
        !bytes.contains { $0 == UInt8(ascii: "*") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "\\") }
    }

    private static let star = UInt8(ascii: "*")
    private static let question = UInt8(ascii: "?")
    private static let open = UInt8(ascii: "[")
    private static let close = UInt8(ascii: "]")
    private static let slash = UInt8(ascii: "/")
    private static let backslash = UInt8(ascii: "\\")

    static func match(_ p: [UInt8], _ pStart: Int, _ s: [UInt8], _ sStart: Int) -> Bool {
        var pi = pStart
        var si = sStart
        while pi < p.count {
            let c = p[pi]
            if c == star {
                if pi + 1 < p.count, p[pi + 1] == star {
                    let next = pi + 2
                    if next < p.count, p[next] == slash {
                        // "**/": zero or more directories.
                        let rest = next + 1
                        if match(p, rest, s, si) { return true }
                        var k = si
                        while k < s.count {
                            if s[k] == slash, match(p, rest, s, k + 1) { return true }
                            k += 1
                        }
                        return false
                    }
                    // "**" elsewhere matches anything, slashes included.
                    var k = si
                    while k <= s.count {
                        if match(p, next, s, k) { return true }
                        k += 1
                    }
                    return false
                }
                // "*": any run without a slash.
                let next = pi + 1
                var k = si
                while true {
                    if match(p, next, s, k) { return true }
                    if k == s.count || s[k] == slash { return false }
                    k += 1
                }
            } else if c == question {
                guard si < s.count, s[si] != slash else { return false }
                pi += 1
                si += 1
            } else if c == open, let (matched, end) = matchClass(p, pi, s, si) {
                guard matched else { return false }
                pi = end
                si += 1
            } else {
                var literal = c
                if c == backslash, pi + 1 < p.count {
                    pi += 1
                    literal = p[pi]
                }
                guard si < s.count, s[si] == literal else { return false }
                pi += 1
                si += 1
            }
        }
        return si == s.count
    }

    /// Matches a `[...]` class at p[start]. Returns nil when the bracket is
    /// unterminated (then '[' is literal), else whether s[si] matched and
    /// the index just past ']'.
    private static func matchClass(_ p: [UInt8], _ start: Int, _ s: [UInt8], _ si: Int) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count, p[i] == UInt8(ascii: "!") || p[i] == UInt8(ascii: "^") {
            negate = true
            i += 1
        }
        var found = false
        var first = true
        guard si < s.count else {
            // Still need the end index to report a clean failure.
            while i < p.count, p[i] != close || first { first = false; i += 1 }
            return i < p.count ? (false, i + 1) : nil
        }
        let ch = s[si]
        while i < p.count {
            var lo = p[i]
            if lo == close, !first { break }
            first = false
            if lo == backslash, i + 1 < p.count {
                i += 1
                lo = p[i]
            }
            if i + 2 < p.count, p[i + 1] == UInt8(ascii: "-"), p[i + 2] != close {
                let hi = p[i + 2]
                if lo <= ch && ch <= hi { found = true }
                i += 3
            } else {
                if lo == ch { found = true }
                i += 1
            }
        }
        guard i < p.count else { return nil }
        if ch == slash { return (false, i + 1) }
        return (found != negate, i + 1)
    }
}
