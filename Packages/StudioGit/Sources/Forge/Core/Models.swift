public import Foundation

// Forge-neutral models shared by the GitHub and GitLab clients and the UI.

public struct ForgeUser: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var login: String
    public var name: String?
    public var avatarURL: URL?
    public var webURL: URL?
    public init(id: String, login: String, name: String? = nil, avatarURL: URL? = nil, webURL: URL? = nil) {
        self.id = id
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.webURL = webURL
    }
}

/// A GitHub organization or a GitLab group.
public struct ForgeOrganization: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var login: String
    public var name: String?
    public var avatarURL: URL?
    public init(id: String, login: String, name: String? = nil, avatarURL: URL? = nil) {
        self.id = id
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }
}

public struct ForgeRepository: Codable, Sendable, Hashable, Identifiable {
    /// GitHub node id or GitLab project id.
    public var id: String
    /// `owner/name` (GitLab: the full namespace path).
    public var fullName: String
    public var owner: String
    public var name: String
    public var description: String?
    public var isPrivate: Bool
    public var isFork: Bool
    public var isArchived: Bool
    public var defaultBranch: String?
    public var httpsCloneURL: String
    public var sshCloneURL: String?
    public var webURL: URL?
    public var stars: Int
    public var language: String?
    public var updatedAt: Date?
    /// Approximate size in kilobytes, when the forge reports it.
    public var sizeKB: Int?
    public var hasLFS: Bool?

    public init(id: String, fullName: String, owner: String, name: String, description: String? = nil, isPrivate: Bool = false,
                isFork: Bool = false, isArchived: Bool = false, defaultBranch: String? = nil, httpsCloneURL: String,
                sshCloneURL: String? = nil, webURL: URL? = nil, stars: Int = 0, language: String? = nil,
                updatedAt: Date? = nil, sizeKB: Int? = nil, hasLFS: Bool? = nil) {
        self.id = id
        self.fullName = fullName
        self.owner = owner
        self.name = name
        self.description = description
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.isArchived = isArchived
        self.defaultBranch = defaultBranch
        self.httpsCloneURL = httpsCloneURL
        self.sshCloneURL = sshCloneURL
        self.webURL = webURL
        self.stars = stars
        self.language = language
        self.updatedAt = updatedAt
        self.sizeKB = sizeKB
        self.hasLFS = hasLFS
    }
}

public struct ForgeBranch: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var commit: String
    public var isProtected: Bool
    public var isDefault: Bool
    public var id: String { name }
    public init(name: String, commit: String, isProtected: Bool = false, isDefault: Bool = false) {
        self.name = name
        self.commit = commit
        self.isProtected = isProtected
        self.isDefault = isDefault
    }
}

public struct ForgeTag: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var commit: String
    public var id: String { name }
    public init(name: String, commit: String) {
        self.name = name
        self.commit = commit
    }
}

public enum PullRequestState: String, Codable, Sendable, Hashable {
    case open, closed, merged
}

/// A GitHub pull request or a GitLab merge request.
public struct PullRequest: Codable, Sendable, Hashable, Identifiable {
    /// GitHub `number`, GitLab `iid`.
    public var number: Int
    public var title: String
    public var body: String
    public var state: PullRequestState
    public var isDraft: Bool
    public var author: ForgeUser?
    /// `owner/name` of the repository the request targets.
    public var repository: String
    public var sourceBranch: String
    public var targetBranch: String
    public var headSHA: String?
    public var webURL: URL?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var labels: [String]
    public var reviewers: [String]
    /// nil while the forge is still computing it.
    public var isMergeable: Bool?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    public var commentCount: Int?

    public var id: String { "\(repository)#\(number)" }

    public init(number: Int, title: String, body: String = "", state: PullRequestState = .open, isDraft: Bool = false,
                author: ForgeUser? = nil, repository: String, sourceBranch: String, targetBranch: String, headSHA: String? = nil,
                webURL: URL? = nil, createdAt: Date? = nil, updatedAt: Date? = nil, labels: [String] = [], reviewers: [String] = [],
                isMergeable: Bool? = nil, additions: Int? = nil, deletions: Int? = nil, changedFiles: Int? = nil, commentCount: Int? = nil) {
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.isDraft = isDraft
        self.author = author
        self.repository = repository
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.headSHA = headSHA
        self.webURL = webURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.labels = labels
        self.reviewers = reviewers
        self.isMergeable = isMergeable
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.commentCount = commentCount
    }
}

public enum PullRequestFilter: Sendable, Hashable {
    /// Open requests in one repository.
    case repository(String, state: PullRequestState = .open)
    /// Open requests the signed-in user authored.
    case authoredByMe
    /// Open requests waiting for the signed-in user's review.
    case reviewRequested
}

public struct PullRequestFile: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case added, modified, removed, renamed }
    public var path: String
    public var previousPath: String?
    public var status: Status
    public var additions: Int
    public var deletions: Int
    /// Unified diff hunks for the file (no `diff --git` header); nil for
    /// binary or very large files.
    public var patch: String?
    public var id: String { path }
    public init(path: String, previousPath: String? = nil, status: Status, additions: Int, deletions: Int, patch: String? = nil) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }
}

public struct PullRequestComment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var author: ForgeUser?
    public var body: String
    public var createdAt: Date?
    /// For line comments: the file and line in the new version.
    public var path: String?
    public var line: Int?
    /// Comments in the same review thread share this id.
    public var threadID: String?
    public var isResolved: Bool?

    public init(id: String, author: ForgeUser? = nil, body: String, createdAt: Date? = nil, path: String? = nil,
                line: Int? = nil, threadID: String? = nil, isResolved: Bool? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.path = path
        self.line = line
        self.threadID = threadID
        self.isResolved = isResolved
    }
}

public enum ReviewEvent: String, Sendable, Hashable, CaseIterable {
    case approve, requestChanges, comment
}

public enum MergeMethod: String, Sendable, Hashable, CaseIterable {
    case merge, squash, rebase
}

/// New pull/merge request.
public struct PullRequestDraft: Sendable, Hashable {
    public var title: String
    public var body: String
    public var sourceBranch: String
    public var targetBranch: String
    public var isDraft: Bool
    public init(title: String, body: String = "", sourceBranch: String, targetBranch: String, isDraft: Bool = false) {
        self.title = title
        self.body = body
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.isDraft = isDraft
    }
}

/// A line comment on a pull request diff.
public struct LineCommentDraft: Sendable, Hashable {
    public var body: String
    public var path: String
    /// Line number in the new file (or the old file for removed lines).
    public var line: Int
    public var onRemovedLine: Bool
    public init(body: String, path: String, line: Int, onRemovedLine: Bool = false) {
        self.body = body
        self.path = path
        self.line = line
        self.onRemovedLine = onRemovedLine
    }
}

public enum CIState: String, Codable, Sendable, Hashable {
    case success, failure, pending, running, canceled, skipped, neutral, none

    /// Combines several runs into one badge state.
    public static func combine(_ states: [CIState]) -> CIState {
        if states.isEmpty { return .none }
        if states.contains(.failure) { return .failure }
        if states.contains(.running) { return .running }
        if states.contains(.pending) { return .pending }
        if states.contains(.canceled) { return .canceled }
        if states.allSatisfy({ $0 == .skipped || $0 == .neutral }) { return .skipped }
        return .success
    }
}

/// One GitHub check run / workflow run, or one GitLab job.
public struct CIRun: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var state: CIState
    public var webURL: URL?
    public var startedAt: Date?
    public var completedAt: Date?
    /// Workflow (GitHub) or stage (GitLab).
    public var group: String?

    public init(id: String, name: String, state: CIState, webURL: URL? = nil, startedAt: Date? = nil,
                completedAt: Date? = nil, group: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.webURL = webURL
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.group = group
    }
}

public struct CIStatus: Codable, Sendable, Hashable {
    public var state: CIState
    public var runs: [CIRun]
    /// The pipeline or check suite page.
    public var webURL: URL?
    public init(state: CIState, runs: [CIRun], webURL: URL? = nil) {
        self.state = state
        self.runs = runs
        self.webURL = webURL
    }
}

/// An SSH key registered on the forge.
public struct ForgeSSHKey: Codable, Sendable, Hashable, Identifiable {
    public enum Usage: String, Codable, Sendable { case authentication, signing, authenticationAndSigning }
    public var id: String
    public var title: String
    public var key: String
    public var usage: Usage
    public var createdAt: Date?

    public init(id: String, title: String, key: String, usage: Usage, createdAt: Date? = nil) {
        self.id = id
        self.title = title
        self.key = key
        self.usage = usage
        self.createdAt = createdAt
    }
}
