public import Foundation
public import Observation
public import GitKit
public import Forge

/// Where a local repository is hosted: each remote read as a forge
/// repository, the signed-in account that can reach it, and the client to
/// talk to it. Pull requests use `pullTarget`; pushes use `pushRemote`.
@MainActor
@Observable
public final class RepositoryHosting {
    public struct Remote: Hashable, Identifiable, Sendable {
        /// The Git remote's name (`origin`, `upstream`).
        public var name: String
        public var url: String
        public var reference: ForgeRemoteReference
        /// The account serving the remote's host; nil when not signed in.
        public var account: ForgeAccount?
        public var id: String { name }

        /// `owner/name` on the forge (path prefix of the instance removed).
        public var repository: String {
            account.map { reference.repositoryPath(on: $0.host) } ?? reference.fullName
        }
    }

    public enum State: Equatable {
        case loading
        /// No remote, or none that looks like a forge repository.
        case noForgeRemote
        /// Remotes are on hosts with no signed-in account.
        case notSignedIn(hostnames: [String])
        case ready
        case failed(String)
    }

    public let repository: GitRepository
    public let services: GitServices
    public private(set) var state: State = .loading
    public private(set) var remotes: [Remote] = []
    /// The remote whose repository pull requests are listed and opened against.
    public private(set) var pullTargetName: String?
    public private(set) var settings: ForgeRepositorySettings?
    public private(set) var settingsError: String?
    public private(set) var currentUser: ForgeUser?

    public init(repository: GitRepository, services: GitServices) {
        self.repository = repository
        self.services = services
    }

    public var pullTarget: Remote? { remotes.first { $0.name == pullTargetName && $0.account != nil } }
    /// The remote new branches are pushed to: `origin` when it is a forge
    /// remote, else the pull target.
    public var pushRemote: Remote? { remotes.first { $0.name == "origin" && $0.account != nil } ?? pullTarget }
    public var client: (any ForgeClient)? { pullTarget?.account.map { services.client(for: $0) } }
    public var kind: ForgeKind? { pullTarget?.account?.host.kind }
    public var requestNoun: String { kind?.requestNoun ?? "pull request" }

    /// Reads the remotes and matches them to accounts.
    public func resolve() async {
        state = .loading
        do {
            let gitRemotes = try await repository.remotes()
            let accounts = await services.allAccounts()
            let preferred = try? await repository.forgeAccount()
            remotes = gitRemotes.compactMap { remote in
                guard let reference = ForgeRemoteReference.parse(remote.url) else { return nil }
                return Remote(name: remote.name, url: remote.url, reference: reference,
                              account: Self.account(for: reference, among: accounts, preferred: preferred ?? nil))
            }
            if remotes.isEmpty {
                state = .noForgeRemote
                return
            }
            let reachable = remotes.filter { $0.account != nil }
            guard !reachable.isEmpty else {
                state = .notSignedIn(hostnames: Array(Set(remotes.map(\.reference.hostname))).sorted())
                return
            }
            // Fork workflow: requests go to `upstream` when it is reachable.
            if pullTargetName == nil || !reachable.contains(where: { $0.name == pullTargetName }) {
                pullTargetName = reachable.first { $0.name == "upstream" }?.name
                    ?? reachable.first { $0.name == "origin" }?.name ?? reachable[0].name
            }
            state = .ready
            await loadSettings()
        } catch {
            state = .failed((error as? any LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// The account for a remote: one serving its host, preferring the
    /// repository's remembered account, then one whose owners include the
    /// repository's owner.
    static func account(for reference: ForgeRemoteReference, among accounts: [ForgeAccount], preferred: UUID?) -> ForgeAccount? {
        let candidates = accounts.filter { reference.isServed(by: $0.host) }
        if let preferred, let match = candidates.first(where: { $0.id == preferred }) { return match }
        let owner = reference.repositoryPath(on: candidates.first?.host ?? .github).split(separator: "/").first.map(String.init) ?? ""
        return candidates.first { $0.owners.contains { $0.caseInsensitiveCompare(owner) == .orderedSame } } ?? candidates.first
    }

    /// Lists and opens requests against another remote's repository.
    public func selectPullTarget(_ name: String) async {
        guard name != pullTargetName, remotes.contains(where: { $0.name == name && $0.account != nil }) else { return }
        pullTargetName = name
        settings = nil
        await loadSettings()
    }

    public func loadSettings() async {
        guard let target = pullTarget, let client else { return }
        do {
            async let settings = client.repositorySettings(target.repository)
            async let user = client.currentUser()
            self.settings = try await settings
            self.currentUser = try await user
            settingsError = nil
        } catch {
            settingsError = "Couldn't read \(target.repository) on \(target.reference.hostname): \(Self.describe(error))"
        }
    }

    /// The sign-in target to preselect for a hostname.
    public static func signInTarget(for hostname: String) -> SignInModel.Target? {
        switch hostname {
        case "github.com": return .github
        case "gitlab.com": return .gitlab
        default: return nil
        }
    }

    static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? "\(error)"
    }
}
