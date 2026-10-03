// StudioModels: the parts of the Hugging Face API the Models screen uses.
//
//   GET /api/models?search=…&expand[]=…    search, with config summaries
//   GET /api/models/<repo>                 does a repo exist, at which commit
//   GET /api/models/<repo>/tree/<rev>      files with sizes, LFS SHA-256 and git blob ids
//   GET /<repo>/resolve/<rev>/<path>       file content, optionally a byte range
//
// Responses for a commit-pinned revision never change. They are cached on
// disk (Library/Caches, so the system may purge them) and in memory, keyed
// by URL and range.

import CryptoKit
import Foundation

public struct HubModelSummary: Codable, Sendable, Hashable, Identifiable {
    public struct ConfigSummary: Codable, Sendable, Hashable {
        public var modelType: String?
        public var architectures: [String]?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case architectures
        }
    }

    public struct Sibling: Codable, Sendable, Hashable {
        public var rfilename: String
    }

    public var id: String
    public var sha: String?
    public var downloads: Int?
    public var likes: Int?
    public var gated: Bool
    public var lastModified: String?
    public var tags: [String]?
    public var config: ConfigSummary?
    public var baseModels: [String]
    public var siblings: [Sibling]?

    enum CodingKeys: String, CodingKey {
        case id, sha, downloads, likes, gated, lastModified, tags, config, cardData, siblings
    }

    enum CardKeys: String, CodingKey {
        case baseModel = "base_model"
    }

    public init(id: String, sha: String?, gated: Bool = false, config: ConfigSummary? = nil,
                baseModels: [String] = [], siblings: [String]? = nil) {
        self.id = id
        self.sha = sha
        self.gated = gated
        self.config = config
        self.baseModels = baseModels
        self.siblings = siblings?.map(Sibling.init(rfilename:))
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sha = try c.decodeIfPresent(String.self, forKey: .sha)
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        // false, or "auto"/"manual" when gated.
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .gated) {
            gated = flag
        } else {
            gated = (try? c.decodeIfPresent(String.self, forKey: .gated)) != nil
        }
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        tags = try? c.decodeIfPresent([String].self, forKey: .tags)
        config = try? c.decodeIfPresent(ConfigSummary.self, forKey: .config)
        siblings = try? c.decodeIfPresent([Sibling].self, forKey: .siblings)
        var bases: [String] = []
        if let card = try? c.nestedContainer(keyedBy: CardKeys.self, forKey: .cardData) {
            if let one = try? card.decode(String.self, forKey: .baseModel) {
                bases = [one]
            } else if let many = try? card.decode([String].self, forKey: .baseModel) {
                bases = many
            }
        }
        baseModels = bases
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(sha, forKey: .sha)
        try c.encodeIfPresent(downloads, forKey: .downloads)
        try c.encode(gated, forKey: .gated)
        try c.encodeIfPresent(config, forKey: .config)
        try c.encodeIfPresent(siblings, forKey: .siblings)
        var card = c.nestedContainer(keyedBy: CardKeys.self, forKey: .cardData)
        try card.encode(baseModels, forKey: .baseModel)
    }

    public var fileNames: [String] { siblings?.map(\.rfilename) ?? [] }
}

public struct HubTreeEntry: Codable, Sendable, Hashable {
    public struct LFS: Codable, Sendable, Hashable {
        public var oid: String
        public var size: Int64
    }

    public var type: String
    public var oid: String?
    public var size: Int64?
    public var path: String
    public var lfs: LFS?

    public var isFile: Bool { type == "file" }

    /// As a pinned file: LFS files by SHA-256, others by git blob id.
    public var modelFile: ModelFile {
        ModelFile(path: path, size: lfs?.size ?? size ?? 0, sha256: lfs?.oid, gitBlobSHA1: lfs == nil ? oid : nil)
    }
}

public enum HubError: Error, LocalizedError, Hashable {
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, url):
            status == 401 ? "Hugging Face refused access (401): add a token for gated models. \(url)"
                : "Hugging Face returned HTTP \(status) for \(url)"
        case .badResponse(let what): "Unexpected Hugging Face response: \(what)"
        }
    }
}

public actor HubClient {
    public nonisolated let endpoint: HubEndpoint
    nonisolated let transport: any HTTPTransport
    nonisolated let cacheDirectory: URL?
    nonisolated let token: @Sendable () -> String?
    private var memory: [String: Data] = [:]

    static let searchExpansions = ["config", "sha", "downloads", "likes", "gated", "lastModified", "cardData",
                                   "siblings", "tags"]

    public init(endpoint: HubEndpoint = .huggingFace, transport: any HTTPTransport = URLSessionTransport(),
                cacheDirectory: URL? = nil, token: @escaping @Sendable () -> String? = { nil }) {
        self.endpoint = endpoint
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.token = token
    }

    public func search(_ text: String, limit: Int = 40) async throws -> [HubModelSummary] {
        var query = [URLQueryItem(name: "search", value: text), URLQueryItem(name: "limit", value: String(limit))]
        query += Self.searchExpansions.map { URLQueryItem(name: "expand[]", value: $0) }
        let data = try await get(endpoint.api("models", query: query), cache: false)
        do {
            return try JSONDecoder().decode([HubModelSummary].self, from: data)
        } catch {
            throw HubError.badResponse("search results: \(error)")
        }
    }

    /// The repository's summary at its current commit, or nil when it does
    /// not exist (Hugging Face answers 401 for unknown repos without a token).
    public func model(_ repository: String) async throws -> HubModelSummary? {
        let query = Self.searchExpansions.map { URLQueryItem(name: "expand[]", value: $0) }
        do {
            let data = try await get(endpoint.api("models/\(repository)", query: query), cache: false)
            return try JSONDecoder().decode(HubModelSummary.self, from: data)
        } catch HubError.http(let status, _) where status == 404 || status == 401 {
            return nil
        }
    }

    public func tree(_ repository: String, revision: String) async throws -> [HubTreeEntry] {
        let url = endpoint.api("models/\(repository)/tree/\(revision)",
                               query: [URLQueryItem(name: "recursive", value: "true")])
        let data = try await get(url, cache: Self.isCommit(revision))
        do {
            return try JSONDecoder().decode([HubTreeEntry].self, from: data)
        } catch {
            throw HubError.badResponse("file list of \(repository): \(error)")
        }
    }

    public func file(_ repository: String, revision: String, path: String) async throws -> Data {
        try await get(endpoint.resolve(repository: repository, revision: revision, path: path),
                      cache: Self.isCommit(revision))
    }

    /// A safetensors file's header JSON, fetched with two range requests.
    public func safetensorsHeader(_ repository: String, revision: String, path: String) async throws -> Data {
        let url = endpoint.resolve(repository: repository, revision: revision, path: path)
        let cache = Self.isCommit(revision)
        let prefix = try await get(url, range: 0..<8, cache: cache)
        guard prefix.count == 8 else { throw HubError.badResponse("safetensors prefix of \(path)") }
        let length = SafetensorsHeader.length(prefix)
        guard length > 0, length <= SafetensorsHeader.maxHeaderBytes else {
            throw HubError.badResponse("safetensors header size of \(path)")
        }
        return try await get(url, range: 8..<(8 + Int64(length)), cache: cache)
    }

    static func isCommit(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit)
    }

    // MARK: Transport and cache

    func get(_ url: URL, range: Range<Int64>? = nil, cache: Bool) async throws -> Data {
        let key = url.absoluteString + (range.map { "#\($0.lowerBound)-\($0.upperBound)" } ?? "")
        if cache, let hit = memory[key] ?? readCache(key) {
            memory[key] = hit
            return hit
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        if let token = token(), endpoint.mayAuthorize(url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw HubError.http(response.statusCode, url.absoluteString) }
        var body = data
        if let range, response.statusCode == 200 {
            // The server sent the whole file; keep the slice that was asked for.
            let lo = Int(range.lowerBound), hi = min(Int(range.upperBound), data.count)
            body = lo < hi ? data.subdata(in: lo..<hi) : Data()
        }
        if cache {
            memory[key] = body
            writeCache(key, body)
        }
        return body
    }

    private nonisolated func cacheURL(_ key: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let name = SHA256.hash(data: Data(key.utf8)).hexString
        return cacheDirectory.appending(path: name)
    }

    private nonisolated func readCache(_ key: String) -> Data? {
        cacheURL(key).flatMap { try? Data(contentsOf: $0) }
    }

    private nonisolated func writeCache(_ key: String, _ data: Data) {
        guard let url = cacheURL(key) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
