public import SwiftUI
import GitKit
public import Forge

/// Pull/merge requests with CI badges, and for a repository a state
/// (open/closed/merged) and scope (everyone's, mine, review requested) bar.
public struct PullRequestListView: View {
    @Bindable var model: PullRequestListModel
    @Binding var selection: PullRequest?
    @Environment(\.gitTheme) private var theme

    public init(model: PullRequestListModel, selection: Binding<PullRequest?>) {
        self.model = model
        self._selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            if model.repository != nil {
                Section {
                    filterBar.listRowSeparator(.hidden)
                }
            }
            ErrorBanner(message: $model.errorMessage)
            ForEach(model.requests) { pr in
                row(pr).tag(pr)
                    .accessibilityIdentifier("git.pull.\(pr.number)")
            }
            if model.requests.isEmpty && !model.isLoading && model.errorMessage == nil {
                ContentUnavailableView("No \(model.scope == .all ? "" : model.scope.title.lowercased() + " ")\(model.state.rawValue) \(model.client.host.kind.requestNoun)s",
                                       systemImage: "arrow.triangle.pull")
            }
        }
        .overlay { if model.isLoading && model.requests.isEmpty { ProgressView() } }
        .refreshable { await model.load() }
        .task { await model.load() }
        .navigationTitle(model.title)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("State", selection: Binding(get: { model.state }, set: { s in Task { await model.set(state: s) } })) {
                Text("Open").tag(PullRequestState.open)
                Text("Closed").tag(PullRequestState.closed)
                Text("Merged").tag(PullRequestState.merged)
            }
            .pickerStyle(.segmented)
            .disabled(model.scope == .reviewRequested)
            .accessibilityIdentifier("git.pulls.state")
            Picker("Show", selection: Binding(get: { model.scope }, set: { s in Task { await model.set(scope: s) } })) {
                ForEach(PullRequestListModel.Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("git.pulls.scope")
        }
    }

    private func row(_ pr: PullRequest) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: pr.state == .merged ? "arrow.triangle.merge" : (pr.state == .closed ? "xmark.circle" : "arrow.triangle.pull"))
                .foregroundStyle(pr.isDraft ? Color.secondary : (pr.state == .merged ? Color.purple : pr.state == .closed ? theme.deleted : theme.added))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(pr.title).font(.body.weight(.semibold)).lineLimit(2)
                    if pr.isDraft { Badge(text: "Draft", color: theme.secondaryText) }
                }
                HStack(spacing: 6) {
                    Text("\(model.client.host.kind.requestSigil)\(pr.number)").monospacedDigit()
                    if let author = pr.author { Text(author.login) }
                    if !pr.sourceBranch.isEmpty { Text("\(pr.sourceBranch) → \(pr.targetBranch)").lineLimit(1) }
                    if let updated = pr.updatedAt { Text(updated.relative) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !pr.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(pr.labels, id: \.self) { Badge(text: $0, color: theme.accent) }
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let state = model.ciStates[pr.id] { CIBadge(state) }
                if let comments = pr.commentCount, comments > 0 {
                    Label("\(comments)", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// A request's description, commits, files with diffs and line comments,
/// conversation and review threads, checks; and its actions: check out,
/// comment, approve or request changes, merge with the repository's allowed
/// methods, close and reopen. Actions the user's permission does not allow
/// are disabled with the reason.
public struct PullRequestDetailView: View {
    @Bindable var model: PullRequestDetailModel
    /// The local repository and remote to check the request out into.
    var checkout: (sourceControl: SourceControlModel, remote: String)?
    @State private var commentingOn: (line: DiffLine, path: String)?
    @State private var lineCommentText = ""
    @State private var tab = Tab.conversation
    @State private var confirmMerge: MergeMethod?
    @State private var confirmClose = false
    @Environment(\.gitTheme) private var theme
    @Environment(\.openURL) private var openURL

    enum Tab: String, CaseIterable { case conversation = "Conversation", commits = "Commits", files = "Files", checks = "Checks" }

    public init(model: PullRequestDetailModel, checkout: (sourceControl: SourceControlModel, remote: String)? = nil) {
        self.model = model
        self.checkout = checkout
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let pr = model.request {
                header(pr)
                actionBar(pr)
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in Text(tabTitle(t)).tag(t) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("git.pull.tabs")
                Divider()
                switch tab {
                case .conversation: conversation(pr)
                case .commits: commits
                case .files: files
                case .checks: checks
                }
            } else if let error = model.errorMessage {
                ContentUnavailableView("Cannot load", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.number) { await model.load() }
        .navigationTitle(model.request.map { "\(model.kind.requestSigil)\($0.number)" } ?? "")
        .confirmationDialog("Merge \(model.title)?", isPresented: Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } }),
                            titleVisibility: .visible, presenting: confirmMerge) { method in
            Button(method.title) { Task { await model.merge(method) } }
        } message: { method in
            Text("\(model.request?.sourceBranch ?? "") into \(model.request?.targetBranch ?? "") on \(model.client.host.hostname).")
        }
        .confirmationDialog("Close \(model.title) without merging?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close \(model.kind.requestNoun.capitalized)", role: .destructive) { Task { await model.setOpen(false) } }
        }
        .sheet(isPresented: Binding(get: { commentingOn != nil }, set: { if !$0 { commentingOn = nil } })) {
            lineCommentSheet
        }
    }

    private func tabTitle(_ t: Tab) -> String {
        switch t {
        case .conversation: return "Conversation"
        case .commits: return "Commits \(model.commits.count)"
        case .files: return "Files \(model.files.count)"
        case .checks: return "Checks"
        }
    }

    private func header(_ pr: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pr.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 8) {
                stateChip(pr)
                Text("\(pr.author?.login ?? "someone") wants to merge \(pr.isCrossRepository ? "\(pr.sourceRepository ?? "a fork"):" : "")\(pr.sourceBranch) into \(pr.targetBranch)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if let ci = model.ci { CIBadge(ci.state).font(.title3) }
                if let url = pr.webURL {
                    Button { openURL(url) } label: { Image(systemName: "safari") }
                        .accessibilityLabel("Open in browser")
                }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(theme.added)
            }
            ErrorBanner(message: $model.errorMessage)
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 6)
    }

    private func actionBar(_ pr: PullRequest) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let checkout {
                    Button {
                        Task { await model.checkOut(into: checkout.sourceControl, remote: checkout.remote) }
                    } label: {
                        Label("Check Out", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("git.pull.checkout")
                }
                reviewMenu
                mergeMenu
                if pr.state == .open {
                    Button(role: .destructive) { confirmClose = true } label: { Label("Close", systemImage: "xmark.circle") }
                        .disabled(model.stateChangeBlocker != nil || model.isWorking)
                        .help(model.stateChangeBlocker ?? "")
                        .accessibilityIdentifier("git.pull.close")
                } else if pr.state == .closed {
                    Button { Task { await model.setOpen(true) } } label: { Label("Reopen", systemImage: "arrow.uturn.left.circle") }
                        .disabled(model.stateChangeBlocker != nil || model.isWorking)
                        .accessibilityIdentifier("git.pull.reopen")
                }
                if model.isWorking { ProgressView().controlSize(.small) }
                if let blocker = model.mergeBlocker, pr.state == .open {
                    Text(blocker).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal)
        }
    }

    private var reviewMenu: some View {
        Menu {
            Button("Approve", systemImage: "checkmark.circle") { Task { await model.review(.approve) } }
                .disabled(model.isAuthor)
            Button("Request Changes", systemImage: "exclamationmark.bubble") {
                model.reviewBody = model.draftComment
                model.draftComment = ""
                Task { await model.review(.requestChanges) }
            }
            .disabled(model.isAuthor)
            Button("Comment Review", systemImage: "text.bubble") {
                model.reviewBody = model.draftComment
                model.draftComment = ""
                Task { await model.review(.comment) }
            }
        } label: {
            Label("Review", systemImage: "eye")
        }
        .disabled(model.reviewBlocker != nil || model.isWorking)
        .accessibilityIdentifier("git.pull.review")
    }

    private var mergeMenu: some View {
        Menu {
            ForEach(model.mergeMethods, id: \.self) { method in
                Button(method.title) { confirmMerge = method }
            }
        } label: {
            Label("Merge", systemImage: "arrow.triangle.merge")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.mergeBlocker != nil || model.isWorking)
        .accessibilityIdentifier("git.pull.merge")
    }

    private func stateChip(_ pr: PullRequest) -> some View {
        let (text, color): (String, Color) = pr.state == .merged ? ("Merged", .purple)
            : pr.state == .closed ? ("Closed", theme.deleted) : pr.isDraft ? ("Draft", .secondary) : ("Open", theme.added)
        return Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3).background(color, in: Capsule())
    }

    private func conversation(_ pr: PullRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                commentCard(author: pr.author?.login ?? "", date: pr.createdAt,
                            body: pr.body.isEmpty ? "_No description._" : pr.body, location: nil)
                ForEach(model.conversation) { c in
                    commentCard(author: c.author?.login ?? "", date: c.createdAt, body: c.body, location: nil)
                }
                if !model.threads.isEmpty {
                    Text("Review Threads").font(.headline).padding(.top, 4)
                    ForEach(model.threads) { thread in threadCard(thread) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.draftComment)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("git.pull.commentField")
                    HStack {
                        Button("Comment") { Task { await model.postComment() } }
                            .buttonStyle(.bordered)
                            .disabled(model.draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                            .accessibilityIdentifier("git.pull.comment")
                        Text("Write a comment, or use it as the body of Review › Request Changes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
    }

    private func threadCard(_ thread: ReviewThread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(theme.accent)
                Text("\(thread.path)\(thread.line.map { ":\($0)" } ?? "")").font(.caption.monospaced()).foregroundStyle(theme.accent)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                if thread.isResolved { Badge(text: "Resolved", color: theme.added) } else { Badge(text: "Unresolved", color: theme.modified) }
                Button {
                    model.selectedFile = thread.path
                    tab = .files
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show in Files")
            }
            ForEach(thread.comments) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.author?.login ?? "").font(.caption.weight(.semibold))
                        if let date = c.createdAt { Text(date.relative).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(LocalizedStringKey(c.body)).font(.callout).textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(thread.isResolved ? 0.2 : 0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func commentCard(author: String, date: Date?, body: String, location: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
                Text(author).font(.callout.weight(.semibold))
                if let date { Text(date.relative).font(.caption).foregroundStyle(.secondary) }
                if let location {
                    Text(location).font(.caption.monospaced()).foregroundStyle(theme.accent)
                }
            }
            Text(LocalizedStringKey(body)).font(.callout).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var commits: some View {
        List(model.commits) { commit in
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.summary).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 8) {
                    Text(commit.shortSHA).font(.caption.monospaced())
                    Text(commit.authorLogin ?? commit.authorName).font(.caption)
                    if let date = commit.date { Text(date.relative).font(.caption) }
                }
                .foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("Copy Commit ID", systemImage: "doc.on.doc") { Pasteboard.copy(commit.sha) }
            }
        }
        .listStyle(.plain)
        .overlay { if model.commits.isEmpty { ContentUnavailableView("No commits", systemImage: "point.3.connected.trianglepath.dotted") } }
    }

    private var files: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.files) { file in
                        let selected = model.selectedFile == file.path
                        Button {
                            model.selectedFile = file.path
                        } label: {
                            HStack(spacing: 6) {
                                ChangeBadge(file.status == .added ? .added : file.status == .removed ? .deleted : file.status == .renamed ? .renamed : .modified)
                                Text((file.path as NSString).lastPathComponent).lineLimit(1)
                                Text("+\(file.additions) −\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selected ? theme.selectionBackground : Color.clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(.quaternary))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            Divider()
            if let path = model.selectedFile {
                HStack {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text("Tap a line to comment on it").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                DiffView(hunks: model.selectedHunks,
                         isBinary: model.files.first { $0.path == path }?.patch == nil,
                         onTapLine: { line, _ in if model.request?.state == .open { commentingOn = (line, path) } },
                         lineMarker: { line in
                             guard let n = line.newLineNumber else { return 0 }
                             return model.comments(onLine: n, path: path).count
                         })
            } else {
                ContentUnavailableView("No files changed", systemImage: "doc")
            }
        }
    }

    private var checks: some View {
        List {
            if let ci = model.ci, !ci.runs.isEmpty {
                ForEach(ci.runs) { run in
                    HStack {
                        CIBadge(run.state)
                        VStack(alignment: .leading) {
                            Text(run.name)
                            if let group = run.group { Text(group).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(run.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        if let url = run.webURL {
                            Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No checks", systemImage: "checklist",
                                       description: Text("No CI has reported on this \(model.kind.requestNoun)'s latest commit."))
            }
        }
    }

    private var lineCommentSheet: some View {
        NavigationStack {
            Form {
                if let target = commentingOn {
                    Section("\(target.path):\(target.line.newLineNumber ?? target.line.oldLineNumber ?? 0)") {
                        Text(target.line.text).font(theme.codeFont)
                    }
                }
                TextEditor(text: $lineCommentText).frame(minHeight: 120)
            }
            .navigationTitle("Comment on Line")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { commentingOn = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        if let target = commentingOn {
                            let text = lineCommentText
                            Task { await model.postLineComment(text, path: target.path, line: target.line) }
                        }
                        lineCommentText = ""
                        commentingOn = nil
                    }
                    .disabled(lineCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// A new pull/merge request from the current branch.
public struct PullRequestComposerView: View {
    @Bindable var model: PullRequestComposerModel
    var done: (PullRequest?) -> Void

    public init(model: PullRequestComposerModel, done: @escaping (PullRequest?) -> Void) {
        self.model = model
        self.done = done
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("From", value: model.sourceBranch ?? "(detached HEAD)")
                Picker("Into", selection: $model.targetBranch) {
                    ForEach(model.targetBranches) { Text($0.name).tag($0.name) }
                    if !model.targetBranch.isEmpty && !model.targetBranches.contains(where: { $0.name == model.targetBranch }) {
                        Text(model.targetBranch).tag(model.targetBranch)
                    }
                }
                .accessibilityIdentifier("git.compose.base")
                if let target = model.hosting.pullTarget {
                    LabeledContent("Repository", value: target.repository)
                }
            } footer: {
                if let source = model.sourceBranch, source == model.targetBranch {
                    Text("You are on \(source), the branch to merge into. Create a branch for your change first (Branches › New Branch).")
                        .foregroundStyle(.red)
                } else if model.needsPush, let source = model.sourceBranch {
                    Text("\(source) will be pushed to \((model.hosting.pushRemote ?? model.hosting.pullTarget)?.name ?? "the remote") first.")
                }
            }
            Section("Title and Description") {
                TextField("Title", text: $model.title)
                    .accessibilityIdentifier("git.compose.title")
                TextEditor(text: $model.body)
                    .frame(minHeight: 140)
                    .accessibilityIdentifier("git.compose.body")
            }
            Section {
                Toggle("Create as Draft", isOn: $model.isDraft)
                TextField("Reviewers (logins, comma-separated)", text: $model.reviewers).plainTextEntry()
                TextField("Labels (comma-separated)", text: $model.labels).plainTextEntry()
            } footer: {
                Text("Reviewers and labels must exist on \(model.hosting.pullTarget?.reference.hostname ?? "the forge"); the request is still created if they cannot be added, and the error says which.")
            }
            if !model.phase.isEmpty {
                Section { Label(model.phase, systemImage: "hourglass") }
            }
            ErrorBanner(message: $model.errorMessage)
        }
        .navigationTitle("New \(model.hosting.requestNoun.capitalized)")
        .inlineTitle()
        .task { await model.prepare() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) }.disabled(model.isWorking) }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.needsPush ? "Push and Create" : "Create") {
                    Task {
                        let pr = await model.submit()
                        if pr != nil && model.errorMessage == nil { done(pr) }
                    }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("git.compose.create")
            }
        }
    }
}
