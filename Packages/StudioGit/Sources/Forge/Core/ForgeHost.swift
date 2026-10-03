public import Foundation

public enum ForgeKind: String, Codable, Sendable, CaseIterable, Hashable {
    case github
    case gitlab

    public var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }
}

/// A forge instance: GitHub.com, a GitHub Enterprise Server, GitLab.com or a
/// self-hosted GitLab.
public struct ForgeHost: Codable, Sendable, Hashable, Identifiable {
    public var kind: ForgeKind
    /// The web root, e.g. `https://github.com` or `https://gitlab.example.com`.
    public var webURL: URL

    public init(kind: ForgeKind, webURL: URL) {
        self.kind = kind
        var url = webURL
        if url.path.hasSuffix("/") { url = URL(string: String(url.absoluteString.dropLast()))! }
        self.webURL = url
    }

    public static let github = ForgeHost(kind: .github, webURL: URL(string: "https://github.com")!)
    public static let gitlab = ForgeHost(kind: .gitlab, webURL: URL(string: "https://gitlab.com")!)

    public var id: String { "\(kind.rawValue):\(webURL.absoluteString)" }
    public var hostname: String { webURL.host ?? webURL.absoluteString }
    public var isGitHubDotCom: Bool { kind == .github && hostname == "github.com" }

    /// REST API root.
    public var apiURL: URL {
        switch kind {
        case .github:
            return isGitHubDotCom ? URL(string: "https://api.github.com")! : webURL.appending(path: "api/v3")
        case .gitlab:
            return webURL.appending(path: "api/v4")
        }
    }

    public var graphQLURL: URL {
        switch kind {
        case .github:
            return isGitHubDotCom ? URL(string: "https://api.github.com/graphql")! : webURL.appending(path: "api/graphql")
        case .gitlab:
            return webURL.appending(path: "api/graphql")
        }
    }

    /// RFC 8628 device authorization endpoint.
    public var deviceAuthorizationURL: URL {
        switch kind {
        case .github: return webURL.appending(path: "login/device/code")
        case .gitlab: return webURL.appending(path: "oauth/authorize_device")
        }
    }

    public var tokenURL: URL {
        switch kind {
        case .github: return webURL.appending(path: "login/oauth/access_token")
        case .gitlab: return webURL.appending(path: "oauth/token")
        }
    }

    /// Where the user creates a personal access token.
    public var personalAccessTokenURL: URL {
        switch kind {
        case .github: return webURL.appending(path: "settings/tokens/new")
        case .gitlab: return webURL.appending(path: "-/user_settings/personal_access_tokens")
        }
    }

    /// Default OAuth scopes. GitHub: repositories, org membership, workflow
    /// files, and SSH key upload (auth and signing). GitLab: `api`.
    public var defaultScopes: [String] {
        switch kind {
        case .github: return ["repo", "read:org", "workflow", "write:public_key", "write:ssh_signing_key"]
        case .gitlab: return ["api", "read_user", "write_repository"]
        }
    }
}
