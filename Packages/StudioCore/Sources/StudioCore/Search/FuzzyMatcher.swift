import Foundation

/// Fuzzy matching for quick open and the command palette.
///
/// A candidate matches when the query's characters appear in it in order
/// (case-insensitively; spaces in the query are ignored). Among all such
/// alignments the matcher finds the best-scoring one with dynamic
/// programming, in the spirit of fzf's v2 algorithm:
///
/// - every matched character scores;
/// - characters at the start, after a path separator, after `_ - . space`,
///   or at a camelCase hump score a boundary bonus;
/// - runs of consecutive characters score more the longer they get;
/// - gaps cost a little, so tight matches win;
/// - matches inside the file name (after the last '/') score extra, and
///   shorter candidates win ties.
public struct FuzzyMatch: Hashable, Sendable {
    public var score: Int
    /// Character offsets in the candidate that matched.
    public var positions: [Int]

    public init(score: Int, positions: [Int]) {
        self.score = score
        self.positions = positions
    }
}

public struct FuzzyMatcher: Sendable {
    public let query: String
    private let needle: [Character]
    private let needleLower: [Character]

    // Scoring constants (fzf's, so rankings feel familiar).
    static let matchScore = 16
    static let gapStart = -3
    static let gapExtension = -1
    static let boundaryWhite = 10
    static let boundarySlash = 9
    static let boundary = 8
    static let boundaryCamel = 7
    static let consecutive = 4
    static let firstCharMultiplier = 2
    static let fileNameBonus = 4
    static let exactCaseBonus = 1

    public init(_ query: String) {
        self.query = query
        let chars = Array(query.filter { !$0.isWhitespace })
        needle = chars
        needleLower = chars.map(Self.fold)
    }

    public var isEmpty: Bool { needle.isEmpty }

    /// Case folding without allocating for ASCII, which is nearly every path.
    @inline(__always)
    static func fold(_ ch: Character) -> Character {
        if let ascii = ch.asciiValue {
            return ascii >= 65 && ascii <= 90 ? Character(Unicode.Scalar(ascii | 0x20)) : ch
        }
        let lower = ch.lowercased()
        return lower.count == 1 ? Character(lower) : ch
    }

    /// Quick subsequence test, no scoring.
    public func isSubsequence(of candidate: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var i = 0
        for ch in candidate where Self.fold(ch) == needleLower[i] {
            i += 1
            if i == needleLower.count { return true }
        }
        return false
    }

    /// Scores `candidate`, or nil when it does not match. An empty query
    /// matches everything with score 0.
    public func match(_ candidate: String) -> FuzzyMatch? {
        let n = needle.count
        guard n > 0 else { return FuzzyMatch(score: 0, positions: []) }
        let hay = Array(candidate)
        let m = hay.count
        guard m >= n, isSubsequence(of: candidate) else { return nil }
        let hayLower = hay.map(Self.fold)
        let lastSlash = hay.lastIndex(of: "/") ?? -1

        // Per-position boundary bonus, and the file-name bonus.
        var bonus = [Int](repeating: 0, count: m)
        var nameBonus = [Int](repeating: 0, count: m)
        for j in 0..<m {
            if j == 0 {
                bonus[j] = Self.boundaryWhite
            } else {
                let prev = hay[j - 1]
                let cur = hay[j]
                if prev == "/" {
                    bonus[j] = Self.boundarySlash
                } else if prev == " " {
                    bonus[j] = Self.boundaryWhite
                } else if prev == "_" || prev == "-" || prev == "." || !prev.isLetter && !prev.isNumber {
                    bonus[j] = (cur.isLetter || cur.isNumber) ? Self.boundary : 0
                } else if prev.isLowercase && cur.isUppercase {
                    bonus[j] = Self.boundaryCamel
                } else if !prev.isNumber && cur.isNumber {
                    bonus[j] = Self.boundaryCamel
                }
            }
            if j > lastSlash { nameBonus[j] = Self.fileNameBonus }
        }

        // DP over (needle index i, haystack index j):
        // matchAt: best score with needle[i] matched exactly at hay[j];
        // best: best score for needle[0...i] within hay[0...j];
        // runBonus: the bonus carried along a consecutive run (fzf's
        // "first bonus"), so a run that starts on a boundary keeps it.
        let negInf = Int.min / 4
        var matchAt = [Int](repeating: negInf, count: n * m)
        var best = [Int](repeating: negInf, count: n * m)
        var runBonus = [Int](repeating: 0, count: n * m)
        var bestFromMatch = [Bool](repeating: false, count: n * m)
        var fromRun = [Bool](repeating: false, count: n * m)

        for i in 0..<n {
            var lastWasMatch = false
            for j in i..<m {
                let idx = i * m + j
                if hayLower[j] == needleLower[i] {
                    let b = bonus[j]
                    let extra = nameBonus[j] + (hay[j] == needle[i] ? Self.exactCaseBonus : 0)
                    if i == 0 {
                        matchAt[idx] = Self.matchScore + b * Self.firstCharMultiplier + extra
                        runBonus[idx] = b
                    } else if j > 0 {
                        let diag = (i - 1) * m + (j - 1)
                        var viaRun = negInf
                        var carried = 0
                        if matchAt[diag] > negInf {
                            carried = b >= Self.boundary ? b : runBonus[diag]
                            viaRun = matchAt[diag] + Self.matchScore + max(b, carried, Self.consecutive) + extra
                        }
                        let viaGap = best[diag] > negInf ? best[diag] + Self.matchScore + b + extra : negInf
                        if viaRun > negInf, viaRun >= viaGap {
                            matchAt[idx] = viaRun
                            runBonus[idx] = carried
                            fromRun[idx] = true
                        } else if viaGap > negInf {
                            matchAt[idx] = viaGap
                            runBonus[idx] = b
                        }
                    }
                }
                let carried: Int
                if j > i, best[idx - 1] > negInf {
                    carried = best[idx - 1] + (lastWasMatch ? Self.gapStart : Self.gapExtension)
                } else {
                    carried = negInf
                }
                if matchAt[idx] > negInf, matchAt[idx] >= carried {
                    best[idx] = matchAt[idx]
                    bestFromMatch[idx] = true
                    lastWasMatch = true
                } else {
                    best[idx] = carried
                    lastWasMatch = false
                }
            }
        }

        let finalScore = best[(n - 1) * m + (m - 1)]
        guard finalScore > negInf else { return nil }

        // Backtrack.
        var positions = [Int](repeating: 0, count: n)
        var i = n - 1
        var j = m - 1
        var mustMatchHere = false
        while i >= 0, j >= 0 {
            let idx = i * m + j
            if mustMatchHere || bestFromMatch[idx] {
                positions[i] = j
                mustMatchHere = fromRun[idx]
                i -= 1
                j -= 1
            } else {
                j -= 1
            }
        }
        // Shorter candidates win ties.
        let lengthPenalty = m / 24
        return FuzzyMatch(score: finalScore - lengthPenalty, positions: positions)
    }

    /// Ranks `candidates`, best first, keeping at most `limit`.
    public func rank<C: Sequence>(_ candidates: C, limit: Int = 100, key: (C.Element) -> String) -> [(element: C.Element, match: FuzzyMatch)] {
        var scored: [(element: C.Element, match: FuzzyMatch)] = []
        for candidate in candidates {
            if let match = match(key(candidate)) { scored.append((candidate, match)) }
        }
        scored.sort { lhs, rhs in
            if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
            return key(lhs.element).count < key(rhs.element).count
        }
        return Array(scored.prefix(limit))
    }
}
