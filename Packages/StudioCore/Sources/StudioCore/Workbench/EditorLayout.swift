import Foundation
import Observation

/// One tab: a document shown in a pane. A preview tab (opened with a single
/// tap in the explorer or search) is replaced by the next preview, until it
/// is edited or pinned.
@MainActor
@Observable
public final class EditorTab: Identifiable {
    public let id = UUID()
    public let document: EditorDocument
    public internal(set) var isPreview: Bool

    init(document: EditorDocument, isPreview: Bool) {
        self.document = document
        self.isPreview = isPreview
    }
}

/// A pane: a tab strip and the editor for its selected tab.
@MainActor
@Observable
public final class EditorPane: Identifiable {
    public let id = UUID()
    public internal(set) var tabs: [EditorTab] = []
    public internal(set) var selectedTabID: UUID?

    public var selectedTab: EditorTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    public func tab(for document: EditorDocument) -> EditorTab? {
        tabs.first { $0.document === document }
    }

    public func tab(id: UUID) -> EditorTab? {
        tabs.first { $0.id == id }
    }
}

/// The editor area: panes arranged in columns (split right) of rows (split
/// down), with resizable fractions, a focused pane and per-pane tabs.
@MainActor
@Observable
public final class EditorLayout {
    public enum SplitDirection: Sendable { case right, down }

    public struct Column: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var paneIDs: [UUID]
        /// Heights of the panes, summing to 1.
        public var fractions: [Double]
    }

    public static let maximumColumns = 3
    public static let maximumRows = 3

    public private(set) var columns: [Column]
    /// Widths of the columns, summing to 1.
    public private(set) var columnFractions: [Double] = [1]
    public private(set) var panes: [UUID: EditorPane]
    public var focusedPaneID: UUID

    public init() {
        let pane = EditorPane()
        panes = [pane.id: pane]
        columns = [Column(id: UUID(), paneIDs: [pane.id], fractions: [1])]
        focusedPaneID = pane.id
    }

    // MARK: Queries

    public var focusedPane: EditorPane {
        panes[focusedPaneID] ?? orderedPanes[0]
    }

    /// Panes in reading order: columns left to right, rows top to bottom.
    public var orderedPanes: [EditorPane] {
        columns.flatMap { $0.paneIDs.compactMap { panes[$0] } }
    }

    public var paneCount: Int { panes.count }

    public var activeDocument: EditorDocument? {
        focusedPane.selectedTab?.document
    }

    /// Every document shown in some tab.
    public var openDocuments: [EditorDocument] {
        var seen = Set<ObjectIdentifier>()
        return orderedPanes.flatMap(\.tabs).map(\.document).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    public func isOpen(_ document: EditorDocument) -> Bool {
        panes.values.contains { $0.tab(for: document) != nil }
    }

    public func pane(containing tabID: UUID) -> EditorPane? {
        panes.values.first { $0.tab(id: tabID) != nil }
    }

    func location(of paneID: UUID) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.paneIDs.firstIndex(of: paneID) { return (c, r) }
        }
        return nil
    }

    // MARK: Opening and selecting

    /// Shows `document` in a pane (the focused one by default). An existing
    /// tab for it is selected; a preview replaces the pane's previous
    /// preview tab.
    @discardableResult
    public func open(_ document: EditorDocument, in paneID: UUID? = nil, preview: Bool = false, focus: Bool = true) -> EditorTab {
        let pane = paneID.flatMap { panes[$0] } ?? focusedPane
        if focus { focusedPaneID = pane.id }
        if let existing = pane.tab(for: document) {
            if !preview { existing.isPreview = false }
            pane.selectedTabID = existing.id
            return existing
        }
        let tab = EditorTab(document: document, isPreview: preview)
        if preview, let index = pane.tabs.firstIndex(where: { $0.isPreview && !$0.document.isDirty }) {
            pane.tabs[index] = tab
        } else if let selected = pane.selectedTab, let index = pane.tabs.firstIndex(where: { $0 === selected }) {
            pane.tabs.insert(tab, at: index + 1)
        } else {
            pane.tabs.append(tab)
        }
        pane.selectedTabID = tab.id
        return tab
    }

    public func select(_ tabID: UUID, in paneID: UUID) {
        guard let pane = panes[paneID], pane.tab(id: tabID) != nil else { return }
        pane.selectedTabID = tabID
        focusedPaneID = paneID
    }

    /// Keeps a preview tab open (double tap, or the first edit).
    public func pin(_ tabID: UUID) {
        pane(containing: tabID)?.tab(id: tabID)?.isPreview = false
    }

    /// Selects the next (or previous) tab in the focused pane, wrapping.
    public func cycleTabs(forward: Bool) {
        let pane = focusedPane
        guard pane.tabs.count > 1, let current = pane.selectedTab,
              let index = pane.tabs.firstIndex(where: { $0 === current }) else { return }
        let next = (index + (forward ? 1 : -1) + pane.tabs.count) % pane.tabs.count
        pane.selectedTabID = pane.tabs[next].id
    }

    /// Focuses the pane at a 1-based position in reading order (⌘1–⌘4).
    public func focusPane(number: Int) {
        let ordered = orderedPanes
        guard number >= 1, number <= ordered.count else { return }
        focusedPaneID = ordered[number - 1].id
    }

    // MARK: Closing

    /// Closes a tab. Returns the document if no other tab shows it, so the
    /// caller can release it. A pane left empty is removed unless it is the
    /// only one.
    @discardableResult
    public func close(_ tabID: UUID) -> EditorDocument? {
        guard let pane = pane(containing: tabID), let index = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let tab = pane.tabs.remove(at: index)
        if pane.selectedTabID == tabID {
            pane.selectedTabID = pane.tabs.isEmpty ? nil : pane.tabs[min(index, pane.tabs.count - 1)].id
        }
        if pane.tabs.isEmpty, panes.count > 1 {
            removePane(pane.id)
        }
        return isOpen(tab.document) ? nil : tab.document
    }

    /// Closes every tab of `document` (e.g. after the file was deleted).
    public func close(document: EditorDocument) {
        for pane in orderedPanes {
            if let tab = pane.tab(for: document) { close(tab.id) }
        }
    }

    /// Closes the other tabs in the tab's pane; returns released documents.
    @discardableResult
    public func closeOthers(_ tabID: UUID) -> [EditorDocument] {
        guard let pane = pane(containing: tabID) else { return [] }
        return pane.tabs.filter { $0.id != tabID }.compactMap { close($0.id) }
    }

    /// Closes all tabs in a pane; returns released documents.
    @discardableResult
    public func closeAll(in paneID: UUID) -> [EditorDocument] {
        guard let pane = panes[paneID] else { return [] }
        return pane.tabs.compactMap { close($0.id) }
    }

    // MARK: Moving

    /// Moves a tab to another pane (or another position in the same pane).
    public func move(_ tabID: UUID, to paneID: UUID, at index: Int? = nil) {
        guard let source = pane(containing: tabID), let target = panes[paneID],
              let from = source.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = source.tabs[from]
        if source === target {
            source.tabs.remove(at: from)
            // `index` counts positions before the removal.
            var to = index ?? source.tabs.count
            if to > from { to -= 1 }
            source.tabs.insert(tab, at: min(max(0, to), source.tabs.count))
            source.selectedTabID = tab.id
            return
        }
        if let existing = target.tab(for: tab.document) {
            // The target already shows this document: select it, drop the moved tab.
            target.selectedTabID = existing.id
            close(tabID)
        } else {
            source.tabs.remove(at: from)
            if source.selectedTabID == tabID { source.selectedTabID = source.tabs.isEmpty ? nil : source.tabs[min(from, source.tabs.count - 1)].id }
            target.tabs.insert(tab, at: min(index ?? target.tabs.count, target.tabs.count))
            target.selectedTabID = tab.id
            if source.tabs.isEmpty, panes.count > 1 { removePane(source.id) }
        }
        focusedPaneID = target.id
    }

    // MARK: Splitting

    /// Splits `paneID` (the focused pane by default): a new pane to the
    /// right or below showing the same document. Returns nil at the limit.
    @discardableResult
    public func split(_ paneID: UUID? = nil, direction: SplitDirection) -> EditorPane? {
        let sourceID = paneID ?? focusedPaneID
        guard let source = panes[sourceID], let (c, r) = location(of: sourceID) else { return nil }
        let pane = EditorPane()
        switch direction {
        case .right:
            guard columns.count < Self.maximumColumns else { return nil }
            panes[pane.id] = pane
            columns.insert(Column(id: UUID(), paneIDs: [pane.id], fractions: [1]), at: c + 1)
            columnFractions = Self.splitFraction(columnFractions, at: c)
        case .down:
            guard columns[c].paneIDs.count < Self.maximumRows else { return nil }
            panes[pane.id] = pane
            columns[c].paneIDs.insert(pane.id, at: r + 1)
            columns[c].fractions = Self.splitFraction(columns[c].fractions, at: r)
        }
        if let document = source.selectedTab?.document {
            open(document, in: pane.id)
        }
        focusedPaneID = pane.id
        return pane
    }

    /// Removes a pane and its tabs (never the last pane).
    public func removePane(_ paneID: UUID) {
        guard panes.count > 1, let (c, r) = location(of: paneID) else { return }
        panes[paneID] = nil
        columns[c].paneIDs.remove(at: r)
        columns[c].fractions = Self.removeFraction(columns[c].fractions, at: r)
        if columns[c].paneIDs.isEmpty {
            columns.remove(at: c)
            columnFractions = Self.removeFraction(columnFractions, at: c)
        }
        if focusedPaneID == paneID {
            let ordered = orderedPanes
            focusedPaneID = ordered[min(max(0, c), ordered.count - 1)].id
        }
    }

    /// Joins every pane into one, keeping all tabs (deduplicated).
    public func joinAll() {
        let ordered = orderedPanes
        guard ordered.count > 1 else { return }
        let keep = ordered[0]
        for pane in ordered.dropFirst() {
            for tab in pane.tabs where keep.tab(for: tab.document) == nil {
                keep.tabs.append(tab)
            }
            panes[pane.id] = nil
        }
        columns = [Column(id: columns[0].id, paneIDs: [keep.id], fractions: [1])]
        columnFractions = [1]
        focusedPaneID = keep.id
    }

    // MARK: Resizing

    /// Sets the boundary between column `index` and `index + 1` to
    /// `position` (0...1 of the whole width), keeping a minimum size.
    public func resizeColumns(boundary index: Int, to position: Double, minimum: Double = 0.12) {
        columnFractions = Self.moveBoundary(columnFractions, boundary: index, to: position, minimum: minimum)
    }

    public func resizeRows(column columnIndex: Int, boundary index: Int, to position: Double, minimum: Double = 0.12) {
        guard columns.indices.contains(columnIndex) else { return }
        columns[columnIndex].fractions = Self.moveBoundary(columns[columnIndex].fractions, boundary: index, to: position, minimum: minimum)
    }

    /// Equal sizes everywhere.
    public func equalize() {
        columnFractions = Array(repeating: 1 / Double(columns.count), count: columns.count)
        for c in columns.indices {
            columns[c].fractions = Array(repeating: 1 / Double(columns[c].paneIDs.count), count: columns[c].paneIDs.count)
        }
    }

    static func splitFraction(_ fractions: [Double], at index: Int) -> [Double] {
        var result = fractions
        let half = result[index] / 2
        result[index] = half
        result.insert(half, at: index + 1)
        return result
    }

    static func removeFraction(_ fractions: [Double], at index: Int) -> [Double] {
        var result = fractions
        let freed = result.remove(at: index)
        guard !result.isEmpty else { return [] }
        let neighbor = min(index, result.count - 1)
        result[neighbor] += freed
        return result
    }

    static func moveBoundary(_ fractions: [Double], boundary index: Int, to position: Double, minimum: Double) -> [Double] {
        guard index >= 0, index + 1 < fractions.count else { return fractions }
        let before = fractions[..<index].reduce(0, +)
        let pair = fractions[index] + fractions[index + 1]
        let lower = before + min(minimum, pair / 2)
        let upper = before + pair - min(minimum, pair / 2)
        let clamped = min(max(position, lower), upper)
        var result = fractions
        result[index] = clamped - before
        result[index + 1] = pair - result[index]
        return result
    }

    // MARK: Snapshot (state restoration)

    public struct Snapshot: Codable, Equatable, Sendable {
        public struct Pane: Codable, Equatable, Sendable {
            /// Workspace-relative paths of the tabs.
            public var tabs: [String]
            public var selected: Int?
        }

        public var columns: [[Pane]]
        public var columnFractions: [Double]
        public var rowFractions: [[Double]]
        public var focused: Int
    }

    public func snapshot(relativePath: (URL) -> String?) -> Snapshot {
        let ordered = orderedPanes
        return Snapshot(
            columns: columns.map { column in
                column.paneIDs.compactMap { panes[$0] }.map { pane in
                    let paths = pane.tabs.compactMap { relativePath($0.document.url) }
                    let selected = pane.selectedTab.flatMap { tab in pane.tabs.firstIndex { $0 === tab } }
                    return Snapshot.Pane(tabs: paths, selected: selected)
                }
            },
            columnFractions: columnFractions,
            rowFractions: columns.map(\.fractions),
            focused: ordered.firstIndex { $0.id == focusedPaneID } ?? 0)
    }

    /// Rebuilds the layout; `document` resolves a relative path (nil drops it).
    public func restore(_ snapshot: Snapshot, document: (String) -> EditorDocument?) {
        let shapeValid = !snapshot.columns.isEmpty && snapshot.columns.allSatisfy { !$0.isEmpty }
            && snapshot.columns.count <= Self.maximumColumns && snapshot.columns.allSatisfy { $0.count <= Self.maximumRows }
        guard shapeValid else { return }
        var newPanes: [UUID: EditorPane] = [:]
        var newColumns: [Column] = []
        for (c, column) in snapshot.columns.enumerated() {
            var ids: [UUID] = []
            for saved in column {
                let pane = EditorPane()
                for path in saved.tabs {
                    if let doc = document(path), pane.tab(for: doc) == nil {
                        pane.tabs.append(EditorTab(document: doc, isPreview: false))
                    }
                }
                if let selected = saved.selected, pane.tabs.indices.contains(selected) {
                    pane.selectedTabID = pane.tabs[selected].id
                } else {
                    pane.selectedTabID = pane.tabs.first?.id
                }
                newPanes[pane.id] = pane
                ids.append(pane.id)
            }
            let rows = snapshot.rowFractions.indices.contains(c) && snapshot.rowFractions[c].count == ids.count
                ? snapshot.rowFractions[c] : Array(repeating: 1 / Double(ids.count), count: ids.count)
            newColumns.append(Column(id: UUID(), paneIDs: ids, fractions: rows))
        }
        panes = newPanes
        columns = newColumns
        columnFractions = snapshot.columnFractions.count == newColumns.count
            ? snapshot.columnFractions : Array(repeating: 1 / Double(newColumns.count), count: newColumns.count)
        let ordered = orderedPanes
        focusedPaneID = ordered[min(max(0, snapshot.focused), ordered.count - 1)].id
        // Drop panes that came back empty, except the last one.
        for pane in ordered where pane.tabs.isEmpty && panes.count > 1 {
            removePane(pane.id)
        }
    }
}
