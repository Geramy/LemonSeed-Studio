import UIKit

/// "Go to line" (⌃G): a small glass field. Accepts `line` or `line:column`.
final class GoToLinePanel: GlassPanel, UITextFieldDelegate {
    var onGo: ((_ line: Int, _ column: Int?) -> Void)?
    var onClose: (() -> Void)?
    let field = FindBarTextField()
    private let hintLabel = UILabel()
    var lineCount = 1 {
        didSet { hintLabel.text = "1–\(lineCount.formatted())" }
    }

    init() {
        super.init(cornerRadius: 16)
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.placeholder = "Go to line"
        field.accessibilityLabel = "Line number"
        field.keyboardType = .numbersAndPunctuation
        field.returnKeyType = .go
        field.autocorrectionType = .no
        field.delegate = self
        field.onEscape = { [weak self] in self?.onClose?() }
        hintLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        hintLabel.textColor = .secondaryLabel
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)
        let icon = UIImageView(image: UIImage(systemName: "arrow.down.to.line", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)))
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [icon, field, hintLabel])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            field.heightAnchor.constraint(equalToConstant: 32),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func applyTheme(_ theme: EditorTheme) {
        super.applyTheme(theme)
        field.textColor = theme.foreground.uiColor
        field.tintColor = theme.accent.uiColor
        field.backgroundColor = theme.foreground.withAlpha(theme.isDark ? 0.07 : 0.05).uiColor
    }

    /// Parses "120", "120:4" or "120,4" into a one-based line and optional column.
    static func parse(_ text: String) -> (line: Int, column: Int?)? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let line = Int(first), line > 0 else {
            return nil
        }
        let column = parts.count > 1 ? Int(parts[1]) : nil
        return (line, column)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let target = Self.parse(textField.text ?? "") {
            onGo?(target.line, target.column)
        } else {
            onClose?()
        }
        return false
    }
}
