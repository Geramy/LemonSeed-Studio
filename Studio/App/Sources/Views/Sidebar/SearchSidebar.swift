import SwiftUI
import StudioCore
import StudioDesign

/// Workspace search: query with case / word / regex toggles, include and
/// exclude globs, and results grouped by file.
struct SearchSidebar: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    let controller: WorkspaceController
    @Bindable var search: SearchModel
    @FocusState private var fieldFocused: Bool
    @State private var focusRequest = FocusRequest()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                TextField("Search", text: $search.query)
                    .textFieldStyle(StudioFieldStyle(symbol: StudioSymbol.search))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($fieldFocused)
                    .onSubmit { search.run() }
                    .onChange(of: search.query) { _, _ in search.scheduleRun() }
                    .accessibilityIdentifier("search.field")
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 2) {
                            toggle("textformat", "Match Case", isOn: $search.caseSensitive, id: "search.case")
                            toggle("w.square", "Match Whole Word", isOn: $search.wholeWord, id: "search.word")
                            toggle("asterisk", "Use Regular Expression", isOn: $search.isRegex, id: "search.regex")
                        }
                        .padding(.trailing, 4)
                    }
                StudioIconButton("line.3.horizontal.decrease", help: "Files to include and exclude",
                                 isActive: search.showsFilters) {
                    withAnimation(Motion.layout) { search.showsFilters.toggle() }
                }
                .accessibilityIdentifier("search.filters")
            }
            if search.showsFilters {
                TextField("Files to include (e.g. *.swift, src/)", text: $search.include)
                    .textFieldStyle(StudioFieldStyle(symbol: "plus.circle"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { search.run() }
                    .accessibilityIdentifier("search.include")
                TextField("Files to exclude", text: $search.exclude)
                    .textFieldStyle(StudioFieldStyle(symbol: "minus.circle"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { search.run() }
                    .accessibilityIdentifier("search.exclude")
            }
            summary
        }
        .padding(.horizontal, Space.m)
        .onChange(of: search.caseSensitive) { _, _ in search.run() }
        .onChange(of: search.wholeWord) { _, _ in search.run() }
        .onChange(of: search.isRegex) { _, _ in search.run() }
        .onChange(of: search.focusRequest) { _, _ in fieldFocused = true }
        .onChange(of: focusRequest.count) { _, _ in fieldFocused = true }
        .onChange(of: fieldFocused) { _, focused in
            if focused { TextInputCoordinator.shared.didFocus(id: "search") }
        }
        .onAppear {
            let request = focusRequest
            TextInputCoordinator.shared.register(TextInputTarget(id: "search", kind: .search) {
                request.fire()
                return true
            })
        }
        .onDisappear { TextInputCoordinator.shared.unregister(id: "search") }

        results
    }

    private func toggle(_ symbol: String, _ help: String, isOn: Binding<Bool>, id: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? theme.palette.textOnAccent.color : theme.palette.textTertiary.color)
                .frame(width: 22, height: 20)
                .background(isOn.wrappedValue ? theme.palette.accentFill.color : .clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    @ViewBuilder private var summary: some View {
        if let error = search.errorMessage {
            Text(error)
                .font(.studio(type.caption))
                .foregroundStyle(theme.palette.error.color)
        } else if search.isSearching {
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.mini)
                Text("Searching…")
            }
            .font(.studio(type.caption))
            .foregroundStyle(theme.palette.textSecondary.color)
        } else if let summary = search.summary {
            Text(summaryText(summary))
                .font(.studio(type.caption))
                .foregroundStyle(theme.palette.textSecondary.color)
                .accessibilityIdentifier("search.summary")
        }
    }

    private func summaryText(_ summary: SearchSummary) -> String {
        if summary.totalMatches == 0 { return "No results in \(summary.filesSearched) files" }
        let results = "\(summary.totalMatches) result\(summary.totalMatches == 1 ? "" : "s")"
        let files = "\(summary.filesMatched) file\(summary.filesMatched == 1 ? "" : "s")"
        let time = summary.duration < 1 ? "\(Int(summary.duration * 1000)) ms" : String(format: "%.1f s", summary.duration)
        return "\(results) in \(files) · \(time)" + (summary.truncated ? " · stopped at the limit" : "")
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(search.results) { file in
                    SearchFileHeader(file: file, collapsed: search.collapsed.contains(file.relativePath)) {
                        withAnimation(Motion.select) {
                            if search.collapsed.contains(file.relativePath) { search.collapsed.remove(file.relativePath) }
                            else { search.collapsed.insert(file.relativePath) }
                        }
                    }
                    if !search.collapsed.contains(file.relativePath) {
                        ForEach(Array(file.matches.prefix(400).enumerated()), id: \.offset) { _, match in
                            SearchMatchRow(match: match) {
                                controller.open(controller.workspace.url(forRelativePath: file.relativePath),
                                                at: match.position, preview: true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.xs + 2)
            .padding(.bottom, Space.l)
        }
        .accessibilityIdentifier("search.results")
    }
}

private struct SearchFileHeader: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    let file: SearchFileResult
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let name = (file.relativePath as NSString).lastPathComponent
        let folder = (file.relativePath as NSString).deletingLastPathComponent
        let icon = FileIcon.forFile(named: name)
        Button(action: toggle) {
            HStack(spacing: Space.xs + 1) {
                Image(systemName: StudioSymbol.chevronRight)
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(theme.palette.textTertiary.color)
                    .frame(width: 12)
                Image(systemName: icon.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(icon.color(in: theme))
                Text(name)
                    .font(.studio(type.body, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary.color)
                    .lineLimit(1)
                Text(folder)
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.textTertiary.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: Space.xs)
                CountBadge(file.matches.count)
            }
            .padding(.horizontal, Space.xs)
            .frame(height: metrics.rowHeight)
            .studioRowBackground(selected: false, hovering: hovering)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .studioHover($hovering)
        .accessibilityIdentifier("search.file.\(file.relativePath)")
    }
}

private struct SearchMatchRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.metrics) private var metrics
    let match: SearchMatch
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("\(match.line)")
                    .font(.studioNumeric(type.micro + 0.5))
                    .foregroundStyle(theme.palette.textTertiary.color)
                    .frame(minWidth: 26, alignment: .trailing)
                previewText
                    .font(.system(size: type.caption + 0.5, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, Space.l + 2)
            .padding(.trailing, Space.xs)
            .frame(minHeight: metrics.rowHeight - 4)
            .studioRowBackground(selected: false, hovering: hovering)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .studioHover($hovering)
        .accessibilityIdentifier("search.match.\(match.line)")
    }

    private var previewText: Text {
        let chars = Array(match.preview)
        let lower = min(match.previewRange.lowerBound, chars.count)
        let upper = min(match.previewRange.upperBound, chars.count)
        var before = AttributedString(String(chars[..<lower]))
        before.foregroundColor = theme.palette.textSecondary.color
        var hit = AttributedString(String(chars[lower..<upper]))
        hit.foregroundColor = theme.palette.textPrimary.color
        hit.backgroundColor = theme.palette.accentWash.color
        hit.inlinePresentationIntent = .stronglyEmphasized
        var after = AttributedString(String(chars[upper...]))
        after.foregroundColor = theme.palette.textSecondary.color
        return Text(before + hit + after)
    }
}
