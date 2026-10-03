import Foundation

/// How a syntax capture is drawn.
public struct SyntaxStyle: Hashable, Sendable {
    public var color: ThemeColor
    public var isBold: Bool
    public var isItalic: Bool

    public init(_ color: ThemeColor, bold: Bool = false, italic: Bool = false) {
        self.color = color
        self.isBold = bold
        self.isItalic = italic
    }
}

/// The base colors of a design system. A Studio design palette maps onto this one to one,
/// and ``EditorTheme/init(name:palette:)`` derives every editor color from it.
public struct ThemePalette: Hashable, Sendable {
    public var isDark: Bool
    /// The editor surface.
    public var background: ThemeColor
    /// Floating layers: completion popups, find bar.
    public var elevatedBackground: ThemeColor
    public var text: ThemeColor
    public var secondaryText: ThemeColor
    public var tertiaryText: ThemeColor
    public var separator: ThemeColor
    /// The single accent color ("lemon").
    public var accent: ThemeColor
    public var red: ThemeColor
    public var orange: ThemeColor
    public var yellow: ThemeColor
    public var green: ThemeColor
    public var teal: ThemeColor
    public var cyan: ThemeColor
    public var blue: ThemeColor
    public var indigo: ThemeColor
    public var purple: ThemeColor
    public var pink: ThemeColor

    public init(isDark: Bool,
                background: ThemeColor,
                elevatedBackground: ThemeColor,
                text: ThemeColor,
                secondaryText: ThemeColor,
                tertiaryText: ThemeColor,
                separator: ThemeColor,
                accent: ThemeColor,
                red: ThemeColor,
                orange: ThemeColor,
                yellow: ThemeColor,
                green: ThemeColor,
                teal: ThemeColor,
                cyan: ThemeColor,
                blue: ThemeColor,
                indigo: ThemeColor,
                purple: ThemeColor,
                pink: ThemeColor) {
        self.isDark = isDark
        self.background = background
        self.elevatedBackground = elevatedBackground
        self.text = text
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.separator = separator
        self.accent = accent
        self.red = red
        self.orange = orange
        self.yellow = yellow
        self.green = green
        self.teal = teal
        self.cyan = cyan
        self.blue = blue
        self.indigo = indigo
        self.purple = purple
        self.pink = pink
    }
}

/// Every color the editor draws with, plus syntax styles keyed by tree-sitter capture name.
public struct EditorTheme: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isDark: Bool

    // Surface
    public var background: ThemeColor
    public var foreground: ThemeColor
    public var elevatedBackground: ThemeColor
    public var separator: ThemeColor

    // Gutter
    public var gutterBackground: ThemeColor
    public var gutterHairline: ThemeColor
    public var lineNumber: ThemeColor
    public var activeLineNumber: ThemeColor

    // Caret and selection
    public var caret: ThemeColor
    public var selection: ThemeColor
    public var currentLine: ThemeColor
    public var secondaryCaret: ThemeColor

    // Guides and markers
    public var indentGuide: ThemeColor
    public var activeIndentGuide: ThemeColor
    public var invisibles: ThemeColor
    public var bracketMatchBackground: ThemeColor
    public var bracketMatchBorder: ThemeColor
    public var findMatch: ThemeColor
    public var currentFindMatch: ThemeColor
    public var foldPlaceholder: ThemeColor
    public var ghostText: ThemeColor

    // Diagnostics
    public var error: ThemeColor
    public var warning: ThemeColor
    public var information: ThemeColor
    public var hint: ThemeColor

    // Minimap
    public var minimapBackground: ThemeColor
    public var minimapSlider: ThemeColor
    public var minimapSliderActive: ThemeColor

    /// Accent used by floating UI (find bar, completion selection).
    public var accent: ThemeColor

    /// Syntax styles keyed by capture name, e.g. `keyword` or `string.special`.
    public var syntax: [String: SyntaxStyle]

    /// Builds a complete theme from a design palette.
    public init(name: String, palette: ThemePalette) {
        self.name = name
        isDark = palette.isDark
        background = palette.background
        foreground = palette.text
        elevatedBackground = palette.elevatedBackground
        separator = palette.separator
        gutterBackground = palette.background
        gutterHairline = .clear
        lineNumber = palette.tertiaryText
        activeLineNumber = palette.text
        caret = palette.accent
        selection = palette.accent.withAlpha(palette.isDark ? 0.26 : 0.30)
        currentLine = palette.text.withAlpha(palette.isDark ? 0.045 : 0.04)
        secondaryCaret = palette.accent.withAlpha(0.85)
        indentGuide = palette.text.withAlpha(palette.isDark ? 0.08 : 0.09)
        activeIndentGuide = palette.text.withAlpha(palette.isDark ? 0.22 : 0.24)
        invisibles = palette.tertiaryText.withAlpha(0.55)
        bracketMatchBackground = palette.accent.withAlpha(0.16)
        bracketMatchBorder = palette.accent.withAlpha(0.55)
        findMatch = palette.yellow.withAlpha(palette.isDark ? 0.26 : 0.32)
        currentFindMatch = palette.orange.withAlpha(palette.isDark ? 0.55 : 0.5)
        foldPlaceholder = palette.secondaryText
        ghostText = palette.tertiaryText
        error = palette.red
        warning = palette.isDark ? palette.yellow : palette.orange
        information = palette.blue
        hint = palette.tertiaryText
        minimapBackground = palette.background
        minimapSlider = palette.text.withAlpha(palette.isDark ? 0.07 : 0.06)
        minimapSliderActive = palette.text.withAlpha(palette.isDark ? 0.14 : 0.12)
        accent = palette.accent
        syntax = Self.syntaxStyles(for: palette)
    }

    /// Style for a capture name. Falls back through the dotted hierarchy (`keyword.control.return` →
    /// `keyword.control` → `keyword`) and through aliases for capture names used by different query sets.
    public func style(forCapture captureName: String) -> SyntaxStyle? {
        var name = captureName.hasPrefix("@") ? String(captureName.dropFirst()) : captureName
        while true {
            if let style = syntax[name] {
                return style
            }
            if let alias = Self.captureAliases[name], let style = syntax[alias] {
                return style
            }
            guard let dotIndex = name.lastIndex(of: ".") else {
                return nil
            }
            name = String(name[..<dotIndex])
        }
    }

    /// Capture names that different query sets (Neovim, Helix, tree-sitter upstream) use for the same thing.
    static let captureAliases: [String: String] = [
        "include": "keyword.directive",
        "preproc": "keyword.directive",
        "define": "keyword.directive",
        "conditional": "keyword",
        "repeat": "keyword",
        "exception": "keyword",
        "storageclass": "keyword",
        "keyword.storage": "keyword",
        "method": "function",
        "method.call": "function",
        "function.call": "function",
        "function.method": "function",
        "function.macro": "function.builtin",
        "macro": "function.builtin",
        "constructor": "type",
        "namespace": "type",
        "module": "type",
        "parameter": "variable.parameter",
        "field": "property",
        "variable.member": "property",
        "boolean": "constant.builtin",
        "float": "number",
        "character": "string",
        "escape": "string.escape",
        "string.regex": "string.special",
        "string.regexp": "string.special",
        "text.title": "markup.heading",
        "text.literal": "markup.raw",
        "text.uri": "markup.link",
        "text.reference": "markup.link",
        "text.emphasis": "markup.italic",
        "text.strong": "markup.bold",
        "tag.attribute": "attribute",
        "decorator": "attribute",
        "annotation": "attribute",
        "symbol": "constant",
        "none": "variable",
        "spell": "variable"
    ]

    private static func syntaxStyles(for palette: ThemePalette) -> [String: SyntaxStyle] {
        let isDark = palette.isDark
        return [
            "comment": SyntaxStyle(palette.tertiaryText, italic: true),
            "comment.documentation": SyntaxStyle(palette.tertiaryText.mixed(with: palette.green, amount: 0.25), italic: true),
            "keyword": SyntaxStyle(palette.purple),
            "keyword.function": SyntaxStyle(palette.purple),
            "keyword.return": SyntaxStyle(palette.purple),
            "keyword.operator": SyntaxStyle(palette.purple),
            "keyword.directive": SyntaxStyle(palette.pink),
            "string": SyntaxStyle(palette.green),
            "string.special": SyntaxStyle(palette.teal),
            "string.escape": SyntaxStyle(palette.cyan),
            "number": SyntaxStyle(palette.orange),
            "constant": SyntaxStyle(palette.orange),
            "constant.builtin": SyntaxStyle(palette.orange),
            "constant.macro": SyntaxStyle(palette.orange),
            "function": SyntaxStyle(palette.blue),
            "function.builtin": SyntaxStyle(palette.cyan),
            "type": SyntaxStyle(palette.teal),
            "type.builtin": SyntaxStyle(palette.teal),
            "type.qualifier": SyntaxStyle(palette.purple),
            "variable": SyntaxStyle(palette.text),
            "variable.builtin": SyntaxStyle(palette.pink, italic: true),
            "variable.parameter": SyntaxStyle(isDark ? palette.text.mixed(with: palette.orange, amount: 0.35)
                                                     : palette.text.mixed(with: palette.orange, amount: 0.45)),
            "property": SyntaxStyle(palette.indigo),
            "operator": SyntaxStyle(palette.secondaryText),
            "punctuation": SyntaxStyle(palette.secondaryText),
            "punctuation.bracket": SyntaxStyle(palette.secondaryText),
            "punctuation.delimiter": SyntaxStyle(palette.secondaryText),
            "punctuation.special": SyntaxStyle(palette.pink),
            "attribute": SyntaxStyle(palette.yellow),
            "label": SyntaxStyle(palette.yellow),
            "tag": SyntaxStyle(palette.red),
            "embedded": SyntaxStyle(palette.text),
            "markup.heading": SyntaxStyle(isDark ? palette.accent : palette.yellow, bold: true),
            "markup.bold": SyntaxStyle(palette.text, bold: true),
            "markup.italic": SyntaxStyle(palette.text, italic: true),
            "markup.raw": SyntaxStyle(palette.green),
            "markup.link": SyntaxStyle(palette.blue),
            "markup.list": SyntaxStyle(palette.pink),
            "markup.quote": SyntaxStyle(palette.secondaryText, italic: true)
        ]
    }
}

// MARK: - Built-in palettes and themes
public extension ThemePalette {
    /// Lemon Dark: a warm near-black surface with a lemon accent.
    static let lemonDark = ThemePalette(
        isDark: true,
        background: ThemeColor(0x161618),
        elevatedBackground: ThemeColor(0x222226),
        text: ThemeColor(0xE7E4DD),
        secondaryText: ThemeColor(0xA29F98),
        tertiaryText: ThemeColor(0x6F6D68),
        separator: ThemeColor(0x2B2B30),
        accent: ThemeColor(0xF4D03F),
        red: ThemeColor(0xF2777A),
        orange: ThemeColor(0xF5A962),
        yellow: ThemeColor(0xE9CF73),
        green: ThemeColor(0xA8D28E),
        teal: ThemeColor(0x73CDBD),
        cyan: ThemeColor(0x7FD3F0),
        blue: ThemeColor(0x82AEFF),
        indigo: ThemeColor(0xA6B1FF),
        purple: ThemeColor(0xCA9BF0),
        pink: ThemeColor(0xF28FB0))

    /// Lemon Light: warm paper with a deeper lemon accent tuned for contrast.
    static let lemonLight = ThemePalette(
        isDark: false,
        background: ThemeColor(0xFBFAF6),
        elevatedBackground: ThemeColor(0xFFFFFF),
        text: ThemeColor(0x2A2925),
        secondaryText: ThemeColor(0x5F5C55),
        tertiaryText: ThemeColor(0x86827A),
        separator: ThemeColor(0xE6E2D8),
        accent: ThemeColor(0xC99A00),
        red: ThemeColor(0xC93A3F),
        orange: ThemeColor(0xA65508),
        yellow: ThemeColor(0x7A6200),
        green: ThemeColor(0x3B7F2A),
        teal: ThemeColor(0x0F7D72),
        cyan: ThemeColor(0x0A7698),
        blue: ThemeColor(0x2E5BC8),
        indigo: ThemeColor(0x5551C9),
        purple: ThemeColor(0x8A3CB8),
        pink: ThemeColor(0xBB3468))

    /// Seed High-Contrast: black surface, pure white text, saturated syntax colors.
    static let seedHighContrast = ThemePalette(
        isDark: true,
        background: ThemeColor(0x000000),
        elevatedBackground: ThemeColor(0x111111),
        text: ThemeColor(0xFFFFFF),
        secondaryText: ThemeColor(0xD6D6D6),
        tertiaryText: ThemeColor(0xA8A8A8),
        separator: ThemeColor(0x5A5A5A),
        accent: ThemeColor(0xFFE14D),
        red: ThemeColor(0xFF6E6E),
        orange: ThemeColor(0xFFB062),
        yellow: ThemeColor(0xFFE680),
        green: ThemeColor(0x9DF08A),
        teal: ThemeColor(0x5CF2D6),
        cyan: ThemeColor(0x7AE6FF),
        blue: ThemeColor(0x8CB8FF),
        indigo: ThemeColor(0xB9C0FF),
        purple: ThemeColor(0xE0A8FF),
        pink: ThemeColor(0xFF9CC7))
}

public extension EditorTheme {
    static let lemonDark = EditorTheme(name: "Lemon Dark", palette: .lemonDark)
    static let lemonLight = EditorTheme(name: "Lemon Light", palette: .lemonLight)
    static let seedHighContrast = EditorTheme(name: "Seed High-Contrast", palette: .seedHighContrast)

    static let builtIn: [EditorTheme] = [.lemonDark, .lemonLight, .seedHighContrast]
}

extension EditorTheme: CustomStringConvertible {
    public var description: String {
        name
    }
}
