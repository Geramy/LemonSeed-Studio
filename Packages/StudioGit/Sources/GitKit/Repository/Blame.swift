import Foundation
import Clibgit2

public struct BlameHunk: Sendable, Hashable, Identifiable, Codable {
    /// 1-based first line in the blamed version of the file.
    public var startLine: Int
    public var lineCount: Int
    public var commit: ObjectID
    public var author: Signature?
    public var summary: String
    /// Path and line where the lines were introduced (follows renames).
    public var originalPath: String?
    public var originalStartLine: Int
    /// The hunk reaches the boundary commit (history root or a shallow edge).
    public var isBoundary: Bool

    public var id: Int { startLine }
    public var lines: ClosedRange<Int> { startLine...(startLine + max(lineCount, 1) - 1) }
}

extension GitRepository {
    /// Line-by-line attribution of `path` as of `revision` (default HEAD).
    public func blame(_ path: String, at revision: String? = nil) throws -> [BlameHunk] {
        var opts = git_blame_options()
        git_blame_options_init(&opts, UInt32(GIT_BLAME_OPTIONS_VERSION))
        if let revision {
            opts.newest_commit = try resolveCommit(revision).oid
        }
        var blame: OpaquePointer?
        try check(git_blame_file(&blame, handle, path, &opts), "git_blame_file(\(path))")
        defer { git_blame_free(blame) }
        var summaries: [ObjectID: String] = [:]
        var result: [BlameHunk] = []
        let count = git_blame_get_hunk_count(blame)
        for i in 0..<count {
            guard let h = git_blame_get_hunk_byindex(blame, i)?.pointee else { continue }
            let commit = ObjectID(h.final_commit_id)
            if summaries[commit] == nil {
                summaries[commit] = (try? commitInfo(commit).summary) ?? ""
            }
            result.append(BlameHunk(
                startLine: Int(h.final_start_line_number),
                lineCount: Int(h.lines_in_hunk),
                commit: commit,
                author: h.final_signature.map { Signature($0) },
                summary: summaries[commit] ?? "",
                originalPath: String(gitCString: h.orig_path),
                originalStartLine: Int(h.orig_start_line_number),
                isBoundary: h.boundary != 0))
        }
        return result
    }
}
