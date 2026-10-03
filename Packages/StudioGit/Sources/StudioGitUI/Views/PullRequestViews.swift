public import SwiftUI
import GitKit
public import Forge

/// Pull/merge requests with CI badges.
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
            ErrorBanner(message: $model.errorMessage)
            ForEach(model.requests) { pr in
                row(pr).tag(pr)
            }
            if model.requests.isEmpty && !model.isLoading && model.errorMessage == nil {
                ContentUnavailableView("No open requests", systemImage: "arrow.triangle.pull")
            }
        }
        .overlay { if model.isLoading && model.requests.isEmpty { ProgressView() } }
        .refreshable { await model.load() }
        .task { await model.load() }
        .navigationTitle(model.title)
    }

    private func row(_ pr: PullRequest) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: pr.isDraft ? "arrow.triangle.pull" : (pr.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull"))
                .foregroundStyle(pr.isDraft ? Color.secondary : (pr.state == .merged ? Color.purple : theme.added))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(pr.title).font(.body.weight(.semibold)).lineLimit(2)
                    if pr.isDraft {
                        Text("Draft").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text("#\(pr.number)").monospacedDigit()
                    if let author = pr.author { Text(author.login) }
                    if !pr.sourceBranch.isEmpty { Text("\(pr.sourceBranch) → \(pr.targetBranch)").lineLimit(1) }
                    if let updated = pr.updatedAt { Text(updated.relative) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !pr.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(pr.labels, id: \.self) { label in
                            Text(label).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(theme.accent.opacity(0.12), in: Capsule())
                        }
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

/// A request's description, checks, files with diffs and line comments,
/// conversation, review and merge.
public struct PullRequestDetailView: View {
    @Bindable var model: PullRequestDetailModel
    @State private var commentingOn: (line: DiffLine, path: String)?
    @State private var lineCommentText = ""
    @State private var tab = Tab.files
    @Environment(\.gitTheme) private var theme
    @Environment(\.openURL) private var openURL

    enum Tab: String, CaseIterable { case conversation = "Conversation", files = "Files", checks = "Checks" }

    public init(model: PullRequestDetailModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let pr = model.request {
                header(pr)
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                Divider()
                switch tab {
                case .conversation: conversation(pr)
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
        .navigationTitle(model.request.map { "#\($0.number)" } ?? "")
        .sheet(isPresented: Binding(get: { commentingOn != nil }, set: { if !$0 { commentingOn = nil } })) {
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

    private func header(_ pr: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pr.title).font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                stateChip(pr)
                Text("\(pr.author?.login ?? "someone") wants to merge \(pr.sourceBranch) into \(pr.targetBranch)")
                    .font(.callout).foregroundStyle(.secondary)
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
        .padding()
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
                if !pr.body.isEmpty {
                    commentCard(author: pr.author?.login ?? "", date: pr.createdAt, body: pr.body, location: nil)
                }
                ForEach(model.comments) { c in
                    commentCard(author: c.author?.login ?? "", date: c.createdAt, body: c.body,
                                location: c.path.map { "\($0)\(c.line.map { ":\($0)" } ?? "")" })
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.draftComment)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Comment") { Task { await model.postComment() } }
                            .disabled(model.draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        reviewMenu
                        mergeMenu(pr)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    private var reviewMenu: some View {
        Menu {
            Button("Approve", systemImage: "checkmark.circle") { Task { await model.review(.approve) } }
            Button("Request Changes", systemImage: "exclamationmark.bubble") {
                model.reviewBody = model.draftComment
                model.draftComment = ""
                Task { await model.review(.requestChanges) }
            }
            Button("Comment Review", systemImage: "text.bubble") {
                model.reviewBody = model.draftComment
                model.draftComment = ""
                Task { await model.review(.comment) }
            }
        } label: {
            Label("Review", systemImage: "eye")
        }
        .disabled(model.isWorking)
    }

    private func mergeMenu(_ pr: PullRequest) -> some View {
        Menu {
            Button("Create a Merge Commit") { Task { await model.merge(.merge) } }
            Button("Squash and Merge") { Task { await model.merge(.squash) } }
            Button("Rebase and Merge") { Task { await model.merge(.rebase) } }
        } label: {
            Label("Merge", systemImage: "arrow.triangle.merge")
        }
        .buttonStyle(.borderedProminent)
        .disabled(pr.state != .open || pr.isDraft || pr.isMergeable == false || model.isWorking)
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

    private var files: some View {
        HStack(spacing: 0) {
            List(selection: $model.selectedFile) {
                ForEach(model.files) { file in
                    HStack {
                        ChangeBadge(file.status == .added ? .added : file.status == .removed ? .deleted : file.status == .renamed ? .renamed : .modified)
                        Text((file.path as NSString).lastPathComponent).lineLimit(1)
                        Spacer()
                        Text("+\(file.additions) −\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(file.path)
                }
            }
            .listStyle(.plain)
            .frame(width: 300)
            Divider()
            if let path = model.selectedFile {
                VStack(spacing: 0) {
                    Text(path).font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    Divider()
                    DiffView(hunks: model.selectedHunks,
                             isBinary: model.files.first { $0.path == path }?.patch == nil,
                             onTapLine: { line, _ in
                                 if line.kind != .context || line.newLineNumber != nil { commentingOn = (line, path) }
                             },
                             lineMarker: { line in
                                 guard let n = line.newLineNumber else { return 0 }
                                 return model.comments(onLine: n, path: path).count
                             })
                }
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc")
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
                ContentUnavailableView("No checks", systemImage: "checklist")
            }
        }
    }
}
