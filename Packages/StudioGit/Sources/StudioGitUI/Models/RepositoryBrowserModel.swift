public import Foundation
public import Observation
public import GitKit
public import Forge

/// Lists an account's repositories (theirs, collaborations and their
/// organizations' or groups'), filters and searches them, and clones.
@MainActor
@Observable
public final class RepositoryBrowserModel {
    public let services: GitServices
    public let folders: SavedFolderStore
    /// Where "On My iPad" clones go.
    public let appFolder: URL
    @ObservationIgnored let makeClient: (ForgeAccount) -> any ForgeClient
    @ObservationIgnored let fixedAccounts: [ForgeAccount]?

    public private(set) var accounts: [ForgeAccount] = []
    public private(set) var hasLoadedAccounts = false
    public var account: ForgeAccount?
    /// Owners to filter by: the user, then their organizations or groups.
    public private(set) var organizations: [ForgeOrganization] = []
    public private(set) var scope: RepositoryScope = .all
    public private(set) var repositories: [ForgeRepository] = []
    public private(set) var searchResults: [ForgeRepository]?
    public var query = ""
    public var showForks = true
    public var showArchived = false
    public private(set) var isLoading = false
    public private(set) var nextCursor: String?
    public var errorMessage: String?

    public struct CloneJob: Identifiable, Equatable {
        public let id = UUID()
        public var repository: String
        public var progress: TransferProgress
        public var destination: URL?
        public var finished = false
    }
    public private(set) var cloneJob: CloneJob?
    @ObservationIgnored private var cloneTask: Task<GitRepository?, Never>?

    /// - Parameters:
    ///   - appFolder: the app's own folder for clones (the Studio's Projects).
    ///   - makeClient: overrides the client per account (sample data, tests).
    ///   - fixedAccounts: accounts to list instead of the signed-in ones.
    public init(services: GitServices, folders: SavedFolderStore = SavedFolderStore(),
                appFolder: URL = CloneLocation.workspacesDirectory,
                makeClient: ((ForgeAccount) -> any ForgeClient)? = nil, fixedAccounts: [ForgeAccount]? = nil) {
        self.services = services
        self.folders = folders
        self.appFolder = appFolder
        self.fixedAccounts = fixedAccounts
        self.makeClient = makeClient ?? { [services] in services.client(for: $0) }
    }

    /// Whether to show the sign-in prompt instead of a list.
    public var needsSignIn: Bool { hasLoadedAccounts && accounts.isEmpty }

    public var visibleRepositories: [ForgeRepository] {
        let base = searchResults ?? repositories
        return base.filter { repo in
            (showForks || !repo.isFork) && (showArchived || !repo.isArchived)
                && (searchResults != nil || query.isEmpty || repo.fullName.localizedCaseInsensitiveContains(query)
                    || (repo.description?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    /// The owner filter's choices as scopes with titles.
    public var scopeChoices: [(scope: RepositoryScope, title: String)] {
        guard let account else { return [] }
        return [(.all, "All Repositories"), (.owned, account.user.login)]
            + organizations.map { (.organization($0.login), $0.login) }
    }

    public var scopeTitle: String {
        scopeChoices.first { $0.scope == scope }?.title ?? "All Repositories"
    }

    public func load() async {
        if let fixedAccounts {
            accounts = fixedAccounts
        } else {
            accounts = await services.allAccounts()
        }
        hasLoadedAccounts = true
        if account == nil || !accounts.contains(where: { $0.id == account?.id }) { account = accounts.first }
        await selectAccount(account)
    }

    public func selectAccount(_ account: ForgeAccount?) async {
        self.account = account
        scope = .all
        organizations = []
        repositories = []
        searchResults = nil
        nextCursor = nil
        guard let account else { return }
        let client = makeClient(account)
        do {
            organizations = try await client.organizations().sorted { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
        } catch {
            errorMessage = "Couldn't list the organizations of \(account.displayName): \(RepositoryHosting.describe(error))"
        }
        await reload()
    }

    public func selectScope(_ scope: RepositoryScope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        await reload()
        if searchResults != nil { await search() }
    }

    public func reload() async {
        guard let account else { repositories = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await makeClient(account).repositories(scope, cursor: nil)
            repositories = page.items
            nextCursor = page.nextCursor
            searchResults = nil
            errorMessage = nil
        } catch {
            repositories = []
            nextCursor = nil
            errorMessage = "Couldn't list repositories: \(RepositoryHosting.describe(error))"
        }
    }

    public func loadMore() async {
        guard let account, let cursor = nextCursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await makeClient(account).repositories(scope, cursor: cursor)
            let known = Set(repositories.map(\.id))
            repositories += page.items.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
        } catch {
            errorMessage = "Couldn't load more repositories: \(RepositoryHosting.describe(error))"
        }
    }

    /// Loads the next page when `repository` is near the end of the list.
    public func loadMoreIfNeeded(after repository: ForgeRepository) async {
        guard searchResults == nil, nextCursor != nil, !isLoading else { return }
        let visible = visibleRepositories
        guard let index = visible.firstIndex(where: { $0.id == repository.id }), index >= visible.count - 5 else { return }
        await loadMore()
    }

    /// Searches the forge within the selected owner (the whole forge for
    /// "All Repositories").
    public func search() async {
        guard let account, !query.trimmingCharacters(in: .whitespaces).isEmpty else { searchResults = nil; return }
        isLoading = true
        defer { isLoading = false }
        do {
            searchResults = try await makeClient(account).searchRepositories(query, scope: scope)
            errorMessage = nil
        } catch {
            errorMessage = "Search failed: \(RepositoryHosting.describe(error))"
        }
    }

    public func clearSearch() {
        searchResults = nil
    }

    public func accountsChanged() async {
        services.accountsDidChange()
        await load()
    }

    // MARK: Cloning

    public struct CloneRequest: Sendable {
        /// What the clone is called in progress and errors (`owner/name`).
        public var displayName: String
        public var httpsURL: String
        public var sshURL: String?
        public var useSSH = false
        public var location: CloneLocation = .appContainer
        public var folderName: String
        public var shallow = false
        public var depth = 1
        public var submodules = true
        public var lfs = true
        /// The account to remember for the clone (`studio.account`).
        public var accountID: UUID?

        public init(repository: ForgeRepository, accountID: UUID? = nil) {
            displayName = repository.fullName
            httpsURL = repository.httpsCloneURL
            sshURL = repository.sshCloneURL
            folderName = repository.name
            self.accountID = accountID
        }

        /// A clone by URL (`https://…`, `ssh://…` or `git@host:owner/name.git`).
        public init(url: String) {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSSH = trimmed.hasPrefix("ssh://") || (!trimmed.contains("://") && trimmed.contains("@"))
            displayName = ForgeRemoteReference.parse(trimmed)?.fullName ?? trimmed
            httpsURL = isSSH ? "" : trimmed
            sshURL = isSSH ? trimmed : nil
            useSSH = isSSH
            folderName = Self.folderName(for: trimmed)
        }

        public var url: String { useSSH ? (sshURL ?? "") : httpsURL }

        /// `https://host/owner/name.git` → `name`.
        public static func folderName(for url: String) -> String {
            var last = url.trimmingCharacters(in: .whitespacesAndNewlines)
            while last.hasSuffix("/") { last.removeLast() }
            last = String(last.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
            if last.hasSuffix(".git") { last.removeLast(4) }
            return last
        }

        /// Why the request cannot run, or nil.
        public var problem: String? {
            if url.isEmpty { return useSSH ? "This repository has no SSH URL." : "Enter a repository URL." }
            if !url.contains("://") && !url.contains("@") && !url.hasPrefix("/") { return "Enter an https://, ssh:// or git@host:owner/name URL." }
            if folderName.isEmpty || folderName.contains("/") || folderName.hasPrefix(".") { return "Enter a folder name." }
            return nil
        }
    }

    /// Clones and returns the repository; progress is in `cloneJob`.
    /// Cancel with `cancelClone()`: the partial folder is removed.
    @discardableResult
    public func clone(_ request: CloneRequest) async -> GitRepository? {
        if let problem = request.problem {
            errorMessage = problem
            return nil
        }
        let task = Task { await self.performClone(request) }
        cloneTask = task
        let result = await task.value
        cloneTask = nil
        return result
    }

    public var isCloning: Bool { cloneTask != nil }

    public func cancelClone() {
        cloneTask?.cancel()
    }

    private func performClone(_ request: CloneRequest) async -> GitRepository? {
        cloneJob = CloneJob(repository: request.displayName, progress: TransferProgress(phase: .connecting))
        errorMessage = nil
        let services = self.services
        let accountID = request.accountID ?? account?.id
        var createdDestination: URL?
        do {
            let repo = try await request.location.withDirectory(folders, appFolder: appFolder) { parent in
                let destination = parent.appending(path: request.folderName, directoryHint: .isDirectory)
                cloneJob?.destination = destination
                if !FileManager.default.fileExists(atPath: destination.path) { createdDestination = destination }
                var options = CloneOptions(url: request.url, destination: destination,
                                           depth: request.shallow ? max(request.depth, 1) : nil,
                                           recurseSubmodules: request.submodules)
                options.lfs = request.lfs
                let network = await services.network(for: nil) { [weak self] p in
                    Task { @MainActor in self?.cloneJob?.progress = p }
                }
                do {
                    let repo = try await GitRepository.clone(options, network: network)
                    if let accountID { try await repo.setForgeAccount(accountID) }
                    return repo
                } catch {
                    // A cancelled clone leaves nothing behind; a failed one
                    // keeps its folder so cloning again resumes it.
                    if Task.isCancelled || (error as? GitError)?.code == .cancelled, let createdDestination {
                        try? FileManager.default.removeItem(at: createdDestination)
                    }
                    throw error
                }
            }
            cloneJob?.finished = true
            return repo
        } catch {
            if Task.isCancelled || (error as? GitError)?.code == .cancelled {
                errorMessage = "Clone cancelled."
            } else {
                errorMessage = "Couldn't clone \(request.displayName): \(RepositoryHosting.describe(error))"
                    + (createdDestination != nil ? " Cloning again into the same folder resumes." : "")
            }
            cloneJob = nil
            return nil
        }
    }

    public func dismissCloneJob() { cloneJob = nil }
}
