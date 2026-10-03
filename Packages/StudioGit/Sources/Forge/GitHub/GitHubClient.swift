public import Foundation

/// GitHub REST v3 and GraphQL v4 client (github.com and Enterprise Server).
public struct GitHubClient: ForgeClient {
    public let host: ForgeHost
    let http: ForgeHTTP

    public init(host: ForgeHost = .github, session: URLSession = .shared, token: @escaping ForgeHTTP.TokenSource) {
        self.host = host
        self.http = ForgeHTTP(baseURL: host.apiURL, session: session,
                              extraHeaders: ["X-GitHub-Api-Version": "2022-11-28"], token: token)
    }

    public var rateLimit: RateLimit { get async { await http.rateLimit } }

    // MARK: DTOs

    struct User: Decodable, Sendable {
        var id: Int
        var login: String
        var name: String?
        var avatarUrl: URL?
        var htmlUrl: URL?
        var model: ForgeUser { ForgeUser(id: String(id), login: login, name: name, avatarURL: avatarUrl, webURL: htmlUrl) }
    }

    struct Org: Decodable, Sendable {
        var id: Int
        var login: String
        var avatarUrl: URL?
    }

    struct Repo: Decodable, Sendable {
        struct Owner: Decodable, Sendable { var login: String }
        var id: Int
        var nodeId: String?
        var name: String
        var fullName: String
        var owner: Owner
        var `private`: Bool
        var fork: Bool
        var archived: Bool?
        var description: String?
        var defaultBranch: String?
        var cloneUrl: String
        var sshUrl: String?
        var htmlUrl: URL?
        var stargazersCount: Int?
        var language: String?
        var updatedAt: Date?
        var size: Int?

        var model: ForgeRepository {
            ForgeRepository(id: nodeId ?? String(id), fullName: fullName, owner: owner.login, name: name, description: description,
                            isPrivate: `private`, isFork: fork, isArchived: archived ?? false, defaultBranch: defaultBranch,
                            httpsCloneURL: cloneUrl, sshCloneURL: sshUrl, webURL: htmlUrl, stars: stargazersCount ?? 0,
                            language: language, updatedAt: updatedAt, sizeKB: size)
        }
    }

    struct Branch: Decodable, Sendable {
        struct Commit: Decodable, Sendable { var sha: String }
        var name: String
        var commit: Commit
        var protected: Bool?
    }

    struct Pull: Decodable, Sendable {
        struct Ref: Decodable, Sendable {
            struct R: Decodable, Sendable { var fullName: String }
            var ref: String
            var sha: String
            var repo: R?
        }
        struct Label: Decodable, Sendable { var name: String }
        struct Login: Decodable, Sendable { var login: String }
        var number: Int
        var title: String
        var body: String?
        var state: String
        var draft: Bool?
        var user: User?
        var head: Ref
        var base: Ref
        var htmlUrl: URL?
        var createdAt: Date?
        var updatedAt: Date?
        var mergedAt: Date?
        var mergeable: Bool?
        var additions: Int?
        var deletions: Int?
        var changedFiles: Int?
        var comments: Int?
        var reviewComments: Int?
        var labels: [Label]?
        var requestedReviewers: [Login]?

        func model(repository: String) -> PullRequest {
            PullRequest(number: number, title: title, body: body ?? "",
                        state: mergedAt != nil ? .merged : (state == "open" ? .open : .closed),
                        isDraft: draft ?? false, author: user?.model, repository: base.repo?.fullName ?? repository,
                        sourceBranch: head.ref, targetBranch: base.ref, headSHA: head.sha, webURL: htmlUrl,
                        createdAt: createdAt, updatedAt: updatedAt, labels: labels?.map(\.name) ?? [],
                        reviewers: requestedReviewers?.map(\.login) ?? [], isMergeable: mergeable,
                        additions: additions, deletions: deletions, changedFiles: changedFiles,
                        commentCount: comments.map { $0 + (reviewComments ?? 0) })
        }
    }

    struct IssueSearch: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            var number: Int
            var title: String
            var body: String?
            var state: String
            var draft: Bool?
            var user: User?
            var htmlUrl: URL?
            var repositoryUrl: String
            var createdAt: Date?
            var updatedAt: Date?
            var comments: Int?
            var labels: [Pull.Label]?
        }
        var items: [Item]
    }

    struct File: Decodable, Sendable {
        var filename: String
        var previousFilename: String?
        var status: String
        var additions: Int
        var deletions: Int
        var patch: String?
    }

    struct Comment: Decodable, Sendable {
        var id: Int
        var user: User?
        var body: String
        var createdAt: Date?
        var path: String?
        var line: Int?
        var originalLine: Int?
        var inReplyToId: Int?
    }

    struct CheckRuns: Decodable, Sendable {
        struct Run: Decodable, Sendable {
            struct App: Decodable, Sendable { var name: String? }
            var id: Int
            var name: String
            var status: String
            var conclusion: String?
            var htmlUrl: URL?
            var detailsUrl: URL?
            var startedAt: Date?
            var completedAt: Date?
            var app: App?
        }
        var checkRuns: [Run]
    }

    struct CombinedStatus: Decodable, Sendable {
        struct Status: Decodable, Sendable {
            var id: Int
            var context: String
            var state: String
            var targetUrl: URL?
            var createdAt: Date?
        }
        var state: String
        var statuses: [Status]
    }

    struct Key: Decodable, Sendable {
        var id: Int
        var key: String
        var title: String?
        var createdAt: Date?
    }

    // MARK: Users and repositories

    public func currentUser() async throws -> ForgeUser {
        try await http.get(User.self, "user").model
    }

    public func organizations() async throws -> [ForgeOrganization] {
        try await http.getAll(Org.self, "user/orgs", query: ["per_page": "100"]).map {
            ForgeOrganization(id: String($0.id), login: $0.login, name: nil, avatarURL: $0.avatarUrl)
        }
    }

    struct ViewerRepos: Decodable, Sendable {
        struct Viewer: Decodable, Sendable { var repositories: Connection }
        struct Connection: Decodable, Sendable {
            struct PageInfo: Decodable, Sendable { var hasNextPage: Bool; var endCursor: String? }
            var pageInfo: PageInfo
            var nodes: [Node]
        }
        struct Node: Decodable, Sendable {
            struct Owner: Decodable, Sendable { var login: String }
            struct Ref: Decodable, Sendable { var name: String }
            struct Lang: Decodable, Sendable { var name: String }
            var id: String
            var name: String
            var nameWithOwner: String
            var owner: Owner
            var description: String?
            var isPrivate: Bool
            var isFork: Bool
            var isArchived: Bool
            var defaultBranchRef: Ref?
            var url: URL
            var sshUrl: String
            var stargazerCount: Int
            var primaryLanguage: Lang?
            var updatedAt: Date?
            var diskUsage: Int?
        }
        var viewer: Viewer
    }

    static let viewerRepositoriesQuery = """
    query($after: String) {
      viewer {
        repositories(first: 50, after: $after, orderBy: {field: UPDATED_AT, direction: DESC},
                     ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id name nameWithOwner owner { login } description isPrivate isFork isArchived
            defaultBranchRef { name } url sshUrl stargazerCount primaryLanguage { name } updatedAt diskUsage
          }
        }
      }
    }
    """

    /// Lists the viewer's repositories through GraphQL (one round trip per
    /// 50 repositories, owner/collaborator/organization member).
    public func repositories(cursor: String?) async throws -> ForgePage<ForgeRepository> {
        let data = try await http.graphQL(ViewerRepos.self, url: host.graphQLURL, query: Self.viewerRepositoriesQuery,
                                          variables: ["after": cursor.map(GraphQLValue.string) ?? .null])
        let conn = data.viewer.repositories
        let items = conn.nodes.map { n in
            ForgeRepository(id: n.id, fullName: n.nameWithOwner, owner: n.owner.login, name: n.name, description: n.description,
                            isPrivate: n.isPrivate, isFork: n.isFork, isArchived: n.isArchived, defaultBranch: n.defaultBranchRef?.name,
                            httpsCloneURL: n.url.absoluteString + ".git", sshCloneURL: n.sshUrl, webURL: n.url,
                            stars: n.stargazerCount, language: n.primaryLanguage?.name, updatedAt: n.updatedAt, sizeKB: n.diskUsage)
        }
        return ForgePage(items: items, nextCursor: conn.pageInfo.hasNextPage ? conn.pageInfo.endCursor : nil)
    }

    public func repositories(organization: String) async throws -> [ForgeRepository] {
        try await http.getAll(Repo.self, "orgs/\(organization)/repos", query: ["per_page": "100", "sort": "updated"]).map(\.model)
    }

    public func searchRepositories(_ query: String) async throws -> [ForgeRepository] {
        struct Result: Decodable, Sendable { var items: [Repo] }
        return try await http.get(Result.self, "search/repositories", query: ["q": query, "per_page": "30"]).items.map(\.model)
    }

    public func repository(_ fullName: String) async throws -> ForgeRepository {
        try await http.get(Repo.self, "repos/\(fullName)").model
    }

    public func branches(_ repository: String) async throws -> [ForgeBranch] {
        async let repo = self.repository(repository)
        let branches = try await http.getAll(Branch.self, "repos/\(repository)/branches", query: ["per_page": "100"])
        let defaultBranch = try await repo.defaultBranch
        return branches.map { ForgeBranch(name: $0.name, commit: $0.commit.sha, isProtected: $0.protected ?? false, isDefault: $0.name == defaultBranch) }
    }

    public func tags(_ repository: String) async throws -> [ForgeTag] {
        try await http.getAll(Branch.self, "repos/\(repository)/tags", query: ["per_page": "100"]).map {
            ForgeTag(name: $0.name, commit: $0.commit.sha)
        }
    }

    public func readme(_ repository: String) async throws -> String? {
        do {
            let response = try await http.send("GET", "repos/\(repository)/readme", accept: "application/vnd.github.raw")
            return String(decoding: response.data, as: UTF8.self)
        } catch ForgeError.notFound {
            return nil
        }
    }

    // MARK: Pull requests

    public func pullRequests(_ filter: PullRequestFilter) async throws -> [PullRequest] {
        switch filter {
        case .repository(let repo, let state):
            let s = state == .open ? "open" : "closed"
            let pulls = try await http.getAll(Pull.self, "repos/\(repo)/pulls", query: ["state": s, "per_page": "50"], maxPages: 2)
            let mapped = pulls.map { $0.model(repository: repo) }
            return state == .merged ? mapped.filter { $0.state == .merged } : mapped
        case .authoredByMe:
            return try await searchPulls("is:pr is:open author:@me archived:false")
        case .reviewRequested:
            return try await searchPulls("is:pr is:open review-requested:@me archived:false")
        }
    }

    private func searchPulls(_ q: String) async throws -> [PullRequest] {
        let result = try await http.get(IssueSearch.self, "search/issues", query: ["q": q, "per_page": "50", "sort": "updated"])
        return result.items.map { item in
            let repo = item.repositoryUrl.components(separatedBy: "/repos/").last ?? ""
            return PullRequest(number: item.number, title: item.title, body: item.body ?? "",
                               state: item.state == "open" ? .open : .closed, isDraft: item.draft ?? false,
                               author: item.user?.model, repository: repo, sourceBranch: "", targetBranch: "",
                               webURL: item.htmlUrl, createdAt: item.createdAt, updatedAt: item.updatedAt,
                               labels: item.labels?.map(\.name) ?? [], commentCount: item.comments)
        }
    }

    public func pullRequest(_ repository: String, number: Int) async throws -> PullRequest {
        try await http.get(Pull.self, "repos/\(repository)/pulls/\(number)").model(repository: repository)
    }

    public func pullRequestFiles(_ repository: String, number: Int) async throws -> [PullRequestFile] {
        try await http.getAll(File.self, "repos/\(repository)/pulls/\(number)/files", query: ["per_page": "100"], maxPages: 30).map { f in
            let status: PullRequestFile.Status
            switch f.status {
            case "added": status = .added
            case "removed": status = .removed
            case "renamed", "copied": status = .renamed
            default: status = .modified
            }
            return PullRequestFile(path: f.filename, previousPath: f.previousFilename, status: status,
                                   additions: f.additions, deletions: f.deletions, patch: f.patch)
        }
    }

    public func pullRequestDiff(_ repository: String, number: Int) async throws -> String {
        let response = try await http.send("GET", "repos/\(repository)/pulls/\(number)", accept: "application/vnd.github.diff")
        return String(decoding: response.data, as: UTF8.self)
    }

    public func comments(_ repository: String, number: Int) async throws -> [PullRequestComment] {
        async let issueComments = http.getAll(Comment.self, "repos/\(repository)/issues/\(number)/comments", query: ["per_page": "100"])
        async let reviewComments = http.getAll(Comment.self, "repos/\(repository)/pulls/\(number)/comments", query: ["per_page": "100"])
        let general = try await issueComments.map {
            PullRequestComment(id: "issue-\($0.id)", author: $0.user?.model, body: $0.body, createdAt: $0.createdAt)
        }
        let inline = try await reviewComments.map {
            PullRequestComment(id: "review-\($0.id)", author: $0.user?.model, body: $0.body, createdAt: $0.createdAt,
                               path: $0.path, line: $0.line ?? $0.originalLine,
                               threadID: "review-\($0.inReplyToId ?? $0.id)")
        }
        return (general + inline).sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    @discardableResult
    public func addComment(_ repository: String, number: Int, body: String) async throws -> PullRequestComment {
        struct Body: Encodable, Sendable { var body: String }
        let c = try await http.post(Comment.self, "repos/\(repository)/issues/\(number)/comments", body: Body(body: body))
        return PullRequestComment(id: "issue-\(c.id)", author: c.user?.model, body: c.body, createdAt: c.createdAt)
    }

    @discardableResult
    public func addLineComment(_ repository: String, number: Int, _ draft: LineCommentDraft) async throws -> PullRequestComment {
        struct Body: Encodable, Sendable {
            var body: String
            var commitId: String
            var path: String
            var line: Int
            var side: String
        }
        let pr = try await pullRequest(repository, number: number)
        let body = Body(body: draft.body, commitId: pr.headSHA ?? "", path: draft.path, line: draft.line,
                        side: draft.onRemovedLine ? "LEFT" : "RIGHT")
        let c = try await http.post(Comment.self, "repos/\(repository)/pulls/\(number)/comments", body: body)
        return PullRequestComment(id: "review-\(c.id)", author: c.user?.model, body: c.body, createdAt: c.createdAt,
                                  path: c.path, line: c.line, threadID: "review-\(c.id)")
    }

    public func createPullRequest(_ repository: String, _ draft: PullRequestDraft) async throws -> PullRequest {
        struct Body: Encodable, Sendable {
            var title: String
            var body: String
            var head: String
            var base: String
            var draft: Bool
        }
        return try await http.post(Pull.self, "repos/\(repository)/pulls",
                                   body: Body(title: draft.title, body: draft.body, head: draft.sourceBranch,
                                              base: draft.targetBranch, draft: draft.isDraft)).model(repository: repository)
    }

    public func review(_ repository: String, number: Int, event: ReviewEvent, body: String) async throws {
        struct Body: Encodable, Sendable { var event: String; var body: String? }
        let e: String
        switch event {
        case .approve: e = "APPROVE"
        case .requestChanges: e = "REQUEST_CHANGES"
        case .comment: e = "COMMENT"
        }
        try await http.send("POST", "repos/\(repository)/pulls/\(number)/reviews", body: Body(event: e, body: body.isEmpty ? nil : body))
    }

    public func merge(_ repository: String, number: Int, method: MergeMethod, commitMessage: String?) async throws {
        struct Body: Encodable, Sendable { var mergeMethod: String; var commitMessage: String? }
        try await http.send("PUT", "repos/\(repository)/pulls/\(number)/merge",
                            body: Body(mergeMethod: method.rawValue, commitMessage: commitMessage))
    }

    // MARK: CI

    public func ciStatus(_ repository: String, ref: String) async throws -> CIStatus {
        async let checks = http.get(CheckRuns.self, "repos/\(repository)/commits/\(ref)/check-runs", query: ["per_page": "100"])
        async let statuses = http.get(CombinedStatus.self, "repos/\(repository)/commits/\(ref)/status")
        var runs: [CIRun] = try await checks.checkRuns.map { r in
            CIRun(id: "check-\(r.id)", name: r.name, state: Self.state(status: r.status, conclusion: r.conclusion),
                  webURL: r.htmlUrl ?? r.detailsUrl, startedAt: r.startedAt, completedAt: r.completedAt, group: r.app?.name)
        }
        runs += try await statuses.statuses.map { s in
            CIRun(id: "status-\(s.id)", name: s.context, state: Self.state(commitStatus: s.state), webURL: s.targetUrl,
                  startedAt: s.createdAt, completedAt: nil, group: nil)
        }
        return CIStatus(state: CIState.combine(runs.map(\.state)), runs: runs,
                        webURL: host.webURL.appending(path: "\(repository)/commit/\(ref)/checks"))
    }

    public func ciLog(_ repository: String, run: CIRun) async throws -> String {
        guard run.id.hasPrefix("check-") else { throw ForgeError.notFound }
        // Actions check-run ids are job ids.
        let jobID = run.id.dropFirst("check-".count)
        let response = try await http.send("GET", "repos/\(repository)/actions/jobs/\(jobID)/logs", accept: "*/*", useCache: false)
        return String(decoding: response.data, as: UTF8.self)
    }

    static func state(status: String, conclusion: String?) -> CIState {
        switch status {
        case "queued", "waiting", "requested", "pending": return .pending
        case "in_progress": return .running
        default: break
        }
        switch conclusion {
        case "success": return .success
        case "failure", "timed_out", "startup_failure", "action_required": return .failure
        case "cancelled": return .canceled
        case "skipped": return .skipped
        case "neutral", "stale": return .neutral
        default: return .none
        }
    }

    static func state(commitStatus: String) -> CIState {
        switch commitStatus {
        case "success": return .success
        case "failure", "error": return .failure
        case "pending": return .pending
        default: return .none
        }
    }

    // MARK: SSH keys

    public func sshKeys() async throws -> [ForgeSSHKey] {
        async let auth = http.getAll(Key.self, "user/keys", query: ["per_page": "100"])
        async let signing = http.getAll(Key.self, "user/ssh_signing_keys", query: ["per_page": "100"])
        let a = try await auth.map { ForgeSSHKey(id: "auth-\($0.id)", title: $0.title ?? "", key: $0.key, usage: .authentication, createdAt: $0.createdAt) }
        let s = (try? await signing.map { ForgeSSHKey(id: "signing-\($0.id)", title: $0.title ?? "", key: $0.key, usage: .signing, createdAt: $0.createdAt) }) ?? []
        return a + s
    }

    /// GitHub registers authentication and signing keys separately; for
    /// `.authenticationAndSigning` both are created.
    @discardableResult
    public func addSSHKey(title: String, publicKey: String, usage: ForgeSSHKey.Usage) async throws -> ForgeSSHKey {
        struct Body: Encodable, Sendable { var title: String; var key: String }
        let body = Body(title: title, key: publicKey)
        var result: ForgeSSHKey?
        if usage != .signing {
            let k = try await http.post(Key.self, "user/keys", body: body)
            result = ForgeSSHKey(id: "auth-\(k.id)", title: k.title ?? title, key: k.key, usage: usage, createdAt: k.createdAt)
        }
        if usage != .authentication {
            let k = try await http.post(Key.self, "user/ssh_signing_keys", body: body)
            result = result ?? ForgeSSHKey(id: "signing-\(k.id)", title: k.title ?? title, key: k.key, usage: usage, createdAt: k.createdAt)
        }
        return result!
    }

    // MARK: GraphQL review threads

    public struct ReviewThread: Sendable, Hashable, Identifiable {
        public var id: String
        public var path: String
        public var line: Int?
        public var isResolved: Bool
        public var comments: [PullRequestComment]
    }

    struct ThreadsData: Decodable, Sendable {
        struct Repo: Decodable, Sendable { var pullRequest: PR }
        struct PR: Decodable, Sendable { var reviewThreads: Threads }
        struct Threads: Decodable, Sendable { var nodes: [Thread] }
        struct Thread: Decodable, Sendable {
            var id: String
            var path: String
            var line: Int?
            var isResolved: Bool
            var comments: Comments
        }
        struct Comments: Decodable, Sendable { var nodes: [C] }
        struct C: Decodable, Sendable {
            struct Author: Decodable, Sendable { var login: String; var avatarUrl: URL? }
            var id: String
            var body: String
            var createdAt: Date?
            var author: Author?
        }
        var repository: Repo
    }

    /// Review threads with their resolved state (GraphQL only).
    public func reviewThreads(_ repository: String, number: Int) async throws -> [ReviewThread] {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ForgeError.notFound }
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 100) {
                nodes { id path line isResolved comments(first: 50) { nodes { id body createdAt author { login avatarUrl } } } }
              }
            }
          }
        }
        """
        let data = try await http.graphQL(ThreadsData.self, url: host.graphQLURL, query: query,
                                          variables: ["owner": .string(parts[0]), "name": .string(parts[1]), "number": .int(number)])
        return data.repository.pullRequest.reviewThreads.nodes.map { t in
            ReviewThread(id: t.id, path: t.path, line: t.line, isResolved: t.isResolved, comments: t.comments.nodes.map { c in
                PullRequestComment(id: c.id, author: c.author.map { ForgeUser(id: $0.login, login: $0.login, avatarURL: $0.avatarUrl) },
                                   body: c.body, createdAt: c.createdAt, path: t.path, line: t.line, threadID: t.id, isResolved: t.isResolved)
            })
        }
    }
}
