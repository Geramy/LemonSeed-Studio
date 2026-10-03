public import Foundation
public import GitKit

public enum AuthMethod: String, Codable, Sendable {
    case oauthDevice
    case personalAccessToken
}

/// A signed-in forge account. Its token lives in the Keychain.
public struct ForgeAccount: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var host: ForgeHost
    public var user: ForgeUser
    public var method: AuthMethod
    public var scopes: [String]
    /// Logins this account can act for (the user plus organizations or
    /// groups), used to pick an account for a remote URL.
    public var owners: [String]
    public var addedAt: Date

    public var displayName: String { "\(user.login) @ \(host.hostname)" }

    public init(id: UUID = UUID(), host: ForgeHost, user: ForgeUser, method: AuthMethod, scopes: [String] = [],
                owners: [String] = [], addedAt: Date = Date()) {
        self.id = id
        self.host = host
        self.user = user
        self.method = method
        self.scopes = scopes
        self.owners = owners.isEmpty ? [user.login] : owners
        self.addedAt = addedAt
    }
}

/// Multiple accounts across GitHub, GitHub Enterprise, GitLab.com and
/// self-hosted GitLab. Account metadata is a JSON file; tokens are Keychain
/// items (service `com.lemonseed.studio.forge.tokens`, one per account).
public actor AccountStore {
    public static let tokenService = "com.lemonseed.studio.forge.tokens"

    private let file: URL?
    private let secrets: any SecretStore
    private let session: URLSession
    private let defaults: UserDefaults
    private var cache: [ForgeAccount] = []
    private var refreshing: [UUID: Task<OAuthToken, any Error>] = [:]

    /// The default store under Application Support with Keychain tokens.
    public static func standard() -> AccountStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "StudioGit", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AccountStore(file: dir.appending(path: "accounts.json"), secrets: KeychainSecretStore())
    }

    public init(file: URL?, secrets: any SecretStore, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.file = file
        self.secrets = secrets
        self.session = session
        self.defaults = defaults
        if let file, let data = try? Data(contentsOf: file),
           let accounts = try? JSONDecoder().decode([ForgeAccount].self, from: data) {
            cache = accounts
        }
    }

    public func accounts() -> [ForgeAccount] { cache }

    public func account(_ id: UUID) -> ForgeAccount? { cache.first { $0.id == id } }

    // MARK: Sign in and out

    /// Validates a token by loading the user and their organizations, then
    /// stores the account. Signing in again to the same user updates it.
    @discardableResult
    public func signIn(host: ForgeHost, token: OAuthToken, method: AuthMethod) async throws -> ForgeAccount {
        let client = ForgeClients.make(host: host, session: session) { token.accessToken }
        let user = try await client.currentUser()
        let orgs = (try? await client.organizations()) ?? []
        let existing = cache.first { $0.host == host && $0.user.id == user.id }
        let account = ForgeAccount(id: existing?.id ?? UUID(), host: host, user: user, method: method,
                                   scopes: token.scopes, owners: [user.login] + orgs.map(\.login),
                                   addedAt: existing?.addedAt ?? Date())
        try saveToken(token, for: account.id)
        cache.removeAll { $0.id == account.id }
        cache.append(account)
        try persist()
        return account
    }

    @discardableResult
    public func signIn(host: ForgeHost, personalAccessToken: String) async throws -> ForgeAccount {
        let token = personalAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ForgeError.validation("Enter a token.") }
        return try await signIn(host: host, token: OAuthToken(accessToken: token), method: .personalAccessToken)
    }

    public func signOut(_ id: UUID) throws {
        try secrets.delete(service: Self.tokenService, account: id.uuidString)
        cache.removeAll { $0.id == id }
        try persist()
    }

    /// Re-reads organizations (for account matching).
    public func refreshOwners(_ id: UUID) async throws {
        guard var account = account(id) else { throw ForgeError.notSignedIn }
        let orgs = try await client(for: account).organizations()
        account.owners = [account.user.login] + orgs.map(\.login)
        cache = cache.map { $0.id == id ? account : $0 }
        try persist()
    }

    // MARK: Tokens

    /// The access token, refreshed first when a GitLab OAuth token is about
    /// to expire.
    public func accessToken(for id: UUID) async throws -> String {
        guard let account = account(id), var token = try loadToken(id) else { throw ForgeError.notSignedIn }
        if token.isExpiring(), token.refreshToken != nil {
            token = try await refresh(account, token)
        }
        return token.accessToken
    }

    private func refresh(_ account: ForgeAccount, _ token: OAuthToken) async throws -> OAuthToken {
        if let running = refreshing[account.id] { return try await running.value }
        guard let clientID = OAuthAppSettings.clientID(for: account.host, defaults: defaults) else {
            throw ForgeError.missingClientID(account.host.kind)
        }
        let flow = DeviceFlow(host: account.host, clientID: clientID, session: session)
        let task = Task { try await flow.refresh(token) }
        refreshing[account.id] = task
        defer { refreshing[account.id] = nil }
        let fresh = try await task.value
        try saveToken(fresh, for: account.id)
        return fresh
    }

    private func saveToken(_ token: OAuthToken, for id: UUID) throws {
        try secrets.write(try JSONEncoder().encode(token), service: Self.tokenService, account: id.uuidString)
    }

    private func loadToken(_ id: UUID) throws -> OAuthToken? {
        guard let data = try secrets.read(service: Self.tokenService, account: id.uuidString) else { return nil }
        return try JSONDecoder().decode(OAuthToken.self, from: data)
    }

    // MARK: Clients and matching

    public nonisolated func client(for account: ForgeAccount) -> any ForgeClient {
        let id = account.id
        return ForgeClients.make(host: account.host, session: session) { [weak self] in
            guard let self else { throw ForgeError.notSignedIn }
            return try await self.accessToken(for: id)
        }
    }

    /// The account to use for a remote URL: same host, preferring one whose
    /// owners include the repository owner.
    public func account(forRemoteURL url: String) -> ForgeAccount? {
        guard let (host, owner) = Self.hostAndOwner(of: url) else { return nil }
        let candidates = cache.filter { $0.host.hostname == host }
        return candidates.first { a in a.owners.contains { $0.caseInsensitiveCompare(owner) == .orderedSame } } ?? candidates.first
    }

    /// `https://github.com/owner/repo.git` or `git@github.com:owner/repo.git`
    /// -> ("github.com", "owner").
    static func hostAndOwner(of url: String) -> (String, String)? {
        if let u = URL(string: url), let host = u.host, u.scheme != nil {
            let parts = u.path.split(separator: "/")
            return parts.count >= 1 ? (host, String(parts[0])) : nil
        }
        guard let at = url.firstIndex(of: "@"), let colon = url.firstIndex(of: ":"), at < colon else { return nil }
        let host = String(url[url.index(after: at)..<colon])
        let path = url[url.index(after: colon)...].split(separator: "/")
        return path.isEmpty ? nil : (host, String(path[0]))
    }

    private func persist() throws {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cache).write(to: file, options: .atomic)
    }
}

/// Answers GitKit credential requests from the signed-in accounts and the
/// SSH key store. The UI, the terminal's `git` and the agent all go
/// through one instance; tokens never leave this layer.
public struct ForgeCredentialProvider: CredentialProvider {
    public let accounts: AccountStore
    public let sshKeys: SSHKeyStore?
    /// The account a repository was cloned with (stored in its config as
    /// `studio.account`), if any.
    public var preferredAccount: UUID?
    public var sshKeyID: UUID?

    public init(accounts: AccountStore, sshKeys: SSHKeyStore? = nil, preferredAccount: UUID? = nil, sshKeyID: UUID? = nil) {
        self.accounts = accounts
        self.sshKeys = sshKeys
        self.preferredAccount = preferredAccount
        self.sshKeyID = sshKeyID
    }

    public func credential(for request: CredentialRequest) async throws -> GitCredential? {
        if request.allowed.contains(.sshKey) || request.allowed == .username {
            let username = request.usernameFromURL ?? "git"
            if request.allowed == .username { return .username(username) }
            guard request.attempt == 1, let sshKeys else { return nil }
            let keyID: UUID?
            if let sshKeyID {
                keyID = sshKeyID
            } else {
                keyID = try await sshKeys.keys().first?.id
            }
            guard let keyID else { return nil }
            return .sshKey(username: username, key: try await sshKeys.signingKey(for: keyID))
        }
        guard request.allowed.contains(.userPassword), request.attempt <= 2 else { return nil }
        let account: ForgeAccount?
        if let preferredAccount {
            account = await accounts.account(preferredAccount)
        } else {
            account = await accounts.account(forRemoteURL: request.url)
        }
        guard let account else { return nil }
        let token = try await accounts.accessToken(for: account.id)
        // GitLab accepts any username with a token; "oauth2" is the documented one.
        let username = account.host.kind == .gitlab ? "oauth2" : account.user.login
        return .userPassword(username: username, password: token)
    }
}

extension GitRepository {
    /// Remembers which account a repository belongs to (`studio.account`).
    public func setForgeAccount(_ id: UUID?) throws {
        try setConfigValue("studio.account", id?.uuidString)
    }

    public func forgeAccount() throws -> UUID? {
        try configValue("studio.account").flatMap(UUID.init(uuidString:))
    }
}
