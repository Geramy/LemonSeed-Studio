import SwiftUI
import Observation
import StudioCore
import StudioDesign
import GitKit
import Forge
import StudioGitUI

/// Source control through StudioGit: libgit2 (GitKit) for repositories,
/// Forge for GitHub and GitLab accounts, StudioGitUI for the panel.
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

private struct GitSidebar: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let provider: StudioGitProvider
    let context: any WorkspaceContext
    @State private var model: SourceControlModel?
    @State private var checked = false
    @State private var showAccounts = false
    @State private var showClone = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                SourceControlView(model: model)
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
                    showClone = true
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
        .sheet(isPresented: $showAccounts) {
            NavigationStack {
                AccountsView(services: provider.services)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showAccounts = false } }
                    }
            }
        }
        .sheet(isPresented: $showClone) {
            NavigationStack {
                RepositoryBrowserView(model: RepositoryBrowserModel(services: provider.services)) { repository in
                    showClone = false
                    if let folder = repository.workingDirectory {
                        context.log("Cloned into \(folder.path)", channel: "Git")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { showClone = false } }
                }
            }
        }
    }

    private var noRepository: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("This folder is not a Git repository.")
                .font(.studio(type.body, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary.color)
            Text("Initialize one here, or clone a repository from GitHub or GitLab. Sign in with a personal access token under Accounts.")
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
