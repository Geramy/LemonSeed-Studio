import Foundation

/// The edit tool's matching and replacement rules, after pi's `edit-diff.ts`
/// (MIT, Mario Zechner):
///
/// - every `oldText` is matched against the original content, never against
///   the result of an earlier edit in the same call;
/// - an exact match is tried first; if any edit has none, matching retries in
///   a normalized space (trailing whitespace stripped, smart quotes, Unicode
///   dashes and special spaces folded to ASCII), and only the lines the edits
///   touch are rewritten so the rest of the file keeps its original bytes;
/// - each `oldText` must be non-empty, found, and unique; edits must not
///   overlap; the call must change something;
/// - line endings are matched as LF and restored to the file's style, and a
///   UTF-8 byte-order mark is kept.
///
/// All checks happen before anything is written, so a call is atomic.
public enum EditEngine {
    public struct Replacement: Sendable, Hashable {
        public var oldText: String
        public var newText: String
        public init(oldText: String, newText: String) {
            self.oldText = oldText
            self.newText = newText
        }
    }

    public enum Failure: Error, Hashable, Sendable, LocalizedError {
        case noEdits
        case emptyOldText(index: Int, total: Int)
        case notFound(index: Int, total: Int, candidates: [String])
        case ambiguous(index: Int, total: Int, occurrences: Int)
        case overlap(first: Int, second: Int)
        case noChange

        public var errorDescription: String? {
            func which(_ i: Int, _ n: Int) -> String { n == 1 ? "the text" : "edits[\(i)]" }
            switch self {
            case .noEdits:
                return "edits must contain at least one replacement."
            case .emptyOldText(let i, let n):
                return n == 1 ? "oldText must not be empty." : "edits[\(i)].oldText must not be empty."
            case .notFound(let i, let n, let candidates):
                var s = "Could not find \(which(i, n)). oldText must match the file exactly, including whitespace and newlines."
                if !candidates.isEmpty {
                    s += " The closest regions in the file are:\n\n" + candidates.joined(separator: "\n\n")
                        + "\n\nCopy the exact text from one of these (without the line numbers) and retry."
                }
                return s
            case .ambiguous(let i, let n, let count):
                return "Found \(count) occurrences of \(which(i, n)). Each oldText must be unique; include more surrounding lines."
            case .overlap(let a, let b):
                return "edits[\(a)] and edits[\(b)] overlap. Merge them into one edit."
            case .noChange:
                return "No changes made: the replacement produced identical content."
            }
        }
    }

    public struct Result: Sendable, Hashable {
        public var content: String
        public var usedFuzzyMatch: Bool
        /// 1-based first changed line in the new content.
        public var firstChangedLine: Int?
    }

    public static func apply(_ edits: [Replacement], to raw: String) throws -> Result {
        guard !edits.isEmpty else { throw Failure.noEdits }
        let (bom, body) = raw.hasPrefix("\u{FEFF}") ? ("\u{FEFF}", String(raw.dropFirst())) : ("", raw)
        let crlf = detectCRLF(body)
        let content = normalizeToLF(body)
        let normalized = edits.map { Replacement(oldText: normalizeToLF($0.oldText), newText: normalizeToLF($0.newText)) }

        for (i, e) in normalized.enumerated() where e.oldText.isEmpty {
            throw Failure.emptyOldText(index: i, total: edits.count)
        }

        let ns = content as NSString
        let needsFuzzy = normalized.contains { ns.range(of: $0.oldText, options: .literal).location == NSNotFound }
        let base = needsFuzzy ? fuzzyNormalize(content) : content
        let baseNS = base as NSString

        var matches: [(index: Int, range: NSRange, newText: String)] = []
        for (i, e) in normalized.enumerated() {
            let needle = needsFuzzy ? fuzzyNormalize(e.oldText) : e.oldText
            let r = baseNS.range(of: needle, options: .literal)
            guard r.location != NSNotFound else {
                throw Failure.notFound(index: i, total: edits.count, candidates: candidates(for: e.oldText, in: content))
            }
            let count = occurrences(of: needle, in: baseNS)
            if count > 1 { throw Failure.ambiguous(index: i, total: edits.count, occurrences: count) }
            matches.append((i, r, e.newText))
        }
        let sorted = matches.sorted { $0.range.location < $1.range.location }
        for (a, b) in zip(sorted, sorted.dropFirst()) where NSMaxRange(a.range) > b.range.location {
            throw Failure.overlap(first: min(a.index, b.index), second: max(a.index, b.index))
        }

        let replaced: String
        if needsFuzzy {
            replaced = try preservingUnchangedLines(original: content, base: base,
                                                    replacements: sorted.map { ($0.range, $0.newText) })
        } else {
            let m = NSMutableString(string: content)
            for r in sorted.reversed() { m.replaceCharacters(in: r.range, with: r.newText) }
            replaced = m as String
        }
        guard replaced != content else { throw Failure.noChange }

        let firstLine = firstDifferingLine(content, replaced)
        let restored = crlf ? replaced.replacingOccurrences(of: "\n", with: "\r\n") : replaced
        return Result(content: bom + restored, usedFuzzyMatch: needsFuzzy, firstChangedLine: firstLine)
    }

    // MARK: Helpers

    static func detectCRLF(_ s: String) -> Bool {
        guard let lf = s.utf8.firstIndex(of: 0x0A) else { return false }
        return lf > s.utf8.startIndex && s.utf8[s.utf8.index(before: lf)] == 0x0D
    }

    static func normalizeToLF(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// pi's fuzzy normalization. Never changes the number of lines.
    public static func fuzzyNormalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        let lines = s.precomposedStringWithCompatibilityMapping.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            if i > 0 { out += "\n" }
            var trimmed = Substring(line)
            while let last = trimmed.last, last == " " || last == "\t" || last.isWhitespace && last != "\n" {
                trimmed = trimmed.dropLast()
            }
            for ch in trimmed.unicodeScalars {
                switch ch.value {
                case 0x2018, 0x2019, 0x201A, 0x201B: out += "'"
                case 0x201C, 0x201D, 0x201E, 0x201F: out += "\""
                case 0x2010...0x2015, 0x2212: out += "-"
                case 0x00A0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000: out += " "
                default: out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }

    static func occurrences(of needle: String, in hay: NSString) -> Int {
        var count = 0
        var search = NSRange(location: 0, length: hay.length)
        while true {
            let r = hay.range(of: needle, options: .literal, range: search)
            if r.location == NSNotFound { break }
            count += 1
            let next = r.location + max(r.length, 1)
            if next >= hay.length { break }
            search = NSRange(location: next, length: hay.length - next)
        }
        return count
    }

    /// Rewrites only the lines the replacements touch (taken from the
    /// normalized base); every other line keeps the original's bytes.
    static func preservingUnchangedLines(original: String, base: String,
                                         replacements: [(NSRange, String)]) throws -> String {
        let origLines = original.components(separatedBy: "\n")
        let baseNS = base as NSString
        var spans: [NSRange] = []
        var start = 0
        for line in base.components(separatedBy: "\n") {
            let len = (line as NSString).length
            spans.append(NSRange(location: start, length: len))
            start += len + 1
        }
        guard spans.count == origLines.count else { throw Failure.noChange }

        func lineOf(_ loc: Int) -> Int {
            spans.lastIndex(where: { $0.location <= loc }) ?? 0
        }
        var groups: [(first: Int, last: Int, reps: [(NSRange, String)])] = []
        for (r, text) in replacements {
            let first = lineOf(r.location)
            let last = lineOf(max(r.location, NSMaxRange(r) - 1))
            if var g = groups.last, first <= g.last {
                g.last = max(g.last, last)
                g.reps.append((r, text))
                groups[groups.count - 1] = g
            } else {
                groups.append((first, last, [(r, text)]))
            }
        }
        var out: [String] = []
        var line = 0
        for g in groups {
            out += origLines[line..<g.first]
            let gStart = spans[g.first].location
            let gEnd = NSMaxRange(spans[g.last])
            let chunk = NSMutableString(string: baseNS.substring(with: NSRange(location: gStart, length: gEnd - gStart)))
            for (r, text) in g.reps.reversed() {
                chunk.replaceCharacters(in: NSRange(location: r.location - gStart, length: r.length), with: text)
            }
            out.append(chunk as String)
            line = g.last + 1
        }
        out += origLines[line...]
        return out.joined(separator: "\n")
    }

    static func firstDifferingLine(_ a: String, _ b: String) -> Int? {
        let la = a.components(separatedBy: "\n"), lb = b.components(separatedBy: "\n")
        for i in 0..<max(la.count, lb.count) where i >= la.count || i >= lb.count || la[i] != lb[i] {
            return i + 1
        }
        return nil
    }

    /// Up to three regions most similar to `oldText`, with line numbers,
    /// compared with whitespace collapsed.
    static func candidates(for oldText: String, in content: String, limit: Int = 3) -> [String] {
        let needleLines = oldText.components(separatedBy: "\n")
        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }
        let window = max(1, min(needleLines.count, 40))
        let target = collapse(oldText)
        guard !target.isEmpty else { return [] }
        let firstNeedle = collapse(needleLines.first(where: { !collapse($0).isEmpty }) ?? "")
        var scored: [(score: Double, start: Int)] = []
        for start in 0..<lines.count {
            // Cheap prefilter on the first non-blank line.
            if !firstNeedle.isEmpty, similarity(collapse(lines[start]), firstNeedle) < 0.5 { continue }
            let chunk = lines[start..<min(lines.count, start + window)].joined(separator: "\n")
            scored.append((similarity(collapse(chunk), target), start))
        }
        let best = scored.filter { $0.score >= 0.5 }.sorted { $0.score > $1.score }
        var chosen: [Int] = []
        for s in best where !chosen.contains(where: { abs($0 - s.start) < window }) {
            chosen.append(s.start)
            if chosen.count == limit { break }
        }
        return chosen.map { start in
            lines[start..<min(lines.count, start + window)].enumerated()
                .map { String(format: "%5d\t", start + $0.offset + 1) + $0.element }
                .joined(separator: "\n")
        }
    }

    static func collapse(_ s: String) -> String {
        fuzzyNormalize(s).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Dice coefficient over character bigrams.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count > 1, y.count > 1 else { return 0 }
        var bigrams: [UInt16: Int] = [:]
        for i in 0..<(x.count - 1) { bigrams[UInt16(x[i]) << 8 | UInt16(x[i + 1]), default: 0] += 1 }
        var common = 0
        for i in 0..<(y.count - 1) {
            let k = UInt16(y[i]) << 8 | UInt16(y[i + 1])
            if let c = bigrams[k], c > 0 { common += 1; bigrams[k] = c - 1 }
        }
        return 2.0 * Double(common) / Double(x.count + y.count - 2)
    }
}
