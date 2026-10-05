public import SwiftUI
public import Observation
public import GitKit
public import Forge

/// Everything for one repository on one screen: changes with the diff and
/// merge-conflict editors, the history graph with commit diffs, branches,
/// and pull/merge requests.
@MainActor
@Observable
public final class GitWorkbenchModel {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case changes, history, branches, pullRequests
        public var id: Self { self }
        public var title: String {
            switch self {
            case .changes: return "Changes"
            case .history: return "History"
            case .branches: return "Branches"
            case .pullRequests: return "Pull Requests"
            }
        }
        public var symbol: String {
            switch self {
            case .changes: return "plusminus.circle"
            case .history: return "point.3.connected.trianglepath.dotted"
            case .branches: return "arrow.triangle.branch"
            case .pullRequests: return "arrow.triangle.pull"
            }
        }
    }

    public let sourceControl: SourceControlModel
    public let hosting: RepositoryHosting
    public var tab: Tab
    public private(set) var history: HistoryModel?
    public private(set) var pullList: PullRequestListModel?
    public var pullSelection: PullRequest? {
        didSet { if oldValue?.id != pullSelection?.id { makePullDetail() } }
    }
    public private(set) var pullDetail: PullRequestDetailModel?
    public var composer: PullRequestComposerModel?

    public init(sourceControl: SourceControlModel, tab: Tab = .changes) {
        self.sourceControl = sourceControl
        self.hosting = RepositoryHosting(repository: sourceControl.repository, services: sourceControl.services)
        self.tab = tab
    }

    public var services: GitServices { sourceControl.services }

    public func historyModel() -> HistoryModel {
        if let history { return history }
        let model = HistoryModel(repository: sourceControl.repository)
        history = model
        return model
    }

    /// Resolves the forge and builds the request list for the pull target.
    public func preparePullRequests() async {
        await hosting.resolve()
        rebuildPullList()
    }

    public func selectPullTarget(_ name: String) async {
        await hosting.selectPullTarget(name)
        pullSelection = nil
        rebuildPullList()
    }

    private func rebuildPullList() {
        guard let client = hosting.client, let target = hosting.pullTarget else { pullList = nil; return }
        if pullList?.repository != target.repository || pullList?.client.host != client.host {
            pullList = PullRequestListModel(client: client, repository: target.repository)
        }
    }

    private func makePullDetail() {
        guard let pr = pullSelection, let list = pullList else { pullDetail = nil; return }
        pullDetail = PullRequestDetailModel(client: list.client, repository: pr.repository.isEmpty ? (list.repository ?? "") : pr.repository,
                                            number: pr.number, settings: hosting.settings, currentUser: hosting.currentUser)
    }

    /// Opens the composer for the current branch.
    public func composePullRequest() {
        tab = .pullRequests
        composer = PullRequestComposerModel(sourceControl: sourceControl, hosting: hosting)
    }

    /// Shows a changed (or conflicted) file in the Changes tab.
    public func showChange(_ path: String, staged: Bool = false) async {
        tab = .changes
        await sourceControl.refresh()
        let entries = staged ? sourceControl.staged : sourceControl.unstaged + sourceControl.conflicted
        if let entry = entries.first(where: { $0.path == path }) {
            await sourceControl.select(entry, staged: staged)
        }
    }
}

public struct GitWorkbenchView: View {
    @Bindable var model: GitWorkbenchModel
    @State private var signingIn: SignInModel?
    @Environment(\.gitTheme) private var theme

    public init(model: GitWorkbenchModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $model.tab) {
                ForEach(GitWorkbenchModel.Tab.allCases) { tab in
                    Label(tab == .pullRequests ? model.hosting.requestNoun.capitalized + "s" : tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("git.workbench.tabs")
            Divider()
            Group {
                switch model.tab {
                case .changes:
                    SourceControlWorkspaceView(model: model.sourceControl)
                case .history:
                    HistoryGraphView(model: model.historyModel())
                case .branches:
                    BranchManagerView(model: model.sourceControl, onCreatePullRequest: { model.composePullRequest() })
                case .pullRequests:
                    pullRequests
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.preparePullRequests() }
        .sheet(item: Binding(get: { model.composer.map(IdentifiedComposer.init) }, set: { model.composer = $0?.model })) { item in
            NavigationStack {
                PullRequestComposerView(model: item.model) { created in
                    model.composer = nil
                    if let created {
                        Task {
                            await model.pullList?.set(state: .open, scope: .all)
                            model.pullSelection = created
                        }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { signingIn.map(SignInItem.init) }, set: { signingIn = $0?.model })) { item in
            NavigationStack {
                SignInView(model: item.model) { _ in
                    signingIn = nil
                    model.services.accountsDidChange()
                    Task { await model.preparePullRequests() }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { item.model.cancel(); signingIn = nil } }
                }
            }
        }
    }

    @ViewBuilder
    private var pullRequests: some View {
        switch model.hosting.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noForgeRemote:
            ContentUnavailableView {
                Label("No GitHub or GitLab remote", systemImage: "network.slash")
            } description: {
                Text("Pull and merge requests need a remote on GitHub or GitLab (GitHub Enterprise and self-hosted GitLab work too). Add one with `git remote add origin <url>` in the terminal, or publish this repository from GitHub or GitLab and clone it.")
            }
        case .notSignedIn(let hostnames):
            ContentUnavailableView {
                Label("Sign in to \(hostnames.joined(separator: " or "))", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("This repository's remotes are on \(hostnames.joined(separator: ", ")), and no account for \(hostnames.count == 1 ? "it" : "them") is signed in.")
            } actions: {
                ForEach(hostnames, id: \.self) { host in
                    Button("Sign In to \(host)…") { signingIn = Self.signInModel(for: host, services: model.services) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("git.pulls.signIn")
        case .failed(let message):
            ContentUnavailableView("Cannot read the remotes", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready:
            if let list = model.pullList {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        pullHeader
                        Divider()
                        PullRequestListView(model: list, selection: $model.pullSelection)
                    }
                    .frame(width: 380)
                    Divider()
                    if let detail = model.pullDetail {
                        PullRequestDetailView(model: detail, checkout: model.hosting.pullTarget.map { (model.sourceControl, $0.name) })
                            .id(detail.number)
                    } else {
                        ContentUnavailableView("Select a \(model.hosting.requestNoun)", systemImage: "arrow.triangle.pull")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var pullHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let reachable = model.hosting.remotes.filter { $0.account != nil }
                if reachable.count > 1 {
                    Menu {
                        ForEach(reachable) { remote in
                            Button("\(remote.name) · \(remote.repository)") { Task { await model.selectPullTarget(remote.name) } }
                        }
                    } label: {
                        Label(model.hosting.pullTarget?.repository ?? "", systemImage: "server.rack")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if let target = model.hosting.pullTarget {
                    Label(target.repository, systemImage: "server.rack").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    model.composePullRequest()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.sourceControl.currentBranch == nil || model.hosting.settings.map { !$0.canPush && model.hosting.pushRemote?.name == model.hosting.pullTarget?.name } ?? false)
                .accessibilityIdentifier("git.pulls.new")
            }
            if let settings = model.hosting.settings {
                Text("Your access: \(settings.permission.displayName)\(settings.isArchived ? " · archived" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.hosting.settingsError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    static func signInModel(for hostname: String, services: GitServices) -> SignInModel {
        let model = SignInModel(accounts: services.accounts)
        if let target = RepositoryHosting.signInTarget(for: hostname) {
            model.target = target
        } else {
            model.target = .selfHostedGitLab
            model.serverURL = "https://\(hostname)"
        }
        return model
    }
}

private struct IdentifiedComposer: Identifiable {
    let model: PullRequestComposerModel
    var id: ObjectIdentifier { ObjectIdentifier(model) }
}

private struct SignInItem: Identifiable {
    let model: SignInModel
    var id: ObjectIdentifier { ObjectIdentifier(model) }
}
