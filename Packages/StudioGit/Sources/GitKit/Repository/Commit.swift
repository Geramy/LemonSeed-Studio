public import Foundation
import Clibgit2

/// Produces a detached signature over a commit's raw content (for example an
/// SSH `sshsig` or an OpenPGP signature). GitKit stores the result in the
/// commit's `gpgsig` header.
public protocol CommitSigner: Sendable {
    /// Returns the ASCII-armored signature of `content`.
    func signCommit(_ content: Data) throws -> String
}

public struct CommitOptions: Sendable {
    /// Defaults to `user.name` / `user.email` from the repository config.
    public var author: Signature?
    /// Defaults to the author.
    public var committer: Signature?
    /// Replace HEAD instead of adding a child (`git commit --amend`).
    public var amend = false
    /// Allow a commit whose tree equals its parent's.
    public var allowEmpty = false
    public var signer: (any CommitSigner)?
    public init(author: Signature? = nil, committer: Signature? = nil, amend: Bool = false, allowEmpty: Bool = false, signer: (any CommitSigner)? = nil) {
        self.author = author
        self.committer = committer
        self.amend = amend
        self.allowEmpty = allowEmpty
        self.signer = signer
    }
}

public struct CommitInfo: Sendable, Hashable, Identifiable, Codable {
    public var id: ObjectID
    public var parents: [ObjectID]
    public var author: Signature
    public var committer: Signature
    public var message: String
    public var isSigned: Bool

    /// The first line of the message.
    public var summary: String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }
    /// The message without its summary line.
    public var body: String {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    public var isMerge: Bool { parents.count > 1 }
}

extension GitRepository {
    /// Commits the index. Handles the first commit, amend, and finishing a
    /// merge (MERGE_HEAD parents) or cherry-pick.
    @discardableResult
    public func commit(message: String, options: CommitOptions = CommitOptions()) throws -> ObjectID {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.invalid("empty commit message", "commit") }
        guard let author = try options.author ?? configuredIdentity() else {
            throw GitError.invalid("no author: set user.name and user.email or pass an author", "commit")
        }
        let committer = options.committer ?? author

        let index = try openIndex()
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) == 1 {
            throw GitError(code: .unmerged, message: "resolve conflicts before committing", operation: "commit")
        }
        var treeID = git_oid()
        try check(git_index_write_tree(&treeID, index), "git_index_write_tree")
        var newTree: OpaquePointer?
        try check(git_tree_lookup(&newTree, handle, &treeID), "git_tree_lookup")
        defer { git_tree_free(newTree) }

        let headState = try head()
        let repoState = state()
        var parentIDs: [ObjectID] = []
        if options.amend {
            guard let headCommit = headState.commit else { throw GitError.invalid("nothing to amend", "commit") }
            parentIDs = try withCommit(headCommit) { c in
                (0..<git_commit_parentcount(c)).map { ObjectID(git_commit_parent_id(c, $0)) }
            }
        } else {
            if let headCommit = headState.commit { parentIDs.append(headCommit) }
            if repoState == .merge { parentIDs.append(contentsOf: try mergeHeads()) }
        }

        if !options.allowEmpty && !options.amend && parentIDs.count == 1 {
            let parentTree = try tree(ofCommit: parentIDs[0])
            defer { git_tree_free(parentTree) }
            if git_oid_equal(git_tree_id(parentTree), &treeID) == 1 {
                throw GitError.invalid("nothing to commit", "commit")
            }
        }

        let gitAuthor = try author.makeGitSignature()
        defer { git_signature_free(gitAuthor) }
        let gitCommitter = try committer.makeGitSignature()
        defer { git_signature_free(gitCommitter) }

        var prettified = git_buf()
        try check(git_message_prettify(&prettified, message, 0, CChar(UInt8(ascii: "#"))), "git_message_prettify")
        let cleanMessage = prettified.takeString()

        var parents: [OpaquePointer?] = []
        defer { parents.forEach { git_commit_free($0) } }
        for id in parentIDs {
            var p: OpaquePointer?
            var oid = id.oid
            try check(git_commit_lookup(&p, handle, &oid), "git_commit_lookup")
            parents.append(p)
        }

        var content = git_buf()
        let parentArray = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: max(parents.count, 1))
        defer { parentArray.deallocate() }
        for (i, p) in parents.enumerated() { parentArray[i] = p }
        try check(git_commit_create_buffer(&content, handle, gitAuthor, gitCommitter, nil, cleanMessage, newTree,
                                           parents.count, parentArray), "git_commit_create_buffer")
        let contentData = content.takeData()
        let signature = try options.signer?.signCommit(contentData)

        var newID = git_oid()
        let contentString = String(decoding: contentData, as: UTF8.self)
        try check(git_commit_create_with_signature(&newID, handle, contentString, signature, nil),
                  "git_commit_create_with_signature")

        let summary = cleanMessage.split(separator: "\n").first.map(String.init) ?? ""
        let kind = options.amend ? "commit (amend)" : headState.isUnborn ? "commit (initial)" : parentIDs.count > 1 ? "commit (merge)" : "commit"
        let refName = headState.isDetached ? "HEAD" : (headState.referenceName ?? "HEAD")
        var ref: OpaquePointer?
        try check(git_reference_create(&ref, handle, refName, &newID, 1, "\(kind): \(summary)"), "git_reference_create(\(refName))")
        git_reference_free(ref)

        if [.merge, .cherryPick, .revert].contains(repoState) {
            try cleanupState()
        }
        return ObjectID(newID)
    }

    /// The commits recorded in MERGE_HEAD.
    func mergeHeads() throws -> [ObjectID] {
        final class Box { var ids: [ObjectID] = [] }
        let box = Box()
        let rc = git_repository_mergehead_foreach(handle, { oid, payload in
            let box = Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue()
            if let oid { box.ids.append(ObjectID(oid)) }
            return 0
        }, Unmanaged.passUnretained(box).toOpaque())
        if rc == GIT_ENOTFOUND.rawValue { return [] }
        try check(rc, "git_repository_mergehead_foreach")
        return box.ids
    }

    /// Details of one commit.
    public func commitInfo(_ id: ObjectID) throws -> CommitInfo {
        try withCommit(id) { Self.info(of: $0) }
    }

    /// The `gpgsig` signature of a commit and the payload it signs, or
    /// throws `.notFound` for an unsigned commit.
    public func commitSignature(_ id: ObjectID) throws -> (signature: String, payload: Data) {
        var sig = git_buf()
        var payload = git_buf()
        var oid = id.oid
        try check(git_commit_extract_signature(&sig, &payload, handle, &oid, nil), "git_commit_extract_signature")
        return (sig.takeString(), payload.takeData())
    }

    /// The message Git prepared for an in-progress merge, revert or cherry-pick.
    public func preparedMessage() -> String? {
        var buf = git_buf()
        guard git_repository_message(&buf, handle) == 0 else { return nil }
        return buf.takeString()
    }

    static func info(of commit: OpaquePointer) -> CommitInfo {
        let count = git_commit_parentcount(commit)
        let parents = (0..<count).map { ObjectID(git_commit_parent_id(commit, $0)) }
        var signed = false
        if let raw = git_commit_raw_header(commit) {
            signed = String(cString: raw).contains("\ngpgsig ")
        }
        return CommitInfo(
            id: ObjectID(git_commit_id(commit)),
            parents: parents,
            author: Signature(git_commit_author(commit)),
            committer: Signature(git_commit_committer(commit)),
            message: String(gitCString: git_commit_message(commit)) ?? "",
            isSigned: signed)
    }
}
