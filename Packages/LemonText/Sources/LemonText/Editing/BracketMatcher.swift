import Foundation

/// A bracket at the caret and its partner.
public struct BracketMatch: Hashable, Sendable {
    public let open: NSRange
    public let close: NSRange
}

/// Finds the bracket matching the one next to the caret.
public struct BracketMatcher: Sendable {
    public var pairs: [BracketPair]
    /// How far to scan, in UTF-16 units, before giving up. Keeps the cost bounded in huge files.
    public var scanLimit: Int

    public init(pairs: [BracketPair], scanLimit: Int = 200_000) {
        self.pairs = pairs.filter { ($0.open as NSString).length == 1 && ($0.close as NSString).length == 1 && $0.open != $0.close }
        self.scanLimit = scanLimit
    }

    /// The bracket pair around the caret. The character after the caret is checked first, then the one before it.
    /// - Parameter isExcluded: Returns true for locations inside comments or strings, which are skipped.
    public func match(in string: NSString, caret: Int, isExcluded: ((Int) -> Bool)? = nil) -> BracketMatch? {
        let candidates = [caret, caret - 1]
        for location in candidates where location >= 0 && location < string.length {
            if isExcluded?(location) == true {
                continue
            }
            let character = string.character(at: location)
            for pair in pairs {
                let open = (pair.open as NSString).character(at: 0)
                let close = (pair.close as NSString).character(at: 0)
                if character == open {
                    if let partner = scan(string, from: location + 1, forward: true, open: open, close: close, isExcluded: isExcluded) {
                        return BracketMatch(open: NSRange(location: location, length: 1), close: NSRange(location: partner, length: 1))
                    }
                    return nil
                } else if character == close {
                    if let partner = scan(string, from: location - 1, forward: false, open: open, close: close, isExcluded: isExcluded) {
                        return BracketMatch(open: NSRange(location: partner, length: 1), close: NSRange(location: location, length: 1))
                    }
                    return nil
                }
            }
        }
        return nil
    }

    private func scan(_ string: NSString, from start: Int, forward: Bool, open: unichar, close: unichar, isExcluded: ((Int) -> Bool)?) -> Int? {
        var depth = 0
        var location = start
        var scanned = 0
        // Read in chunks to avoid a message send per character on large documents.
        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        while scanned < scanLimit && location >= 0 && location < string.length {
            let chunkRange: NSRange
            if forward {
                chunkRange = NSRange(location: location, length: min(chunkSize, string.length - location))
            } else {
                let lower = max(0, location - chunkSize + 1)
                chunkRange = NSRange(location: lower, length: location - lower + 1)
            }
            string.getCharacters(&buffer, range: chunkRange)
            let indices: StrideThrough<Int> = forward
                ? stride(from: 0, through: chunkRange.length - 1, by: 1)
                : stride(from: chunkRange.length - 1, through: 0, by: -1)
            for offset in indices {
                let absolute = chunkRange.location + offset
                let character = buffer[offset]
                scanned += 1
                if character != open && character != close {
                    continue
                }
                if isExcluded?(absolute) == true {
                    continue
                }
                if forward {
                    if character == open {
                        depth += 1
                    } else if depth == 0 {
                        return absolute
                    } else {
                        depth -= 1
                    }
                } else {
                    if character == close {
                        depth += 1
                    } else if depth == 0 {
                        return absolute
                    } else {
                        depth -= 1
                    }
                }
            }
            location = forward ? chunkRange.location + chunkRange.length : chunkRange.location - 1
        }
        return nil
    }
}
