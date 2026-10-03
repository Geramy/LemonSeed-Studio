import SwiftUI
import StudioCore
import StudioDesign

/// A pane's tabs. Tap to select, double tap to keep a preview tab, drag to
/// reorder or move between panes, context menu for close actions.
struct TabStrip: View {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    let controller: WorkspaceController
    let pane: EditorPane
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabItem(controller: controller, pane: pane, tab: tab, index: index,
                                    isSelected: pane.selectedTab?.id == tab.id, paneFocused: isFocused)
                                .id(tab.id)
                        }
                    }
                }
                .onChange(of: pane.selectedTabID) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.select) { proxy.scrollTo(id) }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                StudioIconButton(StudioSymbol.splitRight, help: "Split Editor Right") {
                    controller.layout.focusedPaneID = pane.id
                    controller.split(.right)
                }
                .accessibilityIdentifier("tabs.split")
                Menu {
                    Button("Split Down", systemImage: StudioSymbol.splitDown) {
                        controller.layout.focusedPaneID = pane.id
                        controller.split(.down)
                    }
                    Button("Close All", systemImage: "xmark.square") {
                        for document in controller.layout.closeAll(in: pane.id) { controller.workspace.release(document) }
                    }
                    if controller.layout.paneCount > 1 {
                        Button("Close Pane", systemImage: "rectangle.badge.xmark") {
                            controller.layout.removePane(pane.id)
                        }
                        Button("Join All Panes", systemImage: "rectangle") {
                            withAnimation(Motion.layout) { controller.layout.joinAll() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: metrics.iconSize - 2, weight: .semibold))
                        .foregroundStyle(theme.palette.textSecondary.color)
                        .frame(width: metrics.hitTarget, height: metrics.hitTarget)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("tabs.more")
                .accessibilityLabel("Editor actions")
            }
            .padding(.trailing, Space.xs)
        }
        .frame(height: metrics.tabHeight)
        .background(theme.palette.chrome.color)
        .overlay(alignment: .bottom) { Hairline() }
        .dropDestination(for: String.self) { items, _ in
            for item in items { moveTab(item, to: pane.tabs.count) }
            return true
        }
    }

    private func moveTab(_ payload: String, to index: Int) {
        guard payload.hasPrefix("tab:"), let id = UUID(uuidString: String(payload.dropFirst(4))) else { return }
        withAnimation(Motion.reorder) { controller.layout.move(id, to: pane.id, at: index) }
    }
}

private struct TabItem: View {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.typeScale) private var type
    let controller: WorkspaceController
    let pane: EditorPane
    let tab: EditorTab
    let index: Int
    let isSelected: Bool
    let paneFocused: Bool
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let document = tab.document
        let icon = FileIcon.forFile(named: document.name)
        HStack(spacing: Space.xs + 2) {
            Image(systemName: icon.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(icon.color(in: theme))
            Text(document.name)
                .font(.studio(type.label, weight: isSelected ? .medium : .regular))
                .italic(tab.isPreview)
                .foregroundStyle(isSelected ? theme.palette.textPrimary.color : theme.palette.textSecondary.color)
                .lineLimit(1)
            closeButton(document)
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.xs + 2)
        .frame(height: metrics.tabHeight)
        .background(isSelected ? theme.palette.editor.color : hovering ? theme.palette.hover.color : .clear)
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle()
                    .fill(paneFocused ? theme.palette.accentFill.color : theme.palette.textTertiary.opacity(0.5).color)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .leading) {
            if targeted { Rectangle().fill(theme.palette.accent.color).frame(width: 2) }
        }
        .overlay(alignment: .trailing) { Hairline(.vertical).opacity(isSelected ? 0 : 1) }
        .contentShape(.rect)
        .studioHover($hovering)
        .onTapGesture(count: 2) { controller.layout.pin(tab.id) }
        .onTapGesture { controller.layout.select(tab.id, in: pane.id) }
        .hoverEffect(.highlight)
        .draggable("tab:\(tab.id.uuidString)") {
            Label(document.name, systemImage: icon.symbol)
                .padding(Space.s)
                .background(theme.palette.elevated.color, in: RoundedRectangle(cornerRadius: Radius.s))
        }
        .dropDestination(for: String.self) { items, _ in
            for item in items {
                guard item.hasPrefix("tab:"), let id = UUID(uuidString: String(item.dropFirst(4))) else { continue }
                withAnimation(Motion.reorder) { controller.layout.move(id, to: pane.id, at: index) }
            }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Close", systemImage: StudioSymbol.close) { controller.closeTab(tab.id) }
            Button("Close Others", systemImage: "xmark.square") {
                for released in controller.layout.closeOthers(tab.id) { controller.workspace.release(released) }
            }
            if tab.isPreview {
                Button("Keep Open", systemImage: "pin") { controller.layout.pin(tab.id) }
            }
            Divider()
            Button("Split Right", systemImage: StudioSymbol.splitRight) {
                controller.layout.select(tab.id, in: pane.id)
                controller.split(.right)
            }
            Button("Reveal in Explorer", systemImage: "scope") { controller.reveal(document.url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(document.name + (document.isDirty ? ", edited" : ""))
        .accessibilityIdentifier("tab.\(document.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func closeButton(_ document: EditorDocument) -> some View {
        let showClose = hovering || isSelected || metrics.hitTarget >= 44
        Button {
            controller.closeTab(tab.id)
        } label: {
            ZStack {
                if document.isDirty && !hovering {
                    Circle().fill(theme.palette.textSecondary.color).frame(width: 7, height: 7)
                } else if showClose {
                    Image(systemName: StudioSymbol.close)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.palette.textSecondary.color)
                }
            }
            .frame(width: 18, height: 18)
            .background(hovering && !document.isDirty ? theme.palette.hover.color : .clear, in: RoundedRectangle(cornerRadius: 4))
            .frame(width: 24, height: max(24, metrics.hitTarget - 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close \(document.name)")
        .accessibilityIdentifier("tab.close.\(document.name)")
    }
}

/// The path of the open file; tap a folder to reveal it in the explorer.
struct Breadcrumb: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let controller: WorkspaceController
    let document: EditorDocument

    var body: some View {
        let relative = controller.workspace.relativePath(of: document.url) ?? document.name
        let parts = relative.split(separator: "/").map(String.init)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xs) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Image(systemName: StudioSymbol.chevronRight)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.palette.textTertiary.color)
                    }
                    let isLast = index == parts.count - 1
                    Button {
                        let url = controller.rootURL.appendingPathComponent(parts[...index].joined(separator: "/"))
                        controller.reveal(url)
                    } label: {
                        HStack(spacing: 4) {
                            if isLast {
                                let icon = FileIcon.forFile(named: part)
                                Image(systemName: icon.symbol)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(icon.color(in: theme))
                            }
                            Text(part)
                                .font(.studio(type.caption))
                                .foregroundStyle(isLast ? theme.palette.textPrimary.color : theme.palette.textSecondary.color)
                        }
                        .padding(.horizontal, 3)
                        .frame(minHeight: 22)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
            .padding(.horizontal, Space.m)
        }
        .frame(height: 26)
        .background(theme.palette.editor.color)
        .accessibilityIdentifier("editor.breadcrumb")
    }
}
