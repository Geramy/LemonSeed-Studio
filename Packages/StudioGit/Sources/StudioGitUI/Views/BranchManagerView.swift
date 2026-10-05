public import SwiftUI
import GitKit

/// Local and remote branches with every branch action: switch (bringing or
/// stashing uncommitted changes), create from HEAD, a branch or a commit,
/// rename, delete locally and on the remote, set the upstream, publish
/// (`push -u`), push, and merge into the current branch. Ahead/behind
/// counts are shown against each branch's upstream.
public struct BranchManagerView: View {
    @Bindable var model: SourceControlModel
    /// Called after a switch or create (a popover closes itself).
    var onFinished: () -> Void
    /// Opens the pull request composer for the current branch.
    var onCreatePullRequest: (() -> Void)?
    @State private var filter = ""
    @State private var newBranchFrom: String?
    @State private var renaming: Branch?
    @State private var renameText = ""
    @State private var switching: Branch?
    @State private var deleting: Branch?
    @State private var settingUpstream: Branch?
    @State private var publishing: Branch?
    @Environment(\.gitTheme) private var theme

    public init(model: SourceControlModel, onFinished: @escaping () -> Void = {}, onCreatePullRequest: (() -> Void)? = nil) {
        self.model = model
        self.onFinished = onFinished
        self.onCreatePullRequest = onCreatePullRequest
    }

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            newBranchFrom = "HEAD"
                        } label: {
                            Label("New Branch…", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("git.branches.new")
                        if case .running(let progress) = model.sync {
                            ProgressView().controlSize(.small)
                            Text(TransferProgressView(progress).title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(theme.added)
                    }
                    ErrorBanner(message: $model.errorMessage)
                }
                .listRowSeparator(.hidden)
            }
            Section("Local") {
                ForEach(filtered(remote: false)) { branch in localRow(branch) }
            }
            ForEach(remoteNames, id: \.self) { remote in
                let branches = filtered(remote: true).filter { $0.remoteName == remote }
                if !branches.isEmpty {
                    Section("Remote · \(remote)") {
                        ForEach(branches) { branch in remoteRow(branch) }
                    }
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter branches")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .sheet(item: Binding(get: { newBranchFrom.map(StartPoint.init) }, set: { newBranchFrom = $0?.revision })) { start in
            NavigationStack {
                NewBranchSheet(model: model, startPoint: start.revision) { created in
                    newBranchFrom = nil
                    if created { onFinished() }
                }
            }
        }
        .sheet(item: $settingUpstream) { branch in
            NavigationStack { UpstreamSheet(model: model, branch: branch) { settingUpstream = nil } }
        }
        .alert("Rename Branch", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $renameText).plainTextEntry()
            Button("Rename") {
                if let branch = renaming { Task { await model.renameBranch(branch, to: renameText) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames the local branch \(renaming?.name ?? ""). Its upstream setting moves with it.")
        }
        .confirmationDialog("You have uncommitted changes", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
                            titleVisibility: .visible, presenting: switching) { branch in
            Button("Bring Changes to \(branch.isRemote ? branch.nameWithoutRemote : branch.name)") {
                Task { await model.checkout(branch, strategy: .carry); finishIfSwitched(branch) }
            }
            Button("Stash Changes and Switch") {
                Task { await model.checkout(branch, strategy: .stash); finishIfSwitched(branch) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Bring them along (refused if a changed file differs between the branches), or stash them; pop the stash later from Source Control.")
        }
        .confirmationDialog("Delete branch?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { branch in
            if branch.isRemote {
                Button("Delete \(branch.nameWithoutRemote) on \(branch.remoteName ?? "the remote")", role: .destructive) {
                    Task { await model.deleteRemoteBranch(branch) }
                }
                Button("Forget the Remote-Tracking Branch Only") { Task { await model.deleteBranch(branch) } }
            } else {
                Button("Delete \(branch.name)", role: .destructive) { Task { await model.deleteBranch(branch) } }
                Button("Force Delete (unmerged commits are lost)", role: .destructive) { Task { await model.deleteBranch(branch, force: true) } }
                if let upstream = branch.upstream {
                    Button("Delete \(upstream) on the Remote Too", role: .destructive) {
                        Task {
                            await model.deleteRemoteBranch(branch)
                            if model.errorMessage == nil { await model.deleteBranch(branch, force: true) }
                        }
                    }
                }
            }
        } message: { branch in
            Text(branch.isRemote ? "Deleting on the remote affects everyone using it." : "Delete refuses a branch whose commits are not merged into HEAD or its upstream.")
        }
        .confirmationDialog("Publish to which remote?", isPresented: Binding(get: { publishing != nil }, set: { if !$0 { publishing = nil } }),
                            titleVisibility: .visible, presenting: publishing) { branch in
            ForEach(model.remotes) { remote in
                Button(remote.name) { Task { await model.publish(branch, to: remote.name) } }
            }
        }
    }

    private var remoteNames: [String] {
        Array(Set(model.remoteBranches.compactMap(\.remoteName))).sorted()
    }

    private func filtered(remote: Bool) -> [Branch] {
        model.branches.filter { $0.isRemote == remote && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
    }

    private func finishIfSwitched(_ branch: Branch) {
        let name = branch.isRemote ? branch.nameWithoutRemote : branch.name
        if model.head?.branch == name { onFinished() }
    }

    private func requestSwitch(_ branch: Branch) {
        if model.hasChanges {
            switching = branch
        } else {
            Task { await model.checkout(branch); finishIfSwitched(branch) }
        }
    }

    private func publish(_ branch: Branch) {
        if model.remotes.count == 1, let remote = model.remotes.first {
            Task { await model.publish(branch, to: remote.name) }
        } else if model.remotes.isEmpty {
            model.errorMessage = "This repository has no remote. Add one with `git remote add` in the terminal."
        } else {
            publishing = branch
        }
    }

    private func localRow(_ branch: Branch) -> some View {
        Button {
            requestSwitch(branch)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: branch.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .foregroundStyle(branch.isHead ? theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(branch.name).foregroundStyle(.primary).fontWeight(branch.isHead ? .semibold : .regular)
                    if let upstream = branch.upstream {
                        Text(upstream).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Not published").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                AheadBehind(ahead: branch.ahead, behind: branch.behind)
            }
        }
        .accessibilityIdentifier("git.branch.\(branch.name)")
        .contextMenu { localMenu(branch) }
        .swipeActions {
            if !branch.isHead {
                Button("Delete", role: .destructive) { deleting = branch }
            }
            Button("Rename") { renameText = branch.name; renaming = branch }.tint(.orange)
        }
    }

    @ViewBuilder
    private func localMenu(_ branch: Branch) -> some View {
        if !branch.isHead {
            Button("Switch to \(branch.name)", systemImage: "arrow.right.circle") { requestSwitch(branch) }
        }
        Button("New Branch from Here…", systemImage: "plus") { newBranchFrom = branch.name }
        Button("Rename…", systemImage: "pencil") { renameText = branch.name; renaming = branch }
        Divider()
        if branch.upstream == nil {
            Button("Publish Branch", systemImage: "icloud.and.arrow.up") { publish(branch) }
        } else if branch.ahead > 0 {
            Button("Push \(branch.ahead) Commit\(branch.ahead == 1 ? "" : "s")", systemImage: "arrow.up.circle") {
                Task { await model.push(branch) }
            }
        }
        Button("Set Upstream…", systemImage: "link") { settingUpstream = branch }
        if branch.isHead, let onCreatePullRequest {
            Button("Create Pull Request…", systemImage: "arrow.triangle.pull") { onCreatePullRequest() }
        }
        if !branch.isHead {
            Button("Merge into \(model.head?.branch ?? "Current Branch")", systemImage: "arrow.triangle.merge") {
                Task { await model.merge(branch) }
            }
        }
        Divider()
        if !branch.isHead {
            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = branch }
        }
        if branch.upstream != nil {
            Button("Delete on Remote…", systemImage: "icloud.slash", role: .destructive) {
                Task { await model.deleteRemoteBranch(branch) }
            }
        }
    }

    private func remoteRow(_ branch: Branch) -> some View {
        Button {
            requestSwitch(branch)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "cloud").foregroundStyle(.secondary)
                Text(branch.nameWithoutRemote).foregroundStyle(.primary)
                Spacer()
                if model.localBranches.contains(where: { $0.upstream == branch.name }) {
                    Text("tracked").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityIdentifier("git.remoteBranch.\(branch.name)")
        .contextMenu {
            Button("Check Out as Local Branch", systemImage: "arrow.down.circle") { requestSwitch(branch) }
            Button("New Branch from Here…", systemImage: "plus") { newBranchFrom = branch.name }
            Button("Merge into \(model.head?.branch ?? "Current Branch")", systemImage: "arrow.triangle.merge") {
                Task { await model.merge(branch) }
            }
            Divider()
            Button("Delete on \(branch.remoteName ?? "Remote")…", systemImage: "trash", role: .destructive) { deleting = branch }
        }
    }
}

private struct StartPoint: Identifiable {
    let revision: String
    var id: String { revision }
}

/// "3↑ 1↓" against the upstream.
struct AheadBehind: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: 6) {
            if behind > 0 { Text("\(behind)↓").accessibilityLabel("\(behind) behind") }
            if ahead > 0 { Text("\(ahead)↑").accessibilityLabel("\(ahead) ahead") }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// A new branch: name, start point (HEAD, any branch, or a commit) and
/// whether to switch to it.
struct NewBranchSheet: View {
    @Bindable var model: SourceControlModel
    @State var startPoint: String
    var done: (Bool) -> Void
    @State private var name = ""
    @State private var commit = ""
    @State private var useCommit = false
    @State private var checkout = true

    var body: some View {
        Form {
            Section {
                TextField("Branch name", text: $name)
                    .plainTextEntry()
                    .accessibilityIdentifier("git.newBranch.name")
                if !name.isEmpty && !GitRepository.isValidBranchName(name) {
                    Text("Not a valid branch name (no spaces, “..”, “~”, “^”, “:” or a trailing “/”).")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Section("Start Point") {
                Toggle("A Specific Commit", isOn: $useCommit)
                if useCommit {
                    TextField("Commit ID, tag or revision (e.g. HEAD~2)", text: $commit)
                        .plainTextEntry()
                        .font(.body.monospaced())
                        .accessibilityIdentifier("git.newBranch.commit")
                } else {
                    Picker("From", selection: $startPoint) {
                        Text("Current HEAD\(model.head?.branch.map { " (\($0))" } ?? "")").tag("HEAD")
                        ForEach(model.localBranches) { Text($0.name).tag($0.name) }
                        ForEach(model.remoteBranches) { Text($0.name).tag($0.name) }
                    }
                }
            }
            Section {
                Toggle("Switch to the New Branch", isOn: $checkout)
            } footer: {
                if checkout && model.hasChanges {
                    Text("Uncommitted changes come along to the new branch.")
                }
            }
            ErrorBanner(message: $model.errorMessage)
        }
        .navigationTitle("New Branch")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(false) } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    Task {
                        let from = useCommit ? commit.trimmingCharacters(in: .whitespaces) : startPoint
                        if await model.createBranch(name, from: from, checkout: checkout) { done(true) }
                    }
                }
                .disabled(!GitRepository.isValidBranchName(name.trimmingCharacters(in: .whitespaces))
                          || (useCommit && commit.trimmingCharacters(in: .whitespaces).isEmpty))
                .accessibilityIdentifier("git.newBranch.create")
            }
        }
    }
}

/// Picks the remote branch a local branch tracks.
struct UpstreamSheet: View {
    @Bindable var model: SourceControlModel
    let branch: Branch
    var done: () -> Void

    var body: some View {
        List {
            Section {
                Button {
                    Task { await model.setUpstream(branch, to: nil); done() }
                } label: {
                    HStack {
                        Text("None")
                        Spacer()
                        if branch.upstream == nil { Image(systemName: "checkmark") }
                    }
                }
            }
            Section("Remote Branches") {
                ForEach(model.remoteBranches) { remote in
                    Button {
                        Task { await model.setUpstream(branch, to: remote.name); done() }
                    } label: {
                        HStack {
                            Text(remote.name)
                            Spacer()
                            if branch.upstream == remote.name { Image(systemName: "checkmark") }
                        }
                    }
                }
                if model.remoteBranches.isEmpty {
                    Text("No remote branches. Fetch, or publish the branch instead.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Upstream of \(branch.name)")
        .inlineTitle()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) } }
    }
}
