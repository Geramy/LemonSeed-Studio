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
