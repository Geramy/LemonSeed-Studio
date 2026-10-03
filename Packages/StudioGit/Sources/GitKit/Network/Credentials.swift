public import Foundation

/// What libgit2 is asking credentials for.
public struct CredentialRequest: Sendable, Hashable {
    public struct Kinds: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        /// Username and password (HTTPS; tokens go here).
        public static let userPassword = Kinds(rawValue: 1 << 0)
        /// An SSH key (in-process signing or a private key).
        public static let sshKey = Kinds(rawValue: 1 << 1)
        /// Only a username (SSH asks for it first when the URL has none).
        public static let username = Kinds(rawValue: 1 << 2)
    }

    /// The remote URL.
    public var url: String
    public var host: String?
    /// The username embedded in the URL, if any (`git@github.com:...`).
    public var usernameFromURL: String?
    public var allowed: Kinds
    /// 1 for the first request of an operation; later calls mean the
    /// previous credential was rejected.
    public var attempt: Int

    /// The `owner/repo` path of the URL, for matching an account.
    public var repositoryPath: String? {
        if let u = URL(string: url), u.scheme != nil, let host = u.host, !host.isEmpty {
            return u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        // scp-like: git@host:owner/repo.git
        if let colon = url.firstIndex(of: ":") {
            return String(url[url.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return nil
    }

    public init(url: String, host: String?, usernameFromURL: String?, allowed: Kinds, attempt: Int) {
        self.url = url
        self.host = host
        self.usernameFromURL = usernameFromURL
        self.allowed = allowed
        self.attempt = attempt
    }
}

public enum GitCredential: Sendable {
    /// HTTPS username and password or token.
    case userPassword(username: String, password: String)
    /// An in-process SSH key (Keychain Ed25519 or Secure Enclave P-256);
    /// libssh2 calls back into it for each signature.
    case sshKey(username: String, key: any SSHSigningKey)
    /// An OpenSSH private key in PEM form, possibly passphrase-protected,
    /// parsed by libssh2 itself.
    case sshPrivateKey(username: String, publicKey: String?, privateKey: String, passphrase: String?)
    /// Only a username (for SSH's username round trip).
    case username(String)
}

/// Answers every credential request of a Git network operation. Return nil
/// to give up (the operation fails with an authentication error).
public protocol CredentialProvider: Sendable {
    func credential(for request: CredentialRequest) async throws -> GitCredential?
}

/// A provider that never answers (public repositories).
public struct NoCredentials: CredentialProvider {
    public init() {}
    public func credential(for request: CredentialRequest) async throws -> GitCredential? { nil }
}

/// A fixed credential, offered once per operation.
public struct StaticCredentialProvider: CredentialProvider {
    public var credential: GitCredential
    public var maxAttempts: Int
    public init(_ credential: GitCredential, maxAttempts: Int = 1) {
        self.credential = credential
        self.maxAttempts = maxAttempts
    }

    public func credential(for request: CredentialRequest) async throws -> GitCredential? {
        if request.allowed == .username, case .sshKey(let user, _) = credential { return .username(user) }
        if request.allowed == .username, case .sshPrivateKey(let user, _, _, _) = credential { return .username(user) }
        return request.attempt <= maxAttempts ? credential : nil
    }
}

/// Tries providers in order; the first non-nil answer wins.
public struct ChainedCredentialProvider: CredentialProvider {
    public var providers: [any CredentialProvider]
    public init(_ providers: [any CredentialProvider]) { self.providers = providers }

    public func credential(for request: CredentialRequest) async throws -> GitCredential? {
        for provider in providers {
            if let c = try await provider.credential(for: request) { return c }
        }
        return nil
    }
}

/// Decides whether to trust an SSH host key or a TLS certificate that the
/// system could not verify.
public protocol HostTrustEvaluator: Sendable {
    /// SSH: `fingerprint` is `SHA256:...` of `hostKey` (SSH wire format).
    func trustSSHHost(_ host: String, keyType: String, fingerprint: String, hostKey: Data) async -> Bool
    /// TLS: called only when neither the system trust store nor the bundled
    /// CA list accepts the certificate. `certificate` is the DER leaf.
    func trustTLSCertificate(_ host: String, certificate: Data) async -> Bool
}
