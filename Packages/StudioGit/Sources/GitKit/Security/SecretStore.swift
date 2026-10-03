public import Foundation
import Security

/// Storage for small secrets (tokens, private keys).
public protocol SecretStore: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
    func accounts(service: String) throws -> [String]
}

public struct SecretStoreError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public var status: OSStatus
    public var operation: String
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation): \(message)"
    }
    public var errorDescription: String? { description }
}

/// Keychain-backed store: generic-password items, this device only, never
/// synced to iCloud Keychain, readable after first unlock (so background
/// fetches can authenticate).
public struct KeychainSecretStore: SecretStore {
    /// Optional keychain access group shared with app extensions.
    public var accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    private func baseQuery(service: String, account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read(service: String, account: String) throws -> Data? {
        var q = baseQuery(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError(status: status, operation: "read") }
        return out as? Data
    }

    public func write(_ data: Data, service: String, account: String) throws {
        let q = baseQuery(service: service, account: account)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status, operation: "write") }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError(status: status, operation: "delete")
        }
    }

    public func accounts(service: String) throws -> [String] {
        var q = baseQuery(service: service, account: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SecretStoreError(status: status, operation: "list") }
        let items = out as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Whether the Keychain is usable in this process (unit tests without an
    /// app host may lack the entitlement).
    public static var isAvailable: Bool {
        let store = KeychainSecretStore()
        let service = "studio.git.keychain-probe"
        do {
            try store.write(Data([1]), service: service, account: "probe")
            try store.delete(service: service, account: "probe")
            return true
        } catch {
            return false
        }
    }
}

/// In-memory store for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: [String: Data]] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        lock.withLock { items[service]?[account] }
    }

    public func write(_ data: Data, service: String, account: String) throws {
        lock.withLock { items[service, default: [:]][account] = data }
    }

    public func delete(service: String, account: String) throws {
        _ = lock.withLock { items[service]?.removeValue(forKey: account) }
    }

    public func accounts(service: String) throws -> [String] {
        lock.withLock { items[service].map { Array($0.keys).sorted() } ?? [] }
    }
}
