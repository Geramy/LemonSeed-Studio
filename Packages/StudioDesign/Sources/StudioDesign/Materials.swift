import SwiftUI

/// Materials. The editor and chrome are opaque; Liquid Glass is reserved for
/// floating layers (command palette, popovers, floating toolbars, the agent
/// composer), which is where it reads as depth rather than noise.
public enum StudioMaterial {
    case opaque
    case floating
    case floatingInteractive
}

public extension View {
    /// A floating Liquid Glass layer with a theme-tinted rim.
    func floatingSurface(cornerRadius: CGFloat = Radius.l, interactive: Bool = false) -> some View {
        modifier(FloatingSurface(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// An opaque card on the elevated surface with a hairline border.
    func elevatedSurface(cornerRadius: CGFloat = Radius.m) -> some View {
        modifier(ElevatedSurface(cornerRadius: cornerRadius))
    }
}

private struct FloatingSurface: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(theme.palette.elevated.color, in: shape)
                .overlay(shape.strokeBorder(theme.palette.separator.color, lineWidth: 1))
        } else {
            content
                .glassEffect(interactive ? .regular.tint(theme.palette.elevated.opacity(0.55).color).interactive()
                                         : .regular.tint(theme.palette.elevated.opacity(0.55).color),
                             in: shape)
                .overlay(shape.strokeBorder(theme.palette.hairline.color, lineWidth: 0.5))
                .shadow(color: .black.opacity(theme.appearance == .dark ? 0.45 : 0.14), radius: 30, y: 14)
        }
    }
}

private struct ElevatedSurface: ViewModifier {
    @Environment(\.theme) private var theme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(theme.palette.elevated.color, in: shape)
            .overlay(shape.strokeBorder(theme.palette.hairline.color, lineWidth: 1))
    }
}
