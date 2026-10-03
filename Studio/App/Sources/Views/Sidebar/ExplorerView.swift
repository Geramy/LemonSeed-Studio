import SwiftUI
import UIKit
import StudioCore
import StudioDesign

/// The file tree: lazily loaded folders, file-type icons, inline rename,
/// context menus, and drag and drop (within the tree and from Files).
struct ExplorerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let controller: WorkspaceController
    @State private var rootTargeted = false

    var body: some View {
        let rows = controller.workspace.tree.rows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { row in
                        ExplorerRow(node: row.node, depth: row.depth, controller: controller)
                            .id(row.node.url)
                    }
                    // The empty area below the rows accepts drops into the root.
                    Color.clear
                        .frame(height: 120)
                        .contentShape(.rect)
                        .onTapGesture { controller.explorerSelection = nil }
                        .dropDestination(for: URL.self) { urls, _ in
                            controller.importItems(urls, into: controller.rootURL)
                            return true
                        } isTargeted: { rootTargeted = $0 }
                        .contextMenu { rootMenu }
                }
                .padding(.horizontal, Space.xs + 2)
                .background(rootTargeted ? theme.palette.accentWash.color : .clear)
            }
            .overlay {
                if rows.isEmpty, controller.workspace.tree.root.children != nil {
                    StudioEmptyState(symbol: "folder", title: "Empty folder",
                                     message: "Create a file or folder, or drag files here from Files.") {
                        Button("New File") { controller.newFile() }
                            .buttonStyle(.studioSecondary)
                    }
                }
            }
            .onChange(of: controller.explorerSelection) { _, url in
                guard let url else { return }
                withAnimation(Motion.select) { proxy.scrollTo(url, anchor: nil) }
            }
        }
        .accessibilityIdentifier("explorer.tree")
    }

    @ViewBuilder private var rootMenu: some View {
        Button("New File", systemImage: StudioSymbol.newFile) { controller.newFile(in: controller.rootURL) }
        Button("New Folder", systemImage: StudioSymbol.newFolder) { controller.newFolder(in: controller.rootURL) }
    }
}

struct ExplorerRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.typeScale) private var type
    let node: FileNode
    let depth: Int
    let controller: WorkspaceController
    @State private var hovering = false
    @State private var targeted = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    private var tree: FileTree { controller.workspace.tree }
    private var isSelected: Bool { controller.explorerSelection == node.url }
    private var isRenaming: Bool { controller.renamingURL == node.url }
    private var isActive: Bool { controller.activeDocument?.url == node.url }

    var body: some View {
        HStack(spacing: Space.xs + 1) {
            Group {
                if node.isDirectory {
                    Image(systemName: StudioSymbol.chevronRight)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.palette.textTertiary.color)
                        .rotationEffect(.degrees(tree.isExpanded(node) ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            icon
            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.studio(type.body))
                    .foregroundStyle(theme.palette.textPrimary.color)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($renameFocused)
                    .onSubmit { controller.rename(node.url, to: draftName) }
                    .onKeyPress(.escape) {
                        controller.renamingURL = nil
                        return .handled
                    }
                    .padding(.horizontal, 4)
                    .background(theme.palette.editor.color, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.palette.accent.color, lineWidth: 1))
                    .onAppear {
                        draftName = node.name
                        renameFocused = true
                    }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused, isRenaming { controller.rename(node.url, to: draftName) }
                    }
                    .accessibilityIdentifier("explorer.rename")
            } else {
                Text(node.name)
                    .font(.studio(type.body, weight: isActive ? .medium : .regular))
                    .foregroundStyle(node.name.hasPrefix(".") ? theme.palette.textSecondary.color : theme.palette.textPrimary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let document = controller.workspace.openDocument(at: node.url), document.isDirty {
                Circle().fill(theme.palette.accent.color).frame(width: 6, height: 6)
            }
        }
        .padding(.leading, CGFloat(depth) * metrics.indent + Space.xs)
        .padding(.trailing, Space.s)
        .frame(height: metrics.rowHeight)
        .studioRowBackground(selected: isSelected, hovering: hovering || targeted)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .strokeBorder(theme.palette.accent.color, lineWidth: 1.5)
            }
        }
        .contentShape(.rect)
        .studioHover($hovering)
        .onTapGesture(count: 2) {
            if !node.isDirectory { controller.open(node.url, preview: false) }
        }
        .onTapGesture { activate() }
        .contextMenu { menu }
        .draggable(node.url) {
            Label(node.name, systemImage: FileIcon.forFile(named: node.name).symbol)
                .padding(Space.s)
                .background(theme.palette.elevated.color, in: RoundedRectangle(cornerRadius: Radius.s))
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
            controller.importItems(urls.filter { $0.standardizedFileURL != folder }, into: folder)
            return true
        } isTargeted: { inside in
            targeted = inside && node.isDirectory
            if inside, node.isDirectory, !tree.isExpanded(node) {
                // Spring-load folders while dragging over them.
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    if targeted { await tree.expand(node) }
                }
            }
        }
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityLabel(node.name)
        .accessibilityIdentifier("explorer.row.\(node.relativePath)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var icon: some View {
        if node.isDirectory {
            Image(systemName: tree.isExpanded(node) ? "folder.fill" : "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(theme.syntax.function.opacity(tree.isExpanded(node) ? 1 : 0.85).color)
                .frame(width: 18)
        } else {
            let icon = FileIcon.forFile(named: node.name)
            Image(systemName: icon.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(icon.color(in: theme))
                .frame(width: 18)
        }
    }

    private func activate() {
        controller.explorerSelection = node.url
        if node.isDirectory {
            Task { await tree.toggle(node) }
        } else {
            controller.open(node.url, preview: true)
        }
    }

    @ViewBuilder private var menu: some View {
        if !node.isDirectory {
            Button("Open", systemImage: "doc") { controller.open(node.url, preview: false) }
            Button("Open to the Side", systemImage: StudioSymbol.splitRight) {
                if let pane = controller.layout.split(direction: .right) {
                    controller.open(node.url, preview: false, in: pane.id)
                }
            }
            Divider()
        }
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        Button("New File", systemImage: StudioSymbol.newFile) { controller.newFile(in: folder) }
        Button("New Folder", systemImage: StudioSymbol.newFolder) { controller.newFolder(in: folder) }
        Divider()
        Button("Rename", systemImage: "pencil") {
            controller.explorerSelection = node.url
            controller.renamingURL = node.url
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { controller.duplicate(node.url) }
        Button("Copy Path", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = node.url.path }
        Button("Copy Relative Path", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = node.relativePath }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { controller.pendingDeletion = node.url }
    }
}
