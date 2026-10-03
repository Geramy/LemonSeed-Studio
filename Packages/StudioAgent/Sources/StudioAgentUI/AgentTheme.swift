import SwiftUI

/// Every color, font and metric the agent views use.
///
/// The views read the theme from the environment and never hard-code
/// styling, so the Studio's design package can supply its own tokens with
/// `.agentTheme(_:)`. The defaults follow the Studio's plan: one warm
/// "lemon" accent tuned per appearance, calm opaque content surfaces, and
/// SF Mono for code.
public struct AgentTheme: Sendable {
    public var accent: Color
    /// Text and symbols placed on `accent`.
    public var onAccent: Color
    public var background: Color
    public var surface: Color
    public var elevatedSurface: Color
    public var codeBackground: Color
    public var hairline: Color
    public var primaryText: Color
    public var secondaryText: Color
    public var tertiaryText: Color
    public var userBubble: Color
    public var addition: Color
    public var additionBackground: Color
    public var deletion: Color
    public var deletionBackground: Color
    public var warning: Color
    public var danger: Color
    public var success: Color

    public var bodyFont: Font
    public var codeFont: Font
    public var smallCodeFont: Font
    public var captionFont: Font
    public var titleFont: Font

    public var cornerRadius: CGFloat
    public var cardRadius: CGFloat
    public var spacing: CGFloat

    /// Syntax colors for code blocks.
    public var syntaxKeyword: Color
    public var syntaxString: Color
    public var syntaxComment: Color
    public var syntaxNumber: Color

    public static let standard = AgentTheme(
        accent: Color(light: Color(red: 0.86, green: 0.66, blue: 0.0), dark: Color(red: 1.0, green: 0.86, blue: 0.27)),
        onAccent: Color(light: .white, dark: Color(red: 0.13, green: 0.11, blue: 0.02)),
        background: Color(light: Color(red: 0.975, green: 0.972, blue: 0.962), dark: Color(red: 0.075, green: 0.075, blue: 0.08)),
        surface: Color(light: .white, dark: Color(red: 0.115, green: 0.115, blue: 0.125)),
        elevatedSurface: Color(light: Color(red: 0.995, green: 0.993, blue: 0.985), dark: Color(red: 0.15, green: 0.15, blue: 0.16)),
        codeBackground: Color(light: Color(red: 0.955, green: 0.951, blue: 0.938), dark: Color(red: 0.095, green: 0.095, blue: 0.105)),
        hairline: Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.09)),
        primaryText: Color(light: Color(red: 0.11, green: 0.11, blue: 0.12), dark: Color(red: 0.93, green: 0.93, blue: 0.92)),
        secondaryText: Color(light: Color(red: 0.38, green: 0.38, blue: 0.40), dark: Color(red: 0.64, green: 0.64, blue: 0.66)),
        tertiaryText: Color(light: Color(red: 0.58, green: 0.58, blue: 0.60), dark: Color(red: 0.45, green: 0.45, blue: 0.48)),
        userBubble: Color(light: Color(red: 1.0, green: 0.95, blue: 0.78), dark: Color(red: 0.25, green: 0.22, blue: 0.10)),
        addition: Color(light: Color(red: 0.10, green: 0.50, blue: 0.22), dark: Color(red: 0.45, green: 0.85, blue: 0.52)),
        additionBackground: Color(light: Color(red: 0.88, green: 0.96, blue: 0.89), dark: Color(red: 0.10, green: 0.22, blue: 0.13)),
        deletion: Color(light: Color(red: 0.70, green: 0.15, blue: 0.15), dark: Color(red: 1.0, green: 0.50, blue: 0.47)),
        deletionBackground: Color(light: Color(red: 0.99, green: 0.91, blue: 0.90), dark: Color(red: 0.27, green: 0.11, blue: 0.11)),
        warning: Color(light: Color(red: 0.80, green: 0.45, blue: 0.0), dark: Color(red: 1.0, green: 0.68, blue: 0.25)),
        danger: Color(light: Color(red: 0.78, green: 0.16, blue: 0.16), dark: Color(red: 1.0, green: 0.42, blue: 0.40)),
        success: Color(light: Color(red: 0.12, green: 0.55, blue: 0.28), dark: Color(red: 0.42, green: 0.86, blue: 0.53)),
        bodyFont: .system(size: 15, weight: .regular),
        codeFont: .system(size: 13, weight: .regular, design: .monospaced),
        smallCodeFont: .system(size: 12, weight: .regular, design: .monospaced),
        captionFont: .system(size: 12, weight: .medium),
        titleFont: .system(size: 17, weight: .semibold),
        cornerRadius: 10, cardRadius: 14, spacing: 12,
        syntaxKeyword: Color(light: Color(red: 0.62, green: 0.13, blue: 0.55), dark: Color(red: 0.99, green: 0.47, blue: 0.80)),
        syntaxString: Color(light: Color(red: 0.70, green: 0.25, blue: 0.10), dark: Color(red: 0.99, green: 0.62, blue: 0.43)),
        syntaxComment: Color(light: Color(red: 0.42, green: 0.48, blue: 0.42), dark: Color(red: 0.50, green: 0.58, blue: 0.50)),
        syntaxNumber: Color(light: Color(red: 0.11, green: 0.33, blue: 0.75), dark: Color(red: 0.55, green: 0.75, blue: 1.0)))
}

extension Color {
    /// A color that resolves per appearance.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #else
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light) })
        #endif
    }
}

private struct AgentThemeKey: EnvironmentKey {
    static let defaultValue = AgentTheme.standard
}

extension EnvironmentValues {
    public var agentTheme: AgentTheme {
        get { self[AgentThemeKey.self] }
        set { self[AgentThemeKey.self] = newValue }
    }
}

extension View {
    /// Styles every agent view below this one.
    public func agentTheme(_ theme: AgentTheme) -> some View {
        environment(\.agentTheme, theme)
    }
}
