import LemonTextCore
import UIKit

/// Adapts an ``EditorTheme`` and font to the theme protocol the text engine draws with.
final class CoreThemeAdapter: LemonTextCore.Theme {
    let editorTheme: EditorTheme
    let font: UIFont
    let textColor: UIColor
    let gutterBackgroundColor: UIColor
    let gutterHairlineColor: UIColor
    let gutterHairlineWidth: CGFloat = 0
    let lineNumberColor: UIColor
    let lineNumberFont: UIFont
    let selectedLineBackgroundColor: UIColor
    let selectedLinesLineNumberColor: UIColor
    let selectedLinesGutterBackgroundColor: UIColor
    let invisibleCharactersColor: UIColor
    let pageGuideHairlineColor: UIColor
    let pageGuideHairlineWidth: CGFloat = 1
    let pageGuideBackgroundColor: UIColor
    let markedTextBackgroundColor: UIColor
    let markedTextBackgroundCornerRadius: CGFloat = 3

    private let lock = NSLock()
    private var colorCache: [String: UIColor?] = [:]
    private var traitsCache: [String: FontTraits] = [:]

    init(theme: EditorTheme, font: UIFont, lineNumberFont: UIFont) {
        editorTheme = theme
        self.font = font
        self.lineNumberFont = lineNumberFont
        textColor = theme.foreground.uiColor
        gutterBackgroundColor = theme.gutterBackground.uiColor
        gutterHairlineColor = theme.gutterHairline.uiColor
        lineNumberColor = theme.lineNumber.uiColor
        selectedLineBackgroundColor = theme.currentLine.uiColor
        selectedLinesLineNumberColor = theme.activeLineNumber.uiColor
        selectedLinesGutterBackgroundColor = theme.currentLine.uiColor
        invisibleCharactersColor = theme.invisibles.uiColor
        pageGuideHairlineColor = theme.indentGuide.uiColor
        pageGuideBackgroundColor = theme.foreground.withAlpha(0.015).uiColor
        markedTextBackgroundColor = theme.selection.uiColor
    }

    // Syntax highlighting runs on a background queue, so lookups are cached behind a lock.
    func textColor(for highlightName: String) -> UIColor? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = colorCache[highlightName] {
            return cached
        }
        let color = editorTheme.style(forCapture: highlightName)?.color.uiColor
        colorCache[highlightName] = color
        return color
    }

    func font(for highlightName: String) -> UIFont? {
        nil
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        lock.lock()
        defer { lock.unlock() }
        if let cached = traitsCache[highlightName] {
            return cached
        }
        var traits: FontTraits = []
        if let style = editorTheme.style(forCapture: highlightName) {
            if style.isBold {
                traits.insert(.bold)
            }
            if style.isItalic {
                traits.insert(.italic)
            }
        }
        traitsCache[highlightName] = traits
        return traits
    }

    func shadow(for highlightName: String) -> NSShadow? {
        nil
    }

    func highlightedRange(forFoundTextRange foundTextRange: NSRange, ofStyle style: UITextSearchFoundTextStyle) -> HighlightedRange? {
        switch style {
        case .found:
            HighlightedRange(range: foundTextRange, color: editorTheme.findMatch.uiColor, cornerRadius: 2)
        case .highlighted:
            HighlightedRange(range: foundTextRange, color: editorTheme.currentFindMatch.uiColor, cornerRadius: 2)
        case .normal:
            nil
        @unknown default:
            nil
        }
    }
}
