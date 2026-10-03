import UIKit

/// A colored run in a minimap line: `length` characters starting at `column`.
struct MinimapRun: Hashable, Sendable {
    var column: Int
    var length: Int
    var color: ThemeColor
}

/// Supplies line contents to the minimap.
@MainActor
protocol MinimapDataSource: AnyObject {
    var minimapLineCount: Int { get }
    /// Colored runs for each line in `lines`, in order.
    func minimapRuns(for lines: Range<Int>) -> [[MinimapRun]]
    /// Fraction of the document scrolled (0...1) and the fraction of it that is visible.
    func minimapViewport() -> (scrollFraction: CGFloat, visibleFraction: CGFloat, firstVisibleLine: Int, visibleLineCount: Int)
    /// Scrolls the editor so `line` is at the top of the viewport.
    func minimapScroll(toLine line: Int, animated: Bool)
    /// Scrolls the editor to a fraction of its scrollable height.
    func minimapScroll(toFraction fraction: CGFloat)
}

/// A scaled overview of the document: each line is drawn as colored blocks two points tall.
///
/// The minimap renders a tile of lines around the viewport into a bitmap and moves it as the editor scrolls,
/// re-rendering only when the viewport leaves the tile. Tap a line to jump to it; drag the slider to scroll.
@MainActor
final class MinimapView: UIView {
    weak var dataSource: MinimapDataSource?

    var theme: EditorTheme = .lemonDark {
        didSet {
            backgroundColor = theme.minimapBackground.uiColor
            sliderView.backgroundColor = theme.minimapSlider.uiColor
            invalidate()
        }
    }
    /// Lines with markers (diagnostics, find matches, Git changes) drawn in the right-hand ruler.
    var markers: [(line: Int, color: ThemeColor)] = [] {
        didSet { setNeedsMarkerRender() }
    }
    var currentLine: Int? {
        didSet {
            if currentLine != oldValue {
                updateCurrentLineIndicator()
            }
        }
    }

    let lineHeight: CGFloat = 2
    let characterWidth: CGFloat = 1
    let maximumColumns = 120

    private let tileLayer = CALayer()
    private let markerLayer = CALayer()
    private let currentLineLayer = CALayer()
    private let sliderView = UIView()
    private var tileRange: Range<Int>?
    private var tileIsStale = true
    private var markersAreStale = true
    private var isDraggingSlider = false
    private var dragStartFraction: CGFloat = 0
    private var dragStartY: CGFloat = 0
    private let separatorLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isOpaque = true
        tileLayer.actions = DecorationController.noActions
        tileLayer.magnificationFilter = .nearest
        tileLayer.contentsGravity = .topLeft
        layer.addSublayer(tileLayer)
        currentLineLayer.actions = DecorationController.noActions
        layer.addSublayer(currentLineLayer)
        markerLayer.actions = DecorationController.noActions
        layer.addSublayer(markerLayer)
        separatorLayer.actions = DecorationController.noActions
        layer.addSublayer(separatorLayer)
        sliderView.isUserInteractionEnabled = false
        sliderView.layer.cornerCurve = .continuous
        sliderView.layer.cornerRadius = 3
        addSubview(sliderView)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityLabel = "Minimap"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Discards the rendered tile, e.g. after an edit or when highlighting finishes.
    func invalidate() {
        tileIsStale = true
        markersAreStale = true
        setNeedsLayout()
    }

    func setNeedsMarkerRender() {
        markersAreStale = true
        setNeedsLayout()
    }

    /// Call when the editor scrolls.
    func viewportDidChange() {
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        separatorLayer.frame = CGRect(x: 0, y: 0, width: 1 / max(traitCollection.displayScale, 1), height: bounds.height)
        separatorLayer.backgroundColor = theme.separator.withAlpha(0.6).cgColor
        guard let dataSource, bounds.height > 0 else {
            return
        }
        let lineCount = max(dataSource.minimapLineCount, 1)
        let viewport = dataSource.minimapViewport()
        let visibleMinimapLines = Int(bounds.height / lineHeight)
        let contentHeight = CGFloat(lineCount) * lineHeight
        // When the document is taller than the minimap, the minimap scrolls in proportion to the editor.
        let minimapScrollTop = max(0, contentHeight - bounds.height) * viewport.scrollFraction
        let firstLine = Int(minimapScrollTop / lineHeight)
        let neededRange = firstLine ..< min(lineCount, firstLine + visibleMinimapLines + 1)
        if tileIsStale || !(tileRange.map { $0.contains(neededRange.lowerBound) && ($0.upperBound >= neededRange.upperBound) } ?? false) {
            renderTile(around: neededRange, lineCount: lineCount)
        }
        if let tileRange {
            tileLayer.frame = CGRect(x: 0,
                                     y: CGFloat(tileRange.lowerBound) * lineHeight - minimapScrollTop,
                                     width: tileLayer.frame.width,
                                     height: CGFloat(tileRange.count) * lineHeight)
        }
        // Slider covers the lines visible in the editor.
        let sliderY = CGFloat(viewport.firstVisibleLine) * lineHeight - minimapScrollTop
        let sliderHeight = max(CGFloat(viewport.visibleLineCount) * lineHeight, 16)
        sliderView.frame = CGRect(x: 1, y: sliderY, width: bounds.width - 1, height: sliderHeight)
        sliderView.backgroundColor = (isDraggingSlider ? theme.minimapSliderActive : theme.minimapSlider).uiColor
        if markersAreStale {
            renderMarkers(lineCount: lineCount)
        }
        currentLineScrollTop = minimapScrollTop
        updateCurrentLineIndicator()
        accessibilityValue = "Line \(viewport.firstVisibleLine + 1) of \(lineCount)"
    }

    private var currentLineScrollTop: CGFloat = 0

    private func updateCurrentLineIndicator() {
        guard let currentLine else {
            currentLineLayer.isHidden = true
            return
        }
        currentLineLayer.isHidden = false
        currentLineLayer.backgroundColor = theme.accent.withAlpha(0.55).cgColor
        currentLineLayer.frame = CGRect(x: 0, y: CGFloat(currentLine) * lineHeight - currentLineScrollTop, width: bounds.width, height: lineHeight)
    }

    private func renderTile(around neededRange: Range<Int>, lineCount: Int) {
        guard let dataSource else {
            return
        }
        // Render one extra screen above and below so scrolling rarely needs a new tile.
        let screen = max(neededRange.count, 1)
        let lower = max(0, neededRange.lowerBound - screen)
        let upper = min(lineCount, neededRange.upperBound + screen)
        let range = lower ..< upper
        let runs = dataSource.minimapRuns(for: range)
        let width = bounds.width
        let height = CGFloat(range.count) * lineHeight
        guard width > 0, height > 0 else {
            return
        }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let leadingInset: CGFloat = 6
        let image = renderer.image { context in
            let cgContext = context.cgContext
            var currentColor: ThemeColor?
            for (offset, lineRuns) in runs.enumerated() {
                let y = CGFloat(offset) * lineHeight
                for run in lineRuns where run.column < maximumColumns {
                    if currentColor != run.color {
                        cgContext.setFillColor(run.color.cgColor)
                        currentColor = run.color
                    }
                    let length = min(run.length, maximumColumns - run.column)
                    cgContext.fill(CGRect(x: leadingInset + CGFloat(run.column) * characterWidth, y: y,
                                          width: CGFloat(length) * characterWidth, height: lineHeight * 0.8))
                }
            }
        }
        tileLayer.contents = image.cgImage
        tileLayer.contentsScale = image.scale
        tileLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tileRange = range
        tileIsStale = false
    }

    private func renderMarkers(lineCount: Int) {
        markersAreStale = false
        // Markers use a document-proportional ruler on the trailing edge, like a scroll bar.
        let rulerHeight = bounds.height
        let width: CGFloat = 3
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let size = CGSize(width: width, height: rulerHeight)
        guard size.height > 0 else {
            return
        }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for marker in markers {
                let y = CGFloat(marker.line) / CGFloat(max(lineCount, 1)) * rulerHeight
                context.cgContext.setFillColor(marker.color.cgColor)
                context.cgContext.fill(CGRect(x: 0, y: min(y, rulerHeight - 2), width: width, height: 2))
            }
        }
        markerLayer.contents = image.cgImage
        markerLayer.contentsScale = image.scale
        markerLayer.frame = CGRect(x: bounds.width - width, y: 0, width: width, height: rulerHeight)
    }

    // MARK: - Interaction

    private func line(atY y: CGFloat) -> Int {
        guard let dataSource else {
            return 0
        }
        let lineCount = max(dataSource.minimapLineCount, 1)
        let viewport = dataSource.minimapViewport()
        let contentHeight = CGFloat(lineCount) * lineHeight
        let minimapScrollTop = max(0, contentHeight - bounds.height) * viewport.scrollFraction
        return min(max(Int((y + minimapScrollTop) / lineHeight), 0), lineCount - 1)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let dataSource else {
            return
        }
        let viewport = dataSource.minimapViewport()
        let target = line(atY: gesture.location(in: self).y)
        dataSource.minimapScroll(toLine: max(target - viewport.visibleLineCount / 2, 0), animated: true)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let dataSource else {
            return
        }
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            isDraggingSlider = true
            if !sliderView.frame.insetBy(dx: 0, dy: -8).contains(location) {
                // Grabbing outside the slider jumps there first, then drags.
                let viewport = dataSource.minimapViewport()
                let target = line(atY: location.y)
                dataSource.minimapScroll(toLine: max(target - viewport.visibleLineCount / 2, 0), animated: false)
            }
            dragStartFraction = dataSource.minimapViewport().scrollFraction
            dragStartY = location.y
            setNeedsLayout()
        case .changed:
            let lineCount = max(dataSource.minimapLineCount, 1)
            let viewport = dataSource.minimapViewport()
            let contentHeight = CGFloat(lineCount) * lineHeight
            // Slider travel: in a short document the slider moves over the lines; in a long one over the view.
            let sliderTravel = max(min(contentHeight, bounds.height) - max(CGFloat(viewport.visibleLineCount) * lineHeight, 16), 1)
            let delta = (location.y - dragStartY) / sliderTravel
            dataSource.minimapScroll(toFraction: min(max(dragStartFraction + delta, 0), 1))
        default:
            isDraggingSlider = false
            setNeedsLayout()
        }
    }

    override func accessibilityIncrement() {
        guard let dataSource else { return }
        let viewport = dataSource.minimapViewport()
        dataSource.minimapScroll(toLine: max(viewport.firstVisibleLine - viewport.visibleLineCount, 0), animated: true)
    }

    override func accessibilityDecrement() {
        guard let dataSource else { return }
        let viewport = dataSource.minimapViewport()
        dataSource.minimapScroll(toLine: viewport.firstVisibleLine + viewport.visibleLineCount, animated: true)
    }
}

extension MinimapView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 4, height: 18), radius: 2))
    }
}
