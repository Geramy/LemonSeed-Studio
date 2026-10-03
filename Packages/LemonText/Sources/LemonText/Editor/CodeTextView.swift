import LemonTextCore
import UIKit

/// The text view with LemonText's decoration layers attached.
///
/// Decorations live in three views that share the text view's content coordinates:
/// an underlay behind the text (indentation guides, bracket boxes), an overlay above it
/// (squiggles, extra carets, fold placeholders, ghost text) and a gutter overlay that stays
/// pinned to the leading edge while the text scrolls horizontally.
final class CodeTextView: TextView {
    let underlayView = PassthroughView()
    let overlayView = PassthroughView()
    let gutterOverlayView = GutterOverlayView()
    /// Called after every layout pass, including each scroll step.
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        underlayView.isUserInteractionEnabled = false
        overlayView.isUserInteractionEnabled = false
        insertSubview(underlayView, at: 0)
        addSubview(overlayView)
        addSubview(gutterOverlayView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let contentBounds = CGRect(origin: .zero, size: CGSize(width: max(contentSize.width, bounds.width),
                                                                height: max(contentSize.height, bounds.height)))
        if underlayView.frame != contentBounds {
            underlayView.frame = contentBounds
            overlayView.frame = contentBounds
        }
        sendSubviewToBack(underlayView)
        // The gutter overlay rides above Runestone's gutter, which the superclass brings to the front.
        bringSubviewToFront(overlayView)
        bringSubviewToFront(gutterOverlayView)
        gutterOverlayView.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: showLineNumbers ? gutterWidth : 0, height: bounds.height)
        gutterOverlayView.bounds.origin = CGPoint(x: 0, y: contentOffset.y)
        onLayout?()
    }
}

/// A view that never takes touches, used to host decoration layers.
class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }
}

/// Hosts gutter markers and fold controls. Its bounds origin tracks the content offset so layers can be
/// positioned in content coordinates on the y-axis.
final class GutterOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
