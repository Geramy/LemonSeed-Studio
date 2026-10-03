import SwiftUI
import StudioCore
import StudioDesign

/// One field for files, commands and lines: no prefix searches files,
/// ">" commands, ":" goes to a line, "?" lists the prefixes.
struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    @Bindable var controller: WorkspaceController
    @State private var items: [PaletteItem] = []
    @State private var selection = 0
    @State private var rankTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Image(systemName: modeSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.palette.accent.color)
                    .frame(width: 20)
                TextField(placeholder, text: $controller.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.studio(type.body + 2))
                    .foregroundStyle(theme.palette.textPrimary.color)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { run(selection) }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { controller.dismissPalette(); return .handled }
                    .accessibilityIdentifier("palette.field")
                if !controller.paletteQuery.isEmpty {
                    Button {
                        controller.paletteQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.palette.textTertiary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, Space.l)
            .frame(height: 52)

            Hairline()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, isSelected: index == selection)
                                .id(item.id)
                                .onTapGesture { run(index) }
                                .onHover { inside in if inside { selection = index } }
                        }
                    }
                    .padding(Space.s)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id)
                }
            }
            if items.isEmpty {
                Text(emptyText)
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.textTertiary.color)
                    .padding(Space.l)
            }
            footer
        }
        .frame(width: 640)
        .frame(maxWidth: .infinity)
        .floatingSurface(cornerRadius: Radius.xl)
        .frame(maxWidth: 640)
        .padding(.horizontal, Space.l)
        .onAppear {
            focused = true
            refresh()
        }
        .onChange(of: controller.paletteQuery) { _, _ in refresh() }
        // Opened before indexing finished: refresh when the files arrive.
        .onChange(of: controller.workspace.fileIndex.count) { _, _ in refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("palette")
    }

    private var footer: some View {
        HStack(spacing: Space.l) {
            hint("↑↓", "navigate")
            hint("↩", "open")
            hint("⎋", "close")
            Spacer()
            Text("> commands   : line   ? help")
                .font(.system(size: type.micro + 0.5, design: .monospaced))
                .foregroundStyle(theme.palette.textTertiary.color)
        }
        .padding(.horizontal, Space.l)
        .frame(height: 30)
        .overlay(alignment: .top) { Hairline() }
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KeyCaps(keys)
            Text(label)
                .font(.studio(type.micro + 0.5))
                .foregroundStyle(theme.palette.textTertiary.color)
        }
    }

    // MARK: Modes

    private enum Mode { case files, commands, line, help }

    private var mode: Mode {
        let q = controller.paletteQuery
        if q.hasPrefix(">") { return .commands }
        if q.hasPrefix(":") { return .line }
        if q.hasPrefix("?") { return .help }
        return .files
    }

    private var modeSymbol: String {
        switch mode {
        case .files: "doc.text.magnifyingglass"
        case .commands: StudioSymbol.command
        case .line: "text.line.first.and.arrowtriangle.forward"
        case .help: "questionmark.circle"
        }
    }

    private var placeholder: String {
        switch mode {
        case .files: "Search files by name (type > for commands)"
        case .commands: "Type a command"
        case .line: "Type a line number, e.g. 42 or 42:7"
        case .help: "Prefixes"
        }
    }

    private var emptyText: String {
        switch mode {
        case .files: controller.workspace.isIndexing ? "Indexing files…" : "No matching files"
        case .commands: "No matching commands"
        case .line: controller.activeDocument == nil ? "Open a file first" : "Type a line number"
        case .help: ""
        }
    }

    private func refresh() {
        rankTask?.cancel()
        selection = 0
        let query = controller.paletteQuery
        switch mode {
        case .commands:
            items = app.commands.search(String(query.dropFirst()))
                .filter { $0.command.isEnabled(controller) }
                .map { .command($0.command, $0.match) }
        case .line:
            let text = query.dropFirst().trimmingCharacters(in: .whitespaces)
            if let document = controller.activeDocument, let position = TextPosition(parsing: text) {
                items = [.line(position, total: document.lineCount)]
            } else {
                items = []
            }
        case .help:
            items = [
                .help(">", "Run a command"),
                .help(":", "Go to a line in the current file"),
                .help("", "Open a file by name (fuzzy)"),
                .help("@", "Symbols in this file (with the language server)"),
                .help("#", "Symbols in the workspace (with the language server)"),
            ]
        case .files:
            let index = controller.workspace.fileIndex
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                let recent = controller.recentFiles.filter { index.contains($0) || FileManager.default.fileExists(atPath: controller.workspace.url(forRelativePath: $0).path) }
                let rest = index.filter { !recent.contains($0) }.prefix(max(0, 60 - recent.count))
                items = (recent + rest).map { .file($0, FuzzyMatch(score: 0, positions: []), recent: recent.contains($0)) }
                return
            }
            let recent = controller.recentFiles
            rankTask = Task {
                let ranked = await Task.detached(priority: .userInitiated) {
                    FuzzyMatcher(query).rank(index, limit: 60, key: { $0 })
                }.value
                guard !Task.isCancelled else { return }
                items = ranked.map { .file($0.element, $0.match, recent: recent.contains($0.element)) }
                selection = 0
            }
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    private func run(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        switch item {
        case .file(let path, _, _):
            controller.dismissPalette(restoreFocus: false)
            controller.open(controller.workspace.url(forRelativePath: path), preview: false)
        case .command(let command, _):
            controller.dismissPalette(restoreFocus: false)
            // Let the palette close before the command presents anything.
            Task { @MainActor in app.commands.run(id: command.id, in: controller) }
        case .line(let position, _):
            controller.dismissPalette()
            controller.activeDocument?.pendingReveal = position
        case .help(let prefix, _):
            controller.paletteQuery = prefix
        }
    }
}

enum PaletteItem: Identifiable {
    case file(String, FuzzyMatch, recent: Bool)
    case command(StudioCommand, FuzzyMatch)
    case line(TextPosition, total: Int)
    case help(String, String)

    var id: String {
        switch self {
        case .file(let path, _, _): "file:" + path
        case .command(let command, _): "command:" + command.id
        case .line(let position, _): "line:\(position.line):\(position.column)"
        case .help(let prefix, let text): "help:" + prefix + text
        }
    }
}

private struct PaletteRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            content
        }
        .padding(.horizontal, Space.m)
        .frame(minHeight: max(metrics.rowHeight + 8, 38))
        .background(isSelected ? theme.palette.accentWash.color : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.m - 2, style: .continuous))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("palette.item.\(item.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .file(let path, let match, let recent):
            let name = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            let nameStart = path.count - name.count
            let icon = FileIcon.forFile(named: name)
            Image(systemName: icon.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(icon.color(in: theme))
                .frame(width: 20)
            HighlightedText(name, highlights: match.positions.filter { $0 >= nameStart }.map { $0 - nameStart },
                            baseColor: theme.palette.textPrimary.color)
                .font(.studio(type.body))
                .lineLimit(1)
            HighlightedText(folder, highlights: match.positions.filter { $0 < folder.count },
                            baseColor: theme.palette.textTertiary.color)
                .font(.studio(type.caption))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: Space.s)
            if recent {
                Text("recent")
                    .font(.studio(type.micro))
                    .foregroundStyle(theme.palette.textTertiary.color)
            }
        case .command(let command, let match):
            Image(systemName: command.symbol ?? StudioSymbol.command)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary.color)
                .frame(width: 20)
            HighlightedText(command.paletteTitle, highlights: match.positions, baseColor: theme.palette.textPrimary.color)
                .font(.studio(type.body))
                .lineLimit(1)
            Spacer(minLength: Space.s)
            if let shortcut = command.shortcut {
                KeyCaps(shortcut.description)
            }
        case .line(let position, let total):
            Image(systemName: "arrow.right.to.line")
                .foregroundStyle(theme.palette.textSecondary.color)
                .frame(width: 20)
            Text("Go to line \(position.line)" + (position.column > 1 ? ", column \(position.column)" : ""))
                .font(.studio(type.body))
                .foregroundStyle(theme.palette.textPrimary.color)
            Spacer()
            Text("\(total) lines")
                .font(.studio(type.caption))
                .foregroundStyle(theme.palette.textTertiary.color)
        case .help(let prefix, let text):
            Text(prefix.isEmpty ? "…" : prefix)
                .font(.system(size: type.body, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.palette.accent.color)
                .frame(width: 20)
            Text(text)
                .font(.studio(type.body))
                .foregroundStyle(theme.palette.textPrimary.color)
            Spacer()
        }
    }
}
