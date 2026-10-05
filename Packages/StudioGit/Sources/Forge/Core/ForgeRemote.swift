public import Foundation

/// A Git remote URL read as a forge repository: the host it lives on and
/// its `owner/name` (GitLab: the full namespace path).
///
/// Understands `https://host[:port]/owner/name(.git)`,
/// `ssh://git@host[:port]/owner/name(.git)` and the scp form
/// `git@host:owner/name(.git)`.
public struct ForgeRemoteReference: Sendable, Hashable {
    public var hostname: String
    public var fullName: String

    public init(hostname: String, fullName: String) {
        self.hostname = hostname
        self.fullName = fullName
    }

    public var owner: String { String(fullName.split(separator: "/").dropLast().joined(separator: "/")) }
    public var name: String { String(fullName.split(separator: "/").last ?? "") }

    public static func parse(_ remoteURL: String) -> ForgeRemoteReference? {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        var path: String
        if text.contains("://") {
            guard let url = URL(string: text), let h = url.host, !h.isEmpty,
                  ["https", "http", "ssh", "git"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            host = h
            path = url.path
        } else {
            // scp-like: [user@]host:path (no scheme, a colon before any slash).
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let left = text[..<colon]
            guard !left.contains("/") else { return nil }
            host = String(left.split(separator: "@").last ?? "")
            path = String(text[text.index(after: colon)...])
        }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard !host.isEmpty, parts.count >= 2 else { return nil }
        return ForgeRemoteReference(hostname: host.lowercased(), fullName: parts.joined(separator: "/"))
    }

    /// Whether `host` serves this remote. GitHub.com remotes match the
    /// github.com host; everything else matches by hostname (a GitHub
    /// Enterprise or GitLab instance under a path prefix also matches when
    /// the remote path starts with that prefix).
    public func isServed(by host: ForgeHost) -> Bool {
        guard hostname == host.hostname.lowercased() else { return false }
        let prefix = host.webURL.path.split(separator: "/").joined(separator: "/")
        return prefix.isEmpty || fullName.hasPrefix(prefix + "/")
    }

    /// `owner/name` relative to the host's web root (drops a path prefix).
    public func repositoryPath(on host: ForgeHost) -> String {
        let prefix = host.webURL.path.split(separator: "/").joined(separator: "/")
        guard !prefix.isEmpty, fullName.hasPrefix(prefix + "/") else { return fullName }
        return String(fullName.dropFirst(prefix.count + 1))
    }
}

extension ForgeKind {
    /// The read-only ref every pull/merge request's head is published
    /// under in the target repository.
    public func pullRequestHeadRef(_ number: Int) -> String {
        switch self {
        case .github: return "refs/pull/\(number)/head"
        case .gitlab: return "refs/merge-requests/\(number)/head"
        }
    }

    /// The local branch name for a checked-out request from a fork.
    public func pullRequestBranchName(_ number: Int) -> String {
        switch self {
        case .github: return "pr/\(number)"
        case .gitlab: return "mr/\(number)"
        }
    }

    /// "pull request" or "merge request".
    public var requestNoun: String {
        switch self {
        case .github: return "pull request"
        case .gitlab: return "merge request"
        }
    }

    /// "#" for GitHub, "!" for GitLab.
    public var requestSigil: String {
        switch self {
        case .github: return "#"
        case .gitlab: return "!"
        }
    }
}
