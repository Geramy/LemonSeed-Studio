import Foundation
import TreeSitter

protocol TreeSitterLanguageModeDelegate: AnyObject {
    func treeSitterLanguageMode(_ languageMode: TreeSitterInternalLanguageMode, bytesAt byteIndex: ByteCount) -> TreeSitterTextProviderResult?
    /// A background parse finished and installed a new tree; the given lines need highlighting again.
    func treeSitterLanguageMode(_ languageMode: TreeSitterInternalLanguageMode, didReparseWith lineChangeSet: LineChangeSet)
}

final class TreeSitterInternalLanguageMode: InternalLanguageMode {
    weak var delegate: TreeSitterLanguageModeDelegate?
    var canHighlight: Bool {
        rootLanguageLayer.canHighlight
    }

    private let stringView: StringView
    private let parser: TreeSitterParser
    private let lineManager: LineManager
    private let rootLanguageLayer: TreeSitterLanguageLayer
    private let operationQueue = OperationQueue()
    private let parseLock = NSLock()

    // Deferred parsing. Incremental parsing is not O(edit): tree-sitter re-walks the root's children, which
    // costs tens of milliseconds per keystroke in a file like the SQLite amalgamation. Above this size, edits
    // only shift the tree on the main thread and the reparse runs on a background queue.
    static var deferredParsingThreshold = ByteCount(1_000_000)
    private let backgroundParser = TreeSitterParser(encoding: TSInputEncodingUTF16)
    private let backgroundQueue = DispatchQueue(label: "LemonText.TreeSitterReparse", qos: .userInitiated)
    private var isBackgroundParseRunning = false
    private var isBackgroundParseScheduled = false
    private var editsDuringBackgroundParse: [TreeSitterInputEdit] = []
    private var needsBackgroundParse = false

    init(language: TreeSitterInternalLanguage, languageProvider: TreeSitterLanguageProvider?, stringView: StringView, lineManager: LineManager) {
        self.stringView = stringView
        self.lineManager = lineManager
        operationQueue.name = "TreeSitterLanguageMode"
        operationQueue.qualityOfService = .default
        parser = TreeSitterParser(encoding: TSInputEncodingUTF16)
        rootLanguageLayer = TreeSitterLanguageLayer(
            language: language,
            languageProvider: languageProvider,
            parser: parser,
            stringView: stringView,
            lineManager: lineManager)
        parser.delegate = self
    }

    deinit {
        operationQueue.cancelAllOperations()
    }

    func parse(_ text: NSString) {
        parseLock.withLock {
            rootLanguageLayer.parse(text)
        }
    }

    func parse(_ text: NSString, completion: @escaping ((Bool) -> Void)) {
        operationQueue.cancelAllOperations()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation, weak self] in
            if let self = self, let operation = operation, !operation.isCancelled {
                self.parse(text)
                DispatchQueue.main.async {
                    completion(!operation.isCancelled)
                }
            } else {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
        operationQueue.addOperation(operation)
    }

    func textDidChange(_ change: TextChange) -> LineChangeSet {
        let bytesRemoved = change.byteRange.length
        let bytesAdded = change.bytesAdded
        let edit = TreeSitterInputEdit(
            startByte: change.byteRange.location,
            oldEndByte: change.byteRange.location + bytesRemoved,
            newEndByte: change.byteRange.location + bytesAdded,
            startPoint: TreeSitterTextPoint(change.startLinePosition),
            oldEndPoint: TreeSitterTextPoint(change.oldEndLinePosition),
            newEndPoint: TreeSitterTextPoint(change.newEndLinePosition))
        if rootLanguageLayer.supportsDeferredParsing && stringView.string.byteCount >= Self.deferredParsingThreshold {
            rootLanguageLayer.applyWithoutParsing(edit)
            if isBackgroundParseRunning {
                editsDuringBackgroundParse.append(edit)
            }
            needsBackgroundParse = true
            scheduleBackgroundParse()
            return LineChangeSet()
        }
        return rootLanguageLayer.apply(edit)
    }

    /// Whether a background reparse is queued or running.
    var hasPendingParse: Bool {
        needsBackgroundParse || isBackgroundParseRunning
    }

    private func scheduleBackgroundParse() {
        guard !isBackgroundParseScheduled && !isBackgroundParseRunning else {
            return
        }
        isBackgroundParseScheduled = true
        // Start after the current keystroke has been handled, so a burst of key repeats coalesces into one parse.
        DispatchQueue.main.async { [weak self] in
            self?.startBackgroundParse()
        }
    }

    private func startBackgroundParse() {
        isBackgroundParseScheduled = false
        guard needsBackgroundParse, !isBackgroundParseRunning, let tree = rootLanguageLayer.tree, let oldTree = tree.copy() else {
            return
        }
        needsBackgroundParse = false
        isBackgroundParseRunning = true
        editsDuringBackgroundParse = []
        guard let snapshot = stringView.string.copy() as? NSString else {
            isBackgroundParseRunning = false
            return
        }
        let language = rootLanguageLayer.language.languagePointer
        let parser = backgroundParser
        backgroundQueue.async { [weak self] in
            // Drain temporaries (the UTF-16 copy of the text) after every parse; a run of keystrokes parses
            // back to back and the queue would otherwise hold on to each copy.
            let result: (TreeSitterTree?, [TreeSitterTextRange]) = autoreleasepool {
                parser.language = language
                parser.removeAllIncludedRanges()
                let newTree = parser.parse(snapshot, oldTree: oldTree)
                let changedRanges = newTree.map { oldTree.rangesChanged(comparingTo: $0) } ?? []
                return (newTree, changedRanges)
            }
            DispatchQueue.main.async {
                self?.finishBackgroundParse(newTree: result.0, changedRanges: result.1)
            }
        }
    }

    private func finishBackgroundParse(newTree: TreeSitterTree?, changedRanges: [TreeSitterTextRange]) {
        isBackgroundParseRunning = false
        guard let newTree else {
            return
        }
        // Edits made while parsing are replayed onto the new tree; another parse follows to settle them.
        for edit in editsDuringBackgroundParse {
            newTree.apply(edit)
        }
        if !editsDuringBackgroundParse.isEmpty {
            needsBackgroundParse = true
        }
        editsDuringBackgroundParse = []
        rootLanguageLayer.replaceTree(with: newTree)
        let lineChangeSet = LineChangeSet()
        let lineCount = lineManager.lineCount
        for changedRange in changedRanges {
            let startRow = min(Int(changedRange.startPoint.row), lineCount - 1)
            let endRow = min(Int(changedRange.endPoint.row), lineCount - 1)
            guard startRow >= 0, startRow <= endRow else {
                continue
            }
            for row in startRow ... endRow {
                lineChangeSet.markLineEdited(lineManager.line(atRow: row))
            }
        }
        delegate?.treeSitterLanguageMode(self, didReparseWith: lineChangeSet)
        if needsBackgroundParse {
            scheduleBackgroundParse()
        }
    }

    func captures(in range: ByteRange) -> [TreeSitterCapture] {
        rootLanguageLayer.captures(in: range)
    }

    func createLineSyntaxHighlighter() -> LineSyntaxHighlighter {
        TreeSitterSyntaxHighlighter(stringView: stringView, languageMode: self, operationQueue: operationQueue)
    }

    func currentIndentLevel(of line: DocumentLineNode, using indentStrategy: IndentStrategy) -> Int {
        let measurer = IndentLevelMeasurer(stringView: stringView)
        return measurer.indentLevel(lineStartLocation: line.location, lineTotalLength: line.data.totalLength, tabLength: indentStrategy.tabLength)
    }

    func strategyForInsertingLineBreak(from startLinePosition: LinePosition,
                                       to endLinePosition: LinePosition,
                                       using indentStrategy: IndentStrategy) -> InsertLineBreakIndentStrategy {
        let startLayerAndNode = rootLanguageLayer.layerAndNode(at: startLinePosition)
        let endLayerAndNode = rootLanguageLayer.layerAndNode(at: endLinePosition)
        if let indentationScopes = startLayerAndNode?.layer.language.indentationScopes ?? endLayerAndNode?.layer.language.indentationScopes {
            let indentController = TreeSitterIndentController(
                indentationScopes: indentationScopes,
                stringView: stringView,
                lineManager: lineManager,
                tabLength: indentStrategy.tabLength)
            let startNode = startLayerAndNode?.node
            let endNode = endLayerAndNode?.node
            return indentController.strategyForInsertingLineBreak(
                between: startNode,
                and: endNode,
                caretStartPosition: startLinePosition,
                caretEndPosition: endLinePosition)
        } else {
            return InsertLineBreakIndentStrategy(indentLevel: 0, insertExtraLineBreak: false)
        }
    }

    func syntaxNode(at linePosition: LinePosition) -> SyntaxNode? {
        if let node = rootLanguageLayer.layerAndNode(at: linePosition)?.node, let type = node.type {
            let startLocation = TextLocation(LinePosition(node.startPoint))
            let endLocation = TextLocation(LinePosition(node.endPoint))
            return SyntaxNode(type: type, startLocation: startLocation, endLocation: endLocation)
        } else {
            return nil
        }
    }

    func detectIndentStrategy() -> DetectedIndentStrategy {
        if let tree = rootLanguageLayer.tree {
            let detector = TreeSitterIndentStrategyDetector(lineManager: lineManager, tree: tree, stringView: stringView)
            return detector.detect()
        } else {
            return .unknown
        }
    }
}

extension TreeSitterInternalLanguageMode: TreeSitterParserDelegate {
    func parser(_ parser: TreeSitterParser, bytesAt byteIndex: ByteCount) -> TreeSitterTextProviderResult? {
        delegate?.treeSitterLanguageMode(self, bytesAt: byteIndex)
    }
}
