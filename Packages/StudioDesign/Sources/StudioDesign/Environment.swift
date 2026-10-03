import SwiftUI

public extension EnvironmentValues {
    /// The active Studio theme.
    @Entry var theme: Theme = .lemonDark
    /// The resolved input density (never `.automatic`).
    @Entry var density: Density = .touch
    /// The code font in use.
    @Entry var codeFont: CodeFont = .default
}

public extension EnvironmentValues {
    var metrics: Metrics { Metrics.for(density) }
    var typeScale: TypeScale { TypeScale.for(density) }
}

public extension View {
    /// Applies a theme: the environment value, the color scheme for system
    /// controls, and the accent as the tint.
    func studioTheme(_ theme: Theme) -> some View {
        environment(\.theme, theme)
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.palette.accent.color)
    }
}
