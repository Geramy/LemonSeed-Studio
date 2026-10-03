public import Foundation
public import Observation
public import GitKit
public import Forge

/// Lists an account's repositories, searches, and clones.
@MainActor
@Observable
public final class RepositoryBrowserModel {
    public let services: GitServices
    public let folders: SavedFolderStore
    @ObservationIgnored let makeClient: (ForgeAccount) -> any ForgeClient

    public private(set) var accounts: [ForgeAccount] = []
    public var account: ForgeAccount?
    public private(set) var repositories: [ForgeRepository] = []
    public private(set) var searchResults: [ForgeRepository]?
    public var query = ""
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

    public init(services: GitServices, folders: SavedFolderStore = SavedFolderStore(),
                makeClient: ((ForgeAccount) -> any ForgeClient)? = nil) {
        self.services = services
        self.folders = folders
        let accounts = services.accounts
        self.makeClient = makeClient ?? { accounts.client(for: $0) }
    }

    public var visibleRepositories: [ForgeRepository] {
        if let searchResults { return searchResults }
        guard !query.isEmpty else { return repositories }
        return repositories.filter { $0.fullName.localizedCaseInsensitiveContains(query) }
    }

    public func load() async {
        accounts = await services.accounts.accounts()
        if account == nil || !accounts.contains(where: { $0.id == account?.id }) { account = accounts.first }
        await reload()
    }

    public func reload() async {
        guard let account else { repositories = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await makeClient(account).repositories(cursor: nil)
            repositories = page.items
            nextCursor = page.nextCursor
            searchResults = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func loadMore() async {
        guard let account, let cursor = nextCursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await makeClient(account).repositories(cursor: cursor)
            repositories += page.items
            nextCursor = page.nextCursor
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Searches the whole forge (not only the user's repositories).
    public func search() async {
        guard let account, !query.trimmingCharacters(in: .whitespaces).isEmpty else { searchResults = nil; return }
        isLoading = true
        defer { isLoading = false }
        do {
            searchResults = try await makeClient(account).searchRepositories(query)
        } catch {
            errorMessage = "\(error)"
        }
    }

    public struct CloneRequest: Sendable {
        public var repository: ForgeRepository
        public var useSSH = false
        public var location: CloneLocation = .appContainer
        public var folderName: String
        public var shallow = false
        public var depth = 1
        public var submodules = true
        public var lfs = true
        public init(repository: ForgeRepository) {
            self.repository = repository
            self.folderName = repository.name
        }
    }

    /// Clones and returns the repository; progress is in `cloneJob`.
    @discardableResult
    public func clone(_ request: CloneRequest) async -> GitRepository? {
        cloneJob = CloneJob(repository: request.repository.fullName, progress: TransferProgress(phase: .connecting))
        let services = self.services
        let accountID = account?.id
        do {
            let repo = try await request.location.withDirectory(folders) { parent in
                let destination = parent.appending(path: request.folderName, directoryHint: .isDirectory)
                cloneJob?.destination = destination
                var options = CloneOptions(url: request.useSSH ? (request.repository.sshCloneURL ?? request.repository.httpsCloneURL)
                                                              : request.repository.httpsCloneURL,
                                           destination: destination,
                                           depth: request.shallow ? max(request.depth, 1) : nil,
                                           recurseSubmodules: request.submodules)
                options.lfs = request.lfs
                let network = await services.network(for: nil) { [weak self] p in
                    Task { @MainActor in self?.cloneJob?.progress = p }
                }
                let repo = try await GitRepository.clone(options, network: network)
                try await repo.setForgeAccount(accountID)
                return repo
            }
            cloneJob?.finished = true
            return repo
        } catch {
            errorMessage = (error as? any LocalizedError)?.errorDescription ?? "\(error)"
            cloneJob = nil
            return nil
        }
    }

    public func dismissCloneJob() { cloneJob = nil }
}
