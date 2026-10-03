import UIKit

/// The editor font. `nil` family means SF Mono.
public struct EditorFont: Hashable, Sendable, Codable {
    public var familyName: String?
    public var size: CGFloat
    /// Snap line heights to this grid (in points). The plan's typography uses a 4 pt baseline grid.
    public var baselineGrid: CGFloat
    /// Minimum line height as a multiple of the font size, before snapping.
    public var lineSpacing: CGFloat

    public init(familyName: String? = nil, size: CGFloat = 14, baselineGrid: CGFloat = 4, lineSpacing: CGFloat = 1.45) {
        self.familyName = familyName
        self.size = size
        self.baselineGrid = baselineGrid
        self.lineSpacing = lineSpacing
    }

    @MainActor public var uiFont: UIFont {
        if let familyName, let font = UIFont(name: familyName, size: size) {
            return font
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The line height multiplier that puts every line on the baseline grid.
    @MainActor public var lineHeightMultiplier: CGFloat {
        let font = uiFont
        let natural = font.lineHeight
        let target = max(natural, size * lineSpacing)
        let snapped = baselineGrid > 0 ? (target / baselineGrid).rounded(.up) * baselineGrid : target
        return snapped / natural
    }
}

/// Behaviour and display options for an editor. A value type so a settings screen can bind to it.
public struct EditorConfiguration: Hashable, Sendable {
    public var font = EditorFont()
    public var showLineNumbers = true
    public var highlightCurrentLine = true
    public var showIndentGuides = true
    public var showInvisibles = false
    public var softWrap = false
    public var showMinimap = true
    public var matchBrackets = true
    public var autoClosePairs = true
    /// Shows completions as you type an identifier, not only on ⌃Space or a trigger character.
    public var suggestsWhileTyping = true
    public var showFoldingControls = true
    public var tabWidth = 4
    public var insertSpaces = true
    /// A vertical ruler at this column, or nil for none.
    public var pageGuideColumn: Int?
    /// Lets the last line scroll up to the middle of the view.
    public var scrollPastEnd = true
    public var isEditable = true

    public init() {}

    /// Defaults for a language: Go and Makefiles use tabs, the rest spaces.
    public static func defaults(for language: LemonLanguage) -> EditorConfiguration {
        var configuration = EditorConfiguration()
        configuration.insertSpaces = !language.prefersTabs
        if language == .markdown || language == .plainText {
            configuration.softWrap = true
            configuration.showIndentGuides = false
        }
        return configuration
    }
}
