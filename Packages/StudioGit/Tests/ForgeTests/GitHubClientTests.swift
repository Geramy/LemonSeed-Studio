import Foundation
import Testing
@testable import Forge

@Suite struct GitHubClientTests {
    let server = StubServer()
    var client: GitHubClient { GitHubClient(session: server.session) { "gho_token" } }

    static let pull = """
    {"number":7,"title":"Add telemetry","body":"Body","state":"open","draft":false,
     "user":{"id":1,"login":"alice","avatar_url":"https://a/1.png","html_url":"https://github.com/alice"},
     "head":{"ref":"feature","sha":"aaaa","repo":{"full_name":"alice/mtopg"}},
     "base":{"ref":"main","sha":"bbbb","repo":{"full_name":"lemonade-sdk/amdgpu_mtopg"}},
     "html_url":"https://github.com/lemonade-sdk/amdgpu_mtopg/pull/7","created_at":"2026-09-01T10:00:00Z",
     "updated_at":"2026-09-02T10:00:00.123Z","merged_at":null,"mergeable":true,"additions":10,"deletions":2,
     "changed_files":3,"comments":1,"review_comments":2,"labels":[{"name":"gpu"}],"requested_reviewers":[{"login":"bob"}]}
    """

    @Test func currentUserSendsAuthAndVersionHeaders() async throws {
        server.on("GET", "/user", json: #"{"id":42,"login":"alice","name":"Alice","avatar_url":"https://a/42.png"}"#,
                  headers: ["X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4999", "X-RateLimit-Reset": "1800000000"])
        let user = try await client.currentUser()
        #expect(user.login == "alice")
        #expect(user.id == "42")
        let req = try #require(server.requests.first)
        #expect(req.headers["Authorization"] == "Bearer gho_token")
        #expect(req.headers["X-GitHub-Api-Version"] == "2022-11-28")
        #expect(req.url.host == "api.github.com")
    }

    @Test func repositoriesThroughGraphQL() async throws {
        server.on("POST", "/graphql") { req in
            let after = (req.json["variables"] as? [String: Any])?["after"] as? String
            let hasNext = after == nil
            return .json("""
            {"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":\(hasNext),"endCursor":"c1"},
             "nodes":[{"id":"R_\(after ?? "1")","name":"amdgpu_mtopg","nameWithOwner":"lemonade-sdk/amdgpu_mtopg",
             "owner":{"login":"lemonade-sdk"},"description":"GPU top","isPrivate":false,"isFork":false,"isArchived":false,
             "defaultBranchRef":{"name":"main"},"url":"https://github.com/lemonade-sdk/amdgpu_mtopg",
             "sshUrl":"git@github.com:lemonade-sdk/amdgpu_mtopg.git","stargazerCount":12,"primaryLanguage":{"name":"Swift"},
             "updatedAt":"2026-09-30T12:00:00Z","diskUsage":321}]}}}}
            """)
        }
        let all = try await client.allRepositories()
        #expect(all.count == 2)
        let repo = all[0]
        #expect(repo.fullName == "lemonade-sdk/amdgpu_mtopg")
        #expect(repo.httpsCloneURL == "https://github.com/lemonade-sdk/amdgpu_mtopg.git")
        #expect(repo.sshCloneURL == "git@github.com:lemonade-sdk/amdgpu_mtopg.git")
        #expect(repo.defaultBranch == "main")
        #expect(repo.language == "Swift")
        #expect(repo.sizeKB == 321)
        let query = try #require(server.requests.first?.json["query"] as? String)
        #expect(query.contains("ownerAffiliations"))
    }

    @Test func graphQLErrorsSurface() async throws {
        server.on("POST", "/graphql", json: #"{"data":null,"errors":[{"message":"Bad credentials"}]}"#)
        await #expect(throws: ForgeError.validation("Bad credentials")) { _ = try await client.repositories(cursor: nil) }
    }

    @Test func searchBranchesTagsReadme() async throws {
        server.on("GET", "/search/repositories", json: """
        {"items":[{"id":1,"node_id":"R1","name":"x","full_name":"o/x","owner":{"login":"o"},"private":true,"fork":true,
         "clone_url":"https://github.com/o/x.git","ssh_url":"git@github.com:o/x.git","stargazers_count":3}]}
        """)
        server.on("GET", "/repos/o/x", json: """
        {"id":1,"name":"x","full_name":"o/x","owner":{"login":"o"},"private":true,"fork":false,"default_branch":"dev",
         "clone_url":"https://github.com/o/x.git"}
        """)
        server.on("GET", "/repos/o/x/branches", json: #"[{"name":"dev","commit":{"sha":"1"},"protected":true},{"name":"wip","commit":{"sha":"2"}}]"#)
        server.on("GET", "/repos/o/x/tags", json: #"[{"name":"v1","commit":{"sha":"3"}}]"#)
        server.on("GET", "/repos/o/x/readme") { _ in .text("# X\n") }
        let found = try await client.searchRepositories("gpu language:swift")
        #expect(found.first?.isPrivate == true && found.first?.isFork == true)
        #expect(server.requests("GET", "/search/repositories").first?.query["q"] == "gpu language:swift")
        let branches = try await client.branches("o/x")
        #expect(branches.map(\.name) == ["dev", "wip"])
        #expect(branches[0].isDefault && branches[0].isProtected)
        #expect(try await client.tags("o/x").first?.name == "v1")
        #expect(try await client.readme("o/x") == "# X\n")
        #expect(server.requests("GET", "/repos/o/x/readme").first?.headers["Accept"] == "application/vnd.github.raw")
    }

    @Test func pullRequestListAndDetail() async throws {
        server.on("GET", "/repos/lemonade-sdk/amdgpu_mtopg/pulls", json: "[\(Self.pull)]")
        server.on("GET", "/repos/lemonade-sdk/amdgpu_mtopg/pulls/7", json: Self.pull)
        let list = try await client.pullRequests(.repository("lemonade-sdk/amdgpu_mtopg"))
        let pr = try #require(list.first)
        #expect(pr.number == 7)
        #expect(pr.sourceBranch == "feature" && pr.targetBranch == "main")
        #expect(pr.repository == "lemonade-sdk/amdgpu_mtopg")
        #expect(pr.labels == ["gpu"] && pr.reviewers == ["bob"])
        #expect(pr.commentCount == 3)
        #expect(pr.isMergeable == true)
        #expect(pr.updatedAt != nil)
        #expect(try await client.pullRequest("lemonade-sdk/amdgpu_mtopg", number: 7).headSHA == "aaaa")
    }

    @Test func mergedStateAndSearchFilters() async throws {
        let merged = Self.pull.replacingOccurrences(of: #""merged_at":null"#, with: #""merged_at":"2026-09-03T00:00:00Z""#)
            .replacingOccurrences(of: #""state":"open""#, with: #""state":"closed""#)
        server.on("GET", "/repos/o/r/pulls/7", json: merged)
        #expect(try await client.pullRequest("o/r", number: 7).state == .merged)
        server.on("GET", "/search/issues", json: """
        {"items":[{"number":3,"title":"Fix","state":"open","repository_url":"https://api.github.com/repos/o/r",
         "html_url":"https://github.com/o/r/pull/3","user":{"id":1,"login":"me"}}]}
        """)
        let mine = try await client.pullRequests(.reviewRequested)
        #expect(mine.first?.repository == "o/r")
        #expect(server.requests("GET", "/search/issues").first?.query["q"]?.contains("review-requested:@me") == true)
    }

    @Test func filesDiffAndComments() async throws {
        server.on("GET", "/repos/o/r/pulls/7/files", json: """
        [{"filename":"src/a.swift","status":"modified","additions":2,"deletions":1,"patch":"@@ -1 +1,2 @@\\n-a\\n+b\\n+c"},
         {"filename":"new.txt","previous_filename":"old.txt","status":"renamed","additions":0,"deletions":0}]
        """)
        server.on("GET", "/repos/o/r/pulls/7") { req in
            req.headers["Accept"] == "application/vnd.github.diff" ? .text("diff --git a/x b/x\n") : .json(Self.pull)
        }
        server.on("GET", "/repos/o/r/issues/7/comments", json: #"[{"id":1,"body":"LGTM","created_at":"2026-09-02T00:00:00Z","user":{"id":2,"login":"bob"}}]"#)
        server.on("GET", "/repos/o/r/pulls/7/comments", json: """
        [{"id":5,"body":"nit","created_at":"2026-09-01T00:00:00Z","path":"src/a.swift","line":2,"user":{"id":2,"login":"bob"}},
         {"id":6,"body":"fixed","created_at":"2026-09-03T00:00:00Z","path":"src/a.swift","line":2,"in_reply_to_id":5}]
        """)
        let files = try await client.pullRequestFiles("o/r", number: 7)
        #expect(files[0].patch?.contains("+c") == true)
        #expect(files[1].status == .renamed && files[1].previousPath == "old.txt")
        #expect(try await client.pullRequestDiff("o/r", number: 7).hasPrefix("diff --git"))
        let comments = try await client.comments("o/r", number: 7)
        #expect(comments.map(\.body) == ["nit", "LGTM", "fixed"])
        #expect(comments[0].path == "src/a.swift" && comments[0].line == 2)
        #expect(comments[0].threadID == comments[2].threadID)
    }

    @Test func writeOperations() async throws {
        server.on("GET", "/repos/o/r/pulls/7", json: Self.pull)
        server.on("POST", "/repos/o/r/issues/7/comments", json: #"{"id":9,"body":"Thanks"}"#, status: 201)
        server.on("POST", "/repos/o/r/pulls/7/comments", json: #"{"id":10,"body":"Here","path":"a.c","line":4}"#, status: 201)
        server.on("POST", "/repos/o/r/pulls", json: Self.pull, status: 201)
        server.on("POST", "/repos/o/r/pulls/7/reviews", json: #"{"id":1}"#)
        server.on("PUT", "/repos/o/r/pulls/7/merge", json: #"{"merged":true}"#)

        #expect(try await client.addComment("o/r", number: 7, body: "Thanks").body == "Thanks")
        try await client.addLineComment("o/r", number: 7, LineCommentDraft(body: "Here", path: "a.c", line: 4))
        let line = try #require(server.requests("POST", "/repos/o/r/pulls/7/comments").first?.json)
        #expect(line["commit_id"] as? String == "aaaa")
        #expect(line["side"] as? String == "RIGHT")
        #expect(line["line"] as? Int == 4)

        _ = try await client.createPullRequest("o/r", PullRequestDraft(title: "T", body: "B", sourceBranch: "feature", targetBranch: "main", isDraft: true))
        let create = try #require(server.requests("POST", "/repos/o/r/pulls").first?.json)
        #expect(create["head"] as? String == "feature" && create["base"] as? String == "main" && create["draft"] as? Bool == true)

        try await client.review("o/r", number: 7, event: .requestChanges, body: "Please fix")
        #expect(server.requests("POST", "/repos/o/r/pulls/7/reviews").first?.json["event"] as? String == "REQUEST_CHANGES")
        try await client.merge("o/r", number: 7, method: .squash, commitMessage: nil)
        #expect(server.requests("PUT", "/repos/o/r/pulls/7/merge").first?.json["merge_method"] as? String == "squash")
    }

    @Test func ciStatusCombinesChecksAndStatuses() async throws {
        server.on("GET", "/repos/o/r/commits/main/check-runs", json: """
        {"total_count":2,"check_runs":[
         {"id":11,"name":"build","status":"completed","conclusion":"success","html_url":"https://github.com/o/r/runs/11","app":{"name":"GitHub Actions"}},
         {"id":12,"name":"test","status":"in_progress","conclusion":null}]}
        """)
        server.on("GET", "/repos/o/r/commits/main/status", json: #"{"state":"success","statuses":[{"id":3,"context":"ci/legacy","state":"success"}]}"#)
        server.on("GET", "/repos/o/r/actions/jobs/11/logs") { _ in .text("\u{1B}[32mok\u{1B}[0m\n") }
        let status = try await client.ciStatus("o/r", ref: "main")
        #expect(status.state == .running)
        #expect(status.runs.map(\.name) == ["build", "test", "ci/legacy"])
        #expect(status.runs[0].group == "GitHub Actions")
        let log = try await client.ciLog("o/r", run: status.runs[0])
        #expect(log.contains("ok"))
        #expect(CIState.combine([.success, .failure, .running]) == .failure)
        #expect(CIState.combine([.success, .skipped]) == .success)
        #expect(CIState.combine([]) == .none)
    }

    @Test func sshKeyUploadForAuthAndSigning() async throws {
        server.on("POST", "/user/keys", json: #"{"id":1,"key":"ssh-ed25519 AAAA","title":"iPad"}"#, status: 201)
        server.on("POST", "/user/ssh_signing_keys", json: #"{"id":2,"key":"ssh-ed25519 AAAA","title":"iPad"}"#, status: 201)
        let key = try await client.addSSHKey(title: "iPad", publicKey: "ssh-ed25519 AAAA", usage: .authenticationAndSigning)
        #expect(key.id == "auth-1")
        #expect(server.requests("POST", "/user/keys").first?.json["key"] as? String == "ssh-ed25519 AAAA")
        #expect(server.requests("POST", "/user/ssh_signing_keys").count == 1)
    }

    @Test func errorsPaginationAndETags() async throws {
        server.on("GET", "/repos/o/missing", json: #"{"message":"Not Found"}"#, status: 404)
        await #expect(throws: ForgeError.notFound) { _ = try await client.repository("o/missing") }
        server.on("GET", "/user", json: #"{"message":"Bad credentials"}"#, status: 401)
        await #expect(throws: ForgeError.unauthorized) { _ = try await client.currentUser() }
        server.on("POST", "/repos/o/r/pulls", json: #"{"message":"Validation Failed"}"#, status: 422)
        await #expect(throws: ForgeError.validation("Validation Failed")) {
            _ = try await client.createPullRequest("o/r", PullRequestDraft(title: "x", sourceBranch: "a", targetBranch: "b"))
        }
        server.on("GET", "/repos/o/limited", json: #"{"message":"API rate limit exceeded"}"#, status: 403,
                  headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1900000000"])
        await #expect(throws: ForgeError.self) { _ = try await client.repository("o/limited") }

        // Two pages via Link headers.
        server.on("GET", "/user/orgs") { req in
            if req.query["page"] == "2" { return .json(#"[{"id":2,"login":"b"}]"#) }
            return .json(#"[{"id":1,"login":"a"}]"#, headers: ["Link": "<https://api.github.com/user/orgs?page=2>; rel=\"next\", <https://api.github.com/user/orgs?page=2>; rel=\"last\""])
        }
        #expect(try await client.organizations().map(\.login) == ["a", "b"])

        // ETag: the second request is conditional and a 304 reuses the body.
        let etagServer = StubServer()
        let c = GitHubClient(session: etagServer.session) { nil }
        etagServer.on("GET", "/repos/o/r/tags") { req in
            if req.headers["If-None-Match"] == "\"v1\"" { return StubServer.Response(status: 304, headers: [:], body: Data()) }
            return .json(#"[{"name":"v1","commit":{"sha":"1"}}]"#, headers: ["ETag": "\"v1\""])
        }
        #expect(try await c.tags("o/r").count == 1)
        #expect(try await c.tags("o/r").count == 1)
        #expect(etagServer.requests.last?.headers["If-None-Match"] == "\"v1\"")
        #expect(etagServer.requests.last?.headers["Authorization"] == nil)
    }
}
