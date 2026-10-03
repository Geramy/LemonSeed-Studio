import SwiftUI

/// A complete Studio theme: surfaces, text, accent, states, syntax and the
/// terminal's 16 ANSI colors. Every color a Studio view draws comes from
/// here; views never hard-code a color.
public struct Theme: Identifiable, Hashable, Sendable {
    public enum Appearance: String, Sendable, Codable, CaseIterable {
        case dark, light

        public var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    }

    public let id: String
    public var name: String
    /// One line shown under the name in the theme picker.
    public var summary: String
    public var appearance: Appearance
    public var palette: Palette
    public var syntax: SyntaxPalette
    public var terminal: TerminalPalette

    public init(id: String, name: String, summary: String, appearance: Appearance,
                palette: Palette, syntax: SyntaxPalette, terminal: TerminalPalette) {
        self.id = id
        self.name = name
        self.summary = summary
        self.appearance = appearance
        self.palette = palette
        self.syntax = syntax
        self.terminal = terminal
    }

    public var colorScheme: ColorScheme { appearance.colorScheme }
}

/// Surfaces are layered from the back of the window to the front:
/// `canvas` (window), `chrome` (sidebar, tab strip, status bar), `editor`
/// (the calm, opaque content surface) and `elevated` (panels, popovers).
public struct Palette: Hashable, Sendable {
    // Surfaces
    public var canvas: RGBA
    public var chrome: RGBA
    public var editor: RGBA
    public var elevated: RGBA
    public var gutter: RGBA
    public var currentLine: RGBA
    public var selection: RGBA
    public var hover: RGBA
    public var pressed: RGBA
    public var hairline: RGBA
    public var separator: RGBA

    // Text
    public var textPrimary: RGBA
    public var textSecondary: RGBA
    public var textTertiary: RGBA
    public var textOnAccent: RGBA

    // Accent ("lemon")
    public var accent: RGBA
    /// The accent as a fill (selected tab underline, badges, toggles).
    public var accentFill: RGBA
    /// A low-alpha wash of the accent (selected rows, matches).
    public var accentWash: RGBA

    // States
    public var success: RGBA
    public var warning: RGBA
    public var error: RGBA
    public var info: RGBA

    // Source control
    public var added: RGBA
    public var modified: RGBA
    public var deleted: RGBA

    public init(canvas: RGBA, chrome: RGBA, editor: RGBA, elevated: RGBA, gutter: RGBA,
                currentLine: RGBA, selection: RGBA, hover: RGBA, pressed: RGBA,
                hairline: RGBA, separator: RGBA,
                textPrimary: RGBA, textSecondary: RGBA, textTertiary: RGBA, textOnAccent: RGBA,
                accent: RGBA, accentFill: RGBA, accentWash: RGBA,
                success: RGBA, warning: RGBA, error: RGBA, info: RGBA,
                added: RGBA, modified: RGBA, deleted: RGBA) {
        self.canvas = canvas
        self.chrome = chrome
        self.editor = editor
        self.elevated = elevated
        self.gutter = gutter
        self.currentLine = currentLine
        self.selection = selection
        self.hover = hover
        self.pressed = pressed
        self.hairline = hairline
        self.separator = separator
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.textOnAccent = textOnAccent
        self.accent = accent
        self.accentFill = accentFill
        self.accentWash = accentWash
        self.success = success
        self.warning = warning
        self.error = error
        self.info = info
        self.added = added
        self.modified = modified
        self.deleted = deleted
    }
}

/// Syntax colors keyed by role. Roles follow tree-sitter highlight capture
/// names, so a highlighter maps `@keyword`, `@string` and so on directly.
public struct SyntaxPalette: Hashable, Sendable {
    public enum Role: String, CaseIterable, Sendable {
        case plain, keyword, string, number, comment, type, function, variable
        case constant, `operator`, punctuation, preprocessor, attribute, tag, property
    }

    public var plain: RGBA
    public var keyword: RGBA
    public var string: RGBA
    public var number: RGBA
    public var comment: RGBA
    public var type: RGBA
    public var function: RGBA
    public var variable: RGBA
    public var constant: RGBA
    public var `operator`: RGBA
    public var punctuation: RGBA
    public var preprocessor: RGBA
    public var attribute: RGBA
    public var tag: RGBA
    public var property: RGBA

    public init(plain: RGBA, keyword: RGBA, string: RGBA, number: RGBA, comment: RGBA,
                type: RGBA, function: RGBA, variable: RGBA, constant: RGBA, operator: RGBA,
                punctuation: RGBA, preprocessor: RGBA, attribute: RGBA, tag: RGBA, property: RGBA) {
        self.plain = plain
        self.keyword = keyword
        self.string = string
        self.number = number
        self.comment = comment
        self.type = type
        self.function = function
        self.variable = variable
        self.constant = constant
        self.operator = `operator`
        self.punctuation = punctuation
        self.preprocessor = preprocessor
        self.attribute = attribute
        self.tag = tag
        self.property = property
    }

    public subscript(role: Role) -> RGBA {
        switch role {
        case .plain: plain
        case .keyword: keyword
        case .string: string
        case .number: number
        case .comment: comment
        case .type: type
        case .function: function
        case .variable: variable
        case .constant: constant
        case .operator: `operator`
        case .punctuation: punctuation
        case .preprocessor: preprocessor
        case .attribute: attribute
        case .tag: tag
        case .property: property
        }
    }

    /// The role for a tree-sitter capture name such as `keyword.control`
    /// or `string.special`: the longest known prefix wins.
    public static func role(forCapture capture: String) -> Role {
        let head = capture.split(separator: ".").first.map(String.init) ?? capture
        switch head {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass": return .keyword
        case "string", "character", "escape": return .string
        case "number", "float", "boolean": return .number
        case "comment": return .comment
        case "type", "constructor", "namespace", "module": return .type
        case "function", "method": return .function
        case "variable", "parameter", "field": return capture.hasPrefix("variable.member") ? .property : .variable
        case "constant": return .constant
        case "operator": return .operator
        case "punctuation", "delimiter": return .punctuation
        case "preproc", "define", "macro": return .preprocessor
        case "attribute", "label", "annotation": return .attribute
        case "tag": return .tag
        case "property": return .property
        default: return .plain
        }
    }
}

/// The terminal's colors: foreground, background, caret, selection and the
/// 16 ANSI colors (normal 0–7, bright 8–15).
public struct TerminalPalette: Hashable, Sendable {
    public var foreground: RGBA
    public var background: RGBA
    public var caret: RGBA
    public var selection: RGBA
    public var ansi: [RGBA]

    public init(foreground: RGBA, background: RGBA, caret: RGBA, selection: RGBA, ansi: [RGBA]) {
        precondition(ansi.count == 16, "a terminal palette has 16 ANSI colors")
        self.foreground = foreground
        self.background = background
        self.caret = caret
        self.selection = selection
        self.ansi = ansi
    }
}
