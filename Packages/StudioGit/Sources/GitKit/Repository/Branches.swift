public import Foundation
import Clibgit2

public struct Branch: Sendable, Hashable, Identifiable, Codable {
    /// Short name: `main`, or `origin/main` for a remote-tracking branch.
    public var name: String
    /// Full reference name: `refs/heads/main`.
    public var referenceName: String
    public var isRemote: Bool
    public var isHead: Bool
    public var target: ObjectID?
    /// Short name of the upstream (`origin/main`), local branches only.
    public var upstream: String?
    /// Commits on this branch that are not on its upstream.
    public var ahead: Int
    /// Commits on the upstream that are not on this branch.
    public var behind: Int

    public var id: String { referenceName }
    /// For `origin/feature/x`, the remote name `origin`.
    public var remoteName: String? {
        isRemote ? name.split(separator: "/", maxSplits: 1).first.map(String.init) : nil
    }
    /// For `origin/feature/x`, `feature/x`.
    public var nameWithoutRemote: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

public enum BranchKind: Sendable {
    case local, remote, all
}

/// A reference label for decorating history rows.
public struct ReferenceLabel: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case head, localBranch, remoteBranch, tag }
    public var name: String
    public var kind: Kind
}

public struct CheckoutOptions: Sendable {
    /// Overwrite local modifications (`git checkout -f`).
    public var force = false
    public init(force: Bool = false) { self.force = force }
}

extension GitRepository {
    public func branches(_ kind: BranchKind = .local) throws -> [Branch] {
        let type: git_branch_t
        switch kind {
        case .local: type = GIT_BRANCH_LOCAL
        case .remote: type = GIT_BRANCH_REMOTE
        case .all: type = GIT_BRANCH_ALL
        }
        var iterator: OpaquePointer?
        try check(git_branch_iterator_new(&iterator, handle, type), "git_branch_iterator_new")
        defer { git_branch_iterator_free(iterator) }
        var result: [Branch] = []
        var ref: OpaquePointer?
        var branchType = GIT_BRANCH_LOCAL
        while git_branch_next(&ref, &branchType, iterator) == 0 {
            defer { git_reference_free(ref) }
            guard let ref else { continue }
            let full = String(cString: git_reference_name(ref))
            if full.hasSuffix("/HEAD") { continue } // refs/remotes/origin/HEAD
            result.append(try branchInfo(ref, isRemote: branchType == GIT_BRANCH_REMOTE))
        }
        // An unborn current branch has no ref yet; list it anyway.
        if kind != .remote, git_repository_head_unborn(handle) == 1, let head = try? head(), let name = head.branch,
           !result.contains(where: { $0.name == name }) {
            result.append(Branch(name: name, referenceName: head.referenceName ?? "refs/heads/\(name)", isRemote: false,
                                 isHead: true, target: nil, upstream: nil, ahead: 0, behind: 0))
        }
        return result.sorted { ($0.isRemote ? 1 : 0, $0.name) < ($1.isRemote ? 1 : 0, $1.name) }
    }

    public func branch(named name: String, remote: Bool = false) throws -> Branch {
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, handle, name, remote ? GIT_BRANCH_REMOTE : GIT_BRANCH_LOCAL), "git_branch_lookup(\(name))")
        defer { git_reference_free(ref) }
        return try branchInfo(ref!, isRemote: remote)
    }

    /// The current branch, or nil when HEAD is detached or unborn.
    public func currentBranch() throws -> Branch? {
        let head = try head()
        guard let name = head.branch, !head.isUnborn else { return nil }
        return try branch(named: name)
    }

    private func branchInfo(_ ref: OpaquePointer, isRemote: Bool) throws -> Branch {
        var namePtr: UnsafePointer<CChar>?
        try check(git_branch_name(&namePtr, ref), "git_branch_name")
        let name = String(gitCString: namePtr) ?? ""
        let full = String(cString: git_reference_name(ref))
        let target = git_reference_target(ref).map { ObjectID($0) }
        var b = Branch(name: name, referenceName: full, isRemote: isRemote,
                       isHead: git_branch_is_head(ref) == 1, target: target,
                       upstream: nil, ahead: 0, behind: 0)
        if !isRemote {
            var upstream: OpaquePointer?
            if git_branch_upstream(&upstream, ref) == 0, let upstream {
                defer { git_reference_free(upstream) }
                b.upstream = String(cString: git_reference_name(upstream)).shortRefName
                if let local = target, let up = git_reference_target(upstream).map({ ObjectID($0) }) {
                    let counts = try aheadBehind(local: local, upstream: up)
                    b.ahead = counts.ahead
                    b.behind = counts.behind
                }
            } else {
                git_error_clear()
            }
        }
        return b
    }

    /// Creates a local branch at `revision`.
    @discardableResult
    public func createBranch(_ name: String, at revision: String = "HEAD", checkout: Bool = false, force: Bool = false) throws -> Branch {
        let commitID = try resolveCommit(revision)
        let commit = try lookupCommit(commitID)
        defer { git_commit_free(commit) }
        var ref: OpaquePointer?
        try check(git_branch_create(&ref, handle, name, commit, force ? 1 : 0), "git_branch_create(\(name))")
        git_reference_free(ref)
        if checkout { try self.checkout(branch: name) }
        return try branch(named: name)
    }

    /// Switches to a local branch. For a remote-tracking name (`origin/x`)
    /// with no local branch, creates a local branch tracking it first.
    public func checkout(branch name: String, options: CheckoutOptions = CheckoutOptions()) throws {
        var ref: OpaquePointer?
        var rc = git_branch_lookup(&ref, handle, name, GIT_BRANCH_LOCAL)
        var localName = name
        if rc == GIT_ENOTFOUND.rawValue {
            // Try a remote-tracking branch.
            var remoteRef: OpaquePointer?
            try check(git_branch_lookup(&remoteRef, handle, name, GIT_BRANCH_REMOTE), "git_branch_lookup(\(name))")
            defer { git_reference_free(remoteRef) }
            localName = name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? name
            var existing: OpaquePointer?
            if git_branch_lookup(&existing, handle, localName, GIT_BRANCH_LOCAL) == 0 {
                ref = existing
            } else {
                git_error_clear()
                let commit = try lookupCommit(ObjectID(git_reference_target(remoteRef)))
                defer { git_commit_free(commit) }
                try check(git_branch_create(&ref, handle, localName, commit, 0), "git_branch_create(\(localName))")
                try check(git_branch_set_upstream(ref, name), "git_branch_set_upstream")
            }
            rc = 0
        }
        try check(rc, "git_branch_lookup(\(name))")
        defer { git_reference_free(ref) }
        guard let target = git_reference_target(ref) else { throw GitError.invalid("branch has no target", "checkout") }
        try checkoutTree(ObjectID(target), force: options.force)
        try check(git_repository_set_head(handle, git_reference_name(ref)), "git_repository_set_head")
    }

    /// Checks out a commit with a detached HEAD.
    public func checkout(commit id: ObjectID, options: CheckoutOptions = CheckoutOptions()) throws {
        try checkoutTree(id, force: options.force)
        var oid = id.oid
        try check(git_repository_set_head_detached(handle, &oid), "git_repository_set_head_detached")
    }

    func checkoutTree(_ commitID: ObjectID, force: Bool) throws {
        let commit = try lookupCommit(commitID)
        defer { git_commit_free(commit) }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = force ? GIT_CHECKOUT_FORCE.rawValue : GIT_CHECKOUT_SAFE.rawValue
        try check(git_checkout_tree(handle, commit, &opts), "git_checkout_tree")
    }

    /// Deletes a local branch. Without `force`, refuses a branch whose commits
    /// are not reachable from HEAD or its upstream.
    public func deleteBranch(_ name: String, force: Bool = false) throws {
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, handle, name, GIT_BRANCH_LOCAL), "git_branch_lookup(\(name))")
        defer { git_reference_free(ref) }
        if git_branch_is_head(ref) == 1 {
            throw GitError.invalid("cannot delete the checked-out branch \(name)", "deleteBranch")
        }
        if !force, let target = git_reference_target(ref).map({ ObjectID($0) }) {
            var merged = false
            if let headCommit = try head().commit {
                merged = try headCommit == target || isAncestor(target, of: headCommit)
            }
            if !merged, let b = try? branchInfo(ref!, isRemote: false), let upstream = b.upstream,
               let up = try? resolveCommit("refs/remotes/\(upstream)") {
                merged = try up == target || isAncestor(target, of: up)
            }
            if !merged {
                throw GitError(code: .modified, message: "branch \(name) is not fully merged", operation: "deleteBranch")
            }
        }
        try check(git_branch_delete(ref), "git_branch_delete(\(name))")
    }

    /// Deletes a remote-tracking ref locally (`git branch -dr origin/x`).
    public func deleteRemoteTrackingBranch(_ name: String) throws {
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, handle, name, GIT_BRANCH_REMOTE), "git_branch_lookup(\(name))")
        defer { git_reference_free(ref) }
        try check(git_branch_delete(ref), "git_branch_delete(\(name))")
    }

    public func renameBranch(_ name: String, to newName: String, force: Bool = false) throws {
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, handle, name, GIT_BRANCH_LOCAL), "git_branch_lookup(\(name))")
        defer { git_reference_free(ref) }
        var out: OpaquePointer?
        try check(git_branch_move(&out, ref, newName, force ? 1 : 0), "git_branch_move(\(newName))")
        git_reference_free(out)
    }

    /// Sets (or clears, with nil) the upstream of a local branch, e.g. `origin/main`.
    public func setUpstream(of name: String, to upstream: String?) throws {
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, handle, name, GIT_BRANCH_LOCAL), "git_branch_lookup(\(name))")
        defer { git_reference_free(ref) }
        try check(git_branch_set_upstream(ref, upstream), "git_branch_set_upstream")
    }

    /// Hard-resets the current branch (and index/working tree) to `revision`.
    public func reset(to revision: String, mode: ResetMode) throws {
        let id = try resolveCommit(revision)
        let commit = try lookupCommit(id)
        defer { git_commit_free(commit) }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        let type: git_reset_t
        switch mode {
        case .soft: type = GIT_RESET_SOFT
        case .mixed: type = GIT_RESET_MIXED
        case .hard: type = GIT_RESET_HARD
        }
        try check(git_reset(handle, commit, type, &opts), "git_reset")
    }

    /// Reference labels per commit, for history decorations.
    public func referenceLabels() throws -> [ObjectID: [ReferenceLabel]] {
        var labels: [ObjectID: [ReferenceLabel]] = [:]
        let headState = try? head()
        if let h = headState, let commit = h.commit, h.isDetached {
            labels[commit, default: []].append(ReferenceLabel(name: "HEAD", kind: .head))
        }
        for b in try branches(.all) {
            guard let t = b.target else { continue }
            labels[t, default: []].append(ReferenceLabel(name: b.name, kind: b.isRemote ? .remoteBranch : (b.isHead ? .head : .localBranch)))
        }
        for tag in try tags() {
            labels[tag.target, default: []].append(ReferenceLabel(name: tag.name, kind: .tag))
        }
        return labels
    }
}

public enum ResetMode: Sendable {
    case soft, mixed, hard
}
