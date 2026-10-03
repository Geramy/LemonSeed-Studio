import Foundation

/// Translates the Lua patterns used by `#lua-match?` query predicates into ICU regular expressions.
///
/// Highlight queries written for Neovim use Lua patterns. The subset handled here covers what those
/// queries use in practice: character classes (`%a`, `%d`, `%s`, `%w`, `%u`, `%l`, `%p`, `%x`, `%c`
/// and their negated upper-case forms), escaped punctuation (`%.`), anchors, sets and quantifiers.
/// The lazy quantifier `-` becomes `*?`.
enum LuaPatternTranslator {
    static func regularExpressionPattern(fromLuaPattern luaPattern: String) -> String {
        var result = ""
        var isInSet = false
        var iterator = Array(luaPattern).makeIterator()
        var previousWasAtom = false
        while let character = iterator.next() {
            switch character {
            case "%":
                guard let next = iterator.next() else {
                    result += "%"
                    break
                }
                if let characterClass = characterClass(for: next, isInSet: isInSet) {
                    result += characterClass
                } else {
                    result += NSRegularExpression.escapedPattern(for: String(next))
                }
                previousWasAtom = true
            case "[":
                isInSet = true
                result += "["
                previousWasAtom = false
            case "]":
                isInSet = false
                result += "]"
                previousWasAtom = true
            case "-" where !isInSet && previousWasAtom:
                result += "*?"
                previousWasAtom = false
            case "\\", "{", "}", "|", "/":
                result += "\\" + String(character)
                previousWasAtom = true
            default:
                result += String(character)
                previousWasAtom = !isInSet || character == "]"
            }
        }
        return result
    }

    private static func characterClass(for character: Character, isInSet: Bool) -> String? {
        let positive: String
        switch character.lowercased() {
        case "a": positive = "A-Za-z"
        case "d": positive = "0-9"
        case "l": positive = "a-z"
        case "s": positive = "\\s"
        case "u": positive = "A-Z"
        case "w": positive = "A-Za-z0-9"
        case "x": positive = "A-Fa-f0-9"
        case "p": positive = "\\p{P}"
        case "c": positive = "\\p{Cc}"
        default: return nil
        }
        let isNegated = character.isUppercase
        if isInSet {
            // Negated classes cannot be expressed inside a set without set subtraction; fall back to the positive class.
            return positive
        }
        return isNegated ? "[^\(positive)]" : "[\(positive)]"
    }
}
