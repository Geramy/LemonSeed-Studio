import SwiftUI
import UIKit

/// Calls an action once with the window scene a view is shown in.
private struct WindowSceneReader: UIViewRepresentable {
    let action: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ReaderView { ReaderView(action: action) }
    func updateUIView(_ view: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        private let action: (UIWindowScene) -> Void
        private var reported = false

        init(action: @escaping (UIWindowScene) -> Void) {
            self.action = action
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !reported, let scene = window?.windowScene else { return }
            reported = true
            action(scene)
        }
    }
}

extension View {
    /// Runs `action` once with the window scene this view is shown in.
    func onWindowScene(_ action: @escaping (UIWindowScene) -> Void) -> some View {
        background(WindowSceneReader(action: action).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// Runs an action once, with the window scene, when the window is first active.
private struct ActiveWindowScene: ViewModifier {
    let action: (UIWindowScene) -> Void
    @Environment(\.scenePhase) private var phase
    @State private var scene: UIWindowScene?
    @State private var fired = false

    func body(content: Content) -> some View {
        content
            .onWindowScene { found in
                scene = found
                fire(found, phase)
            }
            .onChange(of: phase) { _, now in
                if let scene { fire(scene, now) }
            }
    }

    private func fire(_ scene: UIWindowScene, _ phase: ScenePhase) {
        guard !fired, phase == .active else { return }
        fired = true
        action(scene)
    }
}

extension View {
    /// Runs `action` once with this view's window scene, when the window is
    /// first active (iPadOS refuses some window requests before that).
    func onActiveWindowScene(_ action: @escaping (UIWindowScene) -> Void) -> some View {
        modifier(ActiveWindowScene(action: action))
    }
}
