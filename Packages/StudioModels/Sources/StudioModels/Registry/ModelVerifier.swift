// StudioModels: checking installed files against their pinned digests.
//
// Hashing runs off the registry actor; the result is written back in one
// update. A file already verified whose size and mtime are unchanged is
// skipped unless `force` is set. Files with no published SHA-256 (non-LFS
// files from a search download) are checked against their git blob id, and
// their SHA-256 is then recorded so later checks use it.

import Foundation

public struct VerificationProgress: Sendable, Hashable {
    public var hashedBytes: Int64
    public var totalBytes: Int64
    public var currentFile: String?

    public var fraction: Double { totalBytes > 0 ? Double(hashedBytes) / Double(totalBytes) : 1 }
}

public enum ModelVerifier {
    /// Verifies a record's files in `dir` and returns the updated files.
    public static func verify(files: [ModelRecord.File], in dir: URL, force: Bool = false,
                              progress: (@Sendable (VerificationProgress) -> Void)? = nil) async -> [ModelRecord.File] {
        await Task.detached(priority: .utility) {
            var result = files
            let total = files.reduce(0) { $0 + $1.size }
            var base: Int64 = 0
            for i in result.indices {
                if Task.isCancelled { break }
                let url = dir.appending(path: result[i].path)
                let stamp = FileStamp.of(url)
                defer { base += result[i].size }
                guard let stamp, stamp.size == result[i].size else {
                    result[i].verification = .missing
                    continue
                }
                if !force, result[i].verification == .verified, result[i].stamp == stamp { continue }
                let path = result[i].path
                let start = base
                do {
                    let sha = try FileDigest.sha256(of: url) { done in
                        progress?(VerificationProgress(hashedBytes: start + done, totalBytes: total, currentFile: path))
                    }
                    if let expected = result[i].sha256 {
                        result[i].verification = expected == sha ? .verified : .mismatch
                    } else if let blob = result[i].gitBlobSHA1 {
                        let ok = try FileDigest.gitBlobSHA1(of: url) == blob
                        result[i].verification = ok ? .verified : .mismatch
                        if ok { result[i].sha256 = sha }
                    } else {
                        // Nothing published to compare against: record a baseline.
                        result[i].sha256 = sha
                        result[i].verification = .verified
                    }
                    result[i].stamp = stamp
                } catch {
                    result[i].verification = .missing
                }
            }
            progress?(VerificationProgress(hashedBytes: total, totalBytes: total, currentFile: nil))
            return result
        }.value
    }
}
