public import SwiftUI

/// Colors and fonts the Git views use. Plain SwiftUI defaults; the design
/// package replaces the whole value with `.gitTheme(_:)` to theme every
/// Git screen at once.
public struct GitTheme: Sendable {
    public var accent: Color = .accentColor
    public var added: Color = .green
    public var modified: Color = .orange
    public var deleted: Color = .red
    public var renamed: Color = .blue
    public var untracked: Color = .teal
    public var conflict: Color = .pink
    public var secondaryText: Color = .secondary
    public var diffAddedBackground: Color = .green.opacity(0.14)
    public var diffRemovedBackground: Color = .red.opacity(0.14)
    public var diffHunkHeaderBackground: Color = .blue.opacity(0.08)
    public var selectionBackground: Color = .accentColor.opacity(0.18)
    /// History graph lane colors, cycled.
    public var laneColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo]
    public var codeFont: Font = .system(.footnote, design: .monospaced)
    public var codeLineHeight: CGFloat = 18
    public var ciSuccess: Color = .green
    public var ciFailure: Color = .red
    public var ciPending: Color = .yellow

    public init() {}

    public func laneColor(_ index: Int) -> Color {
        laneColors.isEmpty ? accent : laneColors[((index % laneColors.count) + laneColors.count) % laneColors.count]
    }
}

private struct GitThemeKey: EnvironmentKey {
    static let defaultValue = GitTheme()
}

extension EnvironmentValues {
    public var gitTheme: GitTheme {
        get { self[GitThemeKey.self] }
        set { self[GitThemeKey.self] = newValue }
    }
}

extension View {
    /// Applies a theme to every Git view below.
    public func gitTheme(_ theme: GitTheme) -> some View {
        environment(\.gitTheme, theme)
    }
}
