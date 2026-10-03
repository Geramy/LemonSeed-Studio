import SwiftUI

// MARK: - Section header

/// Uppercase, tracked section header used in the sidebar and settings.
public struct StudioSectionHeader<Accessory: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    private let title: String
    private let accessory: Accessory

    public init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            Text(title.uppercased())
                .font(.studioSection(type.micro))
                .tracking(0.7)
                .foregroundStyle(theme.palette.textTertiary.color)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            accessory
        }
        .accessibilityAddTraits(.isHeader)
    }
}

public extension StudioSectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

// MARK: - Key caps

/// Renders a shortcut such as "⌘⇧P" as small key caps.
public struct KeyCaps: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    private let keys: [String]

    /// `shortcut` is split into glyphs; modifiers and the key each get a cap.
    public init(_ shortcut: String) {
        keys = Self.split(shortcut)
    }

    /// "⌘⇧P" -> ["⌘", "⇧", "P"]; "⌃`" -> ["⌃", "`"]; "F12" -> ["F12"].
    nonisolated public static func split(_ shortcut: String) -> [String] {
        let modifiers: Set<Character> = ["⌘", "⇧", "⌥", "⌃"]
        var parts: [String] = []
        var rest = Substring(shortcut)
        while let first = rest.first, modifiers.contains(first) {
            parts.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: type.micro + 0.5, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.palette.textSecondary.color)
                    .frame(minWidth: type.micro + 7)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1.5)
                    .background(theme.palette.hover.color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.palette.hairline.color, lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

// MARK: - Badges and dots

/// A small count badge, e.g. problems or changes.
public struct CountBadge: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    private let count: Int
    private let prominent: Bool

    public init(_ count: Int, prominent: Bool = false) {
        self.count = count
        self.prominent = prominent
    }

    public var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.studioNumeric(type.micro, weight: .semibold))
            .foregroundStyle(prominent ? theme.palette.textOnAccent.color : theme.palette.textSecondary.color)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 15)
            .background(prominent ? theme.palette.accentFill.color : theme.palette.hover.color, in: Capsule())
    }
}

/// A status dot with an optional soft halo (used for live states).
public struct StatusDot: View {
    private let color: Color
    private let live: Bool

    public init(_ color: Color, live: Bool = false) {
        self.color = color
        self.live = live
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(live ? 0.28 : 0)).frame(width: 13, height: 13))
            .accessibilityHidden(true)
    }
}

// MARK: - Hairline

/// A one-pixel separator in the theme's hairline color.
public struct Hairline: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var scale
    private let axis: Axis

    public init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        Rectangle()
            .fill(theme.palette.hairline.color)
            .frame(width: axis == .vertical ? 1 / scale : nil, height: axis == .horizontal ? 1 / scale : nil)
            .accessibilityHidden(true)
    }
}

// MARK: - Empty state

/// A calm empty or unavailable state: symbol, title, message, actions.
public struct StudioEmptyState<Actions: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    private let symbol: String
    private let title: String
    private let message: String
    private let actions: Actions

    public init(symbol: String, title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.palette.textTertiary.color)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, Space.xs)
            Text(title)
                .font(.studio(type.body + 1, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary.color)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.studio(type.caption + 0.5))
                .foregroundStyle(theme.palette.textSecondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            actions
                .padding(.top, Space.xs)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public extension StudioEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Highlighted text

/// Text with some character offsets emphasized (fuzzy-match highlighting).
public struct HighlightedText: View {
    @Environment(\.theme) private var theme
    private let text: String
    private let highlights: Set<Int>
    private let baseColor: Color?

    public init(_ text: String, highlights: some Sequence<Int>, baseColor: Color? = nil) {
        self.text = text
        self.highlights = Set(highlights)
        self.baseColor = baseColor
    }

    public var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if highlights.contains(offset) {
                piece.foregroundColor = theme.palette.accent.color
                piece.inlinePresentationIntent = .stronglyEmphasized
            } else if let baseColor {
                piece.foregroundColor = baseColor
            }
            result.append(piece)
        }
        return result
    }
}
