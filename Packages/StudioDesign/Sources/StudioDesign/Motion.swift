import SwiftUI

/// Motion tokens. Springs everywhere, tuned for 120 Hz; every token
/// collapses to a short fade when Reduce Motion is on.
public enum Motion {
    /// Pane splits, sidebar and panel reveal: settles in about 350 ms.
    public static let layout = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Tab moves and reorders.
    public static let reorder = Animation.spring(response: 0.28, dampingFraction: 0.82)
    /// Floating layers (palette, popovers) appearing.
    public static let present = Animation.spring(response: 0.30, dampingFraction: 0.88)
    /// Hover and press feedback: fast, no overshoot.
    public static let feedback = Animation.snappy(duration: 0.14)
    /// Selection changes in lists.
    public static let select = Animation.snappy(duration: 0.18)

    /// The token, or a plain short fade under Reduce Motion.
    public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : animation
    }
}

public extension View {
    /// `withAnimation`-style modifier that honors Reduce Motion.
    func studioAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(StudioAnimationModifier(animation: animation, value: value))
    }
}

private struct StudioAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(Motion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

/// Transitions for floating layers.
public extension AnyTransition {
    static var studioFloat: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -6)),
                    removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    static var studioPanel: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }
}
