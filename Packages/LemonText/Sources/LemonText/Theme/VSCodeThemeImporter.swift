import Foundation

/// Imports VS Code color themes (`*-color-theme.json`).
///
/// Workbench colors map onto the editor's surface colors, and TextMate token scopes map onto
/// tree-sitter capture names. Themes are JSON with comments and trailing commas, both of which are accepted.
public enum VSCodeThemeImporter {
    public enum ImportError: Error, Equatable {
        case invalidJSON(String)
        case missingColors
    }

    /// TextMate scope prefixes and the capture they become. More specific scopes come first.
    static let scopeMappings: [(scope: String, capture: String)] = [
        ("comment.block.documentation", "comment.documentation"),
        ("comment", "comment"),
        ("punctuation.definition.comment", "comment"),
        ("string.regexp", "string.special"),
        ("constant.character.escape", "string.escape"),
        ("string", "string"),
        ("constant.numeric", "number"),
        ("constant.language", "constant.builtin"),
        ("constant.character", "string"),
        ("constant.other", "constant"),
        ("constant", "constant"),
        ("keyword.operator", "operator"),
        ("keyword.control.directive", "keyword.directive"),
        ("meta.preprocessor", "keyword.directive"),
        ("keyword", "keyword"),
        ("storage.type", "keyword"),
        ("storage.modifier", "keyword"),
        ("storage", "keyword"),
        ("support.function", "function.builtin"),
        ("entity.name.function", "function"),
        ("meta.function-call", "function"),
        ("variable.function", "function"),
        ("support.type", "type.builtin"),
        ("support.class", "type"),
        ("entity.name.type", "type"),
        ("entity.name.class", "type"),
        ("entity.name.namespace", "type"),
        ("entity.other.inherited-class", "type"),
        ("entity.name.tag", "tag"),
        ("entity.other.attribute-name", "attribute"),
        ("meta.decorator", "attribute"),
        ("variable.language", "variable.builtin"),
        ("variable.parameter", "variable.parameter"),
        ("variable.other.property", "property"),
        ("variable.other.member", "property"),
        ("support.variable.property", "property"),
        ("variable.other.constant", "constant"),
        ("variable", "variable"),
        ("entity.name.label", "label"),
        ("punctuation.section.embedded", "punctuation.special"),
        ("punctuation", "punctuation"),
        ("markup.heading", "markup.heading"),
        ("markup.bold", "markup.bold"),
        ("markup.italic", "markup.italic"),
        ("markup.inline.raw", "markup.raw"),
        ("markup.fenced_code", "markup.raw"),
        ("markup.underline.link", "markup.link"),
        ("markup.list", "markup.list"),
        ("markup.quote", "markup.quote")
    ]

    /// Imports a theme. Colors the theme does not define are taken from `base`.
    public static func importTheme(from data: Data, name fallbackName: String? = nil, base: EditorTheme? = nil) throws -> EditorTheme {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ImportError.invalidJSON("Not UTF-8")
        }
        let json = JSONCSanitizer.sanitize(raw)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        } catch {
            throw ImportError.invalidJSON(error.localizedDescription)
        }
        guard let root = object as? [String: Any] else {
            throw ImportError.invalidJSON("The top level is not an object")
        }
        let colors = (root["colors"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? String).flatMap(ThemeColor.init(hex:)) }
        let tokenColors = root["tokenColors"] as? [[String: Any]] ?? []
        guard !colors.isEmpty || !tokenColors.isEmpty else {
            throw ImportError.missingColors
        }
        let type = (root["type"] as? String)?.lowercased()
        let isDark: Bool
        if let type {
            isDark = type != "light" && type != "hcLight"
        } else if let background = colors["editor.background"] {
            isDark = background.relativeLuminance < 0.4
        } else {
            isDark = true
        }
        let name = root["name"] as? String ?? fallbackName ?? "Imported Theme"
        var theme = base ?? (isDark ? EditorTheme.lemonDark : EditorTheme.lemonLight)
        theme.name = name
        theme.isDark = isDark
        apply(colors: colors, to: &theme)
        apply(tokenColors: tokenColors, to: &theme)
        return theme
    }

    private static func apply(colors: [String: ThemeColor], to theme: inout EditorTheme) {
        func set(_ keyPath: WritableKeyPath<EditorTheme, ThemeColor>, _ keys: String...) {
            for key in keys {
                if let color = colors[key] {
                    theme[keyPath: keyPath] = color
                    return
                }
            }
        }
        set(\.background, "editor.background")
        set(\.foreground, "editor.foreground", "foreground")
        set(\.elevatedBackground, "editorWidget.background", "editorSuggestWidget.background", "dropdown.background")
        set(\.separator, "editorWidget.border", "panel.border", "editorGroup.border")
        set(\.gutterBackground, "editorGutter.background", "editor.background")
        set(\.lineNumber, "editorLineNumber.foreground")
        set(\.activeLineNumber, "editorLineNumber.activeForeground", "editor.foreground")
        set(\.caret, "editorCursor.foreground")
        set(\.secondaryCaret, "editorCursor.foreground")
        set(\.selection, "editor.selectionBackground")
        set(\.currentLine, "editor.lineHighlightBackground")
        set(\.indentGuide, "editorIndentGuide.background1", "editorIndentGuide.background")
        set(\.activeIndentGuide, "editorIndentGuide.activeBackground1", "editorIndentGuide.activeBackground")
        set(\.invisibles, "editorWhitespace.foreground")
        set(\.bracketMatchBackground, "editorBracketMatch.background")
        set(\.bracketMatchBorder, "editorBracketMatch.border")
        set(\.findMatch, "editor.findMatchHighlightBackground")
        set(\.currentFindMatch, "editor.findMatchBackground")
        set(\.ghostText, "editorGhostText.foreground")
        set(\.error, "editorError.foreground")
        set(\.warning, "editorWarning.foreground")
        set(\.information, "editorInfo.foreground")
        set(\.hint, "editorHint.foreground")
        set(\.minimapBackground, "minimap.background", "editor.background")
        set(\.minimapSlider, "minimapSlider.background")
        set(\.minimapSliderActive, "minimapSlider.activeBackground")
        set(\.accent, "focusBorder", "button.background", "editorCursor.foreground")
        if colors["editor.foreground"] != nil || colors["foreground"] != nil {
            theme.syntax["variable"] = SyntaxStyle(theme.foreground)
        }
    }

    private static func apply(tokenColors: [[String: Any]], to theme: inout EditorTheme) {
        // Later rules win in VS Code, and a more specific scope beats a general one. Track the specificity
        // (length of the matched scope prefix) per capture so a general rule cannot override a specific one.
        var specificity: [String: Int] = [:]
        for rule in tokenColors {
            guard let settings = rule["settings"] as? [String: Any] else {
                continue
            }
            let scopes: [String]
            if let scope = rule["scope"] as? String {
                scopes = scope.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if let scopeList = rule["scope"] as? [String] {
                scopes = scopeList
            } else {
                // A rule without a scope sets the default foreground.
                if let foreground = (settings["foreground"] as? String).flatMap(ThemeColor.init(hex:)) {
                    theme.foreground = foreground
                    theme.syntax["variable"] = SyntaxStyle(foreground)
                }
                continue
            }
            let foreground = (settings["foreground"] as? String).flatMap(ThemeColor.init(hex:))
            let fontStyle = (settings["fontStyle"] as? String)?.lowercased()
            for scope in scopes {
                // Descendant selectors ("meta.class entity.name") apply to their last component.
                guard let leaf = scope.split(separator: " ").last.map(String.init),
                      let (capture, matchedLength) = capture(forScope: leaf) else {
                    continue
                }
                if let existing = specificity[capture], existing > matchedLength {
                    continue
                }
                specificity[capture] = matchedLength
                var style = theme.syntax[capture] ?? SyntaxStyle(theme.foreground)
                if let foreground {
                    style.color = foreground
                }
                if let fontStyle {
                    style.isBold = fontStyle.contains("bold")
                    style.isItalic = fontStyle.contains("italic")
                }
                theme.syntax[capture] = style
            }
        }
    }

    /// The capture for a TextMate scope and the length of the mapping prefix that matched it.
    static func capture(forScope scope: String) -> (String, Int)? {
        var best: (capture: String, length: Int)?
        for mapping in scopeMappings where scope == mapping.scope || scope.hasPrefix(mapping.scope + ".") {
            if mapping.scope.count > (best?.length ?? -1) {
                best = (mapping.capture, mapping.scope.count)
            }
        }
        return best.map { ($0.capture, $0.length) }
    }
}

/// Turns JSON with comments and trailing commas (as written by VS Code) into strict JSON.
enum JSONCSanitizer {
    static func sanitize(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.utf8.count)
        let characters = Array(source.unicodeScalars)
        var index = 0
        var isInString = false
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if isInString {
                output.unicodeScalars.append(character)
                if character == "\\", let next {
                    output.unicodeScalars.append(next)
                    index += 2
                    continue
                }
                if character == "\"" {
                    isInString = false
                }
                index += 1
                continue
            }
            if character == "\"" {
                isInString = true
                output.unicodeScalars.append(character)
                index += 1
            } else if character == "/" && next == "/" {
                while index < characters.count && characters[index] != "\n" {
                    index += 1
                }
            } else if character == "/" && next == "*" {
                index += 2
                while index + 1 < characters.count && !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index += 2
            } else if character == "," {
                // Drop the comma if the next significant character closes an object or array.
                var lookahead = index + 1
                while lookahead < characters.count {
                    let scalar = characters[lookahead]
                    if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" {
                        lookahead += 1
                    } else if scalar == "/" && lookahead + 1 < characters.count && characters[lookahead + 1] == "/" {
                        while lookahead < characters.count && characters[lookahead] != "\n" {
                            lookahead += 1
                        }
                    } else if scalar == "/" && lookahead + 1 < characters.count && characters[lookahead + 1] == "*" {
                        lookahead += 2
                        while lookahead + 1 < characters.count && !(characters[lookahead] == "*" && characters[lookahead + 1] == "/") {
                            lookahead += 1
                        }
                        lookahead += 2
                    } else {
                        break
                    }
                }
                if lookahead < characters.count && (characters[lookahead] == "}" || characters[lookahead] == "]") {
                    index += 1
                } else {
                    output.unicodeScalars.append(character)
                    index += 1
                }
            } else {
                output.unicodeScalars.append(character)
                index += 1
            }
        }
        return output
    }
}
