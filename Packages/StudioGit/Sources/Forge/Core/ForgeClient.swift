public import Foundation

/// A page of results with an opaque cursor for the next page.
public struct ForgePage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var nextCursor: String?
    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Everything the Studio needs from a forge, implemented by `GitHubClient`
/// and `GitLabClient`. Repositories are named by `owner/name` (GitLab: the
/// full project path).
public protocol ForgeClient: Sendable {
    var host: ForgeHost { get }

    func currentUser() async throws -> ForgeUser
    func organizations() async throws -> [ForgeOrganization]
    /// The signed-in user's repositories, most recently updated first.
    func repositories(cursor: String?) async throws -> ForgePage<ForgeRepository>
    func repositories(organization: String) async throws -> [ForgeRepository]
    func searchRepositories(_ query: String) async throws -> [ForgeRepository]
    func repository(_ fullName: String) async throws -> ForgeRepository
    func branches(_ repository: String) async throws -> [ForgeBranch]
    func tags(_ repository: String) async throws -> [ForgeTag]
    /// The README's Markdown, if any.
    func readme(_ repository: String) async throws -> String?

    func pullRequests(_ filter: PullRequestFilter) async throws -> [PullRequest]
    func pullRequest(_ repository: String, number: Int) async throws -> PullRequest
    func pullRequestFiles(_ repository: String, number: Int) async throws -> [PullRequestFile]
    /// The whole request as one unified diff.
    func pullRequestDiff(_ repository: String, number: Int) async throws -> String
    func comments(_ repository: String, number: Int) async throws -> [PullRequestComment]
    @discardableResult
    func addComment(_ repository: String, number: Int, body: String) async throws -> PullRequestComment
    @discardableResult
    func addLineComment(_ repository: String, number: Int, _ draft: LineCommentDraft) async throws -> PullRequestComment
    func createPullRequest(_ repository: String, _ draft: PullRequestDraft) async throws -> PullRequest
    func review(_ repository: String, number: Int, event: ReviewEvent, body: String) async throws
    func merge(_ repository: String, number: Int, method: MergeMethod, commitMessage: String?) async throws

    /// CI for a branch name or commit SHA.
    func ciStatus(_ repository: String, ref: String) async throws -> CIStatus
    /// The log of one CI run/job as plain text (may contain ANSI escapes).
    func ciLog(_ repository: String, run: CIRun) async throws -> String

    func sshKeys() async throws -> [ForgeSSHKey]
    @discardableResult
    func addSSHKey(title: String, publicKey: String, usage: ForgeSSHKey.Usage) async throws -> ForgeSSHKey
}

extension ForgeClient {
    /// Every page of the user's repositories (up to `maxPages`).
    public func allRepositories(maxPages: Int = 10) async throws -> [ForgeRepository] {
        var all: [ForgeRepository] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try await repositories(cursor: cursor)
            all += page.items
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return all
    }
}

/// Builds the right client for a host.
public enum ForgeClients {
    public static func make(host: ForgeHost, session: URLSession = .shared, token: @escaping ForgeHTTP.TokenSource) -> any ForgeClient {
        switch host.kind {
        case .github: return GitHubClient(host: host, session: session, token: token)
        case .gitlab: return GitLabClient(host: host, session: session, token: token)
        }
    }
}
