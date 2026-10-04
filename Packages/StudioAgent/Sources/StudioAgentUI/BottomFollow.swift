import SwiftUI

/// Whether a streaming scroll view keeps its newest (bottom) content in view.
///
/// It follows from the start. Scrolling away from the bottom by hand stops
/// following; scrolling back to the bottom starts it again. Content growing
/// underneath, and scrolls the view makes itself, never change it.
struct BottomFollow: Equatable, Sendable {
    /// How close to the end still counts as the bottom, in points.
    static let tolerance: CGFloat = 24

    private(set) var following = true
    private var userScrolling = false
    private var atBottom = true

    static func isAtBottom(visibleMaxY: CGFloat, contentHeight: CGFloat) -> Bool {
        visibleMaxY >= contentHeight - tolerance
    }

    /// The scroll view moved or its content changed size.
    mutating func geometryChanged(atBottom: Bool) {
        self.atBottom = atBottom
        if userScrolling || atBottom { following = atBottom }
    }

    /// The scroll phase changed: `userDriven` while the user drags or the
    /// scroll they flung decelerates.
    mutating func phaseChanged(userDriven: Bool) {
        if userScrolling, !userDriven { following = atBottom }
        userScrolling = userDriven
    }

    /// Follow again whatever the position (the user sent a message).
    mutating func resume() { following = true }
}

/// Follows the newest content of the scroll view it modifies: each change of
/// `trigger` (the streamed content growing) calls `scrollToBottom` while
/// `BottomFollow` says to. A change of `resume` follows again from wherever
/// the user had scrolled.
struct FollowsBottom<Trigger: Equatable, Resume: Equatable>: ViewModifier {
    let trigger: Trigger
    let resume: Resume
    let scrollToBottom: () -> Void
    @State private var follow = BottomFollow()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                BottomFollow.isAtBottom(visibleMaxY: geometry.visibleRect.maxY,
                                        contentHeight: geometry.contentSize.height)
            } action: { _, atBottom in
                follow.geometryChanged(atBottom: atBottom)
            }
            .onScrollPhaseChange { _, phase in
                follow.phaseChanged(userDriven: phase == .tracking || phase == .interacting || phase == .decelerating)
            }
            .onChange(of: resume) {
                follow.resume()
                scrollToBottom()
            }
            .onChange(of: trigger) {
                if follow.following { scrollToBottom() }
            }
    }
}

extension View {
    /// Keeps this scroll view on its newest content while `trigger` changes,
    /// unless the user has scrolled up (see `BottomFollow`).
    func followsBottom(_ trigger: some Equatable, resume: some Equatable = 0,
                       scrollToBottom: @escaping () -> Void) -> some View {
        modifier(FollowsBottom(trigger: trigger, resume: resume, scrollToBottom: scrollToBottom))
    }
}
