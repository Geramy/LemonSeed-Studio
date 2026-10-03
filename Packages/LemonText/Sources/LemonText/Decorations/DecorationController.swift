import LemonTextCore
import UIKit

/// Draws everything the text engine does not: indentation guides, bracket matches, diagnostics squiggles,
/// gutter markers, fold controls and placeholders, and extra carets.
///
/// Layers are built for a window of lines around the viewport (the visible lines plus one screen above and
/// below) and only rebuilt when scrolling leaves that window or the inputs change, so scrolling costs nothing
/// in most frames.
@MainActor
final class DecorationController {
    private unowned let textView: CodeTextView

    var theme: EditorTheme = .lemonDark {
        didSet { applyThemeColors(); setNeedsUpdate() }
    }
    var configuration = EditorConfiguration() {
        didSet { setNeedsUpdate() }
    }
    var font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular) {
        didSet {
            characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            setNeedsUpdate()
        }
    }

    // Inputs
    var diagnostics: [Diagnostic] = [] {
        didSet {
            sortedDiagnostics = diagnostics.sorted { $0.range.location < $1.range.location }
            setNeedsUpdate()
        }
    }
    var gutterMarkers: [GutterMarker] = [] {
        didSet {
            gutterMarkersByLine = Dictionary(grouping: gutterMarkers, by: \.line)
            setNeedsUpdate()
        }
    }
    var foldingRanges: [FoldingRange] = [] {
        didSet {
            foldingRangesByStart = Dictionary(foldingRanges.map { ($0.startLine, $0) }, uniquingKeysWith: { lhs, rhs in
                lhs.endLine >= rhs.endLine ? lhs : rhs
            })
            setNeedsUpdate()
        }
    }
    var foldState = FoldState() {
        didSet { setNeedsUpdate() }
    }
    var bracketMatch: BracketMatch? {
        didSet {
            if bracketMatch != oldValue {
                updateBracketLayer()
            }
        }
    }
    var secondarySelections: [NSRange] = [] {
        didSet {
            if secondarySelections != oldValue {
                updateSecondarySelectionLayers()
            }
        }
    }
    var caretLine: Int = 0 {
        didSet {
            if caretLine != oldValue {
                updateActiveGuide()
            }
        }
    }

    private(set) var sortedDiagnostics: [Diagnostic] = []
    private var gutterMarkersByLine: [Int: [GutterMarker]] = [:]
    private(set) var foldingRangesByStart: [Int: FoldingRange] = [:]
    private var characterWidth: CGFloat = 8

    // Layers
    private let guidesLayer = CAShapeLayer()
    private let activeGuideLayer = CAShapeLayer()
    private let bracketLayer = CAShapeLayer()
    private var squiggleLayers: [DiagnosticSeverity: CAShapeLayer] = [:]
    private let secondarySelectionLayer = CAShapeLayer()
    private let secondaryCaretLayer = CAShapeLayer()
    private let placeholderContainer = CALayer()
    private let gutterMarkerContainer = CALayer()
    private let foldChevronLayer = CAShapeLayer()
    private let foldedChevronLayer = CAShapeLayer()

    // Window state
    private var window: ClosedRange<Int>?
    private var windowAnchorY: CGFloat = 0
    private var needsUpdate = true
    private var guideLevels: [Int: Int] = [:]
    private(set) var placeholderRects: [(line: Int, rect: CGRect)] = []
    private(set) var foldControlLines: [Int: CGRect] = [:]

    init(textView: CodeTextView) {
        self.textView = textView
        for layer in [guidesLayer, activeGuideLayer] {
            layer.fillColor = nil
            layer.lineWidth = 1
            layer.actions = Self.noActions
            textView.underlayView.layer.addSublayer(layer)
        }
        bracketLayer.lineWidth = 1
        bracketLayer.actions = Self.noActions
        textView.underlayView.layer.addSublayer(bracketLayer)
        for severity in DiagnosticSeverity.allCases.reversed() {
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineWidth = severity == .hint ? 1.5 : 1.2
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.actions = Self.noActions
            if severity == .hint {
                layer.lineDashPattern = [1.5, 2.5]
            }
            squiggleLayers[severity] = layer
            textView.overlayView.layer.addSublayer(layer)
        }
        secondarySelectionLayer.actions = Self.noActions
        textView.underlayView.layer.addSublayer(secondarySelectionLayer)
        secondaryCaretLayer.actions = Self.noActions
        textView.overlayView.layer.addSublayer(secondaryCaretLayer)
        placeholderContainer.actions = Self.noActions
        textView.overlayView.layer.addSublayer(placeholderContainer)
        gutterMarkerContainer.actions = Self.noActions
        textView.gutterOverlayView.layer.addSublayer(gutterMarkerContainer)
        for layer in [foldChevronLayer, foldedChevronLayer] {
            layer.fillColor = nil
            layer.lineWidth = 1.5
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.actions = Self.noActions
            textView.gutterOverlayView.layer.addSublayer(layer)
        }
        applyThemeColors()
    }

    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(), "frame": NSNull(), "contents": NSNull(),
        "hidden": NSNull(), "opacity": NSNull(), "sublayers": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull()
    ]

    func setNeedsUpdate() {
        needsUpdate = true
    }

    /// Text changed: positions of everything may have moved.
    func textDidChange() {
        guideLevels.removeAll(keepingCapacity: true)
        needsUpdate = true
    }

    /// Called on every layout pass of the text view.
    func layoutIfNeeded() {
        guard let visible = textView.visibleLineIndices else {
            return
        }
        if !needsUpdate, let window, window.contains(visible.lowerBound), window.contains(visible.upperBound),
           let extent = textView.verticalExtent(ofLine: window.lowerBound), abs(extent.minY - windowAnchorY) < 0.5 {
            return
        }
        let margin = max(visible.count, 20)
        let lineCount = textView.lineCount
        let newWindow = max(0, visible.lowerBound - margin) ... max(0, min(lineCount - 1, visible.upperBound + margin))
        rebuild(window: newWindow)
    }

    // MARK: - Rebuilding

    private func rebuild(window newWindow: ClosedRange<Int>) {
        needsUpdate = false
        window = newWindow
        windowAnchorY = textView.verticalExtent(ofLine: newWindow.lowerBound)?.minY ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildGuides(in: newWindow)
        updateActiveGuide()
        rebuildSquiggles(in: newWindow)
        rebuildGutter(in: newWindow)
        rebuildPlaceholders(in: newWindow)
        updateBracketLayer()
        updateSecondarySelectionLayers()
        CATransaction.commit()
    }

    private func indentColumns(ofLine line: Int) -> Int? {
        guard let range = textView.range(ofLine: line) else {
            return nil
        }
        let probeLength = min(range.length, 256)
        guard probeLength > 0, let prefix = textView.text(in: NSRange(location: range.location, length: probeLength)) else {
            return nil
        }
        var columns = 0
        var sawContent = false
        for scalar in prefix.unicodeScalars {
            if scalar == " " {
                columns += 1
            } else if scalar == "\t" {
                columns += configuration.tabWidth - columns % max(configuration.tabWidth, 1)
            } else {
                sawContent = true
                break
            }
        }
        // A line of only whitespace counts as blank.
        return sawContent ? columns : (range.length > probeLength ? columns : nil)
    }

    private func rebuildGuides(in window: ClosedRange<Int>) {
        guard configuration.showIndentGuides else {
            guidesLayer.path = nil
            guideLevels = [:]
            return
        }
        // Look a little beyond the window so blank lines at its edges resolve their level.
        let lookaround = 40
        let lower = max(0, window.lowerBound - lookaround)
        let upper = min(textView.lineCount - 1, window.upperBound + lookaround)
        guard lower <= upper else {
            return
        }
        let columns = (lower ... upper).map { textView.isLineHidden($0) ? nil : indentColumns(ofLine: $0) }
        let indentWidth = max(configuration.tabWidth, 1)
        let levels = IndentGuides.levels(indentColumns: columns, indentWidth: indentWidth)
        guideLevels = [:]
        let path = CGMutablePath()
        let textOrigin = textView.textOriginX
        let guideSpacing = CGFloat(indentWidth) * characterWidth
        // Merge vertical runs per level so each guide is one segment per block.
        var runStart: [Int: CGFloat] = [:]
        var runEnd: [Int: CGFloat] = [:]
        func flush(level: Int) {
            if let start = runStart[level], let end = runEnd[level], end > start {
                let x = (textOrigin + CGFloat(level - 1) * guideSpacing).rounded() + 0.5
                path.move(to: CGPoint(x: x, y: start))
                path.addLine(to: CGPoint(x: x, y: end))
            }
            runStart[level] = nil
            runEnd[level] = nil
        }
        var maxLevel = 0
        for line in window {
            let level = levels[line - lower]
            guideLevels[line] = level
            guard let extent = textView.verticalExtent(ofLine: line), extent.height > 0 else {
                continue
            }
            maxLevel = max(maxLevel, level)
            for guide in 1 ... max(maxLevel, 1) {
                if guide <= level {
                    if runStart[guide] == nil {
                        runStart[guide] = extent.minY
                    }
                    runEnd[guide] = extent.minY + extent.height
                } else if runStart[guide] != nil {
                    flush(level: guide)
                }
            }
        }
        for level in Array(runStart.keys) {
            flush(level: level)
        }
        guidesLayer.path = path
    }

    private func updateActiveGuide() {
        guard configuration.showIndentGuides, let window, window.contains(caretLine) else {
            activeGuideLayer.path = nil
            return
        }
        let lines = window.map { guideLevels[$0] ?? 0 }
        guard let active = IndentGuides.activeGuide(levels: lines, caretLine: caretLine - window.lowerBound) else {
            activeGuideLayer.path = nil
            return
        }
        let first = active.lines.lowerBound + window.lowerBound
        let last = active.lines.upperBound + window.lowerBound
        guard let top = textView.verticalExtent(ofLine: first), let bottom = textView.verticalExtent(ofLine: last) else {
            return
        }
        let guideSpacing = CGFloat(max(configuration.tabWidth, 1)) * characterWidth
        let x = (textView.textOriginX + CGFloat(active.level - 1) * guideSpacing).rounded() + 0.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: top.minY))
        path.addLine(to: CGPoint(x: x, y: bottom.minY + bottom.height))
        activeGuideLayer.path = path
    }

    private func rebuildSquiggles(in window: ClosedRange<Int>) {
        var paths: [DiagnosticSeverity: CGMutablePath] = [:]
        if let start = textView.range(ofLine: window.lowerBound)?.location,
           let endRange = textView.range(ofLine: window.upperBound, includingLineBreak: true) {
            let end = endRange.location + endRange.length
            let firstIndex = sortedDiagnostics.partitioningIndex { $0.range.location + $0.range.length >= start }
            for diagnostic in sortedDiagnostics[firstIndex...] {
                if diagnostic.range.location > end {
                    break
                }
                var range = diagnostic.range
                if range.length == 0 {
                    // Zero-width diagnostics (e.g. "expected ';'") underline the character before them.
                    range = NSRange(location: max(range.location - 1, 0), length: 1)
                }
                let path = paths[diagnostic.severity] ?? CGMutablePath()
                for rect in textView.selectionRects(in: range) where rect.width > 0 {
                    if diagnostic.severity == .hint {
                        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1.5))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 1.5))
                    } else {
                        Self.addSquiggle(to: path, from: rect.minX, to: max(rect.maxX, rect.minX + characterWidth), baseline: rect.maxY - 2)
                    }
                }
                paths[diagnostic.severity] = path
            }
        }
        for (severity, layer) in squiggleLayers {
            layer.path = paths[severity]
        }
    }

    static func addSquiggle(to path: CGMutablePath, from startX: CGFloat, to endX: CGFloat, baseline: CGFloat) {
        let wavelength: CGFloat = 4
        let amplitude: CGFloat = 1.25
        var x = startX
        path.move(to: CGPoint(x: x, y: baseline))
        var up = true
        while x < endX {
            let nextX = min(x + wavelength / 2, endX)
            let controlX = (x + nextX) / 2
            path.addQuadCurve(to: CGPoint(x: nextX, y: baseline), control: CGPoint(x: controlX, y: baseline + (up ? -amplitude : amplitude) * 2))
            x = nextX
            up.toggle()
        }
    }

    private func rebuildGutter(in window: ClosedRange<Int>) {
        gutterMarkerContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
        foldControlLines = [:]
        guard textView.showLineNumbers else {
            foldChevronLayer.path = nil
            foldedChevronLayer.path = nil
            return
        }
        let gutterWidth = textView.gutterWidth
        let leadingCenter = textView.gutterLeadingPadding / 2 + 1
        // Highest severity per line.
        var severityByLine: [Int: DiagnosticSeverity] = [:]
        if let start = textView.range(ofLine: window.lowerBound)?.location,
           let endRange = textView.range(ofLine: window.upperBound, includingLineBreak: true) {
            let end = endRange.location + endRange.length
            let firstIndex = sortedDiagnostics.partitioningIndex { $0.range.location + $0.range.length >= start }
            for diagnostic in sortedDiagnostics[firstIndex...] where diagnostic.severity <= .warning {
                if diagnostic.range.location > end {
                    break
                }
                guard let line = textView.lineIndex(containing: min(diagnostic.range.location, max(textView.textLength - 1, 0))) else {
                    continue
                }
                if let existing = severityByLine[line], existing <= diagnostic.severity {
                    continue
                }
                severityByLine[line] = diagnostic.severity
            }
        }
        let chevronPath = CGMutablePath()
        let foldedPath = CGMutablePath()
        let chevronX = gutterWidth - textView.gutterTrailingPadding / 2 - 1
        for line in window {
            guard let extent = textView.verticalExtent(ofLine: line), extent.height > 0 else {
                continue
            }
            let midY = extent.minY + min(extent.height, font.lineHeight * 1.6) / 2
            if let severity = severityByLine[line] {
                let dot = CALayer()
                dot.actions = Self.noActions
                let size: CGFloat = 6
                dot.frame = CGRect(x: leadingCenter - size / 2, y: midY - size / 2, width: size, height: size)
                dot.cornerRadius = size / 2
                dot.backgroundColor = (severity == .error ? theme.error : theme.warning).cgColor
                gutterMarkerContainer.addSublayer(dot)
            }
            for marker in gutterMarkersByLine[line] ?? [] {
                gutterMarkerContainer.addSublayer(markerLayer(for: marker, lineMinY: extent.minY, lineHeight: extent.height,
                                                              midY: midY, gutterWidth: gutterWidth, leadingCenter: leadingCenter))
            }
            if configuration.showFoldingControls, foldingRangesByStart[line] != nil || foldState.isFolded(startingAt: line) {
                let isFolded = foldState.isFolded(startingAt: line)
                let size: CGFloat = 3.5
                let path = isFolded ? foldedPath : chevronPath
                if isFolded {
                    path.move(to: CGPoint(x: chevronX - size / 2, y: midY - size))
                    path.addLine(to: CGPoint(x: chevronX + size / 2, y: midY))
                    path.addLine(to: CGPoint(x: chevronX - size / 2, y: midY + size))
                } else {
                    path.move(to: CGPoint(x: chevronX - size, y: midY - size / 2))
                    path.addLine(to: CGPoint(x: chevronX, y: midY + size / 2))
                    path.addLine(to: CGPoint(x: chevronX + size, y: midY - size / 2))
                }
                foldControlLines[line] = CGRect(x: chevronX - 12, y: extent.minY, width: 24, height: extent.height)
            }
        }
        foldChevronLayer.path = chevronPath
        foldedChevronLayer.path = foldedPath
    }

    private func markerLayer(for marker: GutterMarker, lineMinY: CGFloat, lineHeight: CGFloat, midY: CGFloat,
                             gutterWidth: CGFloat, leadingCenter: CGFloat) -> CALayer {
        let layer = CAShapeLayer()
        layer.actions = Self.noActions
        layer.fillColor = marker.color.cgColor
        switch marker.kind {
        case .dot:
            let size: CGFloat = 7
            layer.path = CGPath(ellipseIn: CGRect(x: leadingCenter - size / 2, y: midY - size / 2, width: size, height: size), transform: nil)
        case .bar:
            layer.path = CGPath(roundedRect: CGRect(x: gutterWidth - 3, y: lineMinY + 1, width: 2.5, height: lineHeight - 2),
                                cornerWidth: 1, cornerHeight: 1, transform: nil)
        case .deletion:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: gutterWidth - 5, y: lineMinY + lineHeight - 3))
            path.addLine(to: CGPoint(x: gutterWidth, y: lineMinY + lineHeight))
            path.addLine(to: CGPoint(x: gutterWidth - 5, y: lineMinY + lineHeight + 3))
            path.closeSubpath()
            layer.path = path
        case .symbol(let name):
            let configuration = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            if let image = UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(marker.color.uiColor, renderingMode: .alwaysOriginal) {
                let imageLayer = CALayer()
                imageLayer.actions = Self.noActions
                let size = image.size
                imageLayer.frame = CGRect(x: leadingCenter - size.width / 2, y: midY - size.height / 2, width: size.width, height: size.height)
                let renderer = UIGraphicsImageRenderer(size: size)
                imageLayer.contents = renderer.image { _ in image.draw(at: .zero) }.cgImage
                imageLayer.contentsScale = textView.traitCollection.displayScale
                return imageLayer
            }
        }
        return layer
    }

    private func rebuildPlaceholders(in window: ClosedRange<Int>) {
        placeholderContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
        placeholderRects = []
        for range in foldState.folded where window.contains(range.startLine) {
            guard let lineRange = textView.range(ofLine: range.startLine) else {
                continue
            }
            let endCaret = textView.caretRect(at: lineRange.location + lineRange.length)
            let height = font.lineHeight
            let width: CGFloat = 26
            let rect = CGRect(x: endCaret.maxX + 8, y: endCaret.midY - height / 2 + 1, width: width, height: height - 2)
            let pill = CALayer()
            pill.actions = Self.noActions
            pill.frame = rect
            pill.cornerRadius = rect.height / 2
            pill.backgroundColor = theme.foreground.withAlpha(theme.isDark ? 0.09 : 0.07).cgColor
            pill.borderWidth = 0.5
            pill.borderColor = theme.foreground.withAlpha(0.12).cgColor
            // Three dots.
            let dots = CAShapeLayer()
            dots.actions = Self.noActions
            dots.frame = pill.bounds
            let dotPath = CGMutablePath()
            for index in -1 ... 1 {
                let center = CGPoint(x: rect.width / 2 + CGFloat(index) * 5, y: rect.height / 2)
                dotPath.addEllipse(in: CGRect(x: center.x - 1.25, y: center.y - 1.25, width: 2.5, height: 2.5))
            }
            dots.path = dotPath
            dots.fillColor = theme.foldPlaceholder.cgColor
            pill.addSublayer(dots)
            placeholderContainer.addSublayer(pill)
            placeholderRects.append((range.startLine, rect))
        }
    }

    private func updateBracketLayer() {
        guard configuration.matchBrackets, let bracketMatch else {
            bracketLayer.path = nil
            return
        }
        let path = CGMutablePath()
        for range in [bracketMatch.open, bracketMatch.close] {
            for rect in textView.selectionRects(in: range) {
                path.addRoundedRect(in: rect.insetBy(dx: -0.5, dy: 1).integral, cornerWidth: 3, cornerHeight: 3)
            }
        }
        bracketLayer.path = path
    }

    private func updateSecondarySelectionLayers() {
        let selectionPath = CGMutablePath()
        let caretPath = CGMutablePath()
        for selection in secondarySelections {
            if selection.length == 0 {
                let caret = textView.caretRect(at: selection.location)
                caretPath.addRect(CGRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height))
            } else {
                for rect in textView.selectionRects(in: selection) {
                    selectionPath.addRect(rect)
                }
                let caret = textView.caretRect(at: selection.location + selection.length)
                caretPath.addRect(CGRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height))
            }
        }
        secondarySelectionLayer.path = selectionPath
        secondaryCaretLayer.path = caretPath
        if secondarySelections.isEmpty {
            secondaryCaretLayer.removeAnimation(forKey: "blink")
        } else if secondaryCaretLayer.animation(forKey: "blink") == nil {
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 1, 0, 0, 1]
            blink.keyTimes = [0, 0.45, 0.5, 0.95, 1]
            blink.duration = 1.0
            blink.repeatCount = .infinity
            secondaryCaretLayer.add(blink, forKey: "blink")
        }
    }

    private func applyThemeColors() {
        guidesLayer.strokeColor = theme.indentGuide.cgColor
        activeGuideLayer.strokeColor = theme.activeIndentGuide.cgColor
        bracketLayer.fillColor = theme.bracketMatchBackground.cgColor
        bracketLayer.strokeColor = theme.bracketMatchBorder.cgColor
        squiggleLayers[.error]?.strokeColor = theme.error.cgColor
        squiggleLayers[.warning]?.strokeColor = theme.warning.cgColor
        squiggleLayers[.information]?.strokeColor = theme.information.cgColor
        squiggleLayers[.hint]?.strokeColor = theme.hint.cgColor
        secondarySelectionLayer.fillColor = theme.selection.cgColor
        secondaryCaretLayer.fillColor = theme.secondaryCaret.cgColor
        foldChevronLayer.strokeColor = theme.lineNumber.withAlpha(0.8).cgColor
        foldedChevronLayer.strokeColor = theme.accent.cgColor
    }

    // MARK: - Hit testing

    /// The fold start line whose placeholder pill contains a point in content coordinates.
    func placeholderLine(at point: CGPoint) -> Int? {
        placeholderRects.first { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }?.line
    }

    /// The fold start line whose gutter control contains a point in the gutter overlay's coordinates.
    func foldControlLine(at point: CGPoint) -> Int? {
        foldControlLines.first { $0.value.contains(point) }?.key
    }

    /// Diagnostics on a line, most severe first.
    func diagnostics(onLine line: Int) -> [Diagnostic] {
        guard let lineRange = textView.range(ofLine: line, includingLineBreak: true) else {
            return []
        }
        let end = lineRange.location + max(lineRange.length, 1)
        let firstIndex = sortedDiagnostics.partitioningIndex { $0.range.location + $0.range.length >= lineRange.location }
        var result: [Diagnostic] = []
        for diagnostic in sortedDiagnostics[firstIndex...] {
            if diagnostic.range.location >= end {
                break
            }
            result.append(diagnostic)
        }
        return result.sorted { $0.severity < $1.severity }
    }
}

extension Collection {
    /// The index of the first element for which `predicate` is true, assuming the collection is partitioned.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Index {
        var low = startIndex
        var count = self.count
        while count > 0 {
            let half = count / 2
            let middle = index(low, offsetBy: half)
            if predicate(self[middle]) {
                count = half
            } else {
                low = index(after: middle)
                count -= half + 1
            }
        }
        return low
    }
}
