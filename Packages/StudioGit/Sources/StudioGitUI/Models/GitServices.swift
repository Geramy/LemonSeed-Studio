public import Foundation
public import Observation
public import GitKit
public import Forge

/// App-wide Git services shared by every Git view: accounts, SSH keys,
/// known hosts, the commit identity and the credential broker.
@MainActor
@Observable
public final class GitServices {
    public let accounts: AccountStore
    public let sshKeys: SSHKeyStore
    public let knownHosts: KnownHostsStore
    @ObservationIgnored let defaults: UserDefaults

    /// A host key waiting for the user's decision (shown as an alert).
    public var pendingHostKey: HostKeyQuestion?

    /// Replaces the forge clients and accounts every Git view uses: set
    /// only for previews, automation and screenshots (sample data). Nil in
    /// normal use, where the signed-in accounts and their tokens are used.
    @ObservationIgnored public var sampleForge: (accounts: [ForgeAccount], client: @MainActor (ForgeAccount) -> any ForgeClient)?

    /// Bumped when accounts change, so views reload.
    public private(set) var accountsRevision = 0

    public struct HostKeyQuestion: Identifiable {
        public let id = UUID()
        public let host: String
        public let keyType: String
        public let fingerprint: String
        let answer: CheckedContinuation<Bool, Never>
    }

    public var authorName: String {
        didSet { defaults.set(authorName, forKey: "StudioGit.authorName") }
    }
    public var authorEmail: String {
        didSet { defaults.set(authorEmail, forKey: "StudioGit.authorEmail") }
    }
    /// The SSH key used for SSH remotes and commit signing.
    public var defaultSSHKeyID: UUID? {
        didSet { defaults.set(defaultSSHKeyID?.uuidString, forKey: "StudioGit.sshKey") }
    }
    public var signCommits: Bool {
        didSet { defaults.set(signCommits, forKey: "StudioGit.signCommits") }
    }

    public init(accounts: AccountStore, sshKeys: SSHKeyStore, knownHosts: KnownHostsStore, defaults: UserDefaults = .standard) {
        self.accounts = accounts
        self.sshKeys = sshKeys
        self.knownHosts = knownHosts
        self.defaults = defaults
        authorName = defaults.string(forKey: "StudioGit.authorName") ?? ""
        authorEmail = defaults.string(forKey: "StudioGit.authorEmail") ?? ""
        defaultSSHKeyID = defaults.string(forKey: "StudioGit.sshKey").flatMap(UUID.init(uuidString:))
        signCommits = defaults.bool(forKey: "StudioGit.signCommits")
        knownHosts.confirmNewHost = { [weak self] host, type, fingerprint in
            await self?.askHostKey(host: host, keyType: type, fingerprint: fingerprint) ?? false
        }
    }

    /// Keychain-backed services with files under Application Support.
    public static func standard() -> GitServices {
        GitServices(accounts: .standard(), sshKeys: SSHKeyStore(), knownHosts: .shared)
    }

    /// In-memory services for previews and tests.
    public static func inMemory(defaults: UserDefaults = UserDefaults(suiteName: "StudioGit.preview") ?? .standard) -> GitServices {
        GitServices(accounts: AccountStore(file: nil, secrets: InMemorySecretStore()),
                    sshKeys: SSHKeyStore(store: InMemorySecretStore()),
                    knownHosts: KnownHostsStore(file: nil), defaults: defaults)
    }

    /// The accounts to list (the signed-in ones).
    public func allAccounts() async -> [ForgeAccount] {
        if let sampleForge { return sampleForge.accounts }
        return await accounts.accounts()
    }

    /// A client for an account; its token is read from the Keychain per request.
    public func client(for account: ForgeAccount) -> any ForgeClient {
        if let sampleForge { return sampleForge.client(account) }
        return accounts.client(for: account)
    }

    /// Call after signing in or out.
    public func accountsDidChange() { accountsRevision += 1 }

    private func askHostKey(host: String, keyType: String, fingerprint: String) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingHostKey = HostKeyQuestion(host: host, keyType: keyType, fingerprint: fingerprint, answer: continuation)
        }
    }

    public func answerHostKey(_ trust: Bool) {
        pendingHostKey?.answer.resume(returning: trust)
        pendingHostKey = nil
    }

    /// The identity for new commits: settings first, then the repository's
    /// git config, then the signed-in account.
    public func identity(for repository: GitRepository?) async -> Signature? {
        if !authorName.isEmpty && !authorEmail.isEmpty {
            return Signature(name: authorName, email: authorEmail)
        }
        if let repository, let configured = try? await repository.configuredIdentity() { return configured }
        if let account = await accounts.accounts().first {
            let email = account.host.kind == .github
                ? "\(account.user.id)+\(account.user.login)@users.noreply.github.com"
                : "\(account.user.login)@users.noreply.\(account.host.hostname)"
            return Signature(name: account.user.name ?? account.user.login, email: email)
        }
        return nil
    }

    /// The commit signer when signing is on and a key is selected.
    public func commitSigner() async -> (any CommitSigner)? {
        guard signCommits, let id = defaultSSHKeyID, let key = try? await sshKeys.signingKey(for: id) else { return nil }
        return SSHCommitSigner(key: key)
    }

    /// Credentials and host trust for network operations on `repository`.
    public func network(for repository: GitRepository?, progress: TransferProgressHandler? = nil) async -> NetworkContext {
        let preferred = try? await repository?.forgeAccount()
        let provider = ForgeCredentialProvider(accounts: accounts, sshKeys: sshKeys,
                                               preferredAccount: preferred ?? nil, sshKeyID: defaultSSHKeyID)
        return NetworkContext(credentials: provider, trust: knownHosts, progress: progress)
    }
}
