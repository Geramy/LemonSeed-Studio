public import Foundation
import Clibgit2
import CGitShim

/// Registers the native `filter=lfs` clean/smudge filter with libgit2.
enum GitLFSFilter {
    static func install() {
        _ = lsg_lfs_filter_register(lfsTransform)
    }
}

/// clean: content -> pointer (storing the content in .git/lfs/objects).
/// smudge: pointer -> content when the object is present locally; a
/// missing object leaves the pointer text in place until `lfsPull`.
private let lfsTransform: lsg_lfs_transform_fn = { toODB, gitDir, _, input, inputLength, out, outLength in
    guard let gitDir, let out, let outLength else { return 0 }
    let data = input.map { Data(bytes: $0, count: inputLength) } ?? Data()
    let store = LFSStore(gitDirectory: URL(fileURLWithPath: String(cString: gitDir), isDirectory: true))
    let result: Data?
    if toODB != 0 {
        if LFSPointer(data: data) != nil { return 0 }
        guard let pointer = try? store.store(data) else { return -1 }
        result = pointer.data
    } else {
        guard let pointer = LFSPointer(data: data), store.contains(pointer) else { return 0 }
        result = try? store.read(pointer)
    }
    guard let result, let buffer = malloc(max(result.count, 1)) else { return 0 }
    result.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: result.count)
    out.pointee = buffer.assumingMemoryBound(to: CChar.self)
    outLength.pointee = result.count
    return 0
}

/// An LFS file in a tree.
public struct LFSFile: Sendable, Hashable {
    public var path: String
    public var pointer: LFSPointer
}

extension GitRepository {
    public nonisolated var lfsStore: LFSStore { LFSStore(gitDirectory: gitDirectory) }

    /// Every LFS pointer in the tree of `revision`.
    public func lfsFiles(at revision: String = "HEAD") throws -> [LFSFile] {
        let id = try resolveCommit(revision)
        let tree = try tree(ofCommit: id)
        defer { git_tree_free(tree) }
        final class Box { var entries: [(String, ObjectID)] = [] }
        let box = Box()
        try check(git_tree_walk(tree, GIT_TREEWALK_PRE, { root, entry, payload in
            guard let entry, git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return 0 }
            let box = Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue()
            let path = (root.map { String(cString: $0) } ?? "") + String(cString: git_tree_entry_name(entry))
            box.entries.append((path, ObjectID(git_tree_entry_id(entry))))
            return 0
        }, Unmanaged.passUnretained(box).toOpaque()), "git_tree_walk")
        var files: [LFSFile] = []
        for (path, blobID) in box.entries {
            var blob: OpaquePointer?
            var oid = blobID.oid
            guard git_blob_lookup(&blob, handle, &oid) == 0, let blob else { continue }
            defer { git_blob_free(blob) }
            let size = Int(git_blob_rawsize(blob))
            guard size <= LFSPointer.maxPointerSize, let raw = git_blob_rawcontent(blob),
                  let pointer = LFSPointer(data: Data(bytes: raw, count: size)) else { continue }
            files.append(LFSFile(path: path, pointer: pointer))
        }
        return files
    }

    /// The LFS endpoint: `lfs.url`, `remote.<name>.lfsurl`, `.lfsconfig` in
    /// the tree, or the one derived from the remote URL.
    public func lfsEndpoint(remote: String = "origin", revision: String = "HEAD") throws -> URL? {
        if let url = try configValue("remote.\(remote).lfsurl") ?? configValue("lfs.url") { return URL(string: url) }
        if let data = try? fileContents(".lfsconfig", at: revision),
           let url = Self.lfsConfigURL(String(decoding: data, as: UTF8.self)) {
            return URL(string: url)
        }
        guard let remoteURL = try? self.remote(named: remote).url else { return nil }
        return LFSClient.endpoint(forRemoteURL: remoteURL)
    }

    static func lfsConfigURL(_ text: String) -> String? {
        var inLFS = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inLFS = line.lowercased().hasPrefix("[lfs]"); continue }
            guard inLFS, let eq = line.firstIndex(of: "=") else { continue }
            if line[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "url" {
                return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Downloads the LFS objects of `revision` in one batch, then rewrites
    /// pointer files in the working tree with their content.
    @discardableResult
    public func lfsPull(remote: String = "origin", revision: String = "HEAD", network: NetworkContext = NetworkContext()) async throws -> Int {
        let files = try lfsFiles(at: revision)
        guard !files.isEmpty else { return 0 }
        guard let endpoint = try lfsEndpoint(remote: remote, revision: revision) else { throw LFSError.noEndpoint }
        let client = LFSClient(endpoint: endpoint, session: network.lfsSession, credentials: network.credentials)
        let progress = network.progress
        let downloaded = try await client.download(files.map(\.pointer), into: lfsStore, ref: try? head().referenceName) { done, total in
            var p = TransferProgress(phase: .lfs)
            p.current = done
            p.total = total
            progress?(p)
        }
        try rewriteLFSFiles(files.map(\.path))
        return downloaded.count
    }

    /// Uploads the LFS objects referenced by `revision` that the server lacks.
    @discardableResult
    public func lfsPush(remote: String = "origin", revision: String = "HEAD", network: NetworkContext = NetworkContext()) async throws -> Int {
        let files = try lfsFiles(at: revision)
        guard !files.isEmpty else { return 0 }
        guard let endpoint = try lfsEndpoint(remote: remote, revision: revision) else { throw LFSError.noEndpoint }
        let client = LFSClient(endpoint: endpoint, session: network.lfsSession, credentials: network.credentials)
        return try await client.upload(files.map(\.pointer), from: lfsStore, ref: try? head().referenceName).count
    }

    /// Re-checks-out paths so the smudge filter replaces pointer text.
    func rewriteLFSFiles(_ paths: [String]) throws {
        guard !paths.isEmpty, git_repository_head_unborn(handle) != 1 else { return }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
        let spec = CStringArray(paths)
        defer { spec.free() }
        opts.paths = spec.array
        // Remove the files first: checkout skips files whose index entry
        // looks unchanged, and pointer text matches the index.
        if let workdir = workingDirectory {
            for path in paths { try? FileManager.default.removeItem(at: workdir.appending(path: path)) }
        }
        try check(git_checkout_head(handle, &opts), "git_checkout_head")
    }
}
