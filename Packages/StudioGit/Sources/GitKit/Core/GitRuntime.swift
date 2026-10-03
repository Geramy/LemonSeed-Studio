public import Foundation
import Clibgit2
import CGitShim

/// Process-wide libgit2 setup. Every GitKit entry point calls
/// `GitRuntime.ensureInitialized()` first; it runs once.
public enum GitRuntime {
    /// Settings applied when libgit2 initializes. Change them before the first
    /// Git call (for example at app launch).
    public struct Configuration: Sendable {
        /// User agent sent on HTTPS requests.
        public var userAgent: String = "LemonSeedStudio-GitKit"
        /// PEM bundle OpenSSL trusts in addition to the system trust store.
        /// Defaults to the bundled Mozilla CA list.
        public var caBundle: URL? = Bundle.module.url(forResource: "cacert", withExtension: "pem")
        /// Directory used as the "global" config level ($HOME/.gitconfig on a
        /// desktop). nil leaves libgit2's default lookup in place.
        public var globalConfigDirectory: URL?
        public var connectTimeoutMilliseconds: Int32 = 30_000
        public var ioTimeoutMilliseconds: Int32 = 120_000
        /// Upper bound for memory-mapped pack windows (memory governor knob).
        public var mappedPackLimitBytes: Int = 256 * 1024 * 1024
        public init() {}
    }

    nonisolated(unsafe) private static var pendingConfiguration = Configuration()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var initialized = false

    /// Replaces the configuration. Only effective before initialization,
    /// except for settings that are re-applied by `apply(_:)`.
    public static func configure(_ configuration: Configuration) {
        lock.lock(); defer { lock.unlock() }
        pendingConfiguration = configuration
        if initialized { apply(configuration) }
    }

    /// libgit2's version, e.g. "1.9.7".
    public static var libgit2Version: String {
        var major: Int32 = 0, minor: Int32 = 0, rev: Int32 = 0
        git_libgit2_version(&major, &minor, &rev)
        return "\(major).\(minor).\(rev)"
    }

    /// Whether the linked libgit2 was built with HTTPS and SSH transports.
    public static var features: (https: Bool, ssh: Bool, threads: Bool) {
        let f = UInt32(bitPattern: git_libgit2_features())
        return (f & GIT_FEATURE_HTTPS.rawValue != 0,
                f & GIT_FEATURE_SSH.rawValue != 0,
                f & GIT_FEATURE_THREADS.rawValue != 0)
    }

    static func ensureInitialized() {
        lock.lock(); defer { lock.unlock() }
        guard !initialized else { return }
        git_libgit2_init()
        initialized = true
        apply(pendingConfiguration)
    }

    private static func apply(_ c: Configuration) {
        _ = lsg_set_user_agent(c.userAgent)
        if let ca = c.caBundle {
            _ = lsg_set_ssl_cert_locations(ca.path, nil)
        }
        _ = lsg_set_server_timeouts(c.connectTimeoutMilliseconds, c.ioTimeoutMilliseconds)
        _ = lsg_set_mwindow_mapped_limit(c.mappedPackLimitBytes)
        // Files-provider folders and external drives report owners that do
        // not match the app's uid; ownership checks only get in the way here.
        _ = lsg_set_owner_validation(0)
        if let dir = c.globalConfigDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = lsg_set_search_path(Int32(GIT_CONFIG_LEVEL_GLOBAL.rawValue), dir.path)
            _ = lsg_set_search_path(Int32(GIT_CONFIG_LEVEL_XDG.rawValue), dir.path)
            _ = lsg_set_search_path(Int32(GIT_CONFIG_LEVEL_SYSTEM.rawValue), dir.path)
        }
    }
}
