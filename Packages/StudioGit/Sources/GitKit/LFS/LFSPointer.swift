public import Foundation
import CryptoKit

/// A Git LFS pointer file (git-lfs spec v1).
public struct LFSPointer: Sendable, Hashable, Codable {
    public static let version = "https://git-lfs.github.com/spec/v1"
    /// Pointer files are small; anything larger is real content.
    public static let maxPointerSize = 1024

    /// Lowercase hex SHA-256 of the content.
    public var oid: String
    public var size: Int

    public init(oid: String, size: Int) {
        self.oid = oid
        self.size = size
    }

    /// The pointer for `content`.
    public init(content: Data) {
        oid = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        size = content.count
    }

    /// Parses pointer text; nil when `data` is not a pointer.
    public init?(data: Data) {
        guard data.count <= Self.maxPointerSize, data.starts(with: Data("version ".utf8)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var oid: String?
        var size: Int?
        var version: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "version": version = parts[1]
            case "oid":
                guard parts[1].hasPrefix("sha256:") else { return nil }
                oid = String(parts[1].dropFirst(7))
            case "size": size = Int(parts[1])
            default: continue
            }
        }
        guard version == Self.version || version == "https://hawser.github.com/spec/v1",
              let oid, oid.count == 64, oid.allSatisfy(\.isHexDigit), let size, size >= 0 else { return nil }
        self.oid = oid.lowercased()
        self.size = size
    }

    /// The canonical pointer text.
    public var text: String {
        "version \(Self.version)\noid sha256:\(oid)\nsize \(size)\n"
    }

    public var data: Data { Data(text.utf8) }
}

/// The local object store, `.git/lfs/objects/aa/bb/<oid>` like git-lfs.
public struct LFSStore: Sendable {
    public let root: URL

    public init(gitDirectory: URL) {
        root = gitDirectory.appending(path: "lfs/objects", directoryHint: .isDirectory)
    }

    public func url(for oid: String) -> URL {
        let a = oid.prefix(2), b = oid.dropFirst(2).prefix(2)
        return root.appending(path: "\(a)/\(b)/\(oid)")
    }

    public func contains(_ pointer: LFSPointer) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: pointer.oid).path)
        return (attrs?[.size] as? NSNumber)?.intValue == pointer.size
    }

    public func read(_ pointer: LFSPointer) throws -> Data {
        try Data(contentsOf: url(for: pointer.oid))
    }

    /// Stores content and returns its pointer.
    @discardableResult
    public func store(_ content: Data) throws -> LFSPointer {
        let pointer = LFSPointer(content: content)
        if !contains(pointer) {
            let target = url(for: pointer.oid)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, options: .atomic)
        }
        return pointer
    }

    /// Moves a downloaded file into place after checking its hash and size.
    func adopt(_ file: URL, as pointer: LFSPointer) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == pointer.size, LFSPointer(content: data).oid == pointer.oid else {
            try? FileManager.default.removeItem(at: file)
            throw LFSError.corruptObject(pointer.oid)
        }
        let target = url(for: pointer.oid)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
    }

    /// Partial downloads live next to the store so they can be resumed.
    func partialURL(for oid: String) -> URL {
        root.deletingLastPathComponent().appending(path: "incomplete/\(oid).part")
    }
}

public enum LFSError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case noEndpoint
    case server(status: Int, message: String)
    case object(oid: String, code: Int, message: String)
    case corruptObject(String)
    case missingObjects([String])

    public var description: String {
        switch self {
        case .noEndpoint: return "No Git LFS endpoint for this remote (set lfs.url)."
        case .server(let status, let message): return "Git LFS server error \(status): \(message)"
        case .object(let oid, let code, let message): return "Git LFS object \(oid.prefix(12)): \(code) \(message)"
        case .corruptObject(let oid): return "Downloaded Git LFS object \(oid.prefix(12)) does not match its hash."
        case .missingObjects(let oids): return "\(oids.count) Git LFS objects are missing locally."
        }
    }
    public var errorDescription: String? { description }
}
