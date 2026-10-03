import SwiftUI
import StudioCore
import StudioDesign

/// The editor area: columns of panes with draggable dividers.
struct EditorArea: View {
    @Environment(\.theme) private var theme
    let controller: WorkspaceController

    var body: some View {
        let layout = controller.layout
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(layout.columns.enumerated()), id: \.element.id) { index, column in
                    ColumnView(controller: controller, column: column, columnIndex: index)
                        .frame(width: max(0, geometry.size.width * layout.columnFractions[safe: index, default: 1]
                                          - (index < layout.columns.count - 1 ? 1 : 0)))
                    if index < layout.columns.count - 1 {
                        PaneDivider(axis: .vertical) { location in
                            layout.resizeColumns(boundary: index, to: location.x / max(1, geometry.size.width))
                        }
                    }
                }
            }
            .coordinateSpace(name: "editorArea")
        }
        .background(theme.palette.editor.color)
        .animation(Motion.layout, value: layout.columns.map(\.paneIDs))
    }
}

private struct ColumnView: View {
    let controller: WorkspaceController
    let column: EditorLayout.Column
    let columnIndex: Int

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ForEach(Array(column.paneIDs.enumerated()), id: \.element) { row, paneID in
                    if let pane = controller.layout.panes[paneID] {
                        PaneView(controller: controller, pane: pane)
                            .frame(height: max(0, geometry.size.height * column.fractions[safe: row, default: 1]
                                               - (row < column.paneIDs.count - 1 ? 1 : 0)))
                    }
                    if row < column.paneIDs.count - 1 {
                        PaneDivider(axis: .horizontal) { location in
                            let frame = geometry.frame(in: .named("editorArea"))
                            controller.layout.resizeRows(column: columnIndex, boundary: row,
                                                         to: (location.y - frame.minY) / max(1, frame.height))
                        }
                    }
                }
            }
        }
    }
}

/// The divider between panes; drag it to resize.
private struct PaneDivider: View {
    @Environment(\.theme) private var theme
    let axis: Axis
    let onDrag: (CGPoint) -> Void
    @State private var active = false

    var body: some View {
        Rectangle()
            .fill(active ? theme.palette.accent.opacity(0.7).color : theme.palette.separator.color)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .overlay {
                Color.clear
                    .frame(width: axis == .vertical ? 14 : nil, height: axis == .horizontal ? 14 : nil)
                    .contentShape(.rect)
                    .onHover { inside in withAnimation(Motion.feedback) { active = inside } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("editorArea"))
                        .onChanged { value in
                            active = true
                            onDrag(value.location)
                        }
                        .onEnded { _ in withAnimation(Motion.feedback) { active = false } })
            }
            .zIndex(1)
            .accessibilityIdentifier("editor.divider")
    }
}

/// One pane: tab strip, breadcrumb, and the editor for the selected tab.
struct PaneView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.editorSettings) private var editorSettings
    let controller: WorkspaceController
    let pane: EditorPane
    @State private var dropTargeted = false

    private var isFocused: Bool { controller.layout.focusedPaneID == pane.id }

    /// No hardware keyboard, the on-screen one is down, and this pane shows text.
    private var showsKeyboardButton: Bool {
        !app.keyboard.hasHardwareKeyboard && !app.keyboard.isSoftwareKeyboardVisible && isFocused
            && pane.selectedTab?.document.loadState == .loaded
    }
    private var index: Int { controller.layout.orderedPanes.firstIndex { $0.id == pane.id } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(controller: controller, pane: pane, isFocused: isFocused)
            if let tab = pane.selectedTab {
                Breadcrumb(controller: controller, document: tab.document)
                if tab.document.hasExternalChanges {
                    ExternalChangeBanner(document: tab.document)
                }
                let document = tab.document
                app.services.editor(for: document)
                    .makeEditor(for: document, context: EditorContext(workspace: controller, settings: editorSettings,
                                                                      isFocused: isFocused))
                    .id(document.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: document.revision) { _, _ in
                        if tab.isPreview, document.isDirty { controller.layout.pin(tab.id) }
                    }
            } else {
                EmptyPaneView(controller: controller)
            }
        }
        .background(theme.palette.editor.color)
        .overlay(alignment: .bottomTrailing) {
            if showsKeyboardButton, let document = pane.selectedTab?.document {
                EditorKeyboardButton(document: document)
            }
        }
        .animation(Motion.present, value: showsKeyboardButton)
        .overlay {
            if dropTargeted {
                Rectangle().fill(theme.palette.accentWash.color).allowsHitTesting(false)
            }
        }
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded {
            if !isFocused { controller.layout.focusedPaneID = pane.id }
        })
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where !FileOperations.isDirectory(url) {
                controller.open(url, preview: false, in: pane.id)
            }
            return true
        } isTargeted: { dropTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.pane.\(index)")
        .accessibilityValue(isFocused ? "focused" : "")
    }
}

private struct ExternalChangeBanner: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let document: EditorDocument

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: StudioSymbol.warning)
                .foregroundStyle(theme.palette.warning.color)
            Text("\(document.name) changed on disk while you were editing it.")
                .font(.studio(type.caption))
                .foregroundStyle(theme.palette.textPrimary.color)
            Spacer()
            Button("Reload") { Task { await document.revert() } }
                .buttonStyle(.studioSecondary)
            Button("Keep Mine") { Task { try? await document.save() } }
                .buttonStyle(.studioPrimary)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
        .background(theme.palette.warning.opacity(0.12).color)
    }
}

/// Shown in a pane with no tabs.
struct EmptyPaneView: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let controller: WorkspaceController

    var body: some View {
        VStack(spacing: Space.xl) {
            LemonMark(size: 88)
                .opacity(0.9)
                .saturation(0.85)
            VStack(spacing: Space.xs) {
                shortcut("Show All Commands", "⇧⌘P", id: "empty.commands") { controller.showPalette(.commands) }
                shortcut("Go to File", "⌘P", id: "empty.quickOpen") { controller.showPalette(.files) }
                shortcut("New File", "⌘N", id: "empty.newFile") { controller.newFile() }
                shortcut("Toggle Terminal", "⌃`", id: "empty.terminal") { controller.toggleTerminal() }
                shortcut("Split Editor", "⌘\\", id: "empty.split") { controller.split(.right) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ title: String, _ keys: String, id: String, action: @escaping () -> Void) -> some View {
        EmptyPaneShortcut(title: title, keys: keys, action: action)
            .accessibilityIdentifier(id)
    }
}

private struct EmptyPaneShortcut: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    let title: String
    let keys: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.studio(type.label))
                    .foregroundStyle(hovering ? theme.palette.textPrimary.color : theme.palette.textSecondary.color)
                Spacer(minLength: Space.xl)
                KeyCaps(keys)
            }
            .padding(.horizontal, Space.m)
            .frame(width: 280, height: max(metrics.rowHeight + 4, 32))
            .studioRowBackground(selected: false, hovering: hovering, cornerRadius: Radius.s + 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .studioHover($hovering)
    }
}

extension Array {
    subscript(safe index: Int, default fallback: Element) -> Element {
        indices.contains(index) ? self[index] : fallback
    }
}
