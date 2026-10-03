import Foundation
@testable import LemonText
import Testing

@Suite("Theme mapping")
struct ThemeTests {
    @Test func parsesHexColors() throws {
        let rgb = try #require(ThemeColor(hex: "#F4D03F"))
        #expect(rgb.hexString == "#F4D03F")
        #expect(rgb.alpha == 1)
        let rgba = try #require(ThemeColor(hex: "11223380"))
        #expect(abs(rgba.alpha - 128.0 / 255.0) < 0.0001)
        let short = try #require(ThemeColor(hex: "#fff"))
        #expect(short == .white)
        #expect(ThemeColor(hex: "#12345") == nil)
        #expect(ThemeColor(hex: "zzzzzz") == nil)
    }

    @Test func resolvesCapturesThroughTheDottedHierarchy() {
        let theme = EditorTheme.lemonDark
        #expect(theme.style(forCapture: "keyword.control.return") == theme.syntax["keyword"])
        #expect(theme.style(forCapture: "keyword.coroutine") == theme.syntax["keyword"])
        #expect(theme.style(forCapture: "string.special.symbol") == theme.syntax["string.special"])
        #expect(theme.style(forCapture: "@comment") == theme.syntax["comment"])
        #expect(theme.style(forCapture: "nonexistent") == nil)
    }

    @Test func resolvesAliasesFromOtherQuerySets() {
        let theme = EditorTheme.lemonDark
        #expect(theme.style(forCapture: "include") == theme.syntax["keyword.directive"])
        #expect(theme.style(forCapture: "method.call") == theme.syntax["function"])
        #expect(theme.style(forCapture: "parameter") == theme.syntax["variable.parameter"])
        #expect(theme.style(forCapture: "text.title") == theme.syntax["markup.heading"])
        #expect(theme.style(forCapture: "function.macro") == theme.syntax["function.builtin"])
    }

    @Test func derivesEditorColorsFromThePalette() {
        let palette = ThemePalette.lemonLight
        let theme = EditorTheme(name: "Test", palette: palette)
        #expect(theme.background == palette.background)
        #expect(theme.foreground == palette.text)
        #expect(theme.caret == palette.accent)
        #expect(theme.lineNumber == palette.tertiaryText)
        #expect(theme.error == palette.red)
        #expect(theme.selection.red == palette.accent.red && theme.selection.alpha < 1)
        #expect(theme.syntax["string"]?.color == palette.green)
        #expect(theme.syntax["comment"]?.isItalic == true)
        #expect(!theme.isDark)
    }

    @Test(arguments: EditorTheme.builtIn)
    func builtInThemesAreReadable(theme: EditorTheme) {
        // Body text must meet WCAG AAA against the editor surface; comments at least AA-large.
        #expect(theme.foreground.contrastRatio(with: theme.background) >= 7)
        let comment = theme.syntax["comment"]!.color
        #expect(comment.contrastRatio(with: theme.background) >= 3)
        for name in ["keyword", "string", "number", "function", "type"] {
            let color = theme.syntax[name]!.color
            #expect(color.contrastRatio(with: theme.background) >= 4.5, "\(theme.name) \(name)")
        }
    }

    @Test func compositesTranslucentColors() {
        let half = ThemeColor.white.withAlpha(0.5)
        let result = half.composited(over: .black)
        #expect(abs(result.red - 0.5) < 0.001 && result.alpha == 1)
    }
}

@Suite("VS Code theme import")
struct VSCodeThemeImportTests {
    let themeJSON = """
    // A VS Code theme, with comments and trailing commas
    {
      "name": "Test Night",
      "type": "dark",
      "colors": {
        "editor.background": "#101010",
        "editor.foreground": "#EEEEEE",
        "editorLineNumber.foreground": "#555555", /* gutter */
        "editorCursor.foreground": "#FFCC00",
        "editor.selectionBackground": "#FFCC0040",
      },
      "tokenColors": [
        { "settings": { "foreground": "#DDDDDD" } },
        { "scope": "comment", "settings": { "foreground": "#666666", "fontStyle": "italic" } },
        { "scope": ["keyword", "storage.type"], "settings": { "foreground": "#FF79C6" } },
        { "scope": "keyword.operator", "settings": { "foreground": "#AAAAAA" } },
        { "scope": "string, constant.character.escape", "settings": { "foreground": "#F1FA8C" } },
        { "scope": "entity.name.function", "settings": { "foreground": "#50FA7B", "fontStyle": "bold" } },
        { "scope": "meta.class entity.name.type.class", "settings": { "foreground": "#8BE9FD" } },
      ],
    }
    """

    @Test func importsWorkbenchAndTokenColors() throws {
        let theme = try VSCodeThemeImporter.importTheme(from: Data(themeJSON.utf8))
        #expect(theme.name == "Test Night")
        #expect(theme.isDark)
        #expect(theme.background == ThemeColor(hex: "#101010"))
        #expect(theme.foreground == ThemeColor(hex: "#DDDDDD"))
        #expect(theme.lineNumber == ThemeColor(hex: "#555555"))
        #expect(theme.caret == ThemeColor(hex: "#FFCC00"))
        #expect(theme.selection == ThemeColor(hex: "#FFCC0040"))
        #expect(theme.style(forCapture: "comment")?.color == ThemeColor(hex: "#666666"))
        #expect(theme.style(forCapture: "comment")?.isItalic == true)
        #expect(theme.style(forCapture: "keyword")?.color == ThemeColor(hex: "#FF79C6"))
        #expect(theme.style(forCapture: "operator")?.color == ThemeColor(hex: "#AAAAAA"))
        #expect(theme.style(forCapture: "string")?.color == ThemeColor(hex: "#F1FA8C"))
        #expect(theme.style(forCapture: "string.escape")?.color == ThemeColor(hex: "#F1FA8C"))
        #expect(theme.style(forCapture: "function")?.color == ThemeColor(hex: "#50FA7B"))
        #expect(theme.style(forCapture: "function")?.isBold == true)
        #expect(theme.style(forCapture: "type")?.color == ThemeColor(hex: "#8BE9FD"))
    }

    @Test func mapsTextMateScopesToCaptures() {
        #expect(VSCodeThemeImporter.capture(forScope: "entity.name.function.cpp")?.0 == "function")
        #expect(VSCodeThemeImporter.capture(forScope: "keyword.operator.arithmetic")?.0 == "operator")
        #expect(VSCodeThemeImporter.capture(forScope: "keyword.control.directive.include")?.0 == "keyword.directive")
        #expect(VSCodeThemeImporter.capture(forScope: "variable.language.this")?.0 == "variable.builtin")
        #expect(VSCodeThemeImporter.capture(forScope: "unknown.scope") == nil)
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: VSCodeThemeImporter.ImportError.self) {
            try VSCodeThemeImporter.importTheme(from: Data("{ not json".utf8))
        }
        #expect(throws: VSCodeThemeImporter.ImportError.missingColors) {
            try VSCodeThemeImporter.importTheme(from: Data("{\"name\": \"Empty\"}".utf8))
        }
    }

    @Test func sanitizerKeepsCommentMarkersInsideStrings() {
        let input = "{\"url\": \"https://example.com/a//b\", /* x */ \"b\": [1,2,],}"
        #expect(JSONCSanitizer.sanitize(input) == "{\"url\": \"https://example.com/a//b\",  \"b\": [1,2]}")
    }
}
