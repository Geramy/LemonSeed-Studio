import Foundation
import Testing
@testable import Forge

@Suite struct GitLabClientTests {
    let server = StubServer()
    let host = ForgeHost(kind: .gitlab, webURL: URL(string: "https://gitlab.example.com")!)
    var client: GitLabClient { GitLabClient(host: host, session: server.session) { "glpat-x" } }
    let project = "/api/v4/projects/group%2Fsub%2Fapp"

    static let mr = """
    {"iid":12,"title":"Draft: speed up","description":"desc","state":"opened","draft":true,
     "author":{"id":3,"username":"carol","name":"Carol"},"source_branch":"fast","target_branch":"main","sha":"cafe",
     "web_url":"https://gitlab.example.com/group/sub/app/-/merge_requests/12","labels":["perf"],
     "reviewers":[{"username":"dave"}],"detailed_merge_status":"mergeable","user_notes_count":4,"changes_count":"3",
     "references":{"full":"group/sub/app!12"},"diff_refs":{"base_sha":"b","head_sha":"h","start_sha":"s"}}
    """

    @Test func projectsWithNamespacesAndPaging() async throws {
        server.on("GET", "/api/v4/projects") { req in
            let page = req.query["page"] ?? "1"
            return .json("""
            [{"id":\(page),"name":"App","path":"app","path_with_namespace":"group/sub/app","namespace":{"full_path":"group/sub"},
              "visibility":"private","default_branch":"main","http_url_to_repo":"https://gitlab.example.com/group/sub/app.git",
              "ssh_url_to_repo":"git@gitlab.example.com:group/sub/app.git","star_count":1,
              "last_activity_at":"2026-09-30T08:00:00.000Z","statistics":{"repository_size":2048000,"lfs_objects_size":10}}]
            """, headers: ["X-Next-Page": page == "1" ? "2" : ""])
        }
        let all = try await client.allRepositories()
        #expect(all.count == 2)
        #expect(all[0].fullName == "group/sub/app")
        #expect(all[0].owner == "group/sub")
        #expect(all[0].name == "app")
        #expect(all[0].isPrivate)
        #expect(all[0].sizeKB == 2000)
        #expect(all[0].hasLFS == true)
        #expect(server.requests.first?.query["membership"] == "true")
        #expect(server.requests.first?.headers["Authorization"] == "Bearer glpat-x")
    }

    @Test func projectPathIsPercentEncoded() async throws {
        server.on("GET", "\(project)/repository/branches", json: #"[{"name":"main","commit":{"id":"1"},"protected":true,"default":true}]"#)
        server.on("GET", "\(project)/repository/tags", json: #"[{"name":"v2","commit":{"id":"2"}}]"#)
        let branches = try await client.branches("group/sub/app")
        #expect(branches.first?.isDefault == true && branches.first?.isProtected == true)
        #expect(try await client.tags("group/sub/app").first?.commit == "2")
    }

    @Test func mergeRequestsAndDiffs() async throws {
        server.on("GET", "\(project)/merge_requests", json: "[\(Self.mr)]")
        server.on("GET", "/api/v4/merge_requests", json: "[\(Self.mr)]")
        server.on("GET", "\(project)/merge_requests/12/diffs", json: """
        [{"old_path":"a.c","new_path":"a.c","diff":"@@ -1 +1,2 @@\\n-x\\n+y\\n+z\\n","new_file":false,"renamed_file":false,"deleted_file":false},
         {"old_path":"o.txt","new_path":"n.txt","diff":"","new_file":false,"renamed_file":true,"deleted_file":false}]
        """)
        let list = try await client.pullRequests(.repository("group/sub/app"))
        let mr = try #require(list.first)
        #expect(mr.number == 12 && mr.isDraft)
        #expect(mr.repository == "group/sub/app")
        #expect(mr.isMergeable == true)
        #expect(mr.reviewers == ["dave"] && mr.changedFiles == 3)
        #expect(server.requests.first?.query["state"] == "opened")
        let mine = try await client.pullRequests(.authoredByMe)
        #expect(mine.first?.repository == "group/sub/app")

        let files = try await client.pullRequestFiles("group/sub/app", number: 12)
        #expect(files[0].additions == 2 && files[0].deletions == 1)
        #expect(files[1].status == .renamed && files[1].previousPath == "o.txt" && files[1].patch == nil)
        let diff = try await client.pullRequestDiff("group/sub/app", number: 12)
        #expect(diff.contains("diff --git a/a.c b/a.c"))
        #expect(diff.contains("+z"))
    }

    @Test func discussionsCommentsAndReview() async throws {
        server.on("GET", "\(project)/merge_requests/12", json: Self.mr)
        server.on("GET", "\(project)/merge_requests/12/discussions", json: """
        [{"id":"d1","notes":[{"id":1,"body":"added 1 commit","system":true,"created_at":"2026-09-01T00:00:00Z"}]},
         {"id":"d2","notes":[{"id":2,"body":"Why?","created_at":"2026-09-02T00:00:00Z","author":{"id":4,"username":"dave"},
           "position":{"new_path":"a.c","new_line":2},"resolved":false},
          {"id":3,"body":"Speed","created_at":"2026-09-03T00:00:00Z","author":{"id":3,"username":"carol"}}]}]
        """)
        server.on("POST", "\(project)/merge_requests/12/notes", json: #"{"id":9,"body":"LGTM"}"#, status: 201)
        server.on("POST", "\(project)/merge_requests/12/discussions", json: #"{"id":"d9","notes":[{"id":10,"body":"Line"}]}"#, status: 201)
        server.on("POST", "\(project)/merge_requests/12/approve", json: "{}", status: 201)
        server.on("POST", "\(project)/merge_requests/12/unapprove", json: "{}", status: 201)

        let comments = try await client.comments("group/sub/app", number: 12)
        #expect(comments.map(\.body) == ["Why?", "Speed"])
        #expect(comments[0].path == "a.c" && comments[0].line == 2 && comments[0].threadID == "d2")
        #expect(comments[0].isResolved == false)

        try await client.addLineComment("group/sub/app", number: 12, LineCommentDraft(body: "Line", path: "a.c", line: 2))
        let position = try #require(server.requests("POST", "\(project)/merge_requests/12/discussions").first?.json["position"] as? [String: Any])
        #expect(position["base_sha"] as? String == "b" && position["head_sha"] as? String == "h" && position["start_sha"] as? String == "s")
        #expect(position["new_line"] as? Int == 2 && position["position_type"] as? String == "text")

        try await client.review("group/sub/app", number: 12, event: .approve, body: "")
        #expect(server.requests("POST", "\(project)/merge_requests/12/approve").count == 1)
        try await client.review("group/sub/app", number: 12, event: .requestChanges, body: "Needs tests")
        #expect(server.requests("POST", "\(project)/merge_requests/12/notes").last?.json["body"] as? String == "Needs tests")
    }

    @Test func createAndMerge() async throws {
        server.on("POST", "\(project)/merge_requests", json: Self.mr, status: 201)
        server.on("PUT", "\(project)/merge_requests/12/merge", json: Self.mr)
        _ = try await client.createPullRequest("group/sub/app", PullRequestDraft(title: "Speed up", body: "B", sourceBranch: "fast", targetBranch: "main", isDraft: true))
        let body = try #require(server.requests("POST", "\(project)/merge_requests").first?.json)
        #expect(body["title"] as? String == "Draft: Speed up")
        #expect(body["source_branch"] as? String == "fast")
        try await client.merge("group/sub/app", number: 12, method: .squash, commitMessage: "Squashed")
        let merge = try #require(server.requests("PUT", "\(project)/merge_requests/12/merge").first?.json)
        #expect(merge["squash"] as? Bool == true)
        #expect(merge["squash_commit_message"] as? String == "Squashed")
    }

    @Test func pipelinesJobsAndLogs() async throws {
        server.on("GET", "\(project)/pipelines", json: #"[{"id":77,"status":"failed","web_url":"https://gitlab.example.com/p/77","sha":"cafe"}]"#)
        server.on("GET", "\(project)/pipelines/77/jobs", json: """
        [{"id":1,"name":"build","stage":"build","status":"success"},{"id":2,"name":"test","stage":"test","status":"failed"}]
        """)
        server.on("GET", "\(project)/jobs/2/trace") { _ in .text("FAILED test_x\n") }
        let status = try await client.ciStatus("group/sub/app", ref: String(repeating: "a", count: 40))
        #expect(status.state == .failure)
        #expect(status.runs.map(\.state) == [.success, .failure])
        #expect(status.runs[1].group == "test")
        #expect(server.requests("GET", "\(project)/pipelines").first?.query["sha"] != nil)
        #expect(try await client.ciLog("group/sub/app", run: status.runs[1]).contains("FAILED"))
        server.on("GET", "\(project)/pipelines", json: "[]")
        #expect(try await client.ciStatus("group/sub/app", ref: "main").state == .none)
    }

    @Test func sshKeysWithUsageType() async throws {
        server.on("POST", "/api/v4/user/keys", json: #"{"id":5,"title":"iPad","key":"ecdsa-sha2-nistp256 AAAA","usage_type":"auth_and_signing"}"#, status: 201)
        server.on("GET", "/api/v4/user/keys", json: #"[{"id":5,"title":"iPad","key":"k","usage_type":"signing"}]"#)
        let key = try await client.addSSHKey(title: "iPad", publicKey: "ecdsa-sha2-nistp256 AAAA", usage: .authenticationAndSigning)
        #expect(key.usage == .authenticationAndSigning)
        #expect(server.requests("POST", "/api/v4/user/keys").first?.json["usage_type"] as? String == "auth_and_signing")
        #expect(try await client.sshKeys().first?.usage == .signing)
    }

    @Test func readmeFallsBackAcrossNames() async throws {
        server.on("GET", project, json: #"{"id":1,"name":"app","path_with_namespace":"group/sub/app","default_branch":"trunk","http_url_to_repo":"x"}"#)
        server.on("GET", "\(project)/repository/files/README/raw") { req in
            req.query["ref"] == "trunk" ? .text("plain readme") : .json("{}", status: 404)
        }
        #expect(try await client.readme("group/sub/app") == "plain readme")
    }
}
