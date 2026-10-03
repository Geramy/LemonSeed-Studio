import Foundation

/// Line lookups over an `NSString`, shared by the editing commands.
struct TextLines {
    let string: NSString

    init(_ string: NSString) {
        self.string = string
    }

    var length: Int { string.length }

    /// Range of the line containing `location`, without its line break.
    func lineRange(containing location: Int) -> NSRange {
        let clamped = min(max(location, 0), string.length)
        var start = 0
        var end = 0
        var contentsEnd = 0
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: clamped, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// Range of the line containing `location`, including its line break.
    func fullLineRange(containing location: Int) -> NSRange {
        let clamped = min(max(location, 0), string.length)
        var start = 0
        var end = 0
        var contentsEnd = 0
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: clamped, length: 0))
        return NSRange(location: start, length: end - start)
    }

    /// The content ranges of every line touched by `selection`. A selection that ends at the very start of a
    /// line does not include that line, matching how editors treat full-line selections.
    func lineRanges(coveredBy selection: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = selection.location
        var upperBound = selection.location + selection.length
        if selection.length > 0 {
            let lastLine = lineRange(containing: upperBound)
            if lastLine.location == upperBound && upperBound > selection.location {
                upperBound -= 1
            }
        }
        while true {
            let line = lineRange(containing: location)
            ranges.append(line)
            let fullLine = fullLineRange(containing: location)
            let next = fullLine.location + fullLine.length
            if next > upperBound || next >= string.length || fullLine.length == line.length {
                break
            }
            location = next
        }
        return ranges
    }

    /// Leading whitespace length of a line (in UTF-16 units).
    func indentationLength(of line: NSRange) -> Int {
        var index = line.location
        let end = line.location + line.length
        while index < end {
            let character = string.character(at: index)
            if character != 0x20 && character != 0x09 {
                break
            }
            index += 1
        }
        return index - line.location
    }

    /// Visual indentation width of a line with tabs expanded.
    func indentationColumns(of line: NSRange, tabWidth: Int) -> Int {
        var columns = 0
        var index = line.location
        let end = line.location + line.length
        while index < end {
            let character = string.character(at: index)
            if character == 0x20 {
                columns += 1
            } else if character == 0x09 {
                columns += tabWidth - (columns % tabWidth)
            } else {
                break
            }
            index += 1
        }
        return columns
    }

    func isBlank(_ line: NSRange) -> Bool {
        indentationLength(of: line) == line.length
    }

    func substring(_ range: NSRange) -> String {
        string.substring(with: range)
    }

    /// Range of the word (letters, digits and underscores) at or immediately before `location`.
    func wordRange(at location: Int) -> NSRange? {
        func isWordCharacter(_ index: Int) -> Bool {
            guard index >= 0 && index < string.length else {
                return false
            }
            let scalar = string.character(at: index)
            if scalar == 0x5F {
                return true
            }
            guard let unicodeScalar = Unicode.Scalar(scalar) else {
                return false
            }
            return CharacterSet.alphanumerics.contains(unicodeScalar)
        }
        var start = location
        if !isWordCharacter(start) {
            if isWordCharacter(start - 1) {
                start -= 1
            } else {
                return nil
            }
        }
        var end = start
        while isWordCharacter(start - 1) {
            start -= 1
        }
        while isWordCharacter(end) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }
}
