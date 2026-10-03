import Foundation

/// A workspace text search, with ripgrep's defaults: ignore files are
/// honored, binary files are skipped, and case is "smart" (insensitive
/// unless the pattern has an uppercase letter).
public struct SearchQuery: Hashable, Sendable {
    public enum CaseSensitivity: String, Hashable, Sendable, CaseIterable {
        case smart, sensitive, insensitive
    }

    public var pattern: String
    public var isRegex: Bool
    public var caseSensitivity: CaseSensitivity
    public var wholeWord: Bool
    /// Globs a file's relative path (or name) must match; empty means all.
    public var includeGlobs: [String]
    /// Globs that exclude files, in addition to ignore files.
    public var excludeGlobs: [String]
    public var maxMatchesPerFile: Int
    public var maxTotalMatches: Int
    public var maxFileBytes: Int

    public init(_ pattern: String, isRegex: Bool = false, caseSensitivity: CaseSensitivity = .smart,
                wholeWord: Bool = false, includeGlobs: [String] = [], excludeGlobs: [String] = [],
                maxMatchesPerFile: Int = 2_000, maxTotalMatches: Int = 20_000, maxFileBytes: Int = 16 * 1024 * 1024) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitivity = caseSensitivity
        self.wholeWord = wholeWord
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.maxMatchesPerFile = maxMatchesPerFile
        self.maxTotalMatches = maxTotalMatches
        self.maxFileBytes = maxFileBytes
    }

    public var isCaseInsensitive: Bool {
        switch caseSensitivity {
        case .sensitive: false
        case .insensitive: true
        case .smart: !pattern.contains { $0.isUppercase }
        }
    }

    /// Parses a comma-separated glob list as typed in the search sidebar.
    public static func globs(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// One match within a file.
public struct SearchMatch: Hashable, Sendable {
    /// 1-based line number.
    public var line: Int
    /// 1-based column, in characters.
    public var column: Int
    /// Match length in characters.
    public var length: Int
    /// The line (trimmed, and clipped around the match when very long).
    public var preview: String
    /// The match's character offsets within `preview`.
    public var previewRange: Range<Int>

    public var position: TextPosition { TextPosition(line: line, column: column) }
}

public struct SearchFileResult: Hashable, Sendable, Identifiable {
    public var relativePath: String
    public var matches: [SearchMatch]
    public var id: String { relativePath }
}

public struct SearchSummary: Hashable, Sendable {
    public var filesSearched = 0
    public var filesMatched = 0
    public var totalMatches = 0
    /// Stopped at `maxTotalMatches`.
    public var truncated = false
    public var duration: TimeInterval = 0
}

public enum SearchEvent: Sendable {
    case file(SearchFileResult)
    case finished(SearchSummary)
}

public enum SearchError: LocalizedError, Equatable {
    case emptyPattern
    case invalidRegex(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPattern: "Type something to search for."
        case .invalidRegex(let message): "Invalid regular expression: \(message)"
        }
    }
}

/// A compiled query, applied to one file's bytes.
public struct SearchMatcher: Sendable {
    enum Kind: @unchecked Sendable {
        case literal([UInt8], caseInsensitive: Bool)
        case regex(NSRegularExpression)
    }

    let kind: Kind
    let wholeWord: Bool
    let maxMatches: Int

    public init(_ query: SearchQuery) throws {
        guard !query.pattern.isEmpty else { throw SearchError.emptyPattern }
        wholeWord = query.wholeWord
        maxMatches = query.maxMatchesPerFile
        let insensitive = query.isCaseInsensitive
        let asciiOnly = query.pattern.utf8.allSatisfy { $0 < 0x80 }
        if !query.isRegex, asciiOnly || !insensitive {
            let bytes = Array((insensitive ? query.pattern.lowercased() : query.pattern).utf8)
            kind = .literal(bytes, caseInsensitive: insensitive)
            return
        }
        var pattern = query.isRegex ? query.pattern : NSRegularExpression.escapedPattern(for: query.pattern)
        if query.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if insensitive { options.insert(.caseInsensitive) }
        do {
            kind = .regex(try NSRegularExpression(pattern: pattern, options: options))
        } catch {
            throw SearchError.invalidRegex((error as NSError).localizedFailureReason ?? error.localizedDescription)
        }
    }

    /// All matches in a file's contents. Binary content yields none.
    public func matches(in data: Data) -> [SearchMatch] {
        data.withUnsafeBytes { raw -> [SearchMatch] in
            if FileSniffer.looksBinary(raw) { return [] }
            switch kind {
            case .literal(let needle, let insensitive):
                return literalMatches(raw, needle: needle, caseInsensitive: insensitive)
            case .regex(let regex):
                return regexMatches(String(decoding: raw, as: UTF8.self), regex: regex)
            }
        }
    }

    public func matches(in text: String) -> [SearchMatch] {
        matches(in: Data(text.utf8))
    }

    // MARK: Literal (byte search)

    private func literalMatches(_ raw: UnsafeRawBufferPointer, needle: [UInt8], caseInsensitive: Bool) -> [SearchMatch] {
        guard let base = raw.baseAddress, !needle.isEmpty, raw.count >= needle.count else { return [] }
        let count = raw.count
        // Fold ASCII case into a scratch copy when needed.
        var folded: [UInt8] = []
        if caseInsensitive {
            folded = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
                let source = base.assumingMemoryBound(to: UInt8.self)
                for i in 0..<count {
                    let b = source[i]
                    buffer[i] = (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b
                }
                initialized = count
            }
        }
        return folded.withUnsafeBufferPointer { foldedBuffer -> [SearchMatch] in
            let hay: UnsafePointer<UInt8> = caseInsensitive ? foldedBuffer.baseAddress! : base.assumingMemoryBound(to: UInt8.self)
            let original = base.assumingMemoryBound(to: UInt8.self)
            var results: [SearchMatch] = []
            var lineNumber = 1
            var lineStart = 0
            var scanned = 0  // newlines counted up to here
            var offset = 0
            needle.withUnsafeBufferPointer { needleBuffer in
                while offset <= count - needle.count, results.count < maxMatches {
                    guard let found = memmem(hay + offset, count - offset, needleBuffer.baseAddress!, needle.count) else { break }
                    let at = hay.distance(to: found.assumingMemoryBound(to: UInt8.self))
                    // Advance line bookkeeping to `at`.
                    var p = scanned
                    while p < at, let nl = memchr(original + p, 0x0A, at - p) {
                        let index = original.distance(to: nl.assumingMemoryBound(to: UInt8.self))
                        lineNumber += 1
                        lineStart = index + 1
                        p = index + 1
                    }
                    scanned = at
                    let end = at + needle.count
                    if wholeWord && (isWordByte(at > 0 ? original[at - 1] : nil) || isWordByte(end < count ? original[end] : nil)) {
                        offset = at + 1
                        continue
                    }
                    let lineEnd = memchr(original + end, 0x0A, count - end)
                        .map { original.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? count
                    results.append(makeMatch(original, lineNumber: lineNumber, lineStart: lineStart,
                                             lineEnd: lineEnd, matchStart: at, matchEnd: end))
                    offset = end
                }
            }
            return results
        }
    }

    private func isWordByte(_ byte: UInt8?) -> Bool {
        guard let b = byte else { return false }
        return (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }

    private func makeMatch(_ bytes: UnsafePointer<UInt8>, lineNumber: Int, lineStart: Int, lineEnd: Int,
                           matchStart: Int, matchEnd: Int) -> SearchMatch {
        func string(_ from: Int, _ to: Int) -> String {
            String(decoding: UnsafeBufferPointer(start: bytes + from, count: max(0, to - from)), as: UTF8.self)
        }
        var end = lineEnd
        if end > lineStart, bytes[end - 1] == 0x0D { end -= 1 }
        let column = string(lineStart, matchStart).count + 1
        let matchText = string(matchStart, matchEnd)
        return Self.preview(prefix: string(lineStart, matchStart), match: matchText,
                            suffix: string(matchEnd, max(matchEnd, end)), line: lineNumber, column: column)
    }

    // MARK: Regex

    private func regexMatches(_ text: String, regex: NSRegularExpression) -> [SearchMatch] {
        let ns = text as NSString
        let length = ns.length
        // UTF-16 offsets where each line starts.
        var lineStarts: [Int] = [0]
        let utf16 = text.utf16
        var i = 0
        for unit in utf16 {
            i += 1
            if unit == 0x0A { lineStarts.append(i) }
        }
        var results: [SearchMatch] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: length)) { result, _, stop in
            guard let range = result?.range, range.length > 0 else { return }
            // Binary search the line.
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= range.location { lo = mid } else { hi = mid - 1 }
            }
            let lineStart = lineStarts[lo]
            var lineEnd = lo + 1 < lineStarts.count ? lineStarts[lo + 1] - 1 : length
            if lineEnd > lineStart, ns.character(at: lineEnd - 1) == 0x0D { lineEnd -= 1 }
            let matchEnd = min(range.location + range.length, max(lineEnd, range.location))
            let prefix = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            let match = ns.substring(with: NSRange(location: range.location, length: matchEnd - range.location))
            let suffix = ns.substring(with: NSRange(location: matchEnd, length: max(0, lineEnd - matchEnd)))
            results.append(Self.preview(prefix: prefix, match: match, suffix: suffix, line: lo + 1, column: prefix.count + 1))
            if results.count >= maxMatches { stop.pointee = true }
        }
        return results
    }

    // MARK: Preview

    static let previewContextBefore = 48
    static let previewMaxLength = 220

    static func preview(prefix: String, match: String, suffix: String, line: Int, column: Int) -> SearchMatch {
        var head = Substring(prefix)
        // Drop leading indentation, then clip long prefixes to some context.
        while let first = head.first, first == " " || first == "\t" { head = head.dropFirst() }
        var clippedHead = false
        if head.count > previewContextBefore {
            head = head.suffix(previewContextBefore)
            clippedHead = true
        }
        let headText = (clippedHead ? "…" : "") + head
        let matchLength = match.count
        let room = max(0, previewMaxLength - headText.count - matchLength)
        var tail = Substring(suffix)
        var clippedTail = false
        if tail.count > room {
            tail = tail.prefix(room)
            clippedTail = true
        }
        let preview = headText + match + tail + (clippedTail ? "…" : "")
        let start = headText.count
        return SearchMatch(line: line, column: column, length: matchLength, preview: preview,
                           previewRange: start..<(start + matchLength))
    }
}

/// Runs searches over a workspace: walks the tree (ignore-aware), then
/// searches files in parallel batches, streaming results per file.
public enum WorkspaceSearch {
    public static func search(_ query: SearchQuery, in root: URL,
                              options: WalkOptions = WalkOptions()) -> AsyncThrowingStream<SearchEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let summary = try await run(query, in: root, options: options) { result in
                        continuation.yield(.file(result))
                    }
                    continuation.yield(.finished(summary))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs a search to completion, collecting results sorted by path.
    public static func collect(_ query: SearchQuery, in root: URL,
                               options: WalkOptions = WalkOptions()) async throws -> ([SearchFileResult], SearchSummary) {
        var results: [SearchFileResult] = []
        let summary = try await run(query, in: root, options: options) { results.append($0) }
        return (results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }, summary)
    }

    static func run(_ query: SearchQuery, in root: URL, options: WalkOptions,
                    emit: (SearchFileResult) -> Void) async throws -> SearchSummary {
        let started = Date()
        let matcher = try SearchMatcher(query)
        var walk = options
        walk.excludePatterns += query.excludeGlobs
        let includes = query.includeGlobs.map { Glob($0) }
        var files = FileWalker.files(in: root, options: walk)
        if !includes.isEmpty {
            files = files.filter { path in
                let name = String(path.split(separator: "/").last ?? "")
                return includes.contains { $0.matches(path) || $0.matches(name) || $0.matches(path + "/") }
                    || includes.contains { glob in
                        // "src" or "src/" includes everything below it.
                        glob.isLiteral && (path.hasPrefix(glob.pattern.hasSuffix("/") ? glob.pattern : glob.pattern + "/"))
                    }
            }
        }
        try Task.checkCancellation()

        let rootURL = root.standardizedFileURL
        let batchSize = 48
        let batches = stride(from: 0, to: files.count, by: batchSize).map { Array(files[$0..<min($0 + batchSize, files.count)]) }
        var summary = SearchSummary()
        summary.filesSearched = files.count
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let maxBytes = query.maxFileBytes

        try await withThrowingTaskGroup(of: [SearchFileResult].self) { group in
            var next = 0
            func addBatch() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask {
                    var found: [SearchFileResult] = []
                    for path in batch {
                        if Task.isCancelled { break }
                        let url = rootURL.appendingPathComponent(path)
                        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count <= maxBytes else { continue }
                        let matches = matcher.matches(in: data)
                        if !matches.isEmpty { found.append(SearchFileResult(relativePath: path, matches: matches)) }
                    }
                    return found
                }
            }
            for _ in 0..<width { addBatch() }
            while let batchResults = try await group.next() {
                try Task.checkCancellation()
                for result in batchResults {
                    guard !summary.truncated else { break }
                    var result = result
                    let room = query.maxTotalMatches - summary.totalMatches
                    if result.matches.count >= room {
                        result.matches = Array(result.matches.prefix(room))
                        summary.truncated = true
                    }
                    summary.filesMatched += 1
                    summary.totalMatches += result.matches.count
                    emit(result)
                }
                if summary.truncated {
                    group.cancelAll()
                    break
                }
                addBatch()
            }
        }
        summary.duration = Date().timeIntervalSince(started)
        return summary
    }
}
