import LemonTextCore
import UIKit

// MARK: - Minimap
extension LemonTextViewController: MinimapDataSource {
    var minimapLineCount: Int {
        codeTextView.lineCount
    }

    func minimapViewport() -> (scrollFraction: CGFloat, visibleFraction: CGFloat, firstVisibleLine: Int, visibleLineCount: Int) {
        let maxOffset = max(codeTextView.contentSize.height - codeTextView.bounds.height, 1)
        let fraction = min(max(codeTextView.contentOffset.y / maxOffset, 0), 1)
        let first = codeTextView.lineIndex(atYOffset: codeTextView.contentOffset.y)
        let last = codeTextView.lineIndex(atYOffset: codeTextView.contentOffset.y + codeTextView.bounds.height)
        let visibleFraction = min(codeTextView.bounds.height / max(codeTextView.contentSize.height, 1), 1)
        return (fraction, visibleFraction, first, max(last - first + 1, 1))
    }

    func minimapScroll(toLine line: Int, animated: Bool) {
        guard let extent = codeTextView.verticalExtent(ofLine: min(max(line, 0), max(codeTextView.lineCount - 1, 0))) else {
            return
        }
        let maxOffset = max(codeTextView.contentSize.height - codeTextView.bounds.height, 0)
        let y = min(max(extent.minY - codeTextView.textContainerInset.top, 0), maxOffset)
        codeTextView.setContentOffset(CGPoint(x: codeTextView.contentOffset.x, y: y), animated: animated)
    }

    func minimapScroll(toFraction fraction: CGFloat) {
        let maxOffset = max(codeTextView.contentSize.height - codeTextView.bounds.height, 0)
        codeTextView.contentOffset = CGPoint(x: codeTextView.contentOffset.x, y: maxOffset * fraction)
    }

    func minimapRuns(for lines: Range<Int>) -> [[MinimapRun]] {
        var result: [[MinimapRun]] = []
        result.reserveCapacity(lines.count)
        guard !lines.isEmpty else {
            return result
        }
        let chunkSize = Self.minimapChunkSize
        let firstChunk = lines.lowerBound / chunkSize
        let lastChunk = (lines.upperBound - 1) / chunkSize
        for chunk in firstChunk ... lastChunk {
            let chunkRuns: [[MinimapRun]]
            if let cached = minimapChunks[chunk] {
                chunkRuns = cached
            } else {
                chunkRuns = computeMinimapRuns(chunk: chunk)
                minimapChunks[chunk] = chunkRuns
            }
            let chunkStart = chunk * chunkSize
            let lower = max(lines.lowerBound, chunkStart) - chunkStart
            let upper = min(lines.upperBound, chunkStart + chunkRuns.count) - chunkStart
            if lower < upper {
                result.append(contentsOf: chunkRuns[lower ..< upper])
            }
        }
        return result
    }

    private func computeMinimapRuns(chunk: Int) -> [[MinimapRun]] {
        let chunkSize = Self.minimapChunkSize
        let firstLine = chunk * chunkSize
        let lastLine = min(firstLine + chunkSize, codeTextView.lineCount) - 1
        guard firstLine <= lastLine, let startRange = codeTextView.range(ofLine: firstLine),
              let endRange = codeTextView.range(ofLine: lastLine, includingLineBreak: true) else {
            return []
        }
        let chunkRange = NSRange(location: startRange.location, length: endRange.location + endRange.length - startRange.location)
        guard let chunkText = codeTextView.text(in: chunkRange) as NSString? else {
            return []
        }
        let captures = isHighlighting ? [] : codeTextView.syntaxHighlightCaptures(in: chunkRange)
        let maxColumns = 120
        let tabWidth = configuration.tabWidth
        let background = theme.minimapBackground
        let defaultColor = theme.foreground.withAlpha(0.42).composited(over: background)
        var colorCache: [String: ThemeColor] = [:]
        func color(forCapture name: String) -> ThemeColor? {
            if let cached = colorCache[name] {
                return cached
            }
            let resolved = theme.style(forCapture: name)?.color.withAlpha(0.8).composited(over: background)
            colorCache[name] = resolved
            return resolved
        }
        var runs: [[MinimapRun]] = []
        runs.reserveCapacity(lastLine - firstLine + 1)
        var captureIndex = 0
        let sortedCaptures = captures.sorted { $0.range.location < $1.range.location }
        var buffer = [unichar](repeating: 0, count: 512)
        for line in firstLine ... lastLine {
            guard let lineRange = codeTextView.range(ofLine: line) else {
                runs.append([])
                continue
            }
            let localStart = lineRange.location - chunkRange.location
            let length = min(lineRange.length, 512)
            chunkText.getCharacters(&buffer, range: NSRange(location: localStart, length: length))
            // Column of each character with tabs expanded; whitespace gets no color.
            var colors = [ThemeColor?](repeating: nil, count: maxColumns)
            var columnOfOffset = [Int](repeating: maxColumns, count: length + 1)
            var column = 0
            for offset in 0 ..< length {
                columnOfOffset[offset] = column
                let character = buffer[offset]
                if character == 0x09 {
                    column += tabWidth - column % max(tabWidth, 1)
                } else {
                    if character != 0x20 && column < maxColumns {
                        colors[column] = defaultColor
                    }
                    column += 1
                }
                if column >= maxColumns {
                    break
                }
            }
            columnOfOffset[length] = min(column, maxColumns)
            // Apply captures overlapping this line, later captures winning like the editor's highlighter.
            while captureIndex < sortedCaptures.count,
                  sortedCaptures[captureIndex].range.location + sortedCaptures[captureIndex].range.length <= lineRange.location {
                captureIndex += 1
            }
            var index = captureIndex
            while index < sortedCaptures.count && sortedCaptures[index].range.location < lineRange.location + lineRange.length {
                let capture = sortedCaptures[index]
                index += 1
                guard let captureColor = color(forCapture: capture.name) else {
                    continue
                }
                let start = max(capture.range.location - lineRange.location, 0)
                let end = min(capture.range.location + capture.range.length - lineRange.location, length)
                guard start < end else {
                    continue
                }
                for offset in start ..< end {
                    let column = columnOfOffset[offset]
                    if column < maxColumns, colors[column] != nil {
                        colors[column] = captureColor
                    }
                }
            }
            var lineRuns: [MinimapRun] = []
            var runStart = 0
            while runStart < maxColumns {
                guard let runColor = colors[runStart] else {
                    runStart += 1
                    continue
                }
                var runEnd = runStart + 1
                while runEnd < maxColumns && colors[runEnd] == runColor {
                    runEnd += 1
                }
                lineRuns.append(MinimapRun(column: runStart, length: runEnd - runStart, color: runColor))
                runStart = runEnd
            }
            runs.append(lineRuns)
        }
        return runs
    }

    func scheduleMinimapRefresh() {
        minimapRefreshTask?.cancel()
        minimapRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else {
                return
            }
            self.minimapView.invalidate()
        }
    }

    func updateMinimapMarkers() {
        var markers: [(line: Int, color: ThemeColor)] = []
        let lineStartsNeeded = !decorations.diagnostics.isEmpty || (isFindVisible && !findMatches.isEmpty)
        if lineStartsNeeded {
            for diagnostic in decorations.diagnostics.prefix(2_000) where diagnostic.severity <= .warning {
                if let line = codeTextView.lineIndex(containing: min(diagnostic.range.location, max(codeTextView.textLength - 1, 0))) {
                    markers.append((line, diagnostic.severity == .error ? theme.error : theme.warning))
                }
            }
            if isFindVisible {
                // Sample matches so a huge result set does not stall the ruler.
                let stride = max(findMatches.count / 2_000, 1)
                for index in Swift.stride(from: 0, to: findMatches.count, by: stride) {
                    if let line = codeTextView.lineIndex(containing: findMatches[index].range.location) {
                        markers.append((line, theme.findMatch.withAlpha(0.9)))
                    }
                }
            }
        }
        for marker in decorations.gutterMarkers {
            markers.append((marker.line, marker.color))
        }
        minimapView.markers = markers
    }
}
