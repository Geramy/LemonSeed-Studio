import XCTest
@testable import StudioCore

@MainActor
final class EditorLayoutTests: XCTestCase {
    private func doc(_ name: String) -> EditorDocument {
        EditorDocument(url: URL(fileURLWithPath: "/w/\(name)"))
    }

    func testOpenSelectsExistingTab() {
        let layout = EditorLayout()
        let a = doc("a.c"), b = doc("b.c")
        let tabA = layout.open(a)
        layout.open(b)
        XCTAssertEqual(layout.focusedPane.tabs.count, 2)
        XCTAssertTrue(layout.open(a) === tabA)
        XCTAssertEqual(layout.focusedPane.tabs.count, 2)
        XCTAssertTrue(layout.activeDocument === a)
    }

    func testNewTabsOpenAfterSelected() {
        let layout = EditorLayout()
        let a = doc("a"), b = doc("b"), c = doc("c")
        layout.open(a)
        layout.open(b)
        layout.open(a)
        layout.open(c)
        XCTAssertEqual(layout.focusedPane.tabs.map(\.document.name), ["a", "c", "b"])
    }

    func testPreviewTabsAreReplaced() {
        let layout = EditorLayout()
        let a = doc("a"), b = doc("b"), c = doc("c")
        layout.open(a, preview: true)
        layout.open(b, preview: true)
        XCTAssertEqual(layout.focusedPane.tabs.map(\.document.name), ["b"])
        // Opening the preview document for real pins it.
        let pinned = layout.open(b)
        XCTAssertFalse(pinned.isPreview)
        layout.open(c, preview: true)
        XCTAssertEqual(layout.focusedPane.tabs.map(\.document.name), ["b", "c"])
    }

    func testCloseReleasesDocumentOnlyWhenUnused() {
        let layout = EditorLayout()
        let a = doc("a")
        let first = layout.open(a)
        let second = layout.split(direction: .right)!
        XCTAssertTrue(second.selectedTab?.document === a, "split shows the same document")
        XCTAssertNil(layout.close(first.id), "still open in the other pane")
        XCTAssertEqual(layout.paneCount, 1, "the emptied pane is removed")
        XCTAssertTrue(layout.close(second.selectedTab!.id) === a)
        XCTAssertEqual(layout.paneCount, 1, "the last pane stays")
        XCTAssertNil(layout.activeDocument)
    }

    func testSplitLimitsAndFractions() {
        let layout = EditorLayout()
        layout.open(doc("a"))
        XCTAssertNotNil(layout.split(direction: .right))
        XCTAssertNotNil(layout.split(direction: .right))
        XCTAssertNil(layout.split(direction: .right), "three columns at most")
        XCTAssertEqual(layout.columns.count, 3)
        XCTAssertEqual(layout.columnFractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertNotNil(layout.split(direction: .down))
        XCTAssertNotNil(layout.split(direction: .down))
        XCTAssertNil(layout.split(direction: .down))
        XCTAssertEqual(layout.columns.last?.paneIDs.count, 3)
        XCTAssertEqual(layout.columns.last!.fractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(layout.paneCount, 5)
        layout.joinAll()
        XCTAssertEqual(layout.paneCount, 1)
        XCTAssertEqual(layout.focusedPane.tabs.count, 1, "duplicates collapse when joining")
    }

    func testSplitPlacement() {
        let layout = EditorLayout()
        layout.open(doc("a"))
        let first = layout.focusedPaneID
        let right = layout.split(direction: .right)!
        layout.focusedPaneID = first
        let below = layout.split(direction: .down)!
        XCTAssertEqual(layout.orderedPanes.map(\.id), [first, below.id, right.id])
        layout.focusPane(number: 3)
        XCTAssertEqual(layout.focusedPaneID, right.id)
        layout.focusPane(number: 9)
        XCTAssertEqual(layout.focusedPaneID, right.id, "out of range is ignored")
    }

    func testMoveTabs() {
        let layout = EditorLayout()
        let a = doc("a"), b = doc("b"), c = doc("c")
        layout.open(a)
        layout.open(b)
        layout.open(c)
        let pane = layout.focusedPane
        // Reorder within the pane: move "a" to the end.
        layout.move(pane.tabs[0].id, to: pane.id, at: 3)
        XCTAssertEqual(pane.tabs.map(\.document.name), ["b", "c", "a"])
        layout.move(pane.tabs[2].id, to: pane.id, at: 0)
        XCTAssertEqual(pane.tabs.map(\.document.name), ["a", "b", "c"])

        // Move to another pane.
        layout.select(pane.tabs[2].id, in: pane.id)
        let other = layout.split(direction: .right)!
        XCTAssertEqual(other.tabs.map(\.document.name), ["c"])
        layout.move(pane.tabs[0].id, to: other.id)
        XCTAssertEqual(pane.tabs.map(\.document.name), ["b", "c"])
        XCTAssertEqual(other.tabs.map(\.document.name), ["c", "a"])
        XCTAssertEqual(layout.focusedPaneID, other.id)

        // Moving onto a pane that already shows the document just selects it.
        layout.move(pane.tabs[1].id, to: other.id)
        XCTAssertEqual(pane.tabs.map(\.document.name), ["b"])
        XCTAssertEqual(other.selectedTab?.document.name, "c")

        // Emptying a pane by moving removes it.
        layout.move(pane.tabs[0].id, to: other.id)
        XCTAssertEqual(layout.paneCount, 1)
    }

    func testCloseOthersAndCycle() {
        let layout = EditorLayout()
        for name in ["a", "b", "c", "d"] { layout.open(doc(name)) }
        layout.cycleTabs(forward: true)
        XCTAssertEqual(layout.activeDocument?.name, "a", "wraps around")
        layout.cycleTabs(forward: false)
        XCTAssertEqual(layout.activeDocument?.name, "d")
        let released = layout.closeOthers(layout.focusedPane.selectedTab!.id)
        XCTAssertEqual(released.map(\.name).sorted(), ["a", "b", "c"])
        XCTAssertEqual(layout.focusedPane.tabs.map(\.document.name), ["d"])
    }

    func testClosingSelectedTabSelectsNeighbor() {
        let layout = EditorLayout()
        for name in ["a", "b", "c"] { layout.open(doc(name)) }
        let pane = layout.focusedPane
        layout.select(pane.tabs[1].id, in: pane.id)
        layout.close(pane.tabs[1].id)
        XCTAssertEqual(pane.selectedTab?.document.name, "c")
    }

    func testResizeClampsToMinimum() {
        let layout = EditorLayout()
        layout.open(doc("a"))
        layout.split(direction: .right)
        layout.resizeColumns(boundary: 0, to: 0.7)
        XCTAssertEqual(layout.columnFractions[0], 0.7, accuracy: 1e-9)
        layout.resizeColumns(boundary: 0, to: 0.99)
        XCTAssertEqual(layout.columnFractions[1], 0.12, accuracy: 1e-9)
        layout.equalize()
        XCTAssertEqual(layout.columnFractions, [0.5, 0.5])
    }

    func testSnapshotRoundTrip() {
        let layout = EditorLayout()
        let docs = Dictionary(uniqueKeysWithValues: ["a", "b", "c"].map { ($0, doc($0)) })
        layout.open(docs["a"]!)
        layout.open(docs["b"]!)
        layout.split(direction: .right)
        layout.open(docs["c"]!)
        layout.resizeColumns(boundary: 0, to: 0.6)
        let snapshot = layout.snapshot { $0.lastPathComponent }
        XCTAssertEqual(snapshot.columns.map { $0.map(\.tabs) }, [[["a", "b"]], [["b", "c"]]])

        let restored = EditorLayout()
        restored.restore(snapshot) { docs[$0] }
        XCTAssertEqual(restored.columns.count, 2)
        XCTAssertEqual(restored.orderedPanes.map { $0.tabs.map(\.document.name) }, [["a", "b"], ["b", "c"]])
        XCTAssertEqual(restored.columnFractions[0], 0.6, accuracy: 1e-9)
        XCTAssertEqual(restored.activeDocument?.name, "c")

        // Missing files drop out; empty panes collapse.
        let partial = EditorLayout()
        partial.restore(snapshot) { $0 == "a" ? docs["a"] : nil }
        XCTAssertEqual(partial.paneCount, 1)
        XCTAssertEqual(partial.focusedPane.tabs.map(\.document.name), ["a"])
    }
}

@MainActor
final class CommandRegistryTests: XCTestCase {
    final class Context: WorkspaceContext {
        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        var rootURL: URL { workspace.rootURL }
        var displayName: String { "Test" }
        var activeDocument: EditorDocument? { nil }
        var log: [String] = []
        func open(_ url: URL, at position: TextPosition?) {}
        func reveal(_ url: URL) {}
        func log(_ text: String, channel: String) { log.append(text) }
    }

    func testRegisterReplaceRunAndRecents() {
        let registry = CommandRegistry()
        let context = Context()
        registry.register([
            StudioCommand(id: "view.toggleSidebar", title: "Toggle Sidebar", category: "View",
                          shortcut: KeyShortcut("b")) { $0.log("sidebar", channel: "t") },
            StudioCommand(id: "file.save", title: "Save", category: "File", shortcut: KeyShortcut("s")) { $0.log("save", channel: "t") },
            StudioCommand(id: "git.commit", title: "Commit", category: "Git", isEnabled: { _ in false }) { _ in },
        ])
        registry.register(StudioCommand(id: "file.save", title: "Save File", category: "File") { $0.log("save2", channel: "t") })
        XCTAssertEqual(registry.commands.count, 3)
        XCTAssertEqual(registry.command(id: "file.save")?.title, "Save File")

        XCTAssertTrue(registry.run(id: "file.save", in: context))
        XCTAssertTrue(registry.run(id: "view.toggleSidebar", in: context))
        XCTAssertFalse(registry.run(id: "git.commit", in: context), "disabled commands do not run")
        XCTAssertFalse(registry.run(id: "missing", in: context))
        XCTAssertEqual(context.log, ["save2", "sidebar"])
        XCTAssertEqual(registry.recentIDs, ["view.toggleSidebar", "file.save"])
        XCTAssertEqual(registry.search("").first?.command.id, "view.toggleSidebar")
    }

    func testSearchRanksByFuzzyScoreAndRecency() {
        let registry = CommandRegistry()
        registry.register([
            StudioCommand(id: "view.split", title: "Split Editor Right", category: "View") { _ in },
            StudioCommand(id: "view.splitDown", title: "Split Editor Down", category: "View") { _ in },
            StudioCommand(id: "view.terminal", title: "Toggle Terminal", category: "View") { _ in },
        ])
        XCTAssertEqual(registry.search("split").map(\.command.id).sorted(), ["view.split", "view.splitDown"])
        XCTAssertEqual(registry.search("tterm").first?.command.id, "view.terminal")
        XCTAssertTrue(registry.search("zzz").isEmpty)
        _ = registry.run(id: "view.splitDown", in: Context())
        XCTAssertEqual(registry.search("split").first?.command.id, "view.splitDown", "recent commands rank higher")
    }

    func testShortcutsAndConflicts() {
        XCTAssertEqual(KeyShortcut("p", [.command, .shift]).description, "⇧⌘P")
        XCTAssertEqual(KeyShortcut("`", .control).description, "⌃`")
        XCTAssertEqual(KeyShortcut("f12", []).description, "F12")
        let registry = CommandRegistry()
        registry.register([
            StudioCommand(id: "a", title: "A", category: "X", shortcut: KeyShortcut("k")) { _ in },
            StudioCommand(id: "b", title: "B", category: "X", shortcut: KeyShortcut("k")) { _ in },
        ])
        XCTAssertEqual(registry.conflicts[KeyShortcut("k")], ["a", "b"])
        XCTAssertEqual(registry.command(for: KeyShortcut("k"))?.id, "a")
    }
}
