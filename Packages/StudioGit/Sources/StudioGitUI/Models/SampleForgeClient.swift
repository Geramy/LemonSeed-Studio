import Foundation
public import Forge

/// An offline ForgeClient with fixed data, for previews, the demo app's
/// sample mode and UI tests. Writes are accepted and recorded.
public final class SampleForgeClient: ForgeClient, @unchecked Sendable {
    public let host: ForgeHost
    private let lock = NSLock()
    private var postedComments: [PullRequestComment] = []
    public private(set) var reviews: [ReviewEvent] = []
    public private(set) var merged: [Int] = []
    public private(set) var closed: [Int] = []
    public private(set) var createdDrafts: [PullRequestDraft] = []

    /// Repositories per page (nil: one page), to exercise paging.
    public let pageSize: Int?
    public private(set) var requestedScopes: [RepositoryScope] = []

    /// Clone URLs served in place of the samples' own (full name to URL),
    /// so a sample repository can be cloned offline from a local one.
    public let cloneSources: [String: String]

    public init(host: ForgeHost = .github, pageSize: Int? = nil, cloneSources: [String: String] = [:]) {
        self.host = host
        self.pageSize = pageSize
        self.cloneSources = cloneSources
    }

    private func served(_ repositories: [ForgeRepository]) -> [ForgeRepository] {
        repositories.map { repository in
            guard let source = cloneSources[repository.fullName] else { return repository }
            var local = repository
            local.httpsCloneURL = source
            local.sshCloneURL = nil
            return local
        }
    }

    /// An account to pair with the sample client.
    public static let sampleAccount = ForgeAccount(host: .github, user: alice, method: .oauthDevice,
                                                   owners: ["alice", "lemonade-sdk"])

    static let date = Date(timeIntervalSince1970: 1_790_000_000)
    static let alice = ForgeUser(id: "1", login: "alice", name: "Alice Moreau")
    static let bob = ForgeUser(id: "2", login: "bob", name: "Bob Tanaka")

    public static let sampleRepositories: [ForgeRepository] = [
        ForgeRepository(id: "R1", fullName: "lemonade-sdk/amdgpu_mtopg", owner: "lemonade-sdk", name: "amdgpu_mtopg",
                        description: "Live AMD GPU telemetry, top-style", defaultBranch: "main",
                        httpsCloneURL: "https://github.com/lemonade-sdk/amdgpu_mtopg.git",
                        sshCloneURL: "git@github.com:lemonade-sdk/amdgpu_mtopg.git", stars: 128, language: "Swift",
                        updatedAt: date, sizeKB: 2_400),
        ForgeRepository(id: "R2", fullName: "lemonade-sdk/mac_linuxgpu", owner: "lemonade-sdk", name: "mac_linuxgpu",
                        description: "Upstream Linux amdgpu on macOS and iPadOS", defaultBranch: "main",
                        httpsCloneURL: "https://github.com/lemonade-sdk/mac_linuxgpu.git",
                        sshCloneURL: "git@github.com:lemonade-sdk/mac_linuxgpu.git", stars: 942, language: "C",
                        updatedAt: date.addingTimeInterval(-86_400), sizeKB: 310_000, hasLFS: true),
        ForgeRepository(id: "R3", fullName: "alice/lemonseed-notes", owner: "alice", name: "lemonseed-notes",
                        description: "Design notes", isPrivate: true, defaultBranch: "main",
                        httpsCloneURL: "https://github.com/alice/lemonseed-notes.git", stars: 3, language: "Markdown",
                        updatedAt: date.addingTimeInterval(-3 * 86_400)),
        ForgeRepository(id: "R4", fullName: "alice/LSE", owner: "alice", name: "LSE",
                        description: "Fork: LemonSeed Engine, LLM inference on AMD GPUs", isFork: true, defaultBranch: "main",
                        httpsCloneURL: "https://github.com/alice/LSE.git", stars: 2, language: "C++",
                        updatedAt: date.addingTimeInterval(-6 * 86_400), sizeKB: 54_000),
        ForgeRepository(id: "R5", fullName: "lemonade-sdk/lemonseed-site", owner: "lemonade-sdk", name: "lemonseed-site",
                        description: "The project website", isPrivate: true, defaultBranch: "main",
                        httpsCloneURL: "https://github.com/lemonade-sdk/lemonseed-site.git",
                        sshCloneURL: "git@github.com:lemonade-sdk/lemonseed-site.git", stars: 9, language: "TypeScript",
                        updatedAt: date.addingTimeInterval(-9 * 86_400), sizeKB: 8_100),
        ForgeRepository(id: "R6", fullName: "alice/gpu-notes-2024", owner: "alice", name: "gpu-notes-2024",
                        description: "Last year's experiments", isArchived: true, defaultBranch: "main",
                        httpsCloneURL: "https://github.com/alice/gpu-notes-2024.git", stars: 1, language: "Python",
                        updatedAt: date.addingTimeInterval(-300 * 86_400), sizeKB: 900),
    ]

    public static let samplePulls: [PullRequest] = [
        PullRequest(number: 42, title: "Telemetry: per-queue occupancy sparkline",
                    body: "Adds a per-queue occupancy sparkline to the GPU screen.\n\n- samples at 10 Hz while visible\n- falls back to fixtures when no GPU is attached",
                    author: alice, repository: "lemonade-sdk/amdgpu_mtopg", sourceBranch: "occupancy", targetBranch: "main",
                    headSHA: "a1b2c3d4", createdAt: date.addingTimeInterval(-7200), updatedAt: date.addingTimeInterval(-600),
                    labels: ["telemetry", "ui"], reviewers: ["bob"], isMergeable: true, additions: 48, deletions: 9,
                    changedFiles: 2, commentCount: 3),
        PullRequest(number: 41, title: "Fix fan curve parsing on RDNA4", body: "", isDraft: true, author: bob,
                    repository: "lemonade-sdk/amdgpu_mtopg", sourceBranch: "rdna4-fan", targetBranch: "main",
                    headSHA: "ffee0011", createdAt: date.addingTimeInterval(-86_400), updatedAt: date.addingTimeInterval(-3600),
                    labels: ["bug"], additions: 12, deletions: 4, changedFiles: 1, commentCount: 0),
        PullRequest(number: 37, title: "Build: pin Swift 6.2 toolchain", author: alice, repository: "lemonade-sdk/amdgpu_mtopg",
                    sourceBranch: "toolchain", targetBranch: "main", headSHA: "0badcafe",
                    createdAt: date.addingTimeInterval(-5 * 86_400), updatedAt: date.addingTimeInterval(-2 * 86_400),
                    isMergeable: false, additions: 3, deletions: 3, changedFiles: 1, commentCount: 5),
    ]

    static let samplePatch = """
    @@ -12,9 +12,14 @@ struct QueueRow: View {
         let queue: QueueStats
         var body: some View {
             HStack {
    -            Text(queue.name)
    +            Text(queue.name).font(.headline)
                 Spacer()
    -            Text("\\(queue.occupancy)%")
    +            Sparkline(samples: queue.history)
    +                .frame(width: 120, height: 24)
    +            Text(queue.occupancy, format: .percent)
    +                .monospacedDigit()
             }
    +        .accessibilityElement(children: .combine)
         }
     }
    """

    public func currentUser() async throws -> ForgeUser { Self.alice }
    public func organizations() async throws -> [ForgeOrganization] {
        [ForgeOrganization(id: "O1", login: "lemonade-sdk", name: "Lemonade SDK", avatarURL: nil)]
    }
    public func repositories(_ scope: RepositoryScope, cursor: String?) async throws -> ForgePage<ForgeRepository> {
        lock.withLock { requestedScopes.append(scope) }
        let all = served(Self.repositories(in: scope))
        guard let pageSize else { return ForgePage(items: all, nextCursor: nil) }
        let start = Int(cursor ?? "0") ?? 0
        let end = min(start + pageSize, all.count)
        return ForgePage(items: Array(all[start..<end]), nextCursor: end < all.count ? String(end) : nil)
    }
    static func repositories(in scope: RepositoryScope) -> [ForgeRepository] {
        switch scope {
        case .all: return sampleRepositories
        case .owned: return sampleRepositories.filter { $0.owner == "alice" }
        case .organization(let login): return sampleRepositories.filter { $0.owner == login }
        }
    }
    public func repositories(organization: String) async throws -> [ForgeRepository] {
        served(Self.sampleRepositories.filter { $0.owner == organization })
    }
    public func searchRepositories(_ query: String, scope: RepositoryScope) async throws -> [ForgeRepository] {
        served(Self.repositories(in: scope).filter { $0.fullName.localizedCaseInsensitiveContains(query) })
    }
    public func repositorySettings(_ repository: String) async throws -> ForgeRepositorySettings {
        ForgeRepositorySettings(fullName: repository, defaultBranch: "main", allowedMergeMethods: [.merge, .squash], permission: .write)
    }
    public func repository(_ fullName: String) async throws -> ForgeRepository {
        guard let r = served(Self.sampleRepositories).first(where: { $0.fullName == fullName }) else { throw ForgeError.notFound }
        return r
    }
    public func branches(_ repository: String) async throws -> [ForgeBranch] {
        [ForgeBranch(name: "main", commit: "a1", isProtected: true, isDefault: true),
         ForgeBranch(name: "occupancy", commit: "a1b2c3d4", isProtected: false, isDefault: false)]
    }
    public func tags(_ repository: String) async throws -> [ForgeTag] { [ForgeTag(name: "v0.3.0", commit: "a1")] }
    public func readme(_ repository: String) async throws -> String? { "# \(repository)\n\nSample README." }

    public func pullRequests(_ filter: PullRequestFilter) async throws -> [PullRequest] {
        switch filter {
        case .repository(let repo, let state): return Self.samplePulls.filter { $0.repository == repo && $0.state == state }
        case .repositoryAuthoredByMe(let repo, let state):
            return Self.samplePulls.filter { $0.repository == repo && $0.state == state && $0.author?.login == "alice" }
        case .repositoryReviewRequested(let repo): return Self.samplePulls.filter { $0.repository == repo && $0.reviewers.contains("alice") }
        case .authoredByMe: return Self.samplePulls.filter { $0.author?.login == "alice" }
        case .reviewRequested: return Self.samplePulls.filter { $0.reviewers.contains("alice") }
        }
    }
    public func pullRequest(_ repository: String, number: Int) async throws -> PullRequest {
        guard let pr = Self.samplePulls.first(where: { $0.number == number }) else { throw ForgeError.notFound }
        return pr
    }
    public func pullRequestFiles(_ repository: String, number: Int) async throws -> [PullRequestFile] {
        [PullRequestFile(path: "Sources/MtopgComponents/QueueRow.swift", previousPath: nil, status: .modified,
                         additions: 7, deletions: 2, patch: Self.samplePatch),
         PullRequestFile(path: "Sources/MtopgComponents/Sparkline.swift", previousPath: nil, status: .added,
                         additions: 41, deletions: 0,
                         patch: "@@ -0,0 +1,6 @@\n+import SwiftUI\n+\n+/// A tiny line chart of recent samples.\n+struct Sparkline: View {\n+    var samples: [Double]\n+    var body: some View { Canvas { _, _ in } }")]
    }
    public func pullRequestDiff(_ repository: String, number: Int) async throws -> String { Self.samplePatch }
    public func pullRequestCommits(_ repository: String, number: Int) async throws -> [ForgeCommit] {
        [ForgeCommit(sha: "9f3c2a1b7e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b", message: "Add Sparkline view", authorName: "Alice Moreau",
                     authorLogin: "alice", date: Self.date.addingTimeInterval(-9000)),
         ForgeCommit(sha: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", message: "QueueRow: show occupancy history\n\nSamples at 10 Hz.",
                     authorName: "Alice Moreau", authorLogin: "alice", date: Self.date.addingTimeInterval(-7400))]
    }
    public func reviewThreads(_ repository: String, number: Int) async throws -> [ReviewThread] {
        let comments = try await self.comments(repository, number: number).filter { $0.threadID != nil }
        return Dictionary(grouping: comments, by: { $0.threadID! }).map { id, items in
            ReviewThread(id: id, path: items[0].path ?? "", line: items[0].line, isResolved: false, comments: items)
        }
    }
    @discardableResult
    public func setPullRequestState(_ repository: String, number: Int, open: Bool) async throws -> PullRequest {
        var pr = try await pullRequest(repository, number: number)
        pr.state = open ? .open : .closed
        if !open { lock.withLock { closed.append(number) } }
        return pr
    }
    public func comments(_ repository: String, number: Int) async throws -> [PullRequestComment] {
        let base = [
            PullRequestComment(id: "c1", author: Self.bob, body: "Nice! Does the sparkline pause when the screen is hidden?",
                               createdAt: Self.date.addingTimeInterval(-5000)),
            PullRequestComment(id: "c2", author: Self.alice, body: "Yes, sampling drops to 0 Hz when the view disappears.",
                               createdAt: Self.date.addingTimeInterval(-4000)),
            PullRequestComment(id: "c3", author: Self.bob, body: "Use `.monospacedDigit()` here so the column doesn't jitter.",
                               createdAt: Self.date.addingTimeInterval(-3000), path: "Sources/MtopgComponents/QueueRow.swift",
                               line: 20, threadID: "t1"),
        ]
        return base + lock.withLock { postedComments }
    }
    @discardableResult
    public func addComment(_ repository: String, number: Int, body: String) async throws -> PullRequestComment {
        let c = PullRequestComment(id: UUID().uuidString, author: Self.alice, body: body, createdAt: Date())
        lock.withLock { postedComments.append(c) }
        return c
    }
    @discardableResult
    public func addLineComment(_ repository: String, number: Int, _ draft: LineCommentDraft) async throws -> PullRequestComment {
        let c = PullRequestComment(id: UUID().uuidString, author: Self.alice, body: draft.body, createdAt: Date(), path: draft.path, line: draft.line)
        lock.withLock { postedComments.append(c) }
        return c
    }
    public func createPullRequest(_ repository: String, _ draft: PullRequestDraft) async throws -> PullRequest {
        lock.withLock { createdDrafts.append(draft) }
        return PullRequest(number: 43, title: draft.title, body: draft.body, author: Self.alice, repository: repository,
                    sourceBranch: draft.sourceBranch, targetBranch: draft.targetBranch)
    }
    public func review(_ repository: String, number: Int, event: ReviewEvent, body: String) async throws {
        lock.withLock { reviews.append(event) }
    }
    public func merge(_ repository: String, number: Int, method: MergeMethod, commitMessage: String?) async throws {
        lock.withLock { merged.append(number) }
    }
    public func ciStatus(_ repository: String, ref: String) async throws -> CIStatus {
        let runs: [CIRun]
        switch ref {
        case "ffee0011":
            runs = [CIRun(id: "1", name: "build (iPadOS)", state: .running, group: "CI")]
        case "0badcafe":
            runs = [CIRun(id: "1", name: "build (iPadOS)", state: .success, group: "CI"),
                    CIRun(id: "2", name: "unit tests", state: .failure, group: "CI")]
        default:
            runs = [CIRun(id: "1", name: "build (iPadOS)", state: .success, group: "CI"),
                    CIRun(id: "2", name: "unit tests", state: .success, group: "CI"),
                    CIRun(id: "3", name: "license gate", state: .success, group: "CI")]
        }
        return CIStatus(state: CIState.combine(runs.map(\.state)), runs: runs)
    }
    public func ciLog(_ repository: String, run: CIRun) async throws -> String { "\u{1B}[32m✓\u{1B}[0m \(run.name)\n" }
    public func sshKeys() async throws -> [ForgeSSHKey] { [] }
    @discardableResult
    public func addSSHKey(title: String, publicKey: String, usage: ForgeSSHKey.Usage) async throws -> ForgeSSHKey {
        ForgeSSHKey(id: "k1", title: title, key: publicKey, usage: usage, createdAt: Date())
    }
}
