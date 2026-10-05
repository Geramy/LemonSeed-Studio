public import SwiftUI
import GitKit

/// The Source Control panel: branch and sync bar, operation banner, commit
/// box, and the conflict / staged / unstaged lists. Selecting a file shows
/// its diff (or merge editor) in `SourceControlDetailView`.
public struct SourceControlView: View {
    @Bindable var model: SourceControlModel
    /// When set (a narrow sidebar with no room for the diff), selecting a
    /// file calls this with its path and whether it is staged instead of
    /// showing the diff beside the list.
    var onOpenChange: ((String, Bool) -> Void)?
    /// Opens the pull request composer for the current branch.
    var onCreatePullRequest: (() -> Void)?
    @Environment(\.gitTheme) private var theme
    @State private var confirmDiscard: [StatusEntry]?

    public init(model: SourceControlModel, onOpenChange: ((String, Bool) -> Void)? = nil, onCreatePullRequest: (() -> Void)? = nil) {
        self.model = model
        self.onOpenChange = onOpenChange
        self.onCreatePullRequest = onCreatePullRequest
    }

    public var body: some View {
        List(selection: selectionBinding) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    BranchBar(model: model, onCreatePullRequest: onCreatePullRequest)
                    OperationBanner(model: model, onResolve: onOpenChange.map { open in
                        { if let first = model.conflicted.first { open(first.path, false) } }
                    })
                    CommitBox(model: model)
                    if let notice = model.notice {
                        HStack(alignment: .top) {
                            Label(notice, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(theme.added)
                            Spacer(minLength: 0)
                            Button { model.notice = nil } label: { Image(systemName: "xmark").font(.caption2) }
                                .buttonStyle(.plain).accessibilityLabel("Dismiss")
                        }
                    }
                    ErrorBanner(message: $model.errorMessage)
                }
                .listRowSeparator(.hidden)
            }
            if !model.conflicted.isEmpty {
                Section("Merge Conflicts") {
                    ForEach(model.conflicted) { entry in
                        row(entry, staged: false)
                    }
                }
            }
            if !model.staged.isEmpty {
                Section {
                    ForEach(model.staged) { entry in
                        row(entry, staged: true)
                            .swipeActions { Button("Unstage") { Task { await model.unstage([entry]) } }.tint(.orange) }
                    }
                } header: {
                    sectionHeader("Staged Changes", count: model.staged.count, action: "Unstage All", systemImage: "minus") {
                        Task { await model.unstageAll() }
                    }
                }
            }
            Section {
                if model.unstaged.isEmpty && model.staged.isEmpty && model.conflicted.isEmpty {
                    Label("No changes", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(model.unstaged) { entry in
                    row(entry, staged: false)
                        .swipeActions {
                            Button("Stage") { Task { await model.stage([entry]) } }.tint(.green)
                            Button("Discard", role: .destructive) { confirmDiscard = [entry] }
                        }
                }
            } header: {
                if !model.unstaged.isEmpty {
                    sectionHeader("Changes", count: model.unstaged.count, action: "Stage All", systemImage: "plus") {
                        Task { await model.stageAll() }
                    }
                }
            }
            if !model.stashes.isEmpty {
                Section("Stashes") {
                    ForEach(model.stashes) { stash in
                        HStack {
                            Label(stash.message, systemImage: "tray.full").lineLimit(1)
                            Spacer()
                            Button("Pop") { Task { await model.popStash(stash) } }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .confirmationDialog("Discard changes?", isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                            presenting: confirmDiscard) { entries in
            Button("Discard \(entries.count == 1 ? entries[0].path : "\(entries.count) files")", role: .destructive) {
                Task { await model.discard(entries) }
            }
        } message: { _ in
            Text("Local changes are lost. Untracked files are deleted.")
        }
    }

    private var selectionBinding: Binding<SourceControlModel.Selection?> {
        Binding(get: { onOpenChange == nil ? model.selection : nil }, set: { newValue in
            guard let newValue else { model.selection = nil; return }
            if let onOpenChange {
                onOpenChange(newValue.path, newValue.staged)
                return
            }
            let entry = (newValue.staged ? model.staged : model.unstaged + model.conflicted).first { $0.path == newValue.path }
            if let entry { Task { await model.select(entry, staged: newValue.staged) } }
        })
    }

    private func sectionHeader(_ title: String, count: Int, action: String, systemImage: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button(action: perform) { Label(action, systemImage: systemImage).labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .accessibilityLabel(action)
        }
    }

    private func row(_ entry: StatusEntry, staged: Bool) -> some View {
        let change = entry.isConflicted ? FileChange.conflicted : (staged ? entry.staged : entry.unstaged) ?? .modified
        let name = (entry.path as NSString).lastPathComponent
        let folder = (entry.path as NSString).deletingLastPathComponent
        return HStack(spacing: 8) {
            ChangeBadge(change)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                    .strikethrough(change == .deleted)
                if let old = entry.oldPath {
                    Text("from \(old)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if !entry.isConflicted {
                Button {
                    Task { staged ? await model.unstage([entry]) : await model.stage([entry]) }
                } label: {
                    Image(systemName: staged ? "minus.circle" : "plus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(staged ? "Unstage \(name)" : "Stage \(name)")
            }
        }
        .tag(SourceControlModel.Selection(path: entry.path, staged: staged))
        .contextMenu {
            if staged {
                Button("Unstage", systemImage: "minus") { Task { await model.unstage([entry]) } }
            } else if !entry.isConflicted {
                Button("Stage", systemImage: "plus") { Task { await model.stage([entry]) } }
                Button("Discard Changes", systemImage: "arrow.uturn.backward", role: .destructive) { confirmDiscard = [entry] }
            }
            Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy(entry.path) }
        }
    }
}

/// Branch picker, sync button with ahead/behind, fetch and stash.
struct BranchBar: View {
    @Bindable var model: SourceControlModel
    var onCreatePullRequest: (() -> Void)?
    @State private var showBranches = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showBranches = true
            } label: {
                Label(branchTitle, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("git.branchButton")
            .popover(isPresented: $showBranches) {
                BranchPickerView(model: model, dismiss: { showBranches = false }, onCreatePullRequest: onCreatePullRequest)
                    .frame(minWidth: 360, minHeight: 480)
            }
            Spacer(minLength: 0)
            if case .running(let progress) = model.sync {
                ProgressView().controlSize(.small)
                    .help(TransferProgressView(progress).title)
            }
            Button {
                Task { await model.synchronize() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.currentBranch?.upstream == nil ? "icloud.and.arrow.up" : "arrow.triangle.2.circlepath")
                    if model.behind > 0 { Text("\(model.behind)↓").monospacedDigit() }
                    if model.ahead > 0 { Text("\(model.ahead)↑").monospacedDigit() }
                }
                .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.sync != .idle || model.currentBranch == nil)
            .accessibilityLabel(model.currentBranch?.upstream == nil ? "Publish branch" : "Sync: \(model.behind) behind, \(model.ahead) ahead")
            Menu {
                Button("Fetch", systemImage: "arrow.down.circle") { Task { await model.fetch() } }
                Button("Stash Changes", systemImage: "tray.and.arrow.down") { Task { await model.stash() } }
                    .disabled(!model.hasChanges)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    var branchTitle: String {
        if let branch = model.head?.branch { return branch }
        if let commit = model.head?.commit { return "(\(commit.short))" }
        return "No branch"
    }
}

/// Shown while a merge, rebase, cherry-pick or revert waits for the user.
struct OperationBanner: View {
    @Bindable var model: SourceControlModel
    /// Opens the merge editor (when the diff is not shown beside the list).
    var onResolve: (() -> Void)?
    @Environment(\.gitTheme) private var theme

    var body: some View {
        if model.state.isInProgress {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.conflict)
                if !model.conflicted.isEmpty {
                    Text("Resolve \(model.conflicted.count) conflicted file\(model.conflicted.count == 1 ? "" : "s"), then \(isRebase ? "continue" : "commit").")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let onResolve, !model.conflicted.isEmpty {
                        Button("Resolve Conflicts…", action: onResolve)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("git.resolveConflicts")
                    }
                    if isRebase {
                        Button("Continue") { Task { await model.continueRebase() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.conflicted.isEmpty)
                    }
                    Button("Abort", role: .destructive) { Task { await model.abortOperation() } }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.conflict.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    var isRebase: Bool { [.rebase, .rebaseMerge, .rebaseInteractive].contains(model.state) }

    var title: String {
        switch model.state {
        case .merge: return "Merging"
        case .rebase, .rebaseMerge, .rebaseInteractive:
            if let r = model.rebase { return "Rebasing (\(r.current)/\(r.total))" }
            return "Rebasing"
        case .cherryPick, .cherryPickSequence: return "Cherry-picking"
        case .revert, .revertSequence: return "Reverting"
        default: return "Operation in progress"
        }
    }
}

/// Commit message editor and button.
struct CommitBox: View {
    @Bindable var model: SourceControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if model.commitMessage.isEmpty {
                    Text(model.head?.branch.map { "Message (commit on \($0))" } ?? "Message")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.commitMessage)
                    .frame(minHeight: 60, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Commit message")
            }
            .padding(4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Toggle("Amend", isOn: $model.amend)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Spacer()
                Button {
                    Task { await model.commit() }
                } label: {
                    Label(model.staged.isEmpty && !model.amend ? "Commit" : "Commit \(model.staged.count)", systemImage: "checkmark")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canCommit)
            }
        }
    }
}

/// The diff of the selected file with hunk and line staging, or the merge
/// editor for a conflicted file.
public struct SourceControlDetailView: View {
    @Bindable var model: SourceControlModel

    public init(model: SourceControlModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let selection = model.selection {
                if model.conflicted.contains(where: { $0.path == selection.path }) {
                    ConflictResolutionView(model: model, path: selection.path)
                } else if let diff = model.selectedDiff {
                    VStack(spacing: 0) {
                        header(diff, staged: selection.staged)
                        Divider()
                        DiffView(hunks: diff.hunks, isBinary: diff.isBinary, hunkActions: actions(staged: selection.staged),
                                 selectedLines: model.selectedLines) { line, hunk in
                            model.toggleLine(line, in: hunk)
                        }
                    }
                } else {
                    ContentUnavailableView("No changes", systemImage: "doc")
                }
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Choose a changed file to see its diff."))
            }
        }
        .navigationTitle(model.selection.map { ($0.path as NSString).lastPathComponent } ?? "Changes")
        .inlineTitle()
    }

    private func header(_ diff: FileDiff, staged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ChangeBadge(diff.change)
                Text(diff.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text("+\(diff.additions) −\(diff.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            HStack(spacing: 8) {
                Text(staged ? "Staged" : "Working Tree").font(.caption).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer(minLength: 4)
                if !model.selectedLines.isEmpty {
                    Button("Clear") { model.selectedLines = [] }
                        .controlSize(.small)
                    Button {
                        Task { await model.applySelectedLines() }
                    } label: {
                        Label("\(staged ? "Unstage" : "Stage") \(model.selectedLines.count) Line\(model.selectedLines.count == 1 ? "" : "s")",
                              systemImage: staged ? "minus" : "plus")
                            .fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if !diff.hunks.isEmpty {
                    Text("Tap lines to stage them one by one").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func actions(staged: Bool) -> [DiffView.HunkAction] {
        if staged {
            return [.init("Unstage Hunk", systemImage: "minus") { hunk in Task { await model.toggleHunk(hunk) } }]
        }
        return [
            .init("Discard", systemImage: "arrow.uturn.backward", role: .destructive) { hunk in Task { await model.discardHunk(hunk) } },
            .init("Stage Hunk", systemImage: "plus") { hunk in Task { await model.toggleHunk(hunk) } },
        ]
    }
}

/// List and detail side by side, for a full-screen Source Control page.
public struct SourceControlWorkspaceView: View {
    @Bindable var model: SourceControlModel

    public init(model: SourceControlModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            SourceControlView(model: model)
                .frame(width: 360)
            Divider()
            SourceControlDetailView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
