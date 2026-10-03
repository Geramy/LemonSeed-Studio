public import Foundation
import Clibgit2

/// One open repository.
///
/// The actor runs on its own serial dispatch queue, so blocking libgit2 work
/// never occupies Swift's cooperative thread pool, and calls into one
/// repository are serialized (libgit2 objects are not thread-safe). Network
/// operations open a second handle on a transfer queue (see `Network.swift`)
/// so status and diffs stay responsive during a long fetch or push.
public actor GitRepository {
    nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated(unsafe) let handle: OpaquePointer

    /// The working directory, or nil for a bare repository.
    public nonisolated let workingDirectory: URL?
    /// The `.git` directory (or the repository itself when bare).
    public nonisolated let gitDirectory: URL
    public nonisolated let isBare: Bool

    init(handle: OpaquePointer) {
        self.handle = handle
        let gitdir = String(cString: git_repository_path(handle))
        self.gitDirectory = URL(fileURLWithPath: gitdir, isDirectory: true)
        if let workdir = git_repository_workdir(handle) {
            self.workingDirectory = URL(fileURLWithPath: String(cString: workdir), isDirectory: true)
        } else {
            self.workingDirectory = nil
        }
        self.isBare = git_repository_is_bare(handle) == 1
        self.queue = DispatchSerialQueue(label: "studio.git.repo.\(gitdir)", qos: .userInitiated)
    }

    deinit {
        git_repository_free(handle)
    }

    // MARK: Open and create

    /// Opens the repository at `url` (a working directory or a `.git` dir).
    /// With `search`, walks up parent directories like `git` does.
    public static func open(at url: URL, search: Bool = false) throws -> GitRepository {
        GitRuntime.ensureInitialized()
        var repo: OpaquePointer?
        if search {
            try check(git_repository_open_ext(&repo, url.path, 0, nil), "git_repository_open_ext")
        } else {
            try check(git_repository_open(&repo, url.path), "git_repository_open")
        }
        return GitRepository(handle: repo!)
    }

    /// Creates a new repository (like `git init`).
    public static func create(at url: URL, bare: Bool = false, initialBranch: String = "main") throws -> GitRepository {
        GitRuntime.ensureInitialized()
        var opts = git_repository_init_options()
        git_repository_init_options_init(&opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        opts.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue
        if bare { opts.flags |= GIT_REPOSITORY_INIT_BARE.rawValue }
        var repo: OpaquePointer?
        try initialBranch.withCString { branch in
            opts.initial_head = branch
            try check(git_repository_init_ext(&repo, url.path, &opts), "git_repository_init_ext")
        }
        return GitRepository(handle: repo!)
    }

    /// Whether `url` is inside a Git working tree or is a repository.
    public static func exists(at url: URL) -> Bool {
        GitRuntime.ensureInitialized()
        var repo: OpaquePointer?
        let ok = git_repository_open_ext(&repo, url.path, UInt32(GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue), nil) == 0
        if let repo { git_repository_free(repo) }
        return ok
    }

    // MARK: HEAD and state

    public struct Head: Sendable, Equatable {
        /// Full reference name (refs/heads/main), nil when detached.
        public var referenceName: String?
        /// Short branch name, nil when detached.
        public var branch: String?
        /// The commit HEAD points to; nil when the branch is unborn.
        public var commit: ObjectID?
        public var isDetached: Bool
        public var isUnborn: Bool
    }

    public func head() throws -> Head {
        if git_repository_head_unborn(handle) == 1 {
            var ref: OpaquePointer?
            try check(git_reference_lookup(&ref, handle, "HEAD"), "git_reference_lookup")
            defer { git_reference_free(ref) }
            let target = String(gitCString: git_reference_symbolic_target(ref)) ?? "refs/heads/main"
            return Head(referenceName: target, branch: target.shortRefName, commit: nil, isDetached: false, isUnborn: true)
        }
        var ref: OpaquePointer?
        try check(git_repository_head(&ref, handle), "git_repository_head")
        defer { git_reference_free(ref) }
        let detached = git_repository_head_detached(handle) == 1
        let name = String(cString: git_reference_name(ref))
        var commit: ObjectID?
        if let target = git_reference_target(ref) { commit = ObjectID(target) }
        return Head(referenceName: detached ? nil : name,
                    branch: detached ? nil : name.shortRefName,
                    commit: commit, isDetached: detached, isUnborn: false)
    }

    public func state() -> RepositoryState {
        RepositoryState(git_repository_state(handle))
    }

    /// Removes merge/rebase/cherry-pick metadata (MERGE_HEAD etc.).
    public func cleanupState() throws {
        try check(git_repository_state_cleanup(handle), "git_repository_state_cleanup")
    }

    // MARK: Revisions and objects

    /// Resolves a revision expression (`HEAD~2`, `main`, a hex id, ...) to a commit.
    public func resolveCommit(_ revision: String) throws -> ObjectID {
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, handle, revision), "git_revparse_single(\(revision))")
        defer { git_object_free(obj) }
        var peeled: OpaquePointer?
        try check(git_object_peel(&peeled, obj, GIT_OBJECT_COMMIT), "git_object_peel")
        defer { git_object_free(peeled) }
        return ObjectID(git_object_id(peeled))
    }

    /// The blob contents of `path` at `revision` (a commit-ish).
    public func fileContents(_ path: String, at revision: String = "HEAD") throws -> Data {
        let commitID = try resolveCommit(revision)
        return try withCommit(commitID) { commit in
            var tree: OpaquePointer?
            try check(git_commit_tree(&tree, commit), "git_commit_tree")
            defer { git_tree_free(tree) }
            var entry: OpaquePointer?
            try check(git_tree_entry_bypath(&entry, tree, path), "git_tree_entry_bypath(\(path))")
            defer { git_tree_entry_free(entry) }
            return try blobData(ObjectID(git_tree_entry_id(entry)))
        }
    }

    /// The contents of the index (stage 0) entry for `path`.
    public func indexContents(_ path: String) throws -> Data? {
        let index = try openIndex()
        defer { git_index_free(index) }
        guard let entry = git_index_get_bypath(index, path, 0) else { return nil }
        return try blobData(ObjectID(entry.pointee.id))
    }

    func blobData(_ id: ObjectID) throws -> Data {
        var blob: OpaquePointer?
        var oid = id.oid
        try check(git_blob_lookup(&blob, handle, &oid), "git_blob_lookup")
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        guard size > 0, let raw = git_blob_rawcontent(blob) else { return Data() }
        return Data(bytes: raw, count: size)
    }

    func withCommit<R>(_ id: ObjectID, _ body: (OpaquePointer) throws -> R) throws -> R {
        let commit = try lookupCommit(id)
        defer { git_commit_free(commit) }
        return try body(commit)
    }

    /// Looks up a commit; the caller frees it with git_commit_free.
    func lookupCommit(_ id: ObjectID) throws -> OpaquePointer {
        var commit: OpaquePointer?
        var oid = id.oid
        try check(git_commit_lookup(&commit, handle, &oid), "git_commit_lookup(\(id.short))")
        return commit!
    }

    func openIndex() throws -> OpaquePointer {
        var index: OpaquePointer?
        try check(git_repository_index(&index, handle), "git_repository_index")
        return index!
    }

    // MARK: Config

    /// Reads a config value (any level), or nil when unset.
    public func configValue(_ key: String) throws -> String? {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, handle), "git_repository_config_snapshot")
        defer { git_config_free(config) }
        var buf = git_buf()
        let rc = git_config_get_string_buf(&buf, config, key)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc, "git_config_get_string_buf(\(key))")
        return buf.takeString()
    }

    /// Writes a config value into the repository's own `.git/config`.
    public func setConfigValue(_ key: String, _ value: String?) throws {
        var config: OpaquePointer?
        try check(git_repository_config(&config, handle), "git_repository_config")
        defer { git_config_free(config) }
        var local: OpaquePointer?
        try check(git_config_open_level(&local, config, GIT_CONFIG_LEVEL_LOCAL), "git_config_open_level")
        defer { git_config_free(local) }
        if let value {
            try check(git_config_set_string(local, key, value), "git_config_set_string(\(key))")
        } else {
            let rc = git_config_delete_entry(local, key)
            if rc != GIT_ENOTFOUND.rawValue { try check(rc, "git_config_delete_entry(\(key))") }
        }
    }

    /// The identity from `user.name` / `user.email`, if both are set.
    public func configuredIdentity() throws -> Signature? {
        guard let name = try configValue("user.name"), let email = try configValue("user.email") else { return nil }
        return Signature(name: name, email: email)
    }
}

extension String {
    /// `refs/heads/main` -> `main`, `refs/remotes/origin/x` -> `origin/x`.
    var shortRefName: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where hasPrefix(prefix) {
            return String(dropFirst(prefix.count))
        }
        return self
    }
}
