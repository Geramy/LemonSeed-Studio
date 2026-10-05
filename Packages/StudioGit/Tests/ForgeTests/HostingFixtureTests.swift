import Foundation
import Testing
@testable import Forge

/// A recorded API response from Tests/ForgeTests/Fixtures.
func fixture(_ name: String) -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
        fatalError("missing fixture \(name).json")
    }
    return text
}

/// Repository listing, settings and pull request work against recorded
/// GitHub responses. No network: every request is answered by StubServer.
@Suite struct GitHubHostingTests {
    let server = StubServer()
    var client: GitHubClient { GitHubClient(session: server.session) { "ghp_token" } }

    func variables(_ request: StubServer.Request) -> [String: Any] { request.json["variables"] as? [String: Any] ?? [:] }

    @Test func listsAllRepositoriesAcrossPagesWithIndicators() async throws {
        server.on("POST", "/graphql") { req in
            (self.variables(req)["after"] as? String) == nil
                ? .json(fixture("github/graphql-viewer-repos-page1")) : .json(fixture("github/graphql-viewer-repos-page2"))
        }
        let first = try await client.repositories(.all, cursor: nil)
        #expect(first.items.map(\.fullName) == ["lemonade-sdk/amdgpu_mtopg", "octo-dev/notes"])
        let cursor = try #require(first.nextCursor)
        let second = try await client.repositories(.all, cursor: cursor)
        #expect(second.nextCursor == nil)
        #expect(second.items.map(\.fullName) == ["octo-dev/LSE", "octo-dev/gpu-notes-2024"])

        #expect(first.items[1].isPrivate && first.items[1].defaultBranch == "trunk")
        #expect(second.items[0].isFork && !second.items[0].isArchived)
        #expect(second.items[1].isArchived && second.items[1].defaultBranch == nil)

        let requests = server.requests("POST", "/graphql")
        #expect(requests.count == 2)
        #expect(variables(requests[1])["after"] as? String == cursor)
        #expect(variables(requests[0])["affiliations"] as? [String] == ["OWNER", "COLLABORATOR", "ORGANIZATION_MEMBER"])
        #expect(try await client.allRepositories().count == 4)
    }

    @Test func ownedAndOrganizationScopes() async throws {
        server.on("POST", "/graphql") { req in
            let query = req.json["query"] as? String ?? ""
            if query.contains("repositoryOwner") {
                return (self.variables(req)["login"] as? String) == "nobody"
                    ? .json(fixture("github/graphql-owner-missing")) : .json(fixture("github/graphql-owner-repos"))
            }
            return .json(fixture("github/graphql-viewer-repos-page2"))
        }
        _ = try await client.repositories(.owned, cursor: nil)
        #expect(variables(server.requests.last!)["affiliations"] as? [String] == ["OWNER"])

        let org = try await client.repositories(.organization("lemonade-sdk"), cursor: nil)
        #expect(org.items.map(\.owner) == ["lemonade-sdk"])
        #expect(variables(server.requests.last!)["login"] as? String == "lemonade-sdk")

        await #expect(throws: ForgeError.validation("No GitHub account or organization named nobody.")) {
            _ = try await client.repositories(.organization("nobody"), cursor: nil)
        }
    }

    @Test func scopedSearchAddsOwnerAndForkQualifiers() async throws {
        server.on("GET", "/search/repositories", json: #"{"items":[]}"#)
        server.on("GET", "/user", json: #"{"id":9001,"login":"octo-dev"}"#)
        _ = try await client.searchRepositories("gpu", scope: .organization("lemonade-sdk"))
        #expect(server.requests("GET", "/search/repositories").last?.query["q"] == "gpu user:lemonade-sdk fork:true")
        _ = try await client.searchRepositories("gpu", scope: .owned)
        #expect(server.requests("GET", "/search/repositories").last?.query["q"] == "gpu user:octo-dev fork:true")
        _ = try await client.searchRepositories("gpu language:c", scope: .all)
        #expect(server.requests("GET", "/search/repositories").last?.query["q"] == "gpu language:c")
    }

    @Test func repositorySettingsMapMergeMethodsAndPermission() async throws {
        server.on("POST", "/graphql", json: fixture("github/graphql-repo-settings"))
        let settings = try await client.repositorySettings("lemonade-sdk/amdgpu_mtopg")
        #expect(settings.allowedMergeMethods == [.squash, .rebase])
        #expect(settings.permission == .maintain)
        #expect(settings.canPush && settings.canTriage)
        #expect(settings.defaultBranch == "main")
        #expect(variables(server.requests[0])["owner"] as? String == "lemonade-sdk")
        await #expect(throws: ForgeError.self) { _ = try await client.repositorySettings("not-a-full-name") }
    }

    @Test func repositoryScopedPullRequestFilters() async throws {
        server.on("GET", "/search/issues", json: fixture("github/search-issues-merged"))
        let merged = try await client.pullRequests(.repositoryAuthoredByMe("lemonade-sdk/amdgpu_mtopg", state: .merged))
        #expect(merged.first?.state == .merged)
        #expect(merged.first?.repository == "lemonade-sdk/amdgpu_mtopg")
        #expect(server.requests.last?.query["q"] == "is:pr repo:lemonade-sdk/amdgpu_mtopg author:@me is:merged")
        _ = try await client.pullRequests(.repositoryAuthoredByMe("o/r", state: .closed))
        #expect(server.requests.last?.query["q"] == "is:pr repo:o/r author:@me is:closed is:unmerged")
        _ = try await client.pullRequests(.repositoryReviewRequested("o/r"))
        #expect(server.requests.last?.query["q"] == "is:pr repo:o/r is:open review-requested:@me")
    }

    @Test func createFromForkWithReviewersAndLabels() async throws {
        server.on("POST", "/repos/lemonade-sdk/amdgpu_mtopg/pulls", json: fixture("github/pull"), status: 201)
        server.on("POST", "/repos/lemonade-sdk/amdgpu_mtopg/pulls/12/requested_reviewers", json: fixture("github/pull-with-reviewers"), status: 201)
        server.on("POST", "/repos/lemonade-sdk/amdgpu_mtopg/issues/12/labels", json: fixture("github/labels"))
        let draft = PullRequestDraft(title: "Telemetry: per-queue occupancy sparkline", body: "Adds a sparkline.",
                                     sourceBranch: "sparkline", targetBranch: "main", isDraft: true,
                                     reviewers: ["bob", "carol"], labels: ["telemetry", "ui"], sourceRepository: "octo-dev/amdgpu_mtopg")
        let pr = try await client.createPullRequest("lemonade-sdk/amdgpu_mtopg", draft)
        #expect(pr.number == 12)
        #expect(pr.isDraft && pr.isCrossRepository && pr.sourceRepository == "octo-dev/amdgpu_mtopg")
        #expect(pr.reviewers == ["bob", "carol"])
        #expect(pr.labels == ["telemetry", "ui"])
        let create = try #require(server.requests("POST", "/repos/lemonade-sdk/amdgpu_mtopg/pulls").first?.json)
        #expect(create["head"] as? String == "octo-dev:sparkline")
        #expect(create["draft"] as? Bool == true)
        let reviewers = try #require(server.requests("POST", "/repos/lemonade-sdk/amdgpu_mtopg/pulls/12/requested_reviewers").first?.json)
        #expect(reviewers["reviewers"] as? [String] == ["bob", "carol"])
        #expect(server.requests("POST", "/repos/lemonade-sdk/amdgpu_mtopg/issues/12/labels").first?.json["labels"] as? [String] == ["telemetry", "ui"])
    }

    @Test func reviewerFailureStillReturnsTheCreatedRequest() async throws {
        server.on("POST", "/repos/o/r/pulls", json: fixture("github/pull"), status: 201)
        server.on("POST", "/repos/o/r/pulls/12/requested_reviewers", json: fixture("github/error-validation-reviewers"), status: 422)
        do {
            _ = try await client.createPullRequest("o/r", PullRequestDraft(title: "T", sourceBranch: "sparkline", targetBranch: "main", reviewers: ["mallory"]))
            Issue.record("expected a partial failure")
        } catch let error as PartialPullRequestError {
            #expect(error.pullRequest.number == 12)
            #expect(error.description.contains("Opened #12"))
            #expect(error.description.contains("mallory"))
            #expect(error.description.contains("not a collaborator"))
        }
    }

    @Test func commitsMergeCloseAndReopen() async throws {
        server.on("GET", "/repos/o/r/pulls/12/commits", json: fixture("github/pull-commits"))
        server.on("PUT", "/repos/o/r/pulls/12/merge", json: #"{"sha":"abc","merged":true,"message":"Pull Request successfully merged"}"#)
        server.on("PATCH", "/repos/o/r/pulls/12") { req in
            req.json["state"] as? String == "closed" ? .json(fixture("github/pull-closed")) : .json(fixture("github/pull"))
        }
        let commits = try await client.pullRequestCommits("o/r", number: 12)
        #expect(commits.map(\.shortSHA) == ["9f3c2a1", "4f2a9c1"])
        #expect(commits[0].authorLogin == "octo-dev" && commits[1].authorLogin == nil)
        #expect(commits[1].summary == "QueueRow: show occupancy history")
        #expect(commits[1].authorName == "Octo Dev")

        try await client.merge("o/r", number: 12, method: .rebase, commitMessage: nil)
        #expect(server.requests("PUT", "/repos/o/r/pulls/12/merge").first?.json["merge_method"] as? String == "rebase")

        let closed = try await client.setPullRequestState("o/r", number: 12, open: false)
        #expect(closed.state == .closed)
        let reopened = try await client.setPullRequestState("o/r", number: 12, open: true)
        #expect(reopened.state == .open)
        #expect(server.requests("PATCH", "/repos/o/r/pulls/12").map { $0.json["state"] as? String } == ["closed", "open"])
    }

    @Test func apiErrorsAreSpecific() async throws {
        server.on("PUT", "/repos/o/r/pulls/12/merge", json: fixture("github/error-not-mergeable"), status: 405)
        await #expect(throws: ForgeError.validation("Pull Request is not mergeable")) {
            try await client.merge("o/r", number: 12, method: .merge, commitMessage: nil)
        }
        server.on("POST", "/repos/o/r/pulls", json: fixture("github/error-validation-head"), status: 422)
        await #expect(throws: ForgeError.validation("Validation Failed (A pull request already exists for octo-dev:sparkline.)")) {
            _ = try await client.createPullRequest("o/r", PullRequestDraft(title: "T", sourceBranch: "sparkline", targetBranch: "main"))
        }
        // A classic token without `repo` sees private repositories as 404.
        server.on("GET", "/repos/o/private", json: #"{"message":"Not Found"}"#, status: 404,
                  headers: ["X-OAuth-Scopes": "read:org, workflow", "X-Accepted-OAuth-Scopes": "repo"])
        await #expect(throws: ForgeError.forbidden("Not found with this token: it lacks the repo scope.")) {
            _ = try await client.repository("o/private")
        }
        server.on("POST", "/repos/o/r/pulls/12/reviews", json: #"{"message":"Resource not accessible by integration"}"#, status: 403,
                  headers: ["X-OAuth-Scopes": "", "X-Accepted-OAuth-Scopes": "repo"])
        await #expect(throws: ForgeError.forbidden("Resource not accessible by integration The token lacks the repo scope.")) {
            try await client.review("o/r", number: 12, event: .approve, body: "")
        }
    }
}

/// The same against recorded GitLab responses (a self-hosted instance).
@Suite struct GitLabHostingTests {
    let server = StubServer()
    static let host = ForgeHost(kind: .gitlab, webURL: URL(string: "https://gitlab.example.com")!)
    var client: GitLabClient { GitLabClient(host: Self.host, session: server.session) { "glpat-token" } }
    let project = "/api/v4/projects/lemonade%2Ftools%2Famdgpu_mtopg"

    @Test func pagesAndScopes() async throws {
        server.on("GET", "/api/v4/projects") { req in
            req.query["page"] == "2" ? .json(fixture("gitlab/projects-page2"), headers: ["X-Next-Page": ""])
                : .json(fixture("gitlab/projects-page1"), headers: ["X-Next-Page": "2", "X-Total-Pages": "2"])
        }
        let first = try await client.repositories(.all, cursor: nil)
        #expect(first.nextCursor == "2")
        let repo = try #require(first.items.first)
        #expect(repo.fullName == "lemonade/tools/amdgpu_mtopg" && repo.owner == "lemonade/tools")
        #expect(repo.isPrivate && repo.hasLFS == true && repo.sizeKB == 2400)
        #expect(server.requests.last?.query["membership"] == "true")
        let second = try await client.repositories(.all, cursor: "2")
        #expect(second.nextCursor == nil)
        #expect(second.items.first?.isFork == true && second.items.first?.isArchived == true && second.items.first?.isPrivate == false)

        _ = try await client.repositories(.owned, cursor: nil)
        #expect(server.requests.last?.query["owned"] == "true")
        server.on("GET", "/api/v4/groups/lemonade%2Ftools/projects", json: fixture("gitlab/projects-page1"))
        _ = try await client.repositories(.organization("lemonade/tools"), cursor: nil)
        #expect(server.requests.last?.query["include_subgroups"] == "true")
        _ = try await client.searchRepositories("gpu", scope: .organization("lemonade/tools"))
        #expect(server.requests.last?.query["search"] == "gpu")
    }

    @Test func settingsFromMergeMethodAndAccessLevel() async throws {
        server.on("GET", project, json: fixture("gitlab/project-settings"))
        let settings = try await client.repositorySettings("lemonade/tools/amdgpu_mtopg")
        #expect(settings.allowedMergeMethods == [.merge, .squash, .rebase])
        #expect(settings.permission == .write)
        #expect(settings.canPush)
    }

    @Test func mergeRequestFilters() async throws {
        server.on("GET", "\(project)/merge_requests", json: "[\(fixture("gitlab/merge-request"))]")
        server.on("GET", "/api/v4/user", json: fixture("gitlab/user"))
        let mine = try await client.pullRequests(.repositoryAuthoredByMe("lemonade/tools/amdgpu_mtopg", state: .merged))
        #expect(mine.first?.number == 5 && mine.first?.isDraft == true)
        #expect(server.requests.last?.query["scope"] == "created_by_me")
        #expect(server.requests.last?.query["state"] == "merged")
        _ = try await client.pullRequests(.repositoryReviewRequested("lemonade/tools/amdgpu_mtopg"))
        #expect(server.requests.last?.query["reviewer_username"] == "octo")
        #expect(server.requests.last?.query["state"] == "opened")
    }

    @Test func createWithReviewersLabelsAndDraft() async throws {
        server.on("GET", "/api/v4/users") { req in
            req.query["username"] == "bob" ? .json(fixture("gitlab/users-bob")) : .json("[]")
        }
        server.on("POST", "\(project)/merge_requests", json: fixture("gitlab/merge-request"), status: 201)
        let draft = PullRequestDraft(title: "Sparkline for queue occupancy", body: "Adds a sparkline.", sourceBranch: "sparkline",
                                     targetBranch: "main", isDraft: true, reviewers: ["@bob"].map { $0.replacingOccurrences(of: "@", with: "") },
                                     labels: ["telemetry", "ui"])
        let mr = try await client.createPullRequest("lemonade/tools/amdgpu_mtopg", draft)
        #expect(mr.number == 5 && mr.reviewers == ["bob"] && !mr.isCrossRepository)
        let body = try #require(server.requests("POST", "\(project)/merge_requests").first?.json)
        #expect(body["title"] as? String == "Draft: Sparkline for queue occupancy")
        #expect(body["reviewer_ids"] as? [Int] == [7])
        #expect(body["labels"] as? String == "telemetry,ui")
        #expect(body["target_project_id"] == nil)

        // An unknown reviewer fails before anything is created.
        let before = server.requests("POST", "\(project)/merge_requests").count
        await #expect(throws: ForgeError.validation("No GitLab user named nobody.")) {
            _ = try await client.createPullRequest("lemonade/tools/amdgpu_mtopg",
                                                   PullRequestDraft(title: "x", sourceBranch: "a", targetBranch: "main", reviewers: ["nobody"]))
        }
        #expect(server.requests("POST", "\(project)/merge_requests").count == before)
    }

    @Test func forkRequestIsCreatedInTheFork() async throws {
        server.on("GET", project, json: fixture("gitlab/project-target"))
        server.on("POST", "/api/v4/projects/octo%2Famdgpu_mtopg/merge_requests", json: fixture("gitlab/merge-request-fork"), status: 201)
        let mr = try await client.createPullRequest("lemonade/tools/amdgpu_mtopg",
                                                    PullRequestDraft(title: "From my fork", sourceBranch: "fix", targetBranch: "main",
                                                                     sourceRepository: "octo/amdgpu_mtopg"))
        #expect(mr.isCrossRepository && mr.sourceRepository == nil)
        #expect(server.requests("POST", "/api/v4/projects/octo%2Famdgpu_mtopg/merge_requests").first?.json["target_project_id"] as? Int == 4001)
    }

    @Test func closeCommitsAndThreads() async throws {
        server.on("PUT", "\(project)/merge_requests/5", json: fixture("gitlab/merge-request-closed"))
        server.on("GET", "\(project)/merge_requests/5/commits", json: fixture("gitlab/mr-commits"))
        server.on("GET", "\(project)/merge_requests/5/discussions", json: fixture("gitlab/discussions"))
        let closed = try await client.setPullRequestState("lemonade/tools/amdgpu_mtopg", number: 5, open: false)
        #expect(closed.state == .closed)
        #expect(server.requests("PUT", "\(project)/merge_requests/5").first?.json["state_event"] as? String == "close")

        let commits = try await client.pullRequestCommits("lemonade/tools/amdgpu_mtopg", number: 5)
        #expect(commits.first?.summary == "QueueRow: show occupancy history")
        #expect(commits.first?.date != nil)

        let threads = try await client.reviewThreads("lemonade/tools/amdgpu_mtopg", number: 5)
        #expect(threads.count == 1)
        #expect(threads[0].path == "Sources/QueueRow.swift" && threads[0].line == 20 && threads[0].isResolved)
        #expect(threads[0].comments.map(\.body) == ["Use monospacedDigit here.", "Done."])
        let comments = try await client.comments("lemonade/tools/amdgpu_mtopg", number: 5)
        #expect(comments.count == 3) // system notes are dropped
    }

    @Test func validationMessagesFromGitLabBodies() async throws {
        server.on("POST", "\(project)/merge_requests", json: #"{"message":["Another open merge request already exists for this source branch: !5"]}"#, status: 409)
        await #expect(throws: ForgeError.validation("Another open merge request already exists for this source branch: !5")) {
            _ = try await client.createPullRequest("lemonade/tools/amdgpu_mtopg", PullRequestDraft(title: "x", sourceBranch: "sparkline", targetBranch: "main"))
        }
        server.on("PUT", "\(project)/merge_requests/5/merge", json: #"{"message":{"base":["Branch cannot be merged"]}}"#, status: 422)
        await #expect(throws: ForgeError.validation("base Branch cannot be merged")) {
            try await client.merge("lemonade/tools/amdgpu_mtopg", number: 5, method: .merge, commitMessage: nil)
        }
    }
}

@Suite struct ForgeRemoteTests {
    @Test func parsesRemoteURLs() throws {
        let cases: [(String, String, String)] = [
            ("https://github.com/lemonade-sdk/amdgpu_mtopg.git", "github.com", "lemonade-sdk/amdgpu_mtopg"),
            ("https://github.com/lemonade-sdk/amdgpu_mtopg", "github.com", "lemonade-sdk/amdgpu_mtopg"),
            ("https://user@GitHub.com/o/r/", "github.com", "o/r"),
            ("git@github.com:o/r.git", "github.com", "o/r"),
            ("ssh://git@gitlab.example.com:2222/group/sub/project.git", "gitlab.example.com", "group/sub/project"),
            ("https://gitlab.example.com:8443/group/project.git", "gitlab.example.com", "group/project"),
        ]
        for (url, host, name) in cases {
            let ref = try #require(ForgeRemoteReference.parse(url), "\(url)")
            #expect(ref.hostname == host, "\(url)")
            #expect(ref.fullName == name, "\(url)")
        }
        #expect(ForgeRemoteReference.parse("/Users/me/repo.git") == nil)
        #expect(ForgeRemoteReference.parse("https://github.com/onlyowner") == nil)
        #expect(ForgeRemoteReference.parse("file:///tmp/x/y.git") == nil)
    }

    @Test func matchesHostsWithPathPrefixes() throws {
        let prefixed = ForgeHost(kind: .gitlab, webURL: URL(string: "https://code.example.com/gitlab")!)
        let ref = try #require(ForgeRemoteReference.parse("https://code.example.com/gitlab/team/app.git"))
        #expect(ref.isServed(by: prefixed))
        #expect(ref.repositoryPath(on: prefixed) == "team/app")
        #expect(!ref.isServed(by: .github))
        #expect(ForgeKind.github.pullRequestHeadRef(7) == "refs/pull/7/head")
        #expect(ForgeKind.gitlab.pullRequestHeadRef(7) == "refs/merge-requests/7/head")
        #expect(ForgeKind.gitlab.pullRequestBranchName(7) == "mr/7")
    }
}
