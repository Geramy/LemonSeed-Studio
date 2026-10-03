public import Foundation
import Clibgit2

public enum MergeResult: Sendable, Equatable {
    case upToDate
    case fastForward(ObjectID)
    /// A merge commit was created.
    case merged(ObjectID)
    /// The merge stopped with conflicts in these paths. The repository is in
    /// the `.merge` state; resolve, stage and `commit`, or `abortMerge()`.
    case conflicts([String])
}

public struct MergeOptions: Sendable {
    public enum FastForward: Sendable { case allowed, only, never }
    public var fastForward: FastForward = .allowed
    /// Defaults to "Merge branch '<name>'".
    public var message: String?
    public var author: Signature?
    public init(fastForward: FastForward = .allowed, message: String? = nil, author: Signature? = nil) {
        self.fastForward = fastForward
        self.message = message
        self.author = author
    }
}

/// One conflicted path in the index.
public struct ConflictEntry: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable {
        case bothModified, bothAdded, deletedByUs, deletedByThem, addedByUs, addedByThem
    }
    public var path: String
    public var ancestor: ObjectID?
    public var ours: ObjectID?
    public var theirs: ObjectID?
    public var id: String { path }

    public var kind: Kind {
        switch (ancestor != nil, ours != nil, theirs != nil) {
        case (true, true, true): return .bothModified
        case (false, true, true): return .bothAdded
        case (true, false, true): return .deletedByUs
        case (true, true, false): return .deletedByThem
        case (false, true, false): return .addedByUs
        default: return .addedByThem
        }
    }
}

/// The three versions of a conflicted file plus Git's merged attempt.
public struct ConflictVersions: Sendable, Hashable {
    public var path: String
    public var base: Data?
    public var ours: Data?
    public var theirs: Data?
    /// The file with `<<<<<<<` / `=======` / `>>>>>>>` markers.
    public var merged: Data
    /// True when the merge had no conflicting hunks.
    public var isAutomergeable: Bool
}

public enum ConflictResolution: Sendable, Hashable {
    case ours
    case theirs
    /// Explicit file contents (from the merge editor).
    case content(Data)
    /// Remove the file.
    case delete
}

extension GitRepository {
    public func merge(_ revision: String, options: MergeOptions = MergeOptions()) throws -> MergeResult {
        var annotated: OpaquePointer?
        try check(git_annotated_commit_from_revspec(&annotated, handle, revision), "git_annotated_commit_from_revspec(\(revision))")
        defer { git_annotated_commit_free(annotated) }
        let theirID = ObjectID(git_annotated_commit_id(annotated))

        var analysis = GIT_MERGE_ANALYSIS_NONE
        var preference = GIT_MERGE_PREFERENCE_NONE
        var heads: [OpaquePointer?] = [annotated]
        try check(git_merge_analysis(&analysis, &preference, handle, &heads, 1), "git_merge_analysis")

        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return .upToDate
        }
        let canFastForward = analysis.rawValue & (GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue | GIT_MERGE_ANALYSIS_UNBORN.rawValue) != 0
        if canFastForward && options.fastForward != .never {
            try fastForward(to: theirID)
            return .fastForward(theirID)
        }
        if options.fastForward == .only {
            throw GitError(code: .nonFastForward, message: "not possible to fast-forward", operation: "merge")
        }

        var mergeOpts = git_merge_options()
        git_merge_options_init(&mergeOpts, UInt32(GIT_MERGE_OPTIONS_VERSION))
        mergeOpts.flags = GIT_MERGE_FIND_RENAMES.rawValue
        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue | GIT_CHECKOUT_CONFLICT_STYLE_MERGE.rawValue
        try check(git_merge(handle, &heads, 1, &mergeOpts, &checkoutOpts), "git_merge")

        let conflicts = try self.conflicts()
        if !conflicts.isEmpty {
            return .conflicts(conflicts.map(\.path))
        }
        let message = try options.message ?? defaultMergeMessage(for: revision)
        let id = try commit(message: message, options: CommitOptions(author: options.author, allowEmpty: true))
        return .merged(id)
    }

    func defaultMergeMessage(for revision: String) throws -> String {
        var ref: OpaquePointer?
        let isRemote = git_branch_lookup(&ref, handle, revision.shortRefName, GIT_BRANCH_REMOTE) == 0
        git_reference_free(ref)
        git_error_clear()
        let kind = isRemote ? "remote-tracking branch" : "branch"
        let ours = try head().branch ?? "HEAD"
        let into = (ours == "main" || ours == "master") ? "" : " into \(ours)"
        return "Merge \(kind) '\(revision.shortRefName)'\(into)"
    }

    /// Moves the current branch to `target` and checks it out.
    func fastForward(to target: ObjectID) throws {
        let h = try head()
        try checkoutTree(target, force: false)
        var oid = target.oid
        var ref: OpaquePointer?
        if h.isDetached {
            try check(git_repository_set_head_detached(handle, &oid), "git_repository_set_head_detached")
        } else {
            let name = h.referenceName ?? "refs/heads/main"
            try check(git_reference_create(&ref, handle, name, &oid, 1, "merge: Fast-forward"), "git_reference_create")
            git_reference_free(ref)
            if h.isUnborn { try check(git_repository_set_head(handle, name), "git_repository_set_head") }
        }
    }

    /// Abandons an in-progress merge, cherry-pick or revert: resets to HEAD.
    public func abortMerge() throws {
        try reset(to: "HEAD", mode: .hard)
        try cleanupState()
    }

    // MARK: Conflicts

    public func conflicts() throws -> [ConflictEntry] {
        let index = try openIndex()
        defer { git_index_free(index) }
        guard git_index_has_conflicts(index) == 1 else { return [] }
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index), "git_index_conflict_iterator_new")
        defer { git_index_conflict_iterator_free(iterator) }
        var result: [ConflictEntry] = []
        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?
        while git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0 {
            let path = [ancestor, ours, theirs].compactMap { $0?.pointee.path }.first.map { String(cString: $0) } ?? ""
            result.append(ConflictEntry(path: path,
                                        ancestor: ancestor.map { ObjectID($0.pointee.id) },
                                        ours: ours.map { ObjectID($0.pointee.id) },
                                        theirs: theirs.map { ObjectID($0.pointee.id) }))
        }
        return result
    }

    /// Base, ours, theirs and a merged file with conflict markers.
    public func conflictVersions(_ path: String, diff3: Bool = false) throws -> ConflictVersions {
        let index = try openIndex()
        defer { git_index_free(index) }
        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?
        try check(git_index_conflict_get(&ancestor, &ours, &theirs, index, path), "git_index_conflict_get(\(path))")
        let base = try ancestor.map { try blobData(ObjectID($0.pointee.id)) }
        let oursData = try ours.map { try blobData(ObjectID($0.pointee.id)) }
        let theirsData = try theirs.map { try blobData(ObjectID($0.pointee.id)) }

        var opts = git_merge_file_options()
        git_merge_file_options_init(&opts, UInt32(GIT_MERGE_FILE_OPTIONS_VERSION))
        if diff3 { opts.flags = GIT_MERGE_FILE_STYLE_DIFF3.rawValue }
        let branchName = (try? head().branch) ?? "HEAD"
        var result = git_merge_file_result()
        let ourLabel = strdup(branchName)
        let theirLabel = strdup("theirs")
        defer { free(ourLabel); free(theirLabel) }
        opts.our_label = UnsafePointer(ourLabel)
        opts.their_label = UnsafePointer(theirLabel)
        let rc = git_merge_file_from_index(&result, handle, ancestor, ours, theirs, &opts)
        try check(rc, "git_merge_file_from_index(\(path))")
        defer { git_merge_file_result_free(&result) }
        let merged = result.ptr.map { Data(bytes: $0, count: result.len) } ?? Data()
        return ConflictVersions(path: path, base: base, ours: oursData, theirs: theirsData,
                                merged: merged, isAutomergeable: result.automergeable == 1)
    }

    /// Resolves one conflicted path: writes the chosen content to the working
    /// tree and stages it, clearing the conflict.
    public func resolveConflict(_ path: String, with resolution: ConflictResolution) throws {
        guard let workdir = workingDirectory else { throw GitError.invalid("bare repository", "resolveConflict") }
        let file = workdir.appending(path: path)
        let versions = try conflictVersions(path)
        let data: Data?
        switch resolution {
        case .ours: data = versions.ours
        case .theirs: data = versions.theirs
        case .content(let d): data = d
        case .delete: data = nil
        }
        if let data {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
        let index = try openIndex()
        defer { git_index_free(index) }
        try check(git_index_conflict_remove(index, path), "git_index_conflict_remove(\(path))")
        if data != nil {
            try check(git_index_add_bypath(index, path), "git_index_add_bypath(\(path))")
        } else {
            let rc = git_index_remove_bypath(index, path)
            if rc != GIT_ENOTFOUND.rawValue { try check(rc, "git_index_remove_bypath") }
        }
        try check(git_index_write(index), "git_index_write")
    }
}
