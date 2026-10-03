public import Foundation

/// The kinds of SSH keys GitKit can create.
///
/// - `ed25519`: Curve25519 in the Keychain. Widely supported and portable
///   (it can be exported to another machine), but the private key exists in
///   app memory while signing.
/// - `secureEnclave`: ECDSA P-256 generated inside the Secure Enclave. The
///   private key can never be read or exported, even by the app; it is lost
///   if the device is erased. GitHub and GitLab accept
///   `ecdsa-sha2-nistp256` for authentication and SSH commit signing.
///   (The Secure Enclave only supports P-256, not Ed25519.)
/// - `p256`: software P-256, used for imported ECDSA keys.
public enum SSHKeyKind: String, Codable, Sendable, CaseIterable {
    case ed25519
    case secureEnclave
    case p256

    public var displayName: String {
        switch self {
        case .ed25519: return "Ed25519 (Keychain)"
        case .secureEnclave: return "ECDSA P-256 (Secure Enclave)"
        case .p256: return "ECDSA P-256 (Keychain)"
        }
    }
}

/// Metadata of a stored key. The private part stays in the store.
public struct SSHKeyInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var label: String
    public var kind: SSHKeyKind
    public var algorithm: String
    public var publicKeyBlob: Data
    public var createdAt: Date

    public var openSSHPublicKey: String {
        SSHPublicKey.openSSH(algorithm: algorithm, blob: publicKeyBlob, comment: label)
    }
    public var fingerprint: String { SSHPublicKey.fingerprint(of: publicKeyBlob) }
}

/// Creates, stores and loads SSH keys. Private keys are Keychain items
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronized).
public actor SSHKeyStore {
    public static let service = "com.lemonseed.studio.git.ssh-keys"

    private struct Stored: Codable {
        var info: SSHKeyInfo
        /// Ed25519/P-256 raw private key, or the Secure Enclave handle.
        var secret: Data
    }

    private let store: any SecretStore
    private let service: String

    public init(store: any SecretStore = KeychainSecretStore(), service: String = SSHKeyStore.service) {
        self.store = store
        self.service = service
    }

    public func keys() throws -> [SSHKeyInfo] {
        try store.accounts(service: service).compactMap { account in
            try load(account)?.info
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Generates and stores a new key.
    @discardableResult
    public func generate(_ kind: SSHKeyKind, label: String) throws -> SSHKeyInfo {
        let key: any SSHSigningKey
        let secret: Data
        switch kind {
        case .ed25519:
            let k = Ed25519SSHKey()
            key = k
            secret = k.rawRepresentation
        case .secureEnclave:
            let k = try SecureEnclaveSSHKey()
            key = k
            secret = k.dataRepresentation
        case .p256:
            let k = P256SSHKey()
            key = k
            secret = k.rawRepresentation
        }
        return try save(key, kind: kind, secret: secret, label: label)
    }

    /// Imports an unencrypted OpenSSH private key (`-----BEGIN OPENSSH
    /// PRIVATE KEY-----`) of type ed25519 or ecdsa-sha2-nistp256.
    @discardableResult
    public func importOpenSSHPrivateKey(_ pem: String, label: String? = nil) throws -> SSHKeyInfo {
        let parsed = try OpenSSHPrivateKey.parse(pem)
        switch parsed {
        case .ed25519(let seed, let comment):
            let k = try Ed25519SSHKey(rawRepresentation: seed)
            return try save(k, kind: .ed25519, secret: seed, label: label ?? comment)
        case .p256(let scalar, let comment):
            let k = try P256SSHKey(rawRepresentation: scalar)
            return try save(k, kind: .p256, secret: scalar, label: label ?? comment)
        }
    }

    public func signingKey(for id: UUID) throws -> any SSHSigningKey {
        guard let stored = try load(id.uuidString) else { throw SSHKeyError.notFound }
        switch stored.info.kind {
        case .ed25519: return try Ed25519SSHKey(rawRepresentation: stored.secret)
        case .p256: return try P256SSHKey(rawRepresentation: stored.secret)
        case .secureEnclave: return try SecureEnclaveSSHKey(dataRepresentation: stored.secret)
        }
    }

    /// The OpenSSH private key text for portable (non-Secure-Enclave) keys.
    public func exportOpenSSHPrivateKey(_ id: UUID) throws -> String {
        guard let stored = try load(id.uuidString) else { throw SSHKeyError.notFound }
        switch stored.info.kind {
        case .ed25519:
            let k = try Ed25519SSHKey(rawRepresentation: stored.secret)
            return OpenSSHPrivateKey.format(ed25519: k, comment: stored.info.label)
        case .p256:
            let k = try P256SSHKey(rawRepresentation: stored.secret)
            return OpenSSHPrivateKey.format(p256: k, comment: stored.info.label)
        case .secureEnclave:
            throw SSHKeyError.unsupportedKeyType("Secure Enclave keys cannot be exported")
        }
    }

    public func rename(_ id: UUID, to label: String) throws {
        guard var stored = try load(id.uuidString) else { throw SSHKeyError.notFound }
        stored.info.label = label
        try store.write(try JSONEncoder().encode(stored), service: service, account: id.uuidString)
    }

    public func delete(_ id: UUID) throws {
        try store.delete(service: service, account: id.uuidString)
    }

    private func save(_ key: any SSHSigningKey, kind: SSHKeyKind, secret: Data, label: String) throws -> SSHKeyInfo {
        let info = SSHKeyInfo(id: UUID(), label: label, kind: kind, algorithm: key.algorithm,
                              publicKeyBlob: key.publicKeyBlob, createdAt: Date())
        let stored = Stored(info: info, secret: secret)
        try store.write(try JSONEncoder().encode(stored), service: service, account: info.id.uuidString)
        return info
    }

    private func load(_ account: String) throws -> Stored? {
        guard let data = try store.read(service: service, account: account) else { return nil }
        return try JSONDecoder().decode(Stored.self, from: data)
    }
}
