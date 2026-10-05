import SwiftUI
import Observation
import StudioCore
import StudioDesign
import GitKit
import Forge
import StudioGitUI

/// Source control through StudioGit: libgit2 (GitKit) for repositories,
/// Forge for GitHub and GitLab accounts, StudioGitUI for the panel, the
/// Git workbench (changes, history, branches, pull requests) and cloning.
///
/// Sign-in works without OAuth client IDs: the sign-in screen then offers a
/// personal access token (and a field to enter a client ID later).
@MainActor
@Observable
final class StudioGitProvider: GitProviding {
    let id = "com.geramyloveless.LemonSeedStudio.git"
    let displayName = "Git (libgit2)"
    let services = GitServices.standard()

    @ObservationIgnored private var models: [URL: SourceControlModel] = [:]

    init() {
        #if DEBUG
        GitSampleMode.installIfRequested(services)
        #endif
    }

    func status(for root: URL) async -> GitStatusSummary? {
        guard let repository = try? GitRepository.open(at: root, search: true) else { return nil }
        let head = try? await repository.head()
        let branch = try? await repository.currentBranch()
        let entries = (try? await repository.status()) ?? []
        var changes: [GitStatusSummary.Change] = []
        for entry in entries {
            if entry.isConflicted {
                changes.append(.init(path: entry.path, kind: .conflicted, staged: false))
                continue
            }
            if let staged = entry.staged, let kind = Self.kind(staged) {
                changes.append(.init(path: entry.path, kind: kind, staged: true))
            }
            if let unstaged = entry.unstaged, let kind = Self.kind(unstaged) {
                changes.append(.init(path: entry.path, kind: kind, staged: false))
            }
        }
        let detachedAt = head?.isDetached == true ? head?.commit.map { String($0.description.prefix(7)) } : nil
        return GitStatusSummary(branch: head?.branch, detachedAt: detachedAt,
                                ahead: branch?.upstream != nil ? branch?.ahead : nil,
                                behind: branch?.upstream != nil ? branch?.behind : nil,
                                changes: changes)
    }

    private static func kind(_ change: FileChange) -> GitStatusSummary.ChangeKind? {
        switch change {
        case .added: .added
        case .modified, .typeChanged: .modified
        case .deleted: .deleted
        case .renamed: .renamed
        case .untracked: .untracked
        case .conflicted: .conflicted
        case .ignored: nil
        }
    }

    func model(for root: URL) -> SourceControlModel? {
        if let model = models[root] { return model }
        guard let repository = try? GitRepository.open(at: root, search: true) else { return nil }
        let model = SourceControlModel(repository: repository, services: services)
        models[root] = model
        return model
    }

    func forget(_ root: URL) { models[root] = nil }

    func makeSourceControlView(context: any WorkspaceContext) -> AnyView {
        AnyView(GitSidebar(provider: self, context: context))
    }
}

/// A Git screen a workspace window presents over its content.
enum GitSheetRequest: Identifiable, Equatable {
    /// The workbench at a tab, optionally showing one changed file or
    /// opening the pull request composer.
    case workbench(GitWorkbenchModel.Tab, path: String? = nil, staged: Bool = false, compose: Bool = false)
    /// The repository browser and clone by URL.
    case clone

    var id: String {
        switch self {
        case .workbench(let tab, let path, let staged, let compose): "workbench.\(tab.rawValue).\(path ?? "").\(staged).\(compose)"
        case .clone: "clone"
        }
    }

    /// `-StudioGitSheet history|branches|pullRequests|changes|compose|clone` (automation).
    init?(launchValue: String) {
        switch launchValue {
        case "clone": self = .clone
        case "compose": self = .workbench(.pullRequests, compose: true)
        default:
            guard let tab = GitWorkbenchModel.Tab(rawValue: launchValue) else { return nil }
            self = .workbench(tab)
        }
    }
}

/// The Source Control sidebar: the change list and commit box, with the
/// workbench (diffs, merge editor, history, branches, requests) one tap away.
private struct GitSidebar: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let provider: StudioGitProvider
    let context: any WorkspaceContext
    @State private var model: SourceControlModel?
    @State private var checked = false
    @State private var showAccounts = false
    @State private var error: String?

    private var controller: WorkspaceController? { context as? WorkspaceController }

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                shortcuts
                Hairline()
                SourceControlView(model: model,
                                  onOpenChange: { path, staged in controller?.gitSheet = .workbench(.changes, path: path, staged: staged) },
                                  onCreatePullRequest: { controller?.gitSheet = .workbench(.pullRequests, compose: true) })
                    .scrollContentBackground(.hidden)
                    .task { await model.refresh() }
            } else if checked {
                noRepository
            } else {
                ProgressView().padding()
            }
            Spacer(minLength: 0)
            Hairline()
            HStack(spacing: Space.s) {
                Button {
                    showAccounts = true
                } label: {
                    Label("Accounts", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("git.accounts")
                Spacer()
                Button {
                    controller?.gitSheet = .clone
                } label: {
                    Label("Clone…", systemImage: "square.and.arrow.down.on.square")
                }
                .accessibilityIdentifier("git.clone")
            }
            .font(.studio(type.caption, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.accent.color)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
        .gitTheme(GitTheme.studio(theme))
        .task(id: context.rootURL) {
            model = provider.model(for: context.rootURL)
            checked = true
        }
        .sheet(isPresented: $showAccounts, onDismiss: { provider.services.accountsDidChange() }) {
            NavigationStack {
                AccountsView(services: provider.services)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showAccounts = false } }
                    }
            }
        }
    }

    /// History, branches and requests, as buttons above the change list.
    private var shortcuts: some View {
        HStack(spacing: Space.xs) {
            shortcut("History", symbol: GitWorkbenchModel.Tab.history.symbol, id: "git.open.history") {
                controller?.gitSheet = .workbench(.history)
            }
            shortcut("Branches", symbol: GitWorkbenchModel.Tab.branches.symbol, id: "git.open.branches") {
                controller?.gitSheet = .workbench(.branches)
            }
            shortcut("Requests", symbol: GitWorkbenchModel.Tab.pullRequests.symbol, id: "git.open.pullRequests") {
                controller?.gitSheet = .workbench(.pullRequests)
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
    }

    private func shortcut(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.studio(type.micro + 1, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.palette.accent.color)
        .hoverEffect(.highlight)
        .accessibilityIdentifier(id)
    }

    private var noRepository: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("This folder is not a Git repository.")
                .font(.studio(type.body, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary.color)
            Text("Initialize one here, or clone a repository from GitHub or GitLab. Sign in under Accounts to browse your repositories.")
                .font(.studio(type.caption))
                .foregroundStyle(theme.palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                do {
                    _ = try GitRepository.create(at: context.rootURL)
                    provider.forget(context.rootURL)
                    model = provider.model(for: context.rootURL)
                } catch {
                    self.error = error.localizedDescription
                }
            } label: {
                Label("Initialize Repository", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.studioPrimary)
            .accessibilityIdentifier("git.init")
            Button {
                controller?.gitSheet = .clone
            } label: {
                Label("Clone a Repository…", systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(.studioSecondary)
            .accessibilityIdentifier("git.cloneInstead")
            if let error {
                Text(error)
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.error.color)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The workbench for a workspace's repository, in a page sheet.
struct GitWorkbenchSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let provider: StudioGitProvider
    let controller: WorkspaceController
    let request: GitSheetRequest
    @State private var model: GitWorkbenchModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    GitWorkbenchView(model: model)
                } else {
                    ContentUnavailableView("Not a Git repository", systemImage: "folder.badge.questionmark",
                                           description: Text("\(controller.displayName) is not in a Git repository."))
                }
            }
            .navigationTitle(model?.sourceControl.name ?? "Source Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("git.workbench.done")
                }
            }
        }
        .gitTheme(GitTheme.studio(theme))
        .task {
            guard model == nil, case .workbench(let tab, let path, let staged, let compose) = request,
                  let sourceControl = provider.model(for: controller.rootURL) else { return }
            let workbench = GitWorkbenchModel(sourceControl: sourceControl, tab: tab)
            model = workbench
            if let path { await workbench.showChange(path, staged: staged) }
            if compose { workbench.composePullRequest() }
            #if DEBUG
            await GitSampleMode.applySelection(to: workbench)
            #endif
        }
        .onDisappear {
            // The sidebar opens the workbench on selection; start fresh.
            model?.sourceControl.selection = nil
            Task { await controller.refreshGitStatus() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git.workbench")
    }
}

/// The repository browser and clone by URL; opens the clone when done.
struct GitCloneSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let provider: StudioGitProvider
    let library: WorkspaceLibrary
    let onOpen: (WorkspaceReference) -> Void
    @State private var model: RepositoryBrowserModel?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    RepositoryBrowserView(model: model) { repository in
                        guard let folder = repository.workingDirectory else { return }
                        do {
                            // Within the app's Projects this is a project;
                            // elsewhere a bookmark (the folder was picked in Files).
                            let reference = try library.addFolder(folder)
                            dismiss()
                            onOpen(reference)
                        } catch {
                            self.error = "Cloned into \(folder.path), but it could not be opened: \(error.localizedDescription)"
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(model?.isCloning ?? false)
                        .accessibilityIdentifier("git.cloneSheet.close")
                }
            }
            .alert("Cannot open the clone", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
        .gitTheme(GitTheme.studio(theme))
        .task {
            if model == nil {
                model = RepositoryBrowserModel(services: provider.services, appFolder: library.projectsFolder)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git.cloneSheet")
    }
}

extension GitTheme {
    static func studio(_ theme: Theme) -> GitTheme {
        let p = theme.palette
        var t = GitTheme()
        t.accent = p.accent.color
        t.added = p.added.color
        t.modified = p.modified.color
        t.deleted = p.deleted.color
        t.secondaryText = p.textSecondary.color
        t.selectionBackground = p.selection.color
        return t
    }
}

#if DEBUG
/// Offline sample data for screenshots and UI checks, only with
/// `-StudioGitSample YES` in a Debug build: a sample GitHub account and
/// client, and with `-StudioGitSampleProject name` a sample repository in
/// Projects whose origin is the sample client's repository (on the branch
/// `-StudioGitSampleBranch`, mid-merge with `-StudioGitSampleConflict YES`).
enum GitSampleMode {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "StudioGitSample") }

    @MainActor
    static func installIfRequested(_ services: GitServices) {
        guard isEnabled else { return }
        let client = SampleForgeClient()
        services.sampleForge = ([SampleForgeClient.sampleAccount], { _ in client })
        if services.authorName.isEmpty {
            services.authorName = "Alice Moreau"
            services.authorEmail = "alice@example.com"
        }
    }

    /// `-StudioGitSelect`: a request number, a changed file's path, or
    /// "merge" (the first merge commit in History), for screenshots.
    @MainActor
    static func applySelection(to workbench: GitWorkbenchModel) async {
        guard let value = UserDefaults.standard.string(forKey: "StudioGitSelect") else { return }
        switch workbench.tab {
        case .pullRequests:
            await workbench.preparePullRequests()
            guard let list = workbench.pullList, let number = Int(value) else { return }
            await list.load()
            workbench.pullSelection = list.requests.first { $0.number == number }
        case .history:
            let history = workbench.historyModel()
            await history.load()
            if let merge = history.rows.first(where: { value == "merge" ? $0.commit.isMerge : $0.commit.id.hex.hasPrefix(value) }) {
                await history.select(merge.commit.id)
            }
        case .changes:
            await workbench.showChange(value)
        case .branches:
            break
        }
    }

    /// Creates the sample project before the first window opens it
    /// (`-StudioOpenProject name`). Blocks launch briefly; automation only.
    @MainActor
    static func makeSampleProject(in library: WorkspaceLibrary) {
        guard isEnabled, let name = UserDefaults.standard.string(forKey: "StudioGitSampleProject") else { return }
        let url = library.projectsFolder.appendingPathComponent(name)
        let conflict = UserDefaults.standard.bool(forKey: "StudioGitSampleConflict")
        let branch = UserDefaults.standard.string(forKey: "StudioGitSampleBranch")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let repo = try await SampleRepository.make(at: url, withConflict: conflict)
                try await repo.addRemote("origin", url: "https://github.com/lemonade-sdk/amdgpu_mtopg.git")
                if let branch { try await repo.createBranch(branch, checkout: true) }
            } catch {
                print("StudioGitSample: could not create \(url.path): \(error)")
            }
            done.signal()
        }
        done.wait()
    }
}
#endif
