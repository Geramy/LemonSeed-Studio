import Foundation

/// Line-based diff (Myers' O(ND) algorithm) with hunk grouping.
public enum LineDiff {
    public enum Op: Sendable, Hashable {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    /// A contiguous change: `oldLines` (at 0-based `oldStart`) replaced by
    /// `newLines` (at 0-based `newStart`), with surrounding context lines.
    public struct Hunk: Sendable, Hashable, Identifiable {
        /// Stable within one diff: the hunk's ordinal.
        public var id: Int
        public var oldStart: Int
        public var newStart: Int
        public var oldLines: [String]
        public var newLines: [String]
        public var contextBefore: [String]
        public var contextAfter: [String]

        public var header: String {
            let oldCount = contextBefore.count + oldLines.count + contextAfter.count
            let newCount = contextBefore.count + newLines.count + contextAfter.count
            let o = oldStart - contextBefore.count + (oldCount == 0 ? 0 : 1)
            let n = newStart - contextBefore.count + (newCount == 0 ? 0 : 1)
            return "@@ -\(o),\(oldCount) +\(n),\(newCount) @@"
        }

        public var additions: Int { newLines.count }
        public var deletions: Int { oldLines.count }
    }

    /// Splits text into lines without their terminators. A trailing newline
    /// does not produce an empty last line.
    public static func lines(_ text: String) -> [String] {
        var ls = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { ls.removeLast() }
        if text.isEmpty { return [] }
        return ls
    }

    public static func diff(_ a: [String], _ b: [String]) -> [Op] {
        // Trim the common prefix and suffix first: agent edits are local, so
        // this makes the quadratic worst case rare.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])
        var ops = a[..<prefix].map(Op.equal)
        ops += myers(midA, midB)
        ops += a[(a.count - suffix)...].map(Op.equal)
        return ops
    }

    static func myers(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return b.map(Op.insert) }
        if m == 0 { return a.map(Op.delete) }
        let max = n + m
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        outer: for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { trace.append(v); break outer }
            }
        }
        // Backtrack.
        var ops: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = v[offset + prevK]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                ops.append(.equal(a[x - 1])); x -= 1; y -= 1
            }
            if d > 0 {
                if x == prevX { ops.append(.insert(b[y - 1])); y -= 1 }
                else { ops.append(.delete(a[x - 1])); x -= 1 }
            }
        }
        while x > 0, y > 0 { ops.append(.equal(a[x - 1])); x -= 1; y -= 1 }
        return ops.reversed()
    }

    /// Groups an edit script into hunks with `context` lines around each.
    /// Changes closer than 2×context lines merge into one hunk.
    public static func hunks(old: String, new: String, context: Int = 3) -> [Hunk] {
        hunks(ops: diff(lines(old), lines(new)), context: context)
    }

    public static func hunks(ops: [Op], context: Int = 3) -> [Hunk] {
        // Raw change blocks first.
        struct Block { var oldStart: Int; var newStart: Int; var old: [String]; var new: [String]; var opIndex: Int; var opEnd: Int }
        var blocks: [Block] = []
        var oi = 0, ni = 0
        var i = 0
        while i < ops.count {
            if case .equal = ops[i] { oi += 1; ni += 1; i += 1; continue }
            var b = Block(oldStart: oi, newStart: ni, old: [], new: [], opIndex: i, opEnd: i)
            while i < ops.count {
                switch ops[i] {
                case .delete(let l): b.old.append(l); oi += 1
                case .insert(let l): b.new.append(l); ni += 1
                case .equal: break
                }
                if case .equal = ops[i] { break }
                i += 1
            }
            b.opEnd = i
            blocks.append(b)
        }
        // Old-side lines, for context.
        let oldLines: [String] = ops.compactMap {
            switch $0 { case .equal(let l), .delete(let l): l; case .insert: nil }
        }
        var hunks: [Hunk] = []
        for b in blocks {
            let before = Array(oldLines[max(0, b.oldStart - context)..<b.oldStart])
            let afterStart = b.oldStart + b.old.count
            let after = Array(oldLines[afterStart..<min(oldLines.count, afterStart + context)])
            hunks.append(Hunk(id: hunks.count, oldStart: b.oldStart, newStart: b.newStart,
                              oldLines: b.old, newLines: b.new, contextBefore: before, contextAfter: after))
        }
        return hunks
    }

    /// Rebuilds a file from `old` and `new`, taking each hunk's new side if
    /// it is accepted and its old side otherwise. This is how per-hunk review
    /// reverts: rejected hunks fall back to the checkpointed original.
    public static func merge(old: String, new: String, accepted: (Int) -> Bool) -> String {
        let a = lines(old), b = lines(new)
        let hs = hunks(ops: diff(a, b), context: 0)
        var out: [String] = []
        var oi = 0
        for h in hs {
            out += a[oi..<h.oldStart]
            out += accepted(h.id) ? h.newLines : h.oldLines
            oi = h.oldStart + h.oldLines.count
        }
        out += a[oi...]
        // Trailing newline: follow whichever side owns the end of the file.
        let lastHunkTouchesEnd = hs.last.map { $0.oldStart + $0.oldLines.count == a.count } ?? false
        let trailing: Bool
        if lastHunkTouchesEnd, let last = hs.last {
            trailing = accepted(last.id) ? (new.hasSuffix("\n") || new.isEmpty) : (old.hasSuffix("\n") || old.isEmpty)
        } else {
            trailing = old.hasSuffix("\n") || (old.isEmpty && new.hasSuffix("\n"))
        }
        if out.isEmpty { return "" }
        return out.joined(separator: "\n") + (trailing ? "\n" : "")
    }

    /// A unified diff, as `diff -u` prints it.
    public static func unified(old: String, new: String, oldName: String = "a", newName: String = "b",
                               context: Int = 3) -> String {
        let hs = hunks(old: old, new: new, context: context)
        guard !hs.isEmpty else { return "" }
        var s = "--- \(oldName)\n+++ \(newName)\n"
        for h in coalesce(hs, context: context) {
            s += h.header + "\n"
            for l in h.contextBefore { s += " \(l)\n" }
            for l in h.oldLines { s += "-\(l)\n" }
            for l in h.newLines { s += "+\(l)\n" }
            for l in h.contextAfter { s += " \(l)\n" }
        }
        return s
    }

    /// Merges hunks whose context overlaps (for display only; the merged
    /// hunk's old/new lines include the shared context between them).
    static func coalesce(_ hs: [Hunk], context: Int) -> [Hunk] {
        var out: [Hunk] = []
        for h in hs {
            if var last = out.last, h.oldStart - (last.oldStart + last.oldLines.count) <= 2 * context {
                let gapStart = last.oldStart + last.oldLines.count
                let gap = h.oldStart - gapStart
                let between = gap <= last.contextAfter.count
                    ? Array(last.contextAfter.prefix(gap))
                    : last.contextAfter + h.contextBefore.suffix(gap - last.contextAfter.count)
                last.oldLines += between + h.oldLines
                last.newLines += between + h.newLines
                last.contextAfter = h.contextAfter
                out[out.count - 1] = last
            } else {
                out.append(h)
            }
        }
        return out.enumerated().map { var h = $1; h.id = $0; return h }
    }
}
