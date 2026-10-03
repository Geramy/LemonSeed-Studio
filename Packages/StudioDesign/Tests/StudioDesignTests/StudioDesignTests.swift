import XCTest
@testable import StudioDesign

final class ThemeTests: XCTestCase {
    func testThemeIDsAreUnique() {
        let ids = Theme.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for theme in Theme.builtIn {
            XCTAssertEqual(Theme.named(theme.id), theme)
        }
    }

    /// Body text must reach WCAG AA (4.5:1) on the editor and chrome in every
    /// theme; the high-contrast theme must reach AAA (7:1).
    func testPrimaryTextContrast() {
        for theme in Theme.builtIn {
            let p = theme.palette
            let minimum = theme.id == Theme.seedHighContrast.id ? 7.0 : 4.5
            XCTAssertGreaterThanOrEqual(p.textPrimary.contrast(against: p.editor), minimum, theme.name)
            XCTAssertGreaterThanOrEqual(p.textPrimary.contrast(against: p.chrome), minimum, theme.name)
            XCTAssertGreaterThanOrEqual(p.textSecondary.contrast(against: p.chrome), 4.5, "\(theme.name) secondary")
        }
    }

    /// Tertiary text, the accent and every syntax role stay legible (3:1,
    /// WCAG's large-text and UI-component threshold) on the editor.
    func testSyntaxAndAccentContrast() {
        for theme in Theme.builtIn {
            let editor = theme.palette.editor
            XCTAssertGreaterThanOrEqual(theme.palette.textTertiary.contrast(against: editor), 3, "\(theme.name) tertiary")
            XCTAssertGreaterThanOrEqual(theme.palette.accent.contrast(against: editor), 3, "\(theme.name) accent")
            for role in SyntaxPalette.Role.allCases {
                XCTAssertGreaterThanOrEqual(theme.syntax[role].contrast(against: editor), 3,
                                            "\(theme.name) \(role.rawValue)")
            }
        }
    }

    func testAccentFillCarriesTextOnAccent() {
        for theme in Theme.builtIn {
            XCTAssertGreaterThanOrEqual(theme.palette.textOnAccent.contrast(against: theme.palette.accentFill), 7, theme.name)
        }
    }

    func testTerminalPalettesHaveSixteenColors() {
        for theme in Theme.builtIn {
            XCTAssertEqual(theme.terminal.ansi.count, 16)
            XCTAssertGreaterThanOrEqual(theme.terminal.foreground.contrast(against: theme.terminal.background), 7, theme.name)
        }
    }

    func testAppearanceMatchesBackgroundLuminance() {
        for theme in Theme.builtIn {
            let dark = theme.palette.editor.luminance < 0.2
            XCTAssertEqual(dark, theme.appearance == .dark, theme.name)
        }
    }
}

final class ColorTests: XCTestCase {
    func testHexRoundTrip() {
        XCTAssertEqual(RGBA(0xF5D547).hexString, "#F5D547")
        XCTAssertEqual(RGBA(hexString: "#F5D547"), RGBA(0xF5D547))
        XCTAssertEqual(RGBA(hexString: "f5d547")?.hexString, "#F5D547")
        let withAlpha = RGBA(hexString: "#00000080")
        XCTAssertEqual(withAlpha?.alpha ?? 0, 128.0 / 255, accuracy: 0.0001)
        XCTAssertNil(RGBA(hexString: "#12345"))
        XCTAssertNil(RGBA(hexString: "zzzzzz"))
    }

    func testContrastExtremes() {
        XCTAssertEqual(RGBA(0xFFFFFF).contrast(against: RGBA(0x000000)), 21, accuracy: 0.01)
        XCTAssertEqual(RGBA(0x777777).contrast(against: RGBA(0x777777)), 1, accuracy: 0.0001)
    }

    func testCompositing() {
        let half = RGBA(0xFFFFFF, alpha: 0.5).composited(over: RGBA(0x000000))
        XCTAssertEqual(half.red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.alpha, 1)
    }

    func testMix() {
        let mid = RGBA(0x000000).mixed(with: RGBA(0xFFFFFF), 0.5)
        XCTAssertEqual(mid.green, 0.5, accuracy: 0.0001)
    }
}

final class MetricsTests: XCTestCase {
    func testGridSnapping() {
        XCTAssertEqual(Grid.snapUp(21), 24)
        XCTAssertEqual(Grid.snapUp(24), 24)
        XCTAssertEqual(Grid.snap(21.9), 20)
        XCTAssertEqual(Grid.snap(22.1), 24)
    }

    func testCodeFontLineHeightIsOnGrid() {
        for size in stride(from: CodeFont.sizeRange.lowerBound, through: CodeFont.sizeRange.upperBound, by: 1) {
            let font = CodeFont(family: .sfMono, size: size)
            XCTAssertEqual(font.lineHeight.truncatingRemainder(dividingBy: 4), 0)
            XCTAssertGreaterThanOrEqual(font.lineHeight, size * 1.5)
        }
    }

    func testCodeFontSizeIsClamped() {
        XCTAssertEqual(CodeFont(family: .menlo, size: 2).size, CodeFont.sizeRange.lowerBound)
        XCTAssertEqual(CodeFont(family: .menlo, size: 200).size, CodeFont.sizeRange.upperBound)
    }

    func testTouchTargetsMeetGuidelines() {
        XCTAssertGreaterThanOrEqual(Metrics.touch.hitTarget, 44)
        XCTAssertGreaterThanOrEqual(Metrics.pointer.hitTarget, 24)
    }

    func testBundledFontsArePresent() {
        FontRegistry.registerBundledFonts()
        XCTAssertFalse(FontRegistry.bundledLicenses().isEmpty)
    }
}

final class IconographyTests: XCTestCase {
    func testFileIcons() {
        XCTAssertEqual(FileIcon.forFile(named: "main.swift").symbol, "swift")
        XCTAssertEqual(FileIcon.forFile(named: "Makefile").symbol, "hammer")
        XCTAssertEqual(FileIcon.forFile(named: "README.md").symbol, "book.closed")
        XCTAssertEqual(FileIcon.forFile(named: "LICENSE").symbol, "checkmark.seal")
        XCTAssertEqual(FileIcon.forFile(named: "kernel.hpp").symbol, "h.square")
        XCTAssertEqual(FileIcon.forFile(named: "unknown.zzz"), .generic)
        XCTAssertEqual(FileIcon.forFile(named: ".gitignore").symbol, "arrow.triangle.branch")
        XCTAssertEqual(FileIcon.forFile(named: ".env").symbol, "gearshape")
    }

    func testCaptureRoles() {
        XCTAssertEqual(SyntaxPalette.role(forCapture: "keyword.control"), .keyword)
        XCTAssertEqual(SyntaxPalette.role(forCapture: "string.special"), .string)
        XCTAssertEqual(SyntaxPalette.role(forCapture: "function.method.call"), .function)
        XCTAssertEqual(SyntaxPalette.role(forCapture: "variable.member"), .property)
        XCTAssertEqual(SyntaxPalette.role(forCapture: "nonsense"), .plain)
    }

    func testKeyCapParsing() {
        XCTAssertEqual(KeyCaps.split("⌘⇧P"), ["⌘", "⇧", "P"])
        XCTAssertEqual(KeyCaps.split("⌃`"), ["⌃", "`"])
        XCTAssertEqual(KeyCaps.split("F12"), ["F12"])
        XCTAssertEqual(KeyCaps.split("⌘\\"), ["⌘", "\\"])
    }
}
