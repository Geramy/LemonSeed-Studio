import UIKit

@MainActor
protocol FindBarDelegate: AnyObject {
    func findBar(_ findBar: FindBar, didChange query: FindQuery)
    func findBarFindNext(_ findBar: FindBar)
    func findBarFindPrevious(_ findBar: FindBar)
    func findBar(_ findBar: FindBar, replaceCurrentWith template: String)
    func findBar(_ findBar: FindBar, replaceAllWith template: String)
    func findBarDidClose(_ findBar: FindBar)
}

/// The find/replace panel: a glass card in the editor's top trailing corner.
final class FindBar: GlassPanel, UITextFieldDelegate {
    weak var delegate: FindBarDelegate?

    let findField = FindBarTextField()
    let replaceField = FindBarTextField()
    private let caseToggle = OptionToggleButton(title: "Aa", accessibilityLabel: "Match Case")
    private let wordToggle = OptionToggleButton(title: "W", accessibilityLabel: "Match Whole Word")
    private let regexToggle = OptionToggleButton(title: ".*", accessibilityLabel: "Use Regular Expression")
    private let countLabel = UILabel()
    private let replaceRow = UIStackView()
    private var expandButton: UIButton!
    private(set) var isReplaceVisible = false

    var query: FindQuery {
        FindQuery(findField.text ?? "",
                  isRegularExpression: regexToggle.isOn,
                  isCaseSensitive: caseToggle.isOn,
                  matchesWholeWord: wordToggle.isOn)
    }

    var replacementTemplate: String {
        replaceField.text ?? ""
    }

    init() {
        super.init(cornerRadius: 16, interactive: false)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        for field in [findField, replaceField] {
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .search
            field.delegate = self
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        }
        findField.placeholder = "Find"
        findField.accessibilityLabel = "Find"
        replaceField.placeholder = "Replace"
        replaceField.accessibilityLabel = "Replace"
        replaceField.returnKeyType = .done
        findField.onEscape = { [weak self] in self?.close() }
        replaceField.onEscape = { [weak self] in self?.close() }
        findField.onShiftReturn = { [weak self] in
            guard let self else { return }
            self.delegate?.findBarFindPrevious(self)
        }

        for toggle in [caseToggle, wordToggle, regexToggle] {
            toggle.onToggle = { [weak self] _ in self?.fieldChanged() }
        }
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabel
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.textAlignment = .right
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true

        expandButton = makeIconButton(systemName: "chevron.right", accessibilityLabel: "Toggle Replace") { [weak self] in
            self?.setReplaceVisible(!(self?.isReplaceVisible ?? false), animated: true)
        }
        let previous = makeIconButton(systemName: "chevron.up", accessibilityLabel: "Previous Match") { [weak self] in
            guard let self else { return }
            self.delegate?.findBarFindPrevious(self)
        }
        let next = makeIconButton(systemName: "chevron.down", accessibilityLabel: "Next Match") { [weak self] in
            guard let self else { return }
            self.delegate?.findBarFindNext(self)
        }
        let close = makeIconButton(systemName: "xmark", accessibilityLabel: "Close Find") { [weak self] in
            self?.close()
        }

        let findRow = UIStackView(arrangedSubviews: [expandButton, findField, caseToggle, wordToggle, regexToggle, countLabel, previous, next, close])
        findRow.axis = .horizontal
        findRow.alignment = .center
        findRow.spacing = 2
        findRow.setCustomSpacing(8, after: findField)
        findRow.setCustomSpacing(8, after: regexToggle)

        let replaceOne = makeTextButton(title: "Replace") { [weak self] in
            guard let self else { return }
            self.delegate?.findBar(self, replaceCurrentWith: self.replacementTemplate)
        }
        let replaceAll = makeTextButton(title: "All") { [weak self] in
            guard let self else { return }
            self.delegate?.findBar(self, replaceAllWith: self.replacementTemplate)
        }
        replaceAll.accessibilityLabel = "Replace All"
        let spacer = UIView()
        spacer.widthAnchor.constraint(equalToConstant: 26).isActive = true
        replaceRow.addArrangedSubview(spacer)
        replaceRow.addArrangedSubview(replaceField)
        replaceRow.addArrangedSubview(replaceOne)
        replaceRow.addArrangedSubview(replaceAll)
        replaceRow.axis = .horizontal
        replaceRow.alignment = .center
        replaceRow.spacing = 4
        replaceRow.isHidden = true
        replaceRow.alpha = 0

        let stack = UIStackView(arrangedSubviews: [findRow, replaceRow])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            findField.heightAnchor.constraint(equalToConstant: 30),
            replaceField.heightAnchor.constraint(equalToConstant: 30),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }

    private func makeTextButton(title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        var attributes = AttributeContainer()
        attributes.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.pointerStyleProvider = { button, _, _ in
            UIPointerStyle(effect: .highlight(UITargetedPreview(view: button)))
        }
        return button
    }

    override func applyTheme(_ theme: EditorTheme) {
        super.applyTheme(theme)
        let accent = theme.accent.uiColor
        for toggle in [caseToggle, wordToggle, regexToggle] {
            toggle.accent = accent
        }
        for field in [findField, replaceField] {
            field.textColor = theme.foreground.uiColor
            field.tintColor = accent
            field.backgroundColor = theme.foreground.withAlpha(theme.isDark ? 0.07 : 0.05).uiColor
        }
    }

    func setReplaceVisible(_ visible: Bool, animated: Bool) {
        isReplaceVisible = visible
        let changes = {
            self.replaceRow.isHidden = !visible
            self.replaceRow.alpha = visible ? 1 : 0
            self.expandButton.transform = visible ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
            self.superview?.layoutIfNeeded()
        }
        if animated {
            UIView.animate(springDuration: 0.35, bounce: 0.15, animations: changes)
        } else {
            changes()
        }
    }

    /// Shows "3 of 12", "No results" or an error.
    func setResult(current: Int?, total: Int, limited: Bool = false, error: String? = nil) {
        if let error {
            countLabel.text = "Invalid"
            countLabel.textColor = .systemRed
            countLabel.accessibilityLabel = error
            findField.accessibilityValue = error
            return
        }
        countLabel.textColor = .secondaryLabel
        let totalText = limited ? "\(total)+" : "\(total)"
        if total == 0 {
            countLabel.text = (findField.text ?? "").isEmpty ? "" : "No results"
        } else if let current {
            countLabel.text = "\(current + 1) of \(totalText)"
        } else {
            countLabel.text = "\(totalText) found"
        }
        countLabel.accessibilityLabel = countLabel.text
    }

    func focus(selectingAll: Bool = true) {
        findField.becomeFirstResponder()
        if selectingAll {
            findField.selectAll(nil)
        }
    }

    private func close() {
        delegate?.findBarDidClose(self)
    }

    @objc private func fieldChanged() {
        delegate?.findBar(self, didChange: query)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === findField {
            delegate?.findBarFindNext(self)
        } else {
            delegate?.findBar(self, replaceCurrentWith: replacementTemplate)
        }
        return false
    }
}

/// A rounded text field that reports Escape and Shift-Return.
final class FindBarTextField: UITextField {
    var onEscape: (() -> Void)?
    var onShiftReturn: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        let padding = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        leftView = padding
        leftViewMode = .always
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))
        let shiftReturn = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(handleShiftReturn))
        escape.wantsPriorityOverSystemBehavior = true
        shiftReturn.wantsPriorityOverSystemBehavior = true
        return [escape, shiftReturn]
    }

    @objc private func handleEscape() {
        onEscape?()
    }

    @objc private func handleShiftReturn() {
        onShiftReturn?()
    }
}
