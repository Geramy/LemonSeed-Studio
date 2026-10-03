import UIKit

/// A floating Liquid Glass panel. The editor surface stays opaque; only floating layers
/// (find bar, go to line, completion, hover cards) use glass.
class GlassPanel: UIView {
    let effectView: UIVisualEffectView
    var contentView: UIView { effectView.contentView }

    init(cornerRadius: CGFloat = 18, interactive: Bool = false) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = interactive
        effectView = UIVisualEffectView(effect: effect)
        super.init(frame: .zero)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.cornerConfiguration = .uniformCorners(radius: .fixed(Double(cornerRadius)))
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 8)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ theme: EditorTheme) {
        if let effect = effectView.effect as? UIGlassEffect {
            let tinted = UIGlassEffect(style: .regular)
            tinted.isInteractive = effect.isInteractive
            tinted.tintColor = theme.elevatedBackground.withAlpha(theme.isDark ? 0.55 : 0.45).uiColor
            effectView.effect = tinted
        }
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
    }
}

/// A compact toggle used for find options (case, whole word, regex).
final class OptionToggleButton: UIButton {
    var isOn = false {
        didSet { updateAppearance() }
    }
    var accent: UIColor = .systemYellow {
        didSet { updateAppearance() }
    }
    var onToggle: ((Bool) -> Void)?

    init(title: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
        var attributes = AttributeContainer()
        attributes.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        configuration.background.cornerRadius = 6
        self.configuration = configuration
        self.accessibilityLabel = accessibilityLabel
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.isOn.toggle()
            self.onToggle?(self.isOn)
        }, for: .primaryActionTriggered)
        pointerStyleProvider = { button, _, _ in
            UIPointerStyle(effect: .highlight(UITargetedPreview(view: button)))
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAppearance() {
        configuration?.baseForegroundColor = isOn ? accent : .secondaryLabel
        configuration?.background.backgroundColor = isOn ? accent.withAlphaComponent(0.18) : .clear
        accessibilityTraits = isOn ? [.button, .selected] : .button
    }
}

/// A borderless icon button for panels.
@MainActor
func makeIconButton(systemName: String, accessibilityLabel: String, action: @escaping @MainActor () -> Void) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.image = UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
    configuration.baseForegroundColor = .secondaryLabel
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 5, bottom: 4, trailing: 5)
    let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    button.accessibilityLabel = accessibilityLabel
    button.pointerStyleProvider = { button, _, _ in
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: button)))
    }
    return button
}
