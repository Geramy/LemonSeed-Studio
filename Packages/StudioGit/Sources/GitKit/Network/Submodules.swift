import Foundation
import Clibgit2

public struct Submodule: Sendable, Hashable, Identifiable, Codable {
    public var name: String
    public var path: String
    public var url: String?
    public var branch: String?
    /// The commit recorded in the superproject's HEAD.
    public var headCommit: ObjectID?
    /// The commit checked out in the submodule's working tree.
    public var workdirCommit: ObjectID?
    /// Registered in .git/config (`git submodule init`).
    public var isInitialized: Bool
    /// The submodule repository exists in the working tree.
    public var isCloned: Bool
    public var id: String { path }
    /// The checked-out commit differs from the recorded one.
    public var isOutOfDate: Bool { isCloned && headCommit != workdirCommit }
}

extension GitRepository {
    public func submodules() throws -> [Submodule] {
        final class Box { var names: [String] = [] }
        let box = Box()
        try check(git_submodule_foreach(handle, { _, name, payload in
            let box = Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue()
            if let name { box.names.append(String(cString: name)) }
            return 0
        }, Unmanaged.passUnretained(box).toOpaque()), "git_submodule_foreach")
        return try box.names.map { try submodule(named: $0) }
    }

    public func submodule(named name: String) throws -> Submodule {
        var sm: OpaquePointer?
        try check(git_submodule_lookup(&sm, handle, name), "git_submodule_lookup(\(name))")
        defer { git_submodule_free(sm) }
        var status: UInt32 = 0
        try check(git_submodule_status(&status, handle, name, GIT_SUBMODULE_IGNORE_NONE), "git_submodule_status")
        return Submodule(
            name: String(cString: git_submodule_name(sm)),
            path: String(cString: git_submodule_path(sm)),
            url: String(gitCString: git_submodule_url(sm)),
            branch: String(gitCString: git_submodule_branch(sm)),
            headCommit: git_submodule_head_id(sm).map { ObjectID($0) },
            workdirCommit: git_submodule_wd_id(sm).map { ObjectID($0) },
            isInitialized: status & GIT_SUBMODULE_STATUS_IN_CONFIG.rawValue != 0,
            isCloned: status & GIT_SUBMODULE_STATUS_IN_WD.rawValue != 0 && git_submodule_wd_id(sm) != nil)
    }

    /// Registers submodules in .git/config (`git submodule init`).
    public func initSubmodules(_ names: [String]? = nil) throws {
        for name in try names ?? submodules().map(\.name) {
            var sm: OpaquePointer?
            try check(git_submodule_lookup(&sm, handle, name), "git_submodule_lookup(\(name))")
            defer { git_submodule_free(sm) }
            try check(git_submodule_init(sm, 0), "git_submodule_init(\(name))")
        }
    }

    /// Adds a submodule (`git submodule add url path`): clones it and stages
    /// .gitmodules and the gitlink.
    public nonisolated func addSubmodule(url: String, path: String, network: NetworkContext = NetworkContext()) async throws {
        let repoPath = gitDirectory.path
        let context = network.makeTransferContext()
        try await TransferQueue.run(context) {
            try GitRepository.withHandle(repoPath) { repo in
                var sm: OpaquePointer?
                try check(git_submodule_add_setup(&sm, repo, url, path, 1), "git_submodule_add_setup")
                defer { git_submodule_free(sm) }
                var opts = git_submodule_update_options()
                git_submodule_update_options_init(&opts, UInt32(GIT_SUBMODULE_UPDATE_OPTIONS_VERSION))
                context.install(into: &opts.fetch_opts.callbacks)
                var subrepo: OpaquePointer?
                let rc = git_submodule_clone(&subrepo, sm, &opts)
                if rc < 0 { throw context.error(for: rc, operation: "git_submodule_clone") }
                git_repository_free(subrepo)
                try check(git_submodule_add_finalize(sm), "git_submodule_add_finalize")
            }
        }
        await reopen()
    }

    /// Clones missing submodules and checks out the recorded commits
    /// (`git submodule update [--init] [--recursive]`).
    public nonisolated func updateSubmodules(_ names: [String]? = nil, initialize: Bool = true, recursive: Bool = true, network: NetworkContext = NetworkContext()) async throws {
        let context = network.makeTransferContext()
        let root = gitDirectory.path
        try await TransferQueue.run(context) {
            try GitRepository.withHandle(root) { repo in
                try GitRepository.updateSubmodules(repo: repo, names: names, initialize: initialize, recursive: recursive, context: context)
            }
        }
        await reopen()
    }

    static func updateSubmodules(repo: OpaquePointer, names: [String]?, initialize: Bool, recursive: Bool, context: TransferContext) throws {
        final class Box { var names: [String] = [] }
        let box = Box()
        try check(git_submodule_foreach(repo, { _, name, payload in
            let box = Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue()
            if let name { box.names.append(String(cString: name)) }
            return 0
        }, Unmanaged.passUnretained(box).toOpaque()), "git_submodule_foreach")
        let wanted = names.map(Set.init)
        for name in box.names where wanted?.contains(name) ?? true {
            if context.isCancelled { throw GitError.cancelled("updateSubmodules") }
            context.step = "Submodule \(name)"
            var sm: OpaquePointer?
            try check(git_submodule_lookup(&sm, repo, name), "git_submodule_lookup(\(name))")
            defer { git_submodule_free(sm) }
            var opts = git_submodule_update_options()
            git_submodule_update_options_init(&opts, UInt32(GIT_SUBMODULE_UPDATE_OPTIONS_VERSION))
            opts.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            context.install(into: &opts.fetch_opts.callbacks)
            let rc = git_submodule_update(sm, initialize ? 1 : 0, &opts)
            if rc < 0 { throw context.error(for: rc, operation: "git_submodule_update(\(name))") }
            if recursive {
                var child: OpaquePointer?
                if git_submodule_open(&child, sm) == 0, let child {
                    defer { git_repository_free(child) }
                    try updateSubmodules(repo: child, names: nil, initialize: initialize, recursive: true, context: context)
                } else {
                    git_error_clear()
                }
            }
        }
    }
}
