public import Foundation

/// GitLab REST v4 client (gitlab.com and self-hosted instances).
public struct GitLabClient: ForgeClient {
    public let host: ForgeHost
    let http: ForgeHTTP

    public init(host: ForgeHost = .gitlab, session: URLSession = .shared, token: @escaping ForgeHTTP.TokenSource) {
        self.host = host
        self.http = ForgeHTTP(baseURL: host.apiURL, session: session, token: token)
    }

    /// `group/sub/project` -> `group%2Fsub%2Fproject`.
    static func projectID(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path
    }

    func project(_ path: String) -> String { "projects/\(Self.projectID(path))" }

    // MARK: DTOs

    struct User: Decodable, Sendable {
        var id: Int
        var username: String
        var name: String?
        var avatarUrl: URL?
        var webUrl: URL?
        var model: ForgeUser { ForgeUser(id: String(id), login: username, name: name, avatarURL: avatarUrl, webURL: webUrl) }
    }

    struct Group: Decodable, Sendable {
        var id: Int
        var fullPath: String
        var name: String?
        var avatarUrl: URL?
    }

    struct Project: Decodable, Sendable {
        struct Namespace: Decodable, Sendable { var fullPath: String }
        struct Statistics: Decodable, Sendable { var repositorySize: Int?; var lfsObjectsSize: Int? }
        struct Fork: Decodable, Sendable { var id: Int }
        var id: Int
        var name: String
        var path: String?
        var pathWithNamespace: String
        var namespace: Namespace?
        var description: String?
        var visibility: String?
        var forkedFromProject: Fork?
        var archived: Bool?
        var defaultBranch: String?
        var httpUrlToRepo: String
        var sshUrlToRepo: String?
        var webUrl: URL?
        var starCount: Int?
        var lastActivityAt: Date?
        var statistics: Statistics?
        var lfsEnabled: Bool?

        var model: ForgeRepository {
            ForgeRepository(id: String(id), fullName: pathWithNamespace,
                            owner: namespace?.fullPath ?? String(pathWithNamespace.split(separator: "/").dropLast().joined(separator: "/")),
                            name: path ?? name, description: description, isPrivate: visibility != "public",
                            isFork: forkedFromProject != nil, isArchived: archived ?? false, defaultBranch: defaultBranch,
                            httpsCloneURL: httpUrlToRepo, sshCloneURL: sshUrlToRepo, webURL: webUrl, stars: starCount ?? 0,
                            language: nil, updatedAt: lastActivityAt,
                            sizeKB: statistics?.repositorySize.map { $0 / 1024 },
                            hasLFS: statistics?.lfsObjectsSize.map { $0 > 0 })
        }
    }

    struct Branch: Decodable, Sendable {
        struct Commit: Decodable, Sendable { var id: String }
        var name: String
        var commit: Commit
        var protected: Bool?
        var `default`: Bool?
    }

    struct MergeRequest: Decodable, Sendable {
        struct Username: Decodable, Sendable { var username: String }
        struct References: Decodable, Sendable { var full: String? }
        struct DiffRefs: Decodable, Sendable { var baseSha: String?; var headSha: String?; var startSha: String? }
        var iid: Int
        var title: String
        var description: String?
        var state: String
        var draft: Bool?
        var workInProgress: Bool?
        var author: User?
        var sourceBranch: String
        var targetBranch: String
        var sha: String?
        var webUrl: URL?
        var createdAt: Date?
        var updatedAt: Date?
        var labels: [String]?
        var reviewers: [Username]?
        var detailedMergeStatus: String?
        var mergeStatus: String?
        var hasConflicts: Bool?
        var userNotesCount: Int?
        var changesCount: String?
        var references: References?
        var diffRefs: DiffRefs?

        func model(repository: String) -> PullRequest {
            let repo = references?.full.map { String($0.split(separator: "!").first ?? "") } ?? repository
            let mergeable: Bool?
            switch detailedMergeStatus ?? mergeStatus {
            case "mergeable", "can_be_merged": mergeable = true
            case "checking", "unchecked", "preparing", nil: mergeable = nil
            default: mergeable = false
            }
            return PullRequest(number: iid, title: title, body: description ?? "",
                               state: state == "merged" ? .merged : (state == "opened" ? .open : .closed),
                               isDraft: draft ?? workInProgress ?? false, author: author?.model,
                               repository: repo.isEmpty ? repository : repo,
                               sourceBranch: sourceBranch, targetBranch: targetBranch, headSHA: sha, webURL: webUrl,
                               createdAt: createdAt, updatedAt: updatedAt, labels: labels ?? [],
                               reviewers: reviewers?.map(\.username) ?? [], isMergeable: mergeable,
                               changedFiles: changesCount.flatMap { Int($0.filter(\.isNumber)) }, commentCount: userNotesCount)
        }
    }

    struct Diff: Decodable, Sendable {
        var oldPath: String
        var newPath: String
        var diff: String
        var newFile: Bool
        var renamedFile: Bool
        var deletedFile: Bool
    }

    struct Note: Decodable, Sendable {
        struct Position: Decodable, Sendable { var newPath: String?; var newLine: Int?; var oldPath: String?; var oldLine: Int? }
        var id: Int
        var body: String
        var author: User?
        var createdAt: Date?
        var system: Bool?
        var position: Position?
        var resolved: Bool?
    }

    struct Discussion: Decodable, Sendable {
        var id: String
        var notes: [Note]
    }

    struct Pipeline: Decodable, Sendable {
        var id: Int
        var status: String
        var webUrl: URL?
        var sha: String?
    }

    struct Job: Decodable, Sendable {
        var id: Int
        var name: String
        var stage: String?
        var status: String
        var webUrl: URL?
        var startedAt: Date?
        var finishedAt: Date?
    }

    struct Key: Decodable, Sendable {
        var id: Int
        var title: String
        var key: String
        var createdAt: Date?
        var usageType: String?
    }

    // MARK: Users and repositories

    public func currentUser() async throws -> ForgeUser {
        try await http.get(User.self, "user").model
    }

    public func organizations() async throws -> [ForgeOrganization] {
        try await http.getAll(Group.self, "groups", query: ["min_access_level": "10", "per_page": "100"]).map {
            ForgeOrganization(id: String($0.id), login: $0.fullPath, name: $0.name, avatarURL: $0.avatarUrl)
        }
    }

    public func repositories(cursor: String?) async throws -> ForgePage<ForgeRepository> {
        let page = Int(cursor ?? "1") ?? 1
        let response = try await http.send("GET", "projects", query: [
            "membership": "true", "order_by": "last_activity_at", "per_page": "50", "page": String(page), "statistics": "true",
        ])
        let projects = try await http.decode([Project].self, response.data)
        let next = response.headers["x-next-page"].flatMap { $0.isEmpty ? nil : $0 } ?? (response.nextURL != nil ? String(page + 1) : nil)
        return ForgePage(items: projects.map(\.model), nextCursor: next)
    }

    public func repositories(organization: String) async throws -> [ForgeRepository] {
        try await http.getAll(Project.self, "groups/\(Self.projectID(organization))/projects",
                              query: ["include_subgroups": "true", "per_page": "100", "order_by": "last_activity_at"]).map(\.model)
    }

    public func searchRepositories(_ query: String) async throws -> [ForgeRepository] {
        try await http.get([Project].self, "projects", query: ["search": query, "per_page": "30", "order_by": "last_activity_at"]).map(\.model)
    }

    public func repository(_ fullName: String) async throws -> ForgeRepository {
        try await http.get(Project.self, project(fullName)).model
    }

    public func branches(_ repository: String) async throws -> [ForgeBranch] {
        try await http.getAll(Branch.self, "\(project(repository))/repository/branches", query: ["per_page": "100"]).map {
            ForgeBranch(name: $0.name, commit: $0.commit.id, isProtected: $0.protected ?? false, isDefault: $0.default ?? false)
        }
    }

    public func tags(_ repository: String) async throws -> [ForgeTag] {
        try await http.getAll(Branch.self, "\(project(repository))/repository/tags", query: ["per_page": "100"]).map {
            ForgeTag(name: $0.name, commit: $0.commit.id)
        }
    }

    public func readme(_ repository: String) async throws -> String? {
        let repo = try await self.repository(repository)
        for name in ["README.md", "README", "readme.md", "README.rst"] {
            do {
                let response = try await http.send("GET", "\(project(repository))/repository/files/\(Self.projectID(name))/raw",
                                                   query: ["ref": repo.defaultBranch ?? "HEAD"], accept: "*/*")
                return String(decoding: response.data, as: UTF8.self)
            } catch ForgeError.notFound {
                continue
            }
        }
        return nil
    }

    // MARK: Merge requests

    public func pullRequests(_ filter: PullRequestFilter) async throws -> [PullRequest] {
        switch filter {
        case .repository(let repo, let state):
            let s: String
            switch state {
            case .open: s = "opened"
            case .closed: s = "closed"
            case .merged: s = "merged"
            }
            return try await http.get([MergeRequest].self, "\(project(repo))/merge_requests",
                                      query: ["state": s, "per_page": "50", "order_by": "updated_at"]).map { $0.model(repository: repo) }
        case .authoredByMe:
            return try await http.get([MergeRequest].self, "merge_requests",
                                      query: ["scope": "created_by_me", "state": "opened", "per_page": "50"]).map { $0.model(repository: "") }
        case .reviewRequested:
            let me = try await currentUser()
            return try await http.get([MergeRequest].self, "merge_requests",
                                      query: ["scope": "all", "reviewer_username": me.login, "state": "opened", "per_page": "50"]).map { $0.model(repository: "") }
        }
    }

    public func pullRequest(_ repository: String, number: Int) async throws -> PullRequest {
        try await mergeRequest(repository, number).model(repository: repository)
    }

    func mergeRequest(_ repository: String, _ iid: Int) async throws -> MergeRequest {
        try await http.get(MergeRequest.self, "\(project(repository))/merge_requests/\(iid)")
    }

    public func pullRequestFiles(_ repository: String, number: Int) async throws -> [PullRequestFile] {
        try await http.getAll(Diff.self, "\(project(repository))/merge_requests/\(number)/diffs", query: ["per_page": "100"], maxPages: 30).map { d in
            let lines = d.diff.split(separator: "\n", omittingEmptySubsequences: false)
            let additions = lines.count { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            let deletions = lines.count { $0.hasPrefix("-") && !$0.hasPrefix("---") }
            let status: PullRequestFile.Status = d.newFile ? .added : d.deletedFile ? .removed : d.renamedFile ? .renamed : .modified
            return PullRequestFile(path: d.newPath, previousPath: d.renamedFile ? d.oldPath : nil, status: status,
                                   additions: additions, deletions: deletions, patch: d.diff.isEmpty ? nil : d.diff)
        }
    }

    public func pullRequestDiff(_ repository: String, number: Int) async throws -> String {
        let files = try await pullRequestFiles(repository, number: number)
        return files.map { f in
            let old = f.previousPath ?? f.path
            let header = "diff --git a/\(old) b/\(f.path)\n--- \(f.status == .added ? "/dev/null" : "a/\(old)")\n+++ \(f.status == .removed ? "/dev/null" : "b/\(f.path)")\n"
            return header + (f.patch ?? "")
        }.joined()
    }

    public func comments(_ repository: String, number: Int) async throws -> [PullRequestComment] {
        let discussions = try await http.getAll(Discussion.self, "\(project(repository))/merge_requests/\(number)/discussions",
                                                query: ["per_page": "100"])
        return discussions.flatMap { d in
            d.notes.filter { $0.system != true }.map { n in
                PullRequestComment(id: String(n.id), author: n.author?.model, body: n.body, createdAt: n.createdAt,
                                   path: n.position?.newPath ?? n.position?.oldPath, line: n.position?.newLine ?? n.position?.oldLine,
                                   threadID: d.id, isResolved: n.resolved)
            }
        }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    @discardableResult
    public func addComment(_ repository: String, number: Int, body: String) async throws -> PullRequestComment {
        struct Body: Encodable, Sendable { var body: String }
        let n = try await http.post(Note.self, "\(project(repository))/merge_requests/\(number)/notes", body: Body(body: body))
        return PullRequestComment(id: String(n.id), author: n.author?.model, body: n.body, createdAt: n.createdAt)
    }

    @discardableResult
    public func addLineComment(_ repository: String, number: Int, _ draft: LineCommentDraft) async throws -> PullRequestComment {
        struct Position: Encodable, Sendable {
            var positionType = "text"
            var baseSha: String
            var startSha: String
            var headSha: String
            var newPath: String
            var oldPath: String
            var newLine: Int?
            var oldLine: Int?
        }
        struct Body: Encodable, Sendable { var body: String; var position: Position }
        let mr = try await mergeRequest(repository, number)
        guard let refs = mr.diffRefs, let base = refs.baseSha, let start = refs.startSha, let head = refs.headSha else {
            throw ForgeError.validation("merge request has no diff yet")
        }
        let position = Position(baseSha: base, startSha: start, headSha: head, newPath: draft.path, oldPath: draft.path,
                                newLine: draft.onRemovedLine ? nil : draft.line, oldLine: draft.onRemovedLine ? draft.line : nil)
        let d = try await http.post(Discussion.self, "\(project(repository))/merge_requests/\(number)/discussions",
                                    body: Body(body: draft.body, position: position))
        let n = d.notes.first
        return PullRequestComment(id: String(n?.id ?? 0), author: n?.author?.model, body: n?.body ?? draft.body, createdAt: n?.createdAt,
                                  path: draft.path, line: draft.line, threadID: d.id)
    }

    public func createPullRequest(_ repository: String, _ draft: PullRequestDraft) async throws -> PullRequest {
        struct Body: Encodable, Sendable {
            var sourceBranch: String
            var targetBranch: String
            var title: String
            var description: String
        }
        let title = draft.isDraft && !draft.title.hasPrefix("Draft:") ? "Draft: \(draft.title)" : draft.title
        return try await http.post(MergeRequest.self, "\(project(repository))/merge_requests",
                                   body: Body(sourceBranch: draft.sourceBranch, targetBranch: draft.targetBranch,
                                              title: title, description: draft.body)).model(repository: repository)
    }

    /// Approve uses the approvals API; "request changes" removes the
    /// user's approval and leaves the body as a comment.
    public func review(_ repository: String, number: Int, event: ReviewEvent, body: String) async throws {
        switch event {
        case .approve:
            try await http.send("POST", "\(project(repository))/merge_requests/\(number)/approve")
            if !body.isEmpty { try await addComment(repository, number: number, body: body) }
        case .requestChanges:
            _ = try? await http.send("POST", "\(project(repository))/merge_requests/\(number)/unapprove")
            try await addComment(repository, number: number, body: body.isEmpty ? "Changes requested." : body)
        case .comment:
            try await addComment(repository, number: number, body: body)
        }
    }

    public func merge(_ repository: String, number: Int, method: MergeMethod, commitMessage: String?) async throws {
        struct Body: Encodable, Sendable { var squash: Bool; var mergeCommitMessage: String?; var squashCommitMessage: String? }
        if method == .rebase {
            try await http.send("PUT", "\(project(repository))/merge_requests/\(number)/rebase")
            // Rebases run asynchronously; wait for GitLab to finish.
            struct State: Decodable, Sendable { var rebaseInProgress: Bool?; var mergeError: String? }
            for _ in 0..<30 {
                let s = try await http.get(State.self, "\(project(repository))/merge_requests/\(number)", query: ["include_rebase_in_progress": "true"])
                if let error = s.mergeError { throw ForgeError.validation(error) }
                if s.rebaseInProgress != true { break }
                try await Task.sleep(for: .seconds(1))
            }
        }
        try await http.send("PUT", "\(project(repository))/merge_requests/\(number)/merge",
                            body: Body(squash: method == .squash,
                                       mergeCommitMessage: method == .merge ? commitMessage : nil,
                                       squashCommitMessage: method == .squash ? commitMessage : nil))
    }

    // MARK: CI

    public func ciStatus(_ repository: String, ref: String) async throws -> CIStatus {
        let isSHA = ref.count == 40 && ref.allSatisfy(\.isHexDigit)
        let pipelines = try await http.get([Pipeline].self, "\(project(repository))/pipelines",
                                           query: [isSHA ? "sha" : "ref": ref, "per_page": "1", "order_by": "id", "sort": "desc"])
        guard let pipeline = pipelines.first else { return CIStatus(state: .none, runs: []) }
        let jobs = try await http.getAll(Job.self, "\(project(repository))/pipelines/\(pipeline.id)/jobs", query: ["per_page": "100"])
        let runs = jobs.map { j in
            CIRun(id: String(j.id), name: j.name, state: Self.state(j.status), webURL: j.webUrl,
                  startedAt: j.startedAt, completedAt: j.finishedAt, group: j.stage)
        }
        return CIStatus(state: Self.state(pipeline.status), runs: runs, webURL: pipeline.webUrl)
    }

    public func ciLog(_ repository: String, run: CIRun) async throws -> String {
        let response = try await http.send("GET", "\(project(repository))/jobs/\(run.id)/trace", accept: "*/*", useCache: false)
        return String(decoding: response.data, as: UTF8.self)
    }

    static func state(_ status: String) -> CIState {
        switch status {
        case "success": return .success
        case "failed": return .failure
        case "running": return .running
        case "created", "pending", "waiting_for_resource", "preparing", "scheduled", "manual": return .pending
        case "canceled", "canceling": return .canceled
        case "skipped": return .skipped
        default: return .none
        }
    }

    // MARK: SSH keys

    public func sshKeys() async throws -> [ForgeSSHKey] {
        try await http.getAll(Key.self, "user/keys", query: ["per_page": "100"]).map {
            ForgeSSHKey(id: String($0.id), title: $0.title, key: $0.key, usage: Self.usage($0.usageType), createdAt: $0.createdAt)
        }
    }

    @discardableResult
    public func addSSHKey(title: String, publicKey: String, usage: ForgeSSHKey.Usage) async throws -> ForgeSSHKey {
        struct Body: Encodable, Sendable { var title: String; var key: String; var usageType: String }
        let type: String
        switch usage {
        case .authentication: type = "auth"
        case .signing: type = "signing"
        case .authenticationAndSigning: type = "auth_and_signing"
        }
        let k = try await http.post(Key.self, "user/keys", body: Body(title: title, key: publicKey, usageType: type))
        return ForgeSSHKey(id: String(k.id), title: k.title, key: k.key, usage: Self.usage(k.usageType), createdAt: k.createdAt)
    }

    static func usage(_ type: String?) -> ForgeSSHKey.Usage {
        switch type {
        case "auth": return .authentication
        case "signing": return .signing
        default: return .authenticationAndSigning
        }
    }
}
