import Foundation
public import Observation
public import GitKit
public import Forge

/// Pull/merge request list for a repository or for the signed-in user.
@MainActor
@Observable
public final class PullRequestListModel {
    /// Whose requests to list in a repository.
    public enum Scope: String, CaseIterable, Identifiable, Sendable {
        case all, mine, reviewRequested
        public var id: Self { self }
        public var title: String {
            switch self {
            case .all: return "Everyone's"
            case .mine: return "Created by Me"
            case .reviewRequested: return "Review Requested"
            }
        }
    }

    public let client: any ForgeClient
    public var filter: PullRequestFilter
    public private(set) var requests: [PullRequest] = []
    public private(set) var ciStates: [String: CIState] = [:]
    public private(set) var isLoading = false
    public var errorMessage: String?

    public init(client: any ForgeClient, filter: PullRequestFilter) {
        self.client = client
        self.filter = filter
    }

    /// A repository's requests with a state and scope.
    public convenience init(client: any ForgeClient, repository: String, state: PullRequestState = .open, scope: Scope = .all) {
        self.init(client: client, filter: Self.filter(repository: repository, state: state, scope: scope))
    }

    public static func filter(repository: String, state: PullRequestState, scope: Scope) -> PullRequestFilter {
        switch scope {
        case .all: return .repository(repository, state: state)
        case .mine: return .repositoryAuthoredByMe(repository, state: state)
        // Review requests only make sense for open requests.
        case .reviewRequested: return .repositoryReviewRequested(repository)
        }
    }

    public var repository: String? {
        switch filter {
        case .repository(let r, _), .repositoryAuthoredByMe(let r, _), .repositoryReviewRequested(let r): return r
        case .authoredByMe, .reviewRequested: return nil
        }
    }

    public var state: PullRequestState {
        switch filter {
        case .repository(_, let s), .repositoryAuthoredByMe(_, let s): return s
        default: return .open
        }
    }

    public var scope: Scope {
        switch filter {
        case .repositoryAuthoredByMe, .authoredByMe: return .mine
        case .repositoryReviewRequested, .reviewRequested: return .reviewRequested
        case .repository: return .all
        }
    }

    /// Changes the state or scope of a repository list and reloads.
    public func set(state: PullRequestState? = nil, scope: Scope? = nil) async {
        guard let repository else { return }
        filter = Self.filter(repository: repository, state: state ?? self.state, scope: scope ?? self.scope)
        requests = []
        await load()
    }

    public var title: String {
        switch filter {
        case .repository(let repo, _): return repo
        case .repositoryAuthoredByMe(let repo, _), .repositoryReviewRequested(let repo): return repo
        case .authoredByMe: return "Created by me"
        case .reviewRequested: return "Review requested"
        }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await client.pullRequests(filter)
            requests = loaded
            errorMessage = nil
            ciStates = [:]
            await withTaskGroup(of: (String, CIState?).self) { group in
                for pr in loaded.prefix(20) where pr.state == .open {
                    let ref = pr.headSHA ?? pr.sourceBranch
                    guard !ref.isEmpty, !pr.repository.isEmpty else { continue }
                    let client = self.client
                    group.addTask { (pr.id, try? await client.ciStatus(pr.repository, ref: ref).state) }
                }
                for await (id, state) in group { if let state { ciStates[id] = state } }
            }
        } catch {
            errorMessage = "Couldn't load \(client.host.kind.requestNoun)s: \(RepositoryHosting.describe(error))"
        }
    }
}

/// One pull/merge request: description, commits, files with diffs,
/// conversation and review threads, CI; review, merge, close, check out.
@MainActor
@Observable
public final class PullRequestDetailModel {
    public let client: any ForgeClient
    public let repository: String
    public let number: Int
    public private(set) var request: PullRequest?
    public private(set) var files: [PullRequestFile] = []
    public private(set) var commits: [ForgeCommit] = []
    public private(set) var comments: [PullRequestComment] = []
    public private(set) var threads: [ReviewThread] = []
    public private(set) var ci: CIStatus?
    /// The signed-in user's permission and the allowed merge methods.
    public var settings: ForgeRepositorySettings?
    public var currentUser: ForgeUser?
    public var selectedFile: String?
    public var draftComment = ""
    public var reviewBody = ""
    public private(set) var isWorking = false
    public var errorMessage: String?
    public private(set) var notice: String?

    public init(client: any ForgeClient, repository: String, number: Int, settings: ForgeRepositorySettings? = nil,
                currentUser: ForgeUser? = nil) {
        self.client = client
        self.repository = repository
        self.number = number
        self.settings = settings
        self.currentUser = currentUser
    }

    public var kind: ForgeKind { client.host.kind }
    public var title: String { "\(kind.requestSigil)\(number)" }

    /// Hunks of the selected file, parsed from the forge's patch.
    public var selectedHunks: [DiffHunk] {
        guard let file = files.first(where: { $0.path == selectedFile }), let patch = file.patch else { return [] }
        return UnifiedDiff.parseHunks(patch)
    }

    public func comments(onLine line: Int, path: String) -> [PullRequestComment] {
        comments.filter { $0.path == path && $0.line == line }
    }

    /// Conversation comments (not attached to a diff line).
    public var conversation: [PullRequestComment] { comments.filter { $0.path == nil } }

    public var isAuthor: Bool {
        guard let me = currentUser?.login, let author = request?.author?.login else { return false }
        return me.caseInsensitiveCompare(author) == .orderedSame
    }

    /// Merge methods to offer: the repository's allowed ones (all three
    /// until settings load).
    public var mergeMethods: [MergeMethod] { settings?.allowedMergeMethods ?? [] }

    /// Why merging is unavailable, or nil when it can be tried.
    public var mergeBlocker: String? {
        guard let pr = request else { return "Loading…" }
        if pr.state != .open { return "This \(kind.requestNoun) is \(pr.state.rawValue)." }
        if pr.isDraft { return "Drafts cannot be merged. Mark it ready for review on \(client.host.hostname) first." }
        guard let settings else { return "Checking your permissions…" }
        if !settings.canPush { return "You need write access to \(repository) to merge (you have \(settings.permission.displayName))." }
        if settings.allowedMergeMethods.isEmpty { return "\(repository) allows no merge method." }
        if pr.isMergeable == false { return "It has conflicts with \(pr.targetBranch) or failing requirements." }
        return nil
    }

    /// Why closing or reopening is unavailable, or nil.
    public var stateChangeBlocker: String? {
        guard let pr = request else { return "Loading…" }
        if pr.state == .merged { return "Merged requests cannot be closed or reopened." }
        if isAuthor { return nil }
        guard let settings else { return "Checking your permissions…" }
        return settings.canTriage ? nil : "Only the author or people with triage access can do this."
    }

    /// Why reviewing is unavailable, or nil.
    public var reviewBlocker: String? {
        guard let pr = request else { return "Loading…" }
        if pr.state != .open { return "This \(kind.requestNoun) is \(pr.state.rawValue)." }
        return nil
    }

    public func load() async {
        do {
            async let pr = client.pullRequest(repository, number: number)
            async let files = client.pullRequestFiles(repository, number: number)
            async let comments = client.comments(repository, number: number)
            async let commits = client.pullRequestCommits(repository, number: number)
            async let threads = client.reviewThreads(repository, number: number)
            let loaded = try await pr
            request = loaded
            self.files = try await files
            self.comments = try await comments
            self.commits = try await commits
            self.threads = try await threads
            if selectedFile == nil || !self.files.contains(where: { $0.path == selectedFile }) { selectedFile = self.files.first?.path }
            let ref = loaded.headSHA ?? loaded.sourceBranch
            if !ref.isEmpty {
                do {
                    ci = try await client.ciStatus(repository, ref: ref)
                } catch {
                    // Checks are optional on a forge; say why they are missing.
                    ci = nil
                    errorMessage = "Checks unavailable: \(RepositoryHosting.describe(error))"
                }
            }
            if settings == nil { settings = try await client.repositorySettings(repository) }
            if currentUser == nil { currentUser = try await client.currentUser() }
        } catch {
            errorMessage = "Couldn't load \(title): \(RepositoryHosting.describe(error))"
        }
    }

    public func postComment() async {
        let body = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        await work("Comment posted", failure: "Couldn't post the comment") {
            try await client.addComment(repository, number: number, body: body)
            draftComment = ""
        }
    }

    public func postLineComment(_ body: String, path: String, line: DiffLine) async {
        guard let lineNumber = line.newLineNumber ?? line.oldLineNumber else { return }
        await work("Comment posted", failure: "Couldn't post the line comment") {
            try await client.addLineComment(repository, number: number,
                                            LineCommentDraft(body: body, path: path, line: lineNumber, onRemovedLine: line.kind == .deletion))
        }
    }

    public func review(_ event: ReviewEvent) async {
        let body = reviewBody
        if event == .requestChanges, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, kind == .github {
            errorMessage = "Say what should change: GitHub requires a comment to request changes."
            return
        }
        await work(event == .approve ? "Approved" : event == .requestChanges ? "Changes requested" : "Review posted",
                   failure: event == .approve ? "Couldn't approve" : "Couldn't post the review") {
            try await client.review(repository, number: number, event: event, body: body)
            reviewBody = ""
        }
    }

    public func merge(_ method: MergeMethod, commitMessage: String? = nil) async {
        if let blocker = mergeBlocker {
            errorMessage = blocker
            return
        }
        guard mergeMethods.contains(method) else {
            errorMessage = "\(repository) does not allow \(method.title.lowercased())."
            return
        }
        await work("Merged", failure: "Couldn't merge \(title)") {
            try await client.merge(repository, number: number, method: method, commitMessage: commitMessage)
        }
    }

    public func setOpen(_ open: Bool) async {
        if let blocker = stateChangeBlocker {
            errorMessage = blocker
            return
        }
        await work(open ? "Reopened" : "Closed", failure: open ? "Couldn't reopen \(title)" : "Couldn't close \(title)") {
            request = try await client.setPullRequestState(repository, number: number, open: open)
        }
    }

    /// Fetches the request's head into `local` and checks it out: a
    /// branch in the same repository gets a local branch tracking it; a
    /// fork's branch becomes `pr/N` (GitHub) or `mr/N` (GitLab).
    @discardableResult
    public func checkOut(into sourceControl: SourceControlModel, remote: String) async -> String? {
        guard let pr = request else { return nil }
        var checkedOut: String?
        await work("Checked out", failure: "Couldn't check out \(title)") {
            let network = await sourceControl.services.network(for: sourceControl.repository)
            checkedOut = try await PullRequestCheckout.checkOut(pr, kind: kind, remote: remote,
                                                                repository: sourceControl.repository, network: network)
            notice = "Checked out \(checkedOut ?? "")"
        }
        await sourceControl.refresh()
        return checkedOut
    }

    private func work(_ success: String, failure: String, _ body: () async throws -> Void) async {
        isWorking = true
        notice = nil
        defer { isWorking = false }
        do {
            try await body()
            await load()
            notice = notice ?? success
        } catch {
            errorMessage = "\(failure): \(RepositoryHosting.describe(error))"
        }
    }
}

extension MergeMethod {
    public var title: String {
        switch self {
        case .merge: return "Create a Merge Commit"
        case .squash: return "Squash and Merge"
        case .rebase: return "Rebase and Merge"
        }
    }
}

/// Checks out a pull/merge request's head locally.
public enum PullRequestCheckout {
    /// - Returns: the local branch name.
    public static func checkOut(_ pr: PullRequest, kind: ForgeKind, remote: String, repository: GitRepository,
                                network: NetworkContext) async throws -> String {
        if !pr.isCrossRepository, !pr.sourceBranch.isEmpty {
            let tracking = "\(remote)/\(pr.sourceBranch)"
            try await repository.fetch(FetchOptions(remote: remote, refspecs: ["+refs/heads/\(pr.sourceBranch):refs/remotes/\(tracking)"]),
                                       network: network)
            if (try? await repository.branch(named: pr.sourceBranch)) != nil {
                try await repository.checkout(branch: pr.sourceBranch)
            } else {
                // Creates the local branch tracking the remote one.
                try await repository.checkout(branch: tracking)
            }
            return pr.sourceBranch
        }
        let local = kind.pullRequestBranchName(pr.number)
        let tracking = "refs/remotes/\(remote)/\(local)"
        try await repository.fetch(FetchOptions(remote: remote, refspecs: ["+\(kind.pullRequestHeadRef(pr.number)):\(tracking)"]),
                                   network: network)
        let fetched = try await repository.resolveCommit(tracking)
        if let existing = try? await repository.branch(named: local), let target = existing.target {
            if target != fetched {
                guard try await repository.isAncestor(target, of: fetched) else {
                    throw GitError(code: .nonFastForward, message: "\(local) has commits that are not in the \(kind.requestNoun). "
                                   + "Rename or delete \(local), then check out again.", operation: "checkout")
                }
                if existing.isHead {
                    _ = try await repository.merge(tracking, options: MergeOptions(fastForward: .only))
                } else {
                    try await repository.createBranch(local, at: fetched.hex, force: true)
                }
            }
        } else {
            try await repository.createBranch(local, at: fetched.hex)
        }
        try await repository.checkout(branch: local)
        return local
    }
}

/// A new pull/merge request from the current branch: pushes the branch
/// first when the remote does not have its commits, then creates it.
@MainActor
@Observable
public final class PullRequestComposerModel {
    public let sourceControl: SourceControlModel
    public let hosting: RepositoryHosting
    public var title = ""
    public var body = ""
    public var targetBranch = ""
    public var isDraft = false
    /// Comma- or space-separated logins.
    public var reviewers = ""
    public var labels = ""
    public private(set) var targetBranches: [ForgeBranch] = []
    public private(set) var isWorking = false
    public private(set) var phase = ""
    public var errorMessage: String?
    public private(set) var created: PullRequest?

    public init(sourceControl: SourceControlModel, hosting: RepositoryHosting) {
        self.sourceControl = sourceControl
        self.hosting = hosting
    }

    public var sourceBranch: String? { sourceControl.currentBranch?.name }

    /// Whether the branch must be pushed before the request can be opened.
    public var needsPush: Bool {
        guard let branch = sourceControl.currentBranch else { return false }
        return branch.upstream == nil || branch.ahead > 0
    }

    public var canSubmit: Bool {
        !isWorking && sourceBranch != nil && !targetBranch.isEmpty && targetBranch != sourceBranch
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hosting.client != nil
    }

    /// Fills the title from the branch's commits and loads target branches.
    public func prepare() async {
        guard let client = hosting.client, let target = hosting.pullTarget else {
            errorMessage = "Sign in to the account that hosts this repository first."
            return
        }
        await sourceControl.refresh()
        do {
            let branches = try await client.branches(target.repository)
            targetBranches = branches
            if targetBranch.isEmpty {
                targetBranch = branches.first(where: \.isDefault)?.name ?? hosting.settings?.defaultBranch ?? branches.first?.name ?? ""
            }
        } catch {
            errorMessage = "Couldn't list the branches of \(target.repository): \(RepositoryHosting.describe(error))"
        }
        var latest = LogOptions()
        latest.limit = 1
        if title.isEmpty, let head = try? await sourceControl.repository.log(latest).first {
            title = head.summary
            if body.isEmpty { body = head.body }
        }
    }

    static func names(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
            .filter { !$0.isEmpty }
    }

    /// Pushes if needed, then opens the request.
    @discardableResult
    public func submit() async -> PullRequest? {
        guard let client = hosting.client, let target = hosting.pullTarget, let source = sourceBranch else {
            errorMessage = "Check out a branch and sign in first."
            return nil
        }
        isWorking = true
        defer { isWorking = false; phase = "" }
        errorMessage = nil
        let push = hosting.pushRemote ?? target
        if needsPush {
            phase = "Pushing \(source) to \(push.name)…"
            guard await sourceControl.pushCurrentBranch(remote: push.name) else {
                errorMessage = "Couldn't push \(source): \(sourceControl.errorMessage ?? "unknown error")"
                return nil
            }
        }
        phase = "Opening the \(hosting.requestNoun)…"
        let draft = PullRequestDraft(title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: body,
                                     sourceBranch: source, targetBranch: targetBranch, isDraft: isDraft,
                                     reviewers: Self.names(reviewers), labels: Self.names(labels),
                                     sourceRepository: push.name == target.name ? nil : push.repository)
        do {
            let pr = try await client.createPullRequest(target.repository, draft)
            created = pr
            return pr
        } catch let partial as PartialPullRequestError {
            created = partial.pullRequest
            errorMessage = partial.description
            return partial.pullRequest
        } catch {
            errorMessage = "Couldn't open the \(hosting.requestNoun): \(RepositoryHosting.describe(error))"
            return nil
        }
    }
}

/// Parses unified diff text (a forge's per-file patch) into hunks.
public enum UnifiedDiff {
    public static func parseHunks(_ patch: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var oldLine = 0, newLine = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                let (os, oc, ns, nc) = parseHeader(line)
                oldLine = os
                newLine = ns
                hunks.append(DiffHunk(id: hunks.count, header: line, oldStart: os, oldCount: oc, newStart: ns, newCount: nc, lines: []))
                continue
            }
            guard !hunks.isEmpty else { continue }
            var hunk = hunks.removeLast()
            if line.hasPrefix("\\") {
                if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].hasNewline = false }
            } else if line.hasPrefix("+") {
                hunk.lines.append(DiffLine(id: hunk.lines.count, kind: .addition, oldLineNumber: nil, newLineNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                hunk.lines.append(DiffLine(id: hunk.lines.count, kind: .deletion, oldLineNumber: oldLine, newLineNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix(" ") || (line.isEmpty && hunk.lines.count < hunk.oldCount + hunk.newCount) {
                hunk.lines.append(DiffLine(id: hunk.lines.count, kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            }
            hunks.append(hunk)
        }
        // A trailing empty split element is not a context line.
        return hunks.map { h in
            var h = h
            let expected = h.lines.filter { $0.kind != .addition }.count
            if expected > h.oldCount, let last = h.lines.last, last.kind == .context, last.text.isEmpty { h.lines.removeLast() }
            return h
        }
    }

    static func parseHeader(_ header: String) -> (Int, Int, Int, Int) {
        // @@ -a,b +c,d @@ section
        let parts = header.split(separator: " ")
        func range(_ s: Substring?) -> (Int, Int) {
            guard let s else { return (0, 0) }
            let nums = s.dropFirst().split(separator: ",").compactMap { Int($0) }
            return (nums.first ?? 0, nums.count > 1 ? nums[1] : 1)
        }
        let old = range(parts.count > 1 ? parts[1] : nil)
        let new = range(parts.count > 2 ? parts[2] : nil)
        return (old.0, old.1, new.0, new.1)
    }
}
