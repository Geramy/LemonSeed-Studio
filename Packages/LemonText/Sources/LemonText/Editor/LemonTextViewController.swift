import LemonTextCore
import os
import UIKit

/// Receives editor events. Every method has a default implementation.
@MainActor
public protocol LemonTextViewControllerDelegate: AnyObject {
    func editorDidChangeText(_ editor: LemonTextViewController)
    func editorDidChangeSelection(_ editor: LemonTextViewController)
    /// The document finished loading; `isHighlighted` is false while the syntax tree is still being built.
    func editorDidLoad(_ editor: LemonTextViewController, metrics: EditorLoadMetrics)
    func editorDidFinishHighlighting(_ editor: LemonTextViewController)
    /// A pointer or Pencil hovers over the text. `location` is nil when the hover ends.
    /// Language features use this to show hover cards before touchdown.
    func editor(_ editor: LemonTextViewController, didHoverAt location: Int?, with input: EditorHoverInput)
    /// Apple Pencil double tap or squeeze, for switching tools (e.g. Ink and Select modes).
    func editor(_ editor: LemonTextViewController, didReceivePencilGesture gesture: EditorPencilGesture, at location: Int?)
}

public extension LemonTextViewControllerDelegate {
    func editorDidChangeText(_ editor: LemonTextViewController) {}
    func editorDidChangeSelection(_ editor: LemonTextViewController) {}
    func editorDidLoad(_ editor: LemonTextViewController, metrics: EditorLoadMetrics) {}
    func editorDidFinishHighlighting(_ editor: LemonTextViewController) {}
    func editor(_ editor: LemonTextViewController, didHoverAt location: Int?, with input: EditorHoverInput) {}
    func editor(_ editor: LemonTextViewController, didReceivePencilGesture gesture: EditorPencilGesture, at location: Int?) {}
}

public enum EditorHoverInput: Sendable {
    case pointer
    case pencil(zOffset: CGFloat)
}

public enum EditorPencilGesture: Sendable {
    case doubleTap
    case squeeze
}

/// Timings for opening a document.
public struct EditorLoadMetrics: Sendable, Hashable {
    /// Building line storage off the main thread.
    public var prepareDuration: Duration
    /// Installing the state and laying out the first screen on the main thread.
    public var firstScreenDuration: Duration
    /// From the call to `load` until the first screen is laid out.
    public var totalToFirstScreen: Duration
    public var lineCount: Int
    public var utf16Length: Int
}

/// The LemonText editor: a code editor view controller built on the LemonTextCore engine.
///
/// It adds themes, decorations (indentation guides, bracket matching, diagnostics, gutter markers),
/// folding, a minimap, find/replace, go to line, several carets, completion and inline suggestion
/// hooks, keyboard shortcuts and Pencil and trackpad input.
@MainActor
public final class LemonTextViewController: UIViewController {
    public weak var delegate: LemonTextViewControllerDelegate?

    // MARK: Public state

    public private(set) var language: LemonLanguage = .plainText
    public var theme: EditorTheme {
        didSet {
            if theme != oldValue {
                applyTheme()
            }
        }
    }
    public var configuration: EditorConfiguration {
        didSet {
            if configuration != oldValue {
                applyConfiguration(previous: oldValue)
            }
        }
    }
    /// Problems to underline and mark in the gutter, e.g. from clangd. Ranges follow edits until replaced.
    public var diagnostics: [Diagnostic] {
        get { decorations.diagnostics }
        set {
            decorations.diagnostics = newValue
            updateMinimapMarkers()
            textView.setNeedsLayout()
        }
    }
    /// Markers in the gutter (breakpoints, Git changes, bookmarks).
    public var gutterMarkers: [GutterMarker] {
        get { decorations.gutterMarkers }
        set {
            decorations.gutterMarkers = newValue
            updateMinimapMarkers()
            textView.setNeedsLayout()
        }
    }
    /// Foldable regions. Computed from the text automatically; set this to use a language server's ranges instead,
    /// which also stops the automatic computation.
    public var foldingRanges: [FoldingRange] {
        get { decorations.foldingRanges }
        set {
            usesExternalFoldingRanges = true
            decorations.foldingRanges = newValue
            textView.setNeedsLayout()
        }
    }
    /// Supplies completions. Defaults to keywords and nearby identifiers.
    public var completionProvider: CompletionProvider?
    /// Whether the syntax tree is still being built after a load.
    public private(set) var isHighlighting = false
    public private(set) var lastLoadMetrics: EditorLoadMetrics?

    /// The underlying text view, for features not wrapped here.
    public var textView: TextView { codeTextView }

    // MARK: Internal state

    let codeTextView = CodeTextView(frame: .zero)
    let minimapView = MinimapView(frame: .zero)
    lazy var decorations = DecorationController(textView: codeTextView)
    let findBar = FindBar()
    let goToLinePanel = GoToLinePanel()
    let completionPopup = CompletionPopup()
    let diagnosticCard = DiagnosticCard()
    let ghostTextLabel = UILabel()
    let hoverCaretLayer = CALayer()
    var themeAdapter: CoreThemeAdapter
    var registry = LanguageRegistry.shared
    var loadGeneration = 0
    var usesExternalFoldingRanges = false
    var foldingTask: Task<Void, Never>?
    var minimapRefreshTask: Task<Void, Never>?
    var completionTask: Task<Void, Never>?
    var hoverTask: Task<Void, Never>?
    var minimapChunks: [Int: [[MinimapRun]]] = [:]
    static let minimapChunkSize = 128

    // Editing state
    var secondarySelections: [NSRange] = [] {
        didSet {
            decorations.secondarySelections = secondarySelections
            textView.characterPairs = secondarySelections.isEmpty && configuration.autoClosePairs ? Self.characterPairs(for: language) : []
        }
    }
    var previousPrimarySelection = NSRange(location: 0, length: 0)
    var isChangingSelectionInternally = false
    var isApplyingBatchEdit = false
    var batchPreservesLineCount = false
    var pendingEdit: (startLine: Int, endLine: Int, insertedLineBreaks: Int, removedLineBreaks: Int, range: NSRange, replacementLength: Int)?

    // Find state
    var findMatches: [FindMatch] = []
    var currentFindIndex: Int?
    var findTask: Task<Void, Never>?
    var isFindVisible: Bool { !findBar.isHidden }

    // Completion state
    var completionPrefixRange: NSRange?
    var inlineSuggestion: (text: String, location: Int)?

    // Keystroke timing: from the text input system asking to change text until the edit is laid out.
    var keystrokeStart: CFTimeInterval?
    var keystrokeDurations: [Double] = []

    // Pencil, gutter and find bookkeeping
    var pencilSelectionAnchor: Int?
    var gutterSelectionAnchorLine: Int?
    var lastGutterTouchWasIndirect = false
    var findHighlightWindow: ClosedRange<Int>?
    lazy var defaultCompletionProvider: WordCompletionProvider = {
        let provider = WordCompletionProvider()
        provider.textProvider = { [weak self] location, radius in
            guard let self else { return nil }
            let start = max(0, location - radius)
            let end = min(self.codeTextView.textLength, location + radius)
            return self.codeTextView.text(in: NSRange(location: start, length: end - start))
        }
        return provider
    }()

    static let signposter = OSSignposter(subsystem: "LemonText", category: "Editor")

    public init(configuration: EditorConfiguration = EditorConfiguration(), theme: EditorTheme = .lemonDark) {
        self.configuration = configuration
        self.theme = theme
        themeAdapter = CoreThemeAdapter(theme: theme, font: configuration.font.uiFont, lineNumberFont: Self.lineNumberFont(for: configuration.font))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View lifecycle

    override public func loadView() {
        let root = UIView()
        root.clipsToBounds = true
        view = root
        root.addSubview(codeTextView)
        root.addSubview(minimapView)
        codeTextView.editorDelegate = self
        codeTextView.delegate = self
        codeTextView.onLayout = { [weak self] in self?.textViewDidLayout() }
        codeTextView.autocorrectionType = .no
        codeTextView.autocapitalizationType = .none
        codeTextView.smartQuotesType = .no
        codeTextView.smartDashesType = .no
        codeTextView.smartInsertDeleteType = .no
        codeTextView.spellCheckingType = .no
        codeTextView.keyboardType = .asciiCapable
        codeTextView.alwaysBounceVertical = true
        codeTextView.contentInsetAdjustmentBehavior = .never
        codeTextView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 16)
        codeTextView.gutterMinimumCharacterCount = 3
        codeTextView.tabSymbol = "→"
        codeTextView.spaceSymbol = "·"
        codeTextView.lineBreakSymbol = "¬"
        codeTextView.isFindInteractionEnabled = false
        minimapView.dataSource = self

        setUpChrome()
        setUpInput()
        applyTheme()
        applyConfiguration(previous: nil)
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let minimapWidth: CGFloat = configuration.showMinimap ? Self.minimapWidth(for: bounds.width) : 0
        minimapView.isHidden = minimapWidth == 0
        codeTextView.frame = CGRect(x: 0, y: 0, width: bounds.width - minimapWidth, height: bounds.height)
        minimapView.frame = CGRect(x: bounds.width - minimapWidth, y: 0, width: minimapWidth, height: bounds.height)
        layoutChrome()
    }

    static func minimapWidth(for width: CGFloat) -> CGFloat {
        width < 500 ? 0 : (width < 800 ? 72 : 96)
    }

    // MARK: - Loading

    /// The full text. Reading copies the document; prefer ``textSnapshot()`` for large files.
    public var text: String {
        get { codeTextView.text }
        set { load(text: newValue, language: language) }
    }

    /// An immutable snapshot of the text, cheap compared with ``text``.
    public func textSnapshot() -> NSString {
        codeTextView.textSnapshot()
    }

    /// Opens a file's contents, picking the language from its name and first bytes.
    public func load(text: String, fileName: String, completion: (@MainActor (EditorLoadMetrics) -> Void)? = nil) {
        let language = LanguageDetector.language(forFileName: fileName, contents: String(text.prefix(4096)))
        load(text: text, language: language, completion: completion)
    }

    /// Replaces the document. Line storage is built off the main thread; small documents are parsed before they
    /// appear so they show highlighted, large ones show immediately and highlight when parsing finishes.
    public func load(text: String, language: LemonLanguage, completion: (@MainActor (EditorLoadMetrics) -> Void)? = nil) {
        loadViewIfNeeded()
        loadGeneration += 1
        let generation = loadGeneration
        let start = ContinuousClock.now
        self.language = language
        let adapter = UncheckedSendableBox(themeAdapter)
        let treeSitterLanguage = UncheckedSendableBox(registry.treeSitterLanguage(for: language))
        let provider = UncheckedSendableBox(registry)
        let parsesBeforeDisplay = (text as NSString).length < Self.synchronousParseThreshold
        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("Load", id: signpostID, "\(text.utf16.count) UTF-16 units")
        Task.detached(priority: .userInitiated) { [weak self] in
            let prepareStart = ContinuousClock.now
            let state: TextViewState
            if parsesBeforeDisplay, let language = treeSitterLanguage.value {
                state = TextViewState(text: text, theme: adapter.value, language: language, languageProvider: provider.value)
            } else {
                state = TextViewState(text: text, theme: adapter.value)
            }
            let prepareDuration = ContinuousClock.now - prepareStart
            let box = UncheckedSendableBox(state)
            await MainActor.run {
                guard let self, generation == self.loadGeneration else {
                    return
                }
                self.install(box.value, prepareDuration: prepareDuration, start: start,
                             highlightLater: !parsesBeforeDisplay && treeSitterLanguage.value != nil,
                             completion: completion)
                Self.signposter.endInterval("Load", interval)
            }
        }
    }

    /// Documents smaller than this (UTF-16 units) are parsed before display.
    static let synchronousParseThreshold = 400_000

    private func install(_ state: TextViewState, prepareDuration: Duration, start: ContinuousClock.Instant,
                         highlightLater: Bool, completion: (@MainActor (EditorLoadMetrics) -> Void)?) {
        let installStart = ContinuousClock.now
        resetDocumentState()
        codeTextView.setState(state)
        applyLanguageSettings()
        switch state.detectedIndentStrategy {
        case .tab:
            if !configuration.insertSpaces || language.prefersTabs {
                codeTextView.indentStrategy = .tab(length: configuration.tabWidth)
            }
        case .space(let length) where length > 0:
            if configuration.insertSpaces {
                codeTextView.indentStrategy = .space(length: length)
            }
        default:
            break
        }
        if let lineEndings = state.detectedLineEndings {
            codeTextView.lineEndings = lineEndings
        }
        codeTextView.contentOffset = .zero
        codeTextView.selectedRange = NSRange(location: 0, length: 0)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        codeTextView.layoutIfNeeded()
        let now = ContinuousClock.now
        let metrics = EditorLoadMetrics(prepareDuration: prepareDuration,
                                        firstScreenDuration: now - installStart,
                                        totalToFirstScreen: now - start,
                                        lineCount: codeTextView.lineCount,
                                        utf16Length: codeTextView.textLength)
        lastLoadMetrics = metrics
        minimapView.invalidate()
        scheduleFoldingRangeUpdate(delay: .zero)
        delegate?.editorDidLoad(self, metrics: metrics)
        completion?(metrics)
        if highlightLater, let treeSitterLanguage = registry.treeSitterLanguage(for: language) {
            isHighlighting = true
            let generation = loadGeneration
            let mode = TreeSitterLanguageMode(language: treeSitterLanguage, languageProvider: registry)
            codeTextView.setLanguageMode(mode) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, generation == self.loadGeneration else {
                        return
                    }
                    self.isHighlighting = false
                    self.minimapChunks.removeAll()
                    self.minimapView.invalidate()
                    self.delegate?.editorDidFinishHighlighting(self)
                }
            }
        } else {
            isHighlighting = false
            delegate?.editorDidFinishHighlighting(self)
        }
    }

    private func resetDocumentState() {
        secondarySelections = []
        decorations.foldState = FoldState()
        if !usesExternalFoldingRanges {
            decorations.foldingRanges = []
        }
        decorations.diagnostics = []
        decorations.bracketMatch = nil
        decorations.textDidChange()
        minimapChunks.removeAll()
        findMatches = []
        currentFindIndex = nil
        codeTextView.highlightedRanges = []
        dismissCompletion()
        setInlineSuggestion(nil)
        pendingEdit = nil
    }

    // MARK: - Appearance

    static func lineNumberFont(for font: EditorFont) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: max(font.size - 2, 9), weight: .regular)
    }

    func applyTheme() {
        themeAdapter = CoreThemeAdapter(theme: theme, font: configuration.font.uiFont, lineNumberFont: Self.lineNumberFont(for: configuration.font))
        codeTextView.theme = themeAdapter
        codeTextView.backgroundColor = theme.background.uiColor
        codeTextView.insertionPointColor = theme.caret.uiColor
        codeTextView.selectionBarColor = theme.caret.uiColor
        codeTextView.selectionHighlightColor = theme.selection.uiColor
        codeTextView.keyboardAppearance = theme.isDark ? .dark : .light
        view.backgroundColor = theme.background.uiColor
        view.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        decorations.theme = theme
        decorations.font = configuration.font.uiFont
        minimapView.theme = theme
        minimapChunks.removeAll()
        for panel in [findBar, goToLinePanel, completionPopup] as [GlassPanel] {
            panel.applyTheme(theme)
        }
        ghostTextLabel.textColor = theme.ghostText.uiColor
        hoverCaretLayer.backgroundColor = theme.caret.withAlpha(0.45).cgColor
        refreshFindHighlights()
        textView.setNeedsLayout()
    }

    func applyConfiguration(previous: EditorConfiguration?) {
        let configuration = configuration
        if previous?.font != configuration.font {
            codeTextView.lineHeightMultiplier = configuration.font.lineHeightMultiplier
            applyTheme()
        }
        codeTextView.showLineNumbers = configuration.showLineNumbers
        codeTextView.lineSelectionDisplayType = configuration.highlightCurrentLine ? .line : .disabled
        codeTextView.showTabs = configuration.showInvisibles
        codeTextView.showSpaces = configuration.showInvisibles
        codeTextView.showLineBreaks = configuration.showInvisibles
        codeTextView.isLineWrappingEnabled = configuration.softWrap
        codeTextView.indentStrategy = configuration.insertSpaces ? .space(length: configuration.tabWidth) : .tab(length: configuration.tabWidth)
        codeTextView.showPageGuide = configuration.pageGuideColumn != nil
        codeTextView.pageGuideColumn = configuration.pageGuideColumn ?? 80
        codeTextView.verticalOverscrollFactor = configuration.scrollPastEnd ? 0.5 : 0
        codeTextView.isEditable = configuration.isEditable
        codeTextView.gutterLeadingPadding = 16
        codeTextView.gutterTrailingPadding = configuration.showFoldingControls ? 22 : 10
        textView.characterPairs = secondarySelections.isEmpty && configuration.autoClosePairs ? Self.characterPairs(for: language) : []
        decorations.configuration = configuration
        if previous?.showMinimap != configuration.showMinimap {
            view.setNeedsLayout()
        }
        textView.setNeedsLayout()
    }

    func applyLanguageSettings() {
        textView.characterPairs = secondarySelections.isEmpty && configuration.autoClosePairs ? Self.characterPairs(for: language) : []
        if language.prefersTabs {
            codeTextView.indentStrategy = .tab(length: configuration.tabWidth)
        }
    }

    static func characterPairs(for language: LemonLanguage) -> [CharacterPair] {
        (language.bracketPairs.filter { $0.open != "<" } + language.quotePairs).map { EditorCharacterPair(leading: $0.open, trailing: $0.close) }
    }

    // MARK: - Layout callbacks

    func textViewDidLayout() {
        decorations.layoutIfNeeded()
        minimapView.viewportDidChange()
        positionGhostText()
        if isFindVisible, !findMatches.isEmpty, let window = findHighlightWindow, let visible = codeTextView.visibleLineIndices,
           let first = codeTextView.range(ofLine: visible.lowerBound)?.location,
           let last = codeTextView.range(ofLine: visible.upperBound)?.location,
           first < window.lowerBound || last > window.upperBound {
            refreshFindHighlights()
        }
    }
}

struct EditorCharacterPair: CharacterPair {
    let leading: String
    let trailing: String
}

/// Moves non-Sendable values across a hop when the hop is known to be safe (the value is not shared).
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) {
        self.value = value
    }
}
