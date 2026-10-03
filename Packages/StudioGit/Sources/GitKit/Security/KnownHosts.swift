public import Foundation

/// SSH `known_hosts` with trust on first use, plus pinned keys for GitHub
/// and GitLab.com, and a decision hook for TLS certificates the system does
/// not trust.
///
/// Unknown SSH hosts are passed to `confirmNewHost` (the UI asks the user);
/// a host whose key changed is always rejected until its entry is removed.
public final class KnownHostsStore: HostTrustEvaluator, @unchecked Sendable {
    public typealias Confirm = @Sendable (_ host: String, _ keyType: String, _ fingerprint: String) async -> Bool
    public typealias ConfirmTLS = @Sendable (_ host: String, _ certificate: Data) async -> Bool

    /// Keys published by GitHub (api.github.com/meta) and GitLab.com.
    public static let pinned: [String] = [
        "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
        "github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=",
        "github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=",
        "gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf",
        "gitlab.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFSMqzJeV9rUzU4kWitGjeR4PWSa29SPqJ1fVkhtj3Hw9xjLVXVYrU9QlYWrOLXBpQ6KWjbjTDTdDkoohFzgbEY=",
        "gitlab.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsj2bNKTBSpIYDEGk9KxsGh3mySTRgMtXL583qmBpzeQ+jqCMRgBqB98u3z++J1sKlXHWfM9dyhSevkMwSbhoR8XIq/U0tCNyokEi/ueaBMCvbcTHhO7FcwzY92WK4Yt0aGROY5qX2UKSeOvuP4D6TPqKF1onrSzH9bx9XUf2lEdWT/ia1NEKjunUqu1xOB/StKDHMoX4/OKyIzuS0q/T1zOATthvasJFoPrAjkohTyaDUz2LN5JoH839hViyEG82yB+MjcFV5MU3N1l1QL3cVUCh93xSaua1N85qivl+siMkPGbO5xR/En4iEY6K2XPASUEMaieWVNTRCtJ4S8H+9",
    ]

    public struct Entry: Sendable, Hashable {
        public var host: String
        public var keyType: String
        public var key: Data
        public var fingerprint: String { SSHPublicKey.fingerprint(of: key) }
    }

    public enum Decision: Sendable, Equatable {
        case trusted
        case unknown
        case mismatch
    }

    private let file: URL?
    private let lock = NSLock()
    private var entries: [Entry] = []
    public var confirmNewHost: Confirm?
    public var confirmTLS: ConfirmTLS?

    /// The app-wide store under Application Support.
    public static let shared: KnownHostsStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "StudioGit", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return KnownHostsStore(file: dir.appending(path: "known_hosts"))
    }()

    /// - Parameter file: known_hosts file to load and append to (nil keeps
    ///   entries in memory only).
    public init(file: URL?, confirmNewHost: Confirm? = nil, confirmTLS: ConfirmTLS? = nil) {
        self.file = file
        self.confirmNewHost = confirmNewHost
        self.confirmTLS = confirmTLS
        for line in Self.pinned { if let e = Self.parse(line) { entries.append(e) } }
        if let file, let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let e = Self.parse(String(line)) { entries.append(e) }
            }
        }
    }

    public var allEntries: [Entry] { lock.withLock { entries } }

    public func decision(host: String, keyType: String, key: Data) -> Decision {
        lock.withLock {
            let forHost = entries.filter { $0.host == host }
            if forHost.contains(where: { $0.key == key }) { return .trusted }
            // A different key of the same type is a mismatch; another type is unknown.
            if forHost.contains(where: { $0.keyType == keyType }) { return .mismatch }
            return .unknown
        }
    }

    public func add(host: String, keyType: String, key: Data) {
        let entry = Entry(host: host, keyType: keyType, key: key)
        lock.withLock {
            entries.removeAll { $0.host == host && $0.keyType == keyType }
            entries.append(entry)
        }
        persist()
    }

    public func remove(host: String) {
        lock.withLock { entries.removeAll { $0.host == host } }
        persist()
    }

    public func trustSSHHost(_ host: String, keyType: String, fingerprint: String, hostKey: Data) async -> Bool {
        switch decision(host: host, keyType: keyType, key: hostKey) {
        case .trusted:
            return true
        case .mismatch:
            return false
        case .unknown:
            guard let confirm = confirmNewHost, await confirm(host, keyType, fingerprint) else { return false }
            add(host: host, keyType: keyType, key: hostKey)
            return true
        }
    }

    public func trustTLSCertificate(_ host: String, certificate: Data) async -> Bool {
        guard let confirmTLS else { return false }
        return await confirmTLS(host, certificate)
    }

    private func persist() {
        guard let file else { return }
        let pinned = Set(Self.pinned.compactMap(Self.parse))
        let lines = lock.withLock {
            entries.filter { !pinned.contains($0) }.map { "\($0.host) \($0.keyType) \($0.key.base64EncodedString())" }
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func parse(_ line: String) -> Entry? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 3, !parts[0].hasPrefix("#"), let key = Data(base64Encoded: parts[2]) else { return nil }
        return Entry(host: parts[0], keyType: parts[1], key: key)
    }
}
