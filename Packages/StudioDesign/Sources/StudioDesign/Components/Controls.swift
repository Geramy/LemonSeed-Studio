import SwiftUI

// MARK: - Icon button

/// A borderless toolbar icon with a hover wash, a pointer lift on iPad, a
/// tooltip, and a hit target that never drops below the density minimum.
public struct StudioIconButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    private let symbol: String
    private let help: String
    private let isActive: Bool
    private let action: () -> Void

    public init(_ symbol: String, help: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: metrics.iconSize - 1, weight: .medium))
                .symbolVariant(isActive ? .fill : .none)
                .foregroundStyle(isActive ? theme.palette.accent.color
                                 : hovering ? theme.palette.textPrimary.color : theme.palette.textSecondary.color)
                .frame(width: metrics.hitTarget, height: metrics.hitTarget)
                .background {
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(hovering ? theme.palette.hover.color : .clear)
                        .padding(metrics.hitTarget > 30 ? 6 : 2)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .studioHover($hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Buttons

public struct StudioButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, plain, destructive }

    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    @Environment(\.isEnabled) private var isEnabled
    private let kind: Kind

    public init(_ kind: Kind = .secondary) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        let p = theme.palette
        let shape = RoundedRectangle(cornerRadius: Radius.s + 2, style: .continuous)
        configuration.label
            .font(.studio(type.label, weight: kind == .primary ? .semibold : .medium))
            .padding(.horizontal, Space.m + 2)
            .frame(minHeight: max(metrics.hitTarget - 4, 30))
            .foregroundStyle(foreground(p))
            .background(background(p, pressed: configuration.isPressed), in: shape)
            .overlay(shape.strokeBorder(kind == .secondary ? p.separator.color : .clear, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.feedback, value: configuration.isPressed)
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
    }

    private func foreground(_ p: Palette) -> Color {
        switch kind {
        case .primary: p.textOnAccent.color
        case .secondary, .plain: p.textPrimary.color
        case .destructive: p.error.color
        }
    }

    private func background(_ p: Palette, pressed: Bool) -> Color {
        switch kind {
        case .primary: p.accentFill.color.opacity(pressed ? 0.85 : 1)
        case .secondary: (pressed ? p.pressed : p.hover).color
        case .plain: pressed ? p.pressed.color : .clear
        case .destructive: p.error.opacity(pressed ? 0.22 : 0.14).color
        }
    }
}

public extension ButtonStyle where Self == StudioButtonStyle {
    static var studioPrimary: StudioButtonStyle { StudioButtonStyle(.primary) }
    static var studioSecondary: StudioButtonStyle { StudioButtonStyle(.secondary) }
    static var studioPlain: StudioButtonStyle { StudioButtonStyle(.plain) }
    static var studioDestructive: StudioButtonStyle { StudioButtonStyle(.destructive) }
}

// MARK: - Text field

public struct StudioFieldStyle: TextFieldStyle {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    private let symbol: String?

    public init(symbol: String? = nil) {
        self.symbol = symbol
    }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        HStack(spacing: Space.s) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: type.caption, weight: .medium))
                    .foregroundStyle(theme.palette.textTertiary.color)
            }
            configuration
                .font(.studio(type.body))
                .foregroundStyle(theme.palette.textPrimary.color)
        }
        .padding(.horizontal, Space.s + 2)
        .frame(minHeight: max(metrics.rowHeight, 30))
        .background(theme.palette.editor.color, in: RoundedRectangle(cornerRadius: Radius.s + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s + 1, style: .continuous)
            .strokeBorder(theme.palette.separator.color, lineWidth: 1))
    }
}

// MARK: - Hover

public extension View {
    /// Tracks pointer hover into a binding and adds the system lift effect.
    func studioHover(_ hovering: Binding<Bool>) -> some View {
        self
            .onHover { inside in
                withAnimation(Motion.feedback) { hovering.wrappedValue = inside }
            }
    }

    /// A row background: accent wash when selected, hover wash on hover.
    func studioRowBackground(selected: Bool, hovering: Bool, cornerRadius: CGFloat = Radius.s) -> some View {
        modifier(RowBackground(selected: selected, hovering: hovering, cornerRadius: cornerRadius))
    }
}

private struct RowBackground: ViewModifier {
    @Environment(\.theme) private var theme
    let selected: Bool
    let hovering: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(selected ? theme.palette.accentWash.color : hovering ? theme.palette.hover.color : .clear)
        }
    }
}
