import SwiftUI

/// The built-in themes. Lemon Dark and Lemon Light are the defaults; Seed
/// High Contrast meets WCAG AAA for body text; Orchard and Paper are the two
/// signature themes.
public extension Theme {
    static let builtIn: [Theme] = [.lemonDark, .lemonLight, .orchard, .paper, .seedHighContrast]

    static func named(_ id: String) -> Theme? {
        builtIn.first { $0.id == id }
    }

    static let defaultDark = lemonDark
    static let defaultLight = lemonLight

    // MARK: Lemon Dark

    static let lemonDark = Theme(
        id: "lemon-dark",
        name: "Lemon Dark",
        summary: "Warm graphite with a lemon accent",
        appearance: .dark,
        palette: Palette(
            canvas: RGBA(0x0E0F11), chrome: RGBA(0x141518), editor: RGBA(0x18191D),
            elevated: RGBA(0x202126), gutter: RGBA(0x18191D),
            currentLine: RGBA(0xFFFFFF, alpha: 0.035), selection: RGBA(0xF5D547, alpha: 0.20),
            hover: RGBA(0xFFFFFF, alpha: 0.06), pressed: RGBA(0xFFFFFF, alpha: 0.10),
            hairline: RGBA(0xFFFFFF, alpha: 0.07), separator: RGBA(0xFFFFFF, alpha: 0.10),
            textPrimary: RGBA(0xE8E6E1), textSecondary: RGBA(0xA3A19B), textTertiary: RGBA(0x75746F),
            textOnAccent: RGBA(0x1A1607),
            accent: RGBA(0xF5D547), accentFill: RGBA(0xF5D547), accentWash: RGBA(0xF5D547, alpha: 0.13),
            success: RGBA(0x7FD18B), warning: RGBA(0xF0B85A), error: RGBA(0xF27A6E), info: RGBA(0x7AB0F5),
            added: RGBA(0x6CC685), modified: RGBA(0x6FA8F0), deleted: RGBA(0xEE6B61)),
        syntax: SyntaxPalette(
            plain: RGBA(0xE8E6E1), keyword: RGBA(0xF0A6CA), string: RGBA(0xB5D98A),
            number: RGBA(0xF5B76B), comment: RGBA(0x75777F), type: RGBA(0x7DD3D8),
            function: RGBA(0x8FB8FF), variable: RGBA(0xE8E6E1), constant: RGBA(0xF59B8B),
            operator: RGBA(0xBDBAB3), punctuation: RGBA(0x8E8C87), preprocessor: RGBA(0xF5D547),
            attribute: RGBA(0xE3C27A), tag: RGBA(0x8FB8FF), property: RGBA(0xC9C6F0)),
        terminal: .make(foreground: RGBA(0xE8E6E1), background: RGBA(0x141518),
                        caret: RGBA(0xF5D547), selection: RGBA(0xF5D547, alpha: 0.25),
                        normal: [0x202126, 0xF27A6E, 0x7FD18B, 0xF5D547, 0x7AB0F5, 0xF0A6CA, 0x7DD3D8, 0xD6D3CC],
                        bright: [0x5A5C66, 0xFF9488, 0x9BE3A5, 0xFFE36E, 0x99C3FF, 0xF7BEDA, 0x9DE5E8, 0xF5F3EE]))

    // MARK: Lemon Light

    static let lemonLight = Theme(
        id: "lemon-light",
        name: "Lemon Light",
        summary: "Warm paper white, ink text, a deeper lemon",
        appearance: .light,
        palette: Palette(
            canvas: RGBA(0xE9E7E1), chrome: RGBA(0xF3F1EC), editor: RGBA(0xFCFBF8),
            elevated: RGBA(0xFFFFFF), gutter: RGBA(0xFCFBF8),
            currentLine: RGBA(0x000000, alpha: 0.032), selection: RGBA(0xF2C230, alpha: 0.30),
            hover: RGBA(0x000000, alpha: 0.05), pressed: RGBA(0x000000, alpha: 0.09),
            hairline: RGBA(0x000000, alpha: 0.08), separator: RGBA(0x000000, alpha: 0.11),
            textPrimary: RGBA(0x1E1D1A), textSecondary: RGBA(0x5C5A55), textTertiary: RGBA(0x87847E),
            textOnAccent: RGBA(0x1E1A08),
            accent: RGBA(0x8C6900), accentFill: RGBA(0xF5C928), accentWash: RGBA(0xF5C928, alpha: 0.22),
            success: RGBA(0x2E8B47), warning: RGBA(0xA86400), error: RGBA(0xC8392B), info: RGBA(0x2F6BD6),
            added: RGBA(0x2E9A4E), modified: RGBA(0x2F6BD6), deleted: RGBA(0xD0453A)),
        syntax: SyntaxPalette(
            plain: RGBA(0x1E1D1A), keyword: RGBA(0xA2307A), string: RGBA(0x3D7A1F),
            number: RGBA(0xB0560A), comment: RGBA(0x87847E), type: RGBA(0x0B7A80),
            function: RGBA(0x2557C7), variable: RGBA(0x1E1D1A), constant: RGBA(0xC23A2B),
            operator: RGBA(0x5C5A55), punctuation: RGBA(0x75726C), preprocessor: RGBA(0x8C6900),
            attribute: RGBA(0x8A5A00), tag: RGBA(0x2557C7), property: RGBA(0x5B4BC4)),
        terminal: .make(foreground: RGBA(0x1E1D1A), background: RGBA(0xF7F5F0),
                        caret: RGBA(0x8C6900), selection: RGBA(0xF2C230, alpha: 0.35),
                        normal: [0x1E1D1A, 0xC8392B, 0x2E8B47, 0x8C6900, 0x2F6BD6, 0xA2307A, 0x0B7A80, 0x87847E],
                        bright: [0x5C5A55, 0xE0503F, 0x3BA85A, 0xB08A00, 0x4A84E8, 0xC04A98, 0x1A9AA0, 0xB9B6AF]))

    // MARK: Orchard (signature dark)

    static let orchard = Theme(
        id: "orchard",
        name: "Orchard",
        summary: "Deep grove green, lemon keywords",
        appearance: .dark,
        palette: Palette(
            canvas: RGBA(0x0A1210), chrome: RGBA(0x0F1916), editor: RGBA(0x121D1A),
            elevated: RGBA(0x192723), gutter: RGBA(0x121D1A),
            currentLine: RGBA(0xFFFFFF, alpha: 0.035), selection: RGBA(0xE9D45C, alpha: 0.20),
            hover: RGBA(0xFFFFFF, alpha: 0.06), pressed: RGBA(0xFFFFFF, alpha: 0.10),
            hairline: RGBA(0xFFFFFF, alpha: 0.07), separator: RGBA(0xFFFFFF, alpha: 0.10),
            textPrimary: RGBA(0xDCE7E2), textSecondary: RGBA(0x95A8A1), textTertiary: RGBA(0x667A73),
            textOnAccent: RGBA(0x13180A),
            accent: RGBA(0xE9D45C), accentFill: RGBA(0xE9D45C), accentWash: RGBA(0xE9D45C, alpha: 0.13),
            success: RGBA(0x8CD69A), warning: RGBA(0xE8B76A), error: RGBA(0xEE8274), info: RGBA(0x7FB8E8),
            added: RGBA(0x7ACB8C), modified: RGBA(0x7FB8E8), deleted: RGBA(0xEE8274)),
        syntax: SyntaxPalette(
            plain: RGBA(0xDCE7E2), keyword: RGBA(0xE9D45C), string: RGBA(0xF2B98B),
            number: RGBA(0xF0A27C), comment: RGBA(0x627A72), type: RGBA(0x8FD9C8),
            function: RGBA(0xA9C9F5), variable: RGBA(0xDCE7E2), constant: RGBA(0xF29A9A),
            operator: RGBA(0xA9B8B2), punctuation: RGBA(0x7F918A), preprocessor: RGBA(0xC5A3F0),
            attribute: RGBA(0xE8C77F), tag: RGBA(0xA9C9F5), property: RGBA(0xB9D6CC)),
        terminal: .make(foreground: RGBA(0xDCE7E2), background: RGBA(0x0F1916),
                        caret: RGBA(0xE9D45C), selection: RGBA(0xE9D45C, alpha: 0.25),
                        normal: [0x192723, 0xEE8274, 0x8CD69A, 0xE9D45C, 0x7FB8E8, 0xC5A3F0, 0x8FD9C8, 0xC9D6D1],
                        bright: [0x4E6560, 0xFF9C8F, 0xA8E6B3, 0xF7E583, 0x9DCBF2, 0xD7BEF7, 0xAEE8DB, 0xF0F6F3]))

    // MARK: Paper (signature light)

    static let paper = Theme(
        id: "paper",
        name: "Paper",
        summary: "Sepia stock and iron-gall ink",
        appearance: .light,
        palette: Palette(
            canvas: RGBA(0xE6DECD), chrome: RGBA(0xEFE8D9), editor: RGBA(0xF8F3E8),
            elevated: RGBA(0xFFFCF5), gutter: RGBA(0xF8F3E8),
            currentLine: RGBA(0x5A4A2A, alpha: 0.05), selection: RGBA(0xE3B63A, alpha: 0.30),
            hover: RGBA(0x3B2F1A, alpha: 0.06), pressed: RGBA(0x3B2F1A, alpha: 0.10),
            hairline: RGBA(0x3B2F1A, alpha: 0.10), separator: RGBA(0x3B2F1A, alpha: 0.14),
            textPrimary: RGBA(0x2B2418), textSecondary: RGBA(0x665A47), textTertiary: RGBA(0x8E816B),
            textOnAccent: RGBA(0x2B2418),
            accent: RGBA(0x855C00), accentFill: RGBA(0xE8B828), accentWash: RGBA(0xE8B828, alpha: 0.24),
            success: RGBA(0x3F7D3A), warning: RGBA(0x9C5A08), error: RGBA(0xB2392E), info: RGBA(0x2F5E9E),
            added: RGBA(0x3F7D3A), modified: RGBA(0x2F5E9E), deleted: RGBA(0xB2392E)),
        syntax: SyntaxPalette(
            plain: RGBA(0x2B2418), keyword: RGBA(0x8C2F52), string: RGBA(0x4E7A2A),
            number: RGBA(0xA2560E), comment: RGBA(0x8E816B), type: RGBA(0x1F6C73),
            function: RGBA(0x2F4F9E), variable: RGBA(0x2B2418), constant: RGBA(0xB2392E),
            operator: RGBA(0x665A47), punctuation: RGBA(0x85785F), preprocessor: RGBA(0x855C00),
            attribute: RGBA(0x7A5A1A), tag: RGBA(0x2F4F9E), property: RGBA(0x5E4596)),
        terminal: .make(foreground: RGBA(0x2B2418), background: RGBA(0xF3EDE0),
                        caret: RGBA(0x855C00), selection: RGBA(0xE3B63A, alpha: 0.35),
                        normal: [0x2B2418, 0xB2392E, 0x3F7D3A, 0x855C00, 0x2F5E9E, 0x8C2F52, 0x1F6C73, 0x8E816B],
                        bright: [0x665A47, 0xC9503F, 0x52944B, 0xA77A10, 0x4675B8, 0xA8476D, 0x2F8A91, 0xBDB29B]))

    // MARK: Seed High Contrast

    static let seedHighContrast = Theme(
        id: "seed-high-contrast",
        name: "Seed High Contrast",
        summary: "True black, maximum legibility",
        appearance: .dark,
        palette: Palette(
            canvas: RGBA(0x000000), chrome: RGBA(0x000000), editor: RGBA(0x000000),
            elevated: RGBA(0x101010), gutter: RGBA(0x000000),
            currentLine: RGBA(0xFFFFFF, alpha: 0.08), selection: RGBA(0xFFE14D, alpha: 0.35),
            hover: RGBA(0xFFFFFF, alpha: 0.12), pressed: RGBA(0xFFFFFF, alpha: 0.20),
            hairline: RGBA(0xFFFFFF, alpha: 0.32), separator: RGBA(0xFFFFFF, alpha: 0.45),
            textPrimary: RGBA(0xFFFFFF), textSecondary: RGBA(0xDADADA), textTertiary: RGBA(0xB0B0B0),
            textOnAccent: RGBA(0x000000),
            accent: RGBA(0xFFE14D), accentFill: RGBA(0xFFE14D), accentWash: RGBA(0xFFE14D, alpha: 0.22),
            success: RGBA(0x5CF08A), warning: RGBA(0xFFC24D), error: RGBA(0xFF7A6E), info: RGBA(0x7DC0FF),
            added: RGBA(0x5CF08A), modified: RGBA(0x7DC0FF), deleted: RGBA(0xFF7A6E)),
        syntax: SyntaxPalette(
            plain: RGBA(0xFFFFFF), keyword: RGBA(0xFFA8E4), string: RGBA(0xB9F27C),
            number: RGBA(0xFFC370), comment: RGBA(0xB8B8B8), type: RGBA(0x6FF0F0),
            function: RGBA(0x95CBFF), variable: RGBA(0xFFFFFF), constant: RGBA(0xFF9C8F),
            operator: RGBA(0xFFFFFF), punctuation: RGBA(0xDADADA), preprocessor: RGBA(0xFFE14D),
            attribute: RGBA(0xFFD68A), tag: RGBA(0x95CBFF), property: RGBA(0xD9D4FF)),
        terminal: .make(foreground: RGBA(0xFFFFFF), background: RGBA(0x000000),
                        caret: RGBA(0xFFE14D), selection: RGBA(0xFFE14D, alpha: 0.4),
                        normal: [0x000000, 0xFF7A6E, 0x5CF08A, 0xFFE14D, 0x7DC0FF, 0xFFA8E4, 0x6FF0F0, 0xE6E6E6],
                        bright: [0x8A8A8A, 0xFF9C8F, 0x8CFFAE, 0xFFEE8A, 0xA6D4FF, 0xFFC7EE, 0xA6FFFF, 0xFFFFFF]))
}

public extension TerminalPalette {
    static func make(foreground: RGBA, background: RGBA, caret: RGBA, selection: RGBA,
                     normal: [UInt32], bright: [UInt32]) -> TerminalPalette {
        TerminalPalette(foreground: foreground, background: background, caret: caret,
                        selection: selection, ansi: (normal + bright).map { RGBA($0) })
    }
}
