import UIKit

/// The completion list shown under the caret.
final class CompletionPopup: GlassPanel, UITableViewDataSource, UITableViewDelegate {
    var onAccept: ((CompletionItem) -> Void)?
    private(set) var items: [CompletionItem] = []
    private(set) var selectedIndex = 0
    private var prefix = ""
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var theme: EditorTheme = .lemonDark
    static let rowHeight: CGFloat = 28
    static let maximumVisibleRows = 8

    init() {
        super.init(cornerRadius: 12)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = Self.rowHeight
        tableView.showsVerticalScrollIndicator = true
        tableView.register(CompletionCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        contentView.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        accessibilityLabel = "Completions"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func applyTheme(_ theme: EditorTheme) {
        super.applyTheme(theme)
        self.theme = theme
        tableView.reloadData()
    }

    func show(items: [CompletionItem], prefix: String) {
        self.items = items
        self.prefix = prefix
        selectedIndex = 0
        tableView.reloadData()
        if !items.isEmpty {
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        }
    }

    var preferredHeight: CGFloat {
        CGFloat(min(items.count, Self.maximumVisibleRows)) * Self.rowHeight + 8
    }

    var selectedItem: CompletionItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else {
            return
        }
        let previous = selectedIndex
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        tableView.reloadRows(at: [IndexPath(row: previous, section: 0), IndexPath(row: selectedIndex, section: 0)], with: .none)
        tableView.scrollToRow(at: IndexPath(row: selectedIndex, section: 0), at: .none, animated: false)
        UIAccessibility.post(notification: .announcement, argument: items[selectedIndex].label)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // swiftlint:disable:next force_cast
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! CompletionCell
        cell.configure(item: items[indexPath.row], prefix: prefix, theme: theme, isSelected: indexPath.row == selectedIndex)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onAccept?(items[indexPath.row])
    }
}

private final class CompletionCell: UITableViewCell {
    private let iconView = UIImageView()
    private let label = UILabel()
    private let detailLabel = UILabel()
    private let highlight = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        highlight.layer.cornerRadius = 7
        highlight.layer.cornerCurve = .continuous
        highlight.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(highlight)
        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        detailLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        detailLabel.textAlignment = .right
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [iconView, label, detailLabel])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            highlight.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            highlight.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(item: CompletionItem, prefix: String, theme: EditorTheme, isSelected: Bool) {
        iconView.image = UIImage(systemName: item.kind.symbolName)
        iconView.tintColor = color(for: item.kind, theme: theme).uiColor
        let attributed = NSMutableAttributedString(string: item.label, attributes: [
            .foregroundColor: theme.foreground.uiColor,
            .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ])
        // Emphasise the characters that matched the typed prefix.
        let lowerLabel = Array(item.label.lowercased().utf16)
        let lowerPrefix = Array(prefix.lowercased().utf16)
        var prefixIndex = 0
        for (index, unit) in lowerLabel.enumerated() where prefixIndex < lowerPrefix.count && unit == lowerPrefix[prefixIndex] {
            attributed.addAttributes([.foregroundColor: theme.accent.uiColor,
                                      .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)],
                                     range: NSRange(location: index, length: 1))
            prefixIndex += 1
        }
        label.attributedText = attributed
        detailLabel.text = item.detail
        detailLabel.textColor = theme.lineNumber.uiColor
        highlight.backgroundColor = isSelected ? theme.accent.withAlpha(theme.isDark ? 0.2 : 0.22).uiColor : .clear
        accessibilityLabel = [item.label, item.detail].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }

    private func color(for kind: CompletionItemKind, theme: EditorTheme) -> ThemeColor {
        let style: SyntaxStyle?
        switch kind {
        case .function, .method, .constructor: style = theme.style(forCapture: "function")
        case .keyword: style = theme.style(forCapture: "keyword")
        case .class, .struct, .interface, .enum, .typeParameter: style = theme.style(forCapture: "type")
        case .constant, .enumMember, .value: style = theme.style(forCapture: "constant")
        case .property, .field: style = theme.style(forCapture: "property")
        case .snippet: style = theme.style(forCapture: "string")
        default: style = nil
        }
        return style?.color ?? theme.lineNumber
    }
}

/// A card showing diagnostics for a line, shown from the gutter marker or on hover.
final class DiagnosticCard: GlassPanel {
    private let stack = UIStackView()

    init() {
        super.init(cornerRadius: 12)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ diagnostics: [Diagnostic], theme: EditorTheme) {
        applyTheme(theme)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for diagnostic in diagnostics.prefix(4) {
            let color: ThemeColor
            let symbol: String
            switch diagnostic.severity {
            case .error: (color, symbol) = (theme.error, "xmark.octagon.fill")
            case .warning: (color, symbol) = (theme.warning, "exclamationmark.triangle.fill")
            case .information: (color, symbol) = (theme.information, "info.circle.fill")
            case .hint: (color, symbol) = (theme.hint, "lightbulb.fill")
            }
            let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
            icon.tintColor = color.uiColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let message = UILabel()
            message.numberOfLines = 0
            message.font = .systemFont(ofSize: 13)
            message.textColor = theme.foreground.uiColor
            message.text = diagnostic.message
            let source = UILabel()
            source.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            source.textColor = theme.lineNumber.uiColor
            source.text = [diagnostic.source, diagnostic.code].compactMap { $0 }.joined(separator: " · ")
            source.isHidden = source.text?.isEmpty ?? true
            let texts = UIStackView(arrangedSubviews: [message, source])
            texts.axis = .vertical
            texts.spacing = 2
            let row = UIStackView(arrangedSubviews: [icon, texts])
            row.spacing = 8
            row.alignment = .firstBaseline
            stack.addArrangedSubview(row)
        }
        accessibilityLabel = diagnostics.map(\.message).joined(separator: ". ")
    }
}
