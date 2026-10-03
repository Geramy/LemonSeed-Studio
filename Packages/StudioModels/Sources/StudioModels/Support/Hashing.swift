// StudioModels: streaming digests for verification.

import CryptoKit
import Foundation

public enum FileDigest {
    static let bufferSize = 8 << 20

    /// SHA-256 of a file in 8 MiB reads. `progress` gets the bytes hashed so far.
    public static func sha256(of url: URL, progress: (@Sendable (Int64) -> Void)? = nil) throws -> String {
        var hasher = SHA256()
        try stream(url, range: nil) { chunk, done in
            hasher.update(data: chunk)
            progress?(done)
        }
        return hasher.finalize().hexString
    }

    /// The git blob id Hugging Face publishes for non-LFS files:
    /// SHA-1 of "blob <size>\0" followed by the content.
    public static func gitBlobSHA1(of url: URL) throws -> String {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size?.int64Value ?? 0)\0".utf8))
        try stream(url, range: nil) { chunk, _ in hasher.update(data: chunk) }
        return hasher.finalize().hexString
    }

    /// Feeds `range` of a file (all of it when nil) to `body` in buffers.
    static func stream(_ url: URL, range: Range<Int64>?, _ body: (Data, Int64) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = range?.lowerBound ?? 0
        let end = range?.upperBound ?? Int64.max
        try handle.seek(toOffset: UInt64(offset))
        var done: Int64 = 0
        while offset < end {
            let want = Int(min(Int64(bufferSize), end - offset))
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                    offset = end
                    return
                }
                offset += Int64(chunk.count)
                done += Int64(chunk.count)
                try body(chunk, done)
            }
        }
    }
}

/// SHA-256 over a file assembled out of order: chunks are fed strictly in
/// sequence, and a chunk that lands early waits until the gap before it
/// fills. The state is in memory only; after a relaunch the hashed prefix is
/// rebuilt from the part file.
struct OrderedHasher {
    private var hasher = SHA256()
    private(set) var hashedThrough: Int64 = 0

    mutating func feed(_ data: Data) {
        hasher.update(data: data)
        hashedThrough += Int64(data.count)
    }

    /// Hashes `url` from `hashedThrough` up to `end`.
    mutating func catchUp(from url: URL, to end: Int64) throws {
        guard end > hashedThrough else { return }
        let start = hashedThrough
        try FileDigest.stream(url, range: start..<end) { chunk, _ in feed(chunk) }
    }

    func digest() -> String { hasher.finalize().hexString }
}

#if !canImport(ObjectiveC)
@inline(__always) func autoreleasepool<T>(_ body: () throws -> T) rethrows -> T { try body() }
#endif

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
