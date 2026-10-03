import Foundation

/// Replaces `range` (UTF-16, in the text before any edit of the same batch is applied) with `replacement`.
public struct TextEdit: Hashable, Sendable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public static func insert(_ text: String, at location: Int) -> TextEdit {
        TextEdit(range: NSRange(location: location, length: 0), replacement: text)
    }

    public static func delete(_ range: NSRange) -> TextEdit {
        TextEdit(range: range, replacement: "")
    }

    /// Change in length this edit causes.
    public var lengthDelta: Int {
        (replacement as NSString).length - range.length
    }
}

/// The outcome of an editing command: edits to apply as one undo step and the selections afterwards.
public struct EditResult: Hashable, Sendable {
    /// Non-overlapping edits sorted by location, expressed against the original text.
    public var edits: [TextEdit]
    /// Selections in the edited text. The first is the primary selection.
    public var selections: [NSRange]

    public init(edits: [TextEdit], selections: [NSRange]) {
        self.edits = edits
        self.selections = selections
    }

    public var isEmpty: Bool {
        edits.isEmpty
    }
}

public extension TextEdit {
    /// Applies non-overlapping edits (expressed against `string`) and returns the result.
    static func apply(_ edits: [TextEdit], to string: String) -> String {
        let result = NSMutableString(string: string)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    /// Maps a location in the original text to the edited text.
    ///
    /// A location inside a replaced range moves to the end of its replacement; a location exactly at
    /// an insertion point moves after the insertion when `insertionsShiftLocation` is set.
    static func map(_ location: Int, through edits: [TextEdit], insertionsShiftLocation: Bool = true) -> Int {
        var delta = 0
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            let editEnd = edit.range.location + edit.range.length
            if edit.range.length == 0 && edit.range.location == location {
                if insertionsShiftLocation {
                    delta += edit.lengthDelta
                }
                continue
            }
            if editEnd <= location {
                delta += edit.lengthDelta
            } else if edit.range.location < location {
                // Location is inside the replaced range.
                return edit.range.location + delta + (edit.replacement as NSString).length
            } else {
                break
            }
        }
        return location + delta
    }
}
