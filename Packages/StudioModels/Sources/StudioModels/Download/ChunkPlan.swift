// StudioModels: splitting files into HTTP range chunks.
//
// Every file larger than one chunk is fetched as independent `Range:`
// requests. A finished chunk is written into the part file at its offset and
// recorded in the registry, so an interruption costs at most the chunks in
// flight. A chunk in flight can still continue from its URLSession resume
// data. Small files are one plain request.

import Foundation

public struct ChunkKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public var model: String
    public var path: String
    public var chunk: Int

    public var description: String { "\(model)/\(path)#\(chunk)" }

    /// Stored in URLSessionTask.taskDescription, so tasks still running after
    /// a relaunch map back to their chunk.
    var encoded: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }

    init(model: String, path: String, chunk: Int) {
        self.model = model
        self.path = path
        self.chunk = chunk
    }

    init?(encoded: String?) {
        guard let data = encoded?.data(using: .utf8),
              let key = try? JSONDecoder().decode(ChunkKey.self, from: data) else { return nil }
        self = key
    }
}

public enum ChunkPlan {
    public static let defaultChunkSize: Int64 = 256 << 20

    /// The chunk size used for a file: the whole file when it is small.
    public static func chunkSize(forFileOfSize size: Int64, preferred: Int64) -> Int64 {
        max(1, size <= preferred ? max(size, 1) : preferred)
    }

    public static func count(size: Int64, chunkSize: Int64) -> Int {
        size <= 0 ? 1 : Int((size + chunkSize - 1) / chunkSize)
    }

    public static func range(of chunk: Int, size: Int64, chunkSize: Int64) -> Range<Int64> {
        let start = Int64(chunk) * chunkSize
        return start..<min(size, start + chunkSize)
    }

    /// Chunks not yet written, in order.
    public static func remaining(size: Int64, chunkSize: Int64, completed: [Int]) -> [Int] {
        let done = Set(completed)
        return (0..<count(size: size, chunkSize: chunkSize)).filter { !done.contains($0) }
    }

    /// The end of the run of completed chunks from offset 0.
    public static func contiguousEnd(size: Int64, chunkSize: Int64, completed: [Int]) -> Int64 {
        let done = Set(completed)
        var chunk = 0
        while done.contains(chunk) { chunk += 1 }
        return min(size, Int64(chunk) * chunkSize)
    }

    /// The `Range` header value for a chunk, or nil when the chunk is the whole file.
    public static func rangeHeader(of chunk: Int, size: Int64, chunkSize: Int64) -> String? {
        let r = range(of: chunk, size: size, chunkSize: chunkSize)
        if r.lowerBound == 0 && r.upperBound == size { return nil }
        return "bytes=\(r.lowerBound)-\(r.upperBound - 1)"
    }

    /// Parses `Content-Range: bytes a-b/total`.
    public static func parseContentRange(_ value: String?) -> (range: Range<Int64>, total: Int64?)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let spec = value.dropFirst(6)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let a = Int64(bounds[0]), let b = Int64(bounds[1]), b >= a else { return nil }
        return (a..<(b + 1), Int64(parts[1]))
    }
}
