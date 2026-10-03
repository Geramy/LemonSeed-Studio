import LemonTextCore
import UIKit

// MARK: - Touch, Pencil, trackpad and hover
extension LemonTextViewController: UIGestureRecognizerDelegate {
    func setUpInput() {
        // Apple Pencil selects text and never scrolls; fingers and the trackpad scroll.
        codeTextView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        let pencilPan = UIPanGestureRecognizer(target: self, action: #selector(handlePencilPan(_:)))
        pencilPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilPan.maximumNumberOfTouches = 1
        pencilPan.delegate = self
        codeTextView.addGestureRecognizer(pencilPan)

        // ⌥-click (or ⌥-tap with a keyboard) adds a caret.
        let optionTap = UITapGestureRecognizer(target: self, action: #selector(handleOptionTap(_:)))
        optionTap.delegate = self
        optionTap.name = "LemonText.optionTap"
        codeTextView.addGestureRecognizer(optionTap)

        // Taps on fold placeholders.
        let placeholderTap = UITapGestureRecognizer(target: self, action: #selector(handlePlaceholderTap(_:)))
        placeholderTap.delegate = self
        placeholderTap.name = "LemonText.placeholderTap"
        codeTextView.addGestureRecognizer(placeholderTap)

        // Hover from the trackpad pointer or Apple Pencil.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        codeTextView.addGestureRecognizer(hover)

        // Gutter: tap folds, shows diagnostics or selects a line; drag selects lines.
        let gutterTap = UITapGestureRecognizer(target: self, action: #selector(handleGutterTap(_:)))
        codeTextView.gutterOverlayView.addGestureRecognizer(gutterTap)
        let gutterPan = UIPanGestureRecognizer(target: self, action: #selector(handleGutterPan(_:)))
        gutterPan.delegate = self
        gutterPan.name = "LemonText.gutterPan"
        codeTextView.gutterOverlayView.addGestureRecognizer(gutterPan)
        codeTextView.gutterOverlayView.addInteraction(UIPointerInteraction(delegate: self))
        codeTextView.addInteraction(UIPointerInteraction(delegate: self))

        let pencilInteraction = UIPencilInteraction(delegate: self)
        codeTextView.addInteraction(pencilInteraction)
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        switch gestureRecognizer.name {
        case "LemonText.optionTap":
            return gestureRecognizer.modifierFlags.contains(.alternate)
        case "LemonText.placeholderTap":
            return decorations.placeholderLine(at: gestureRecognizer.location(in: codeTextView)) != nil
        case "LemonText.gutterPan":
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }
            // Vertical drags in the gutter select lines; anything else scrolls.
            let velocity = pan.velocity(in: codeTextView)
            return abs(velocity.y) > abs(velocity.x) && pan.numberOfTouches <= 1 && gutterPanIsSelecting(pan)
        default:
            return true
        }
    }

    private func gutterPanIsSelecting(_ pan: UIPanGestureRecognizer) -> Bool {
        // Fingers scroll the gutter like the text; the pointer and Pencil select.
        lastGutterTouchWasIndirect
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer.name == "LemonText.gutterPan" {
            lastGutterTouchWasIndirect = touch.type == .indirectPointer || touch.type == .pencil
        }
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.name == "LemonText.optionTap"
    }

    // MARK: Pencil selection

    @objc func handlePencilPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: codeTextView)
        guard let location = codeTextView.closestLocation(to: point) else {
            return
        }
        switch gesture.state {
        case .began:
            secondarySelections = []
            pencilSelectionAnchor = location
            _ = codeTextView.becomeFirstResponder()
            codeTextView.selectedRange = NSRange(location: location, length: 0)
        case .changed:
            guard let anchor = pencilSelectionAnchor else {
                return
            }
            let range = NSRange(location: min(anchor, location), length: abs(location - anchor))
            codeTextView.selectedRange = range
            autoscrollForPencil(at: gesture.location(in: view))
        default:
            pencilSelectionAnchor = nil
        }
    }

    private func autoscrollForPencil(at pointInView: CGPoint) {
        let edge: CGFloat = 48
        var offset = codeTextView.contentOffset
        if pointInView.y < edge {
            offset.y = max(offset.y - (edge - pointInView.y) * 0.6, 0)
        } else if pointInView.y > view.bounds.height - edge {
            let maxOffset = max(codeTextView.contentSize.height - codeTextView.bounds.height, 0)
            offset.y = min(offset.y + (pointInView.y - (view.bounds.height - edge)) * 0.6, maxOffset)
        }
        if offset != codeTextView.contentOffset {
            codeTextView.contentOffset = offset
        }
    }

    // MARK: Extra carets

    @objc func handleOptionTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let location = codeTextView.closestLocation(to: gesture.location(in: codeTextView)) else {
            return
        }
        let before = previousPrimarySelection
        // The text interaction may already have moved the caret to the tap; keep the old caret as an extra one.
        DispatchQueue.main.async { [self] in
            let primary = codeTextView.selectedRange
            var extras = secondarySelections
            if primary.location == location {
                extras.append(before)
            } else {
                extras.append(NSRange(location: location, length: 0))
            }
            secondarySelections = EditCommands.normalizedSelections(extras).filter { $0 != primary }
            previousPrimarySelection = primary
        }
    }

    // MARK: Folding and gutter

    @objc func handlePlaceholderTap(_ gesture: UITapGestureRecognizer) {
        if let line = decorations.placeholderLine(at: gesture.location(in: codeTextView)) {
            unfold(atLine: line)
        }
    }

    @objc func handleGutterTap(_ gesture: UITapGestureRecognizer) {
        let gutterPoint = gesture.location(in: codeTextView.gutterOverlayView)
        if let line = decorations.foldControlLine(at: gutterPoint) {
            UISelectionFeedbackGenerator().selectionChanged()
            toggleFold(atLine: line)
            return
        }
        let contentPoint = gesture.location(in: codeTextView)
        let line = codeTextView.lineIndex(atYOffset: contentPoint.y)
        let lineDiagnostics = decorations.diagnostics(onLine: line)
        if !lineDiagnostics.isEmpty && gutterPoint.x < codeTextView.gutterLeadingPadding + 4 {
            showDiagnosticCard(lineDiagnostics, line: line)
            return
        }
        selectLines(from: line, to: line)
    }

    @objc func handleGutterPan(_ gesture: UIPanGestureRecognizer) {
        let line = codeTextView.lineIndex(atYOffset: gesture.location(in: codeTextView).y)
        switch gesture.state {
        case .began:
            gutterSelectionAnchorLine = line
            selectLines(from: line, to: line)
        case .changed:
            selectLines(from: gutterSelectionAnchorLine ?? line, to: line)
            autoscrollForPencil(at: gesture.location(in: view))
        default:
            gutterSelectionAnchorLine = nil
        }
    }

    func selectLines(from first: Int, to last: Int) {
        let lower = min(first, last)
        let upper = max(first, last)
        guard let start = codeTextView.range(ofLine: lower), let end = codeTextView.range(ofLine: upper, includingLineBreak: true) else {
            return
        }
        secondarySelections = []
        _ = codeTextView.becomeFirstResponder()
        codeTextView.selectedRange = NSRange(location: start.location, length: end.location + end.length - start.location)
    }

    // MARK: Hover

    @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let point = gesture.location(in: codeTextView)
        let input: EditorHoverInput = gesture.zOffset > 0 ? .pencil(zOffset: gesture.zOffset) : .pointer
        switch gesture.state {
        case .began, .changed:
            let location = codeTextView.closestLocation(to: point)
            if case .pencil = input, let location {
                // Show where the Pencil will place the caret before it touches down.
                let caret = codeTextView.caretRect(at: location)
                hoverCaretLayer.frame = CGRect(x: caret.minX - 0.5, y: caret.minY, width: 2, height: caret.height)
                hoverCaretLayer.isHidden = false
            } else {
                hoverCaretLayer.isHidden = true
            }
            delegate?.editor(self, didHoverAt: location, with: input)
            scheduleDiagnosticHover(at: location, point: point)
        default:
            hoverCaretLayer.isHidden = true
            hoverTask?.cancel()
            delegate?.editor(self, didHoverAt: nil, with: input)
        }
    }

    private func scheduleDiagnosticHover(at location: Int?, point: CGPoint) {
        hoverTask?.cancel()
        guard let location, !decorations.diagnostics.isEmpty else {
            return
        }
        let hits = decorations.diagnostics.filter { NSLocationInRange(location, $0.range) || ($0.range.length == 0 && $0.range.location == location) }
        guard !hits.isEmpty else {
            if !diagnosticCard.isHidden {
                hideDiagnosticCard()
            }
            return
        }
        let line = codeTextView.lineIndex(containing: location) ?? 0
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else {
                return
            }
            self.showDiagnosticCard(hits.sorted { $0.severity < $1.severity }, line: line)
        }
    }

    func showDiagnosticCard(_ diagnostics: [Diagnostic], line: Int) {
        diagnosticCard.show(diagnostics, theme: theme)
        guard let extent = codeTextView.verticalExtent(ofLine: line) else {
            return
        }
        let anchor = codeTextView.convert(CGRect(x: codeTextView.textOriginX, y: extent.minY, width: 1, height: extent.height), to: view)
        let maxWidth = min(520, view.bounds.width - 32)
        let size = diagnosticCard.systemLayoutSizeFitting(CGSize(width: maxWidth, height: UIView.layoutFittingCompressedSize.height),
                                                          withHorizontalFittingPriority: .defaultLow, verticalFittingPriority: .fittingSizeLevel)
        let width = min(size.width, maxWidth)
        var y = anchor.maxY + 6
        if y + size.height > view.bounds.height - 12 {
            y = anchor.minY - size.height - 6
        }
        diagnosticCard.frame = CGRect(x: min(max(anchor.minX, 12), view.bounds.width - width - 12), y: y, width: width, height: size.height)
        if diagnosticCard.isHidden {
            diagnosticCard.alpha = 0
            diagnosticCard.isHidden = false
            UIView.animate(springDuration: 0.25, bounce: 0.1) {
                self.diagnosticCard.alpha = 1
            }
        }
    }

    func hideDiagnosticCard() {
        hoverTask?.cancel()
        guard !diagnosticCard.isHidden else {
            return
        }
        diagnosticCard.isHidden = true
    }
}

// MARK: - Pointer
extension LemonTextViewController: UIPointerInteractionDelegate {
    public func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                                   defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        if interaction.view === codeTextView.gutterOverlayView {
            if let line = decorations.foldControlLine(at: request.location) {
                return UIPointerRegion(rect: decorations.foldControlLines[line] ?? defaultRegion.rect, identifier: "fold-\(line)" as NSString)
            }
            return UIPointerRegion(rect: defaultRegion.rect, identifier: "gutter" as NSString)
        }
        let lineHeight = configuration.font.uiFont.lineHeight
        let line = codeTextView.lineIndex(atYOffset: request.location.y)
        return UIPointerRegion(rect: CGRect(x: request.location.x - 1, y: request.location.y - lineHeight / 2, width: 2, height: lineHeight),
                               identifier: "text-\(line)" as NSString)
    }

    public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        if interaction.view === codeTextView.gutterOverlayView {
            if let identifier = region.identifier as? String, identifier.hasPrefix("fold-"),
               let preview = foldControlPreview(for: region) {
                return UIPointerStyle(effect: .highlight(preview))
            }
            return nil
        }
        let lineHeight = configuration.font.uiFont.lineHeight
        return UIPointerStyle(shape: .verticalBeam(length: lineHeight), constrainedAxes: .vertical)
    }

    private func foldControlPreview(for region: UIPointerRegion) -> UITargetedPreview? {
        let gutter = codeTextView.gutterOverlayView
        let snapshotView = UIView(frame: region.rect)
        snapshotView.backgroundColor = .clear
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: region.rect.size).insetBy(dx: 4, dy: 2), cornerRadius: 6)
        let target = UIPreviewTarget(container: gutter, center: CGPoint(x: region.rect.midX, y: region.rect.midY))
        return UITargetedPreview(view: snapshotView, parameters: parameters, target: target)
    }
}

// MARK: - Apple Pencil gestures
extension LemonTextViewController: UIPencilInteractionDelegate {
    public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        let location = tap.hoverPose.flatMap { codeTextView.closestLocation(to: $0.location) }
        delegate?.editor(self, didReceivePencilGesture: .doubleTap, at: location)
    }

    public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else {
            return
        }
        let location = squeeze.hoverPose.flatMap { codeTextView.closestLocation(to: $0.location) }
        delegate?.editor(self, didReceivePencilGesture: .squeeze, at: location)
    }
}
