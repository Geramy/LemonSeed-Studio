public import Foundation

public enum ForgeError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case unauthorized
    case forbidden(String)
    case notFound
    case rateLimited(resetAt: Date?)
    case validation(String)
    case http(status: Int, message: String)
    case decoding(String)
    case transport(String)
    /// Device flow: the user denied access or the code expired.
    case authorizationDenied
    case authorizationExpired
    /// The instance has no device flow (GitLab < 17.9 or no OAuth app).
    case deviceFlowUnsupported
    case missingClientID(ForgeKind)
    case notSignedIn

    public var description: String {
        switch self {
        case .unauthorized: return "The token was rejected. Sign in again."
        case .forbidden(let m): return "Forbidden: \(m)"
        case .notFound: return "Not found."
        case .rateLimited(let reset):
            if let reset { return "Rate limited until \(reset.formatted(date: .omitted, time: .shortened))." }
            return "Rate limited."
        case .validation(let m): return m
        case .http(let status, let m): return "HTTP \(status): \(m)"
        case .decoding(let m): return "Unexpected response: \(m)"
        case .transport(let m): return m
        case .authorizationDenied: return "Access was denied."
        case .authorizationExpired: return "The code expired. Start again."
        case .deviceFlowUnsupported: return "This server does not support device sign-in. Use a personal access token."
        case .missingClientID(let kind): return "No OAuth client ID is configured for \(kind.displayName). Add one in Settings, or use a personal access token."
        case .notSignedIn: return "Not signed in."
        }
    }

    public var errorDescription: String? { description }
}

/// Rate-limit state from the last response.
public struct RateLimit: Sendable, Equatable {
    public var limit: Int?
    public var remaining: Int?
    public var resetAt: Date?
}

/// A small JSON-over-HTTPS client: auth header, ETag caching, Link-header
/// pagination, rate-limit tracking and error mapping.
public actor ForgeHTTP {
    public typealias TokenSource = @Sendable () async throws -> String?

    public nonisolated let baseURL: URL
    private let session: URLSession
    private let token: TokenSource
    private let extraHeaders: [String: String]
    private var etags: [URL: (etag: String, data: Data)] = [:]
    public private(set) var rateLimit = RateLimit()

    public init(baseURL: URL, session: URLSession = .shared, extraHeaders: [String: String] = [:], token: @escaping TokenSource) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
        self.extraHeaders = extraHeaders
    }

    public struct Response: Sendable {
        public var data: Data
        public var status: Int
        public var headers: [String: String]
        public var nextURL: URL?
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: text) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: text) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date \(text)")
        }
        return d
    }()

    /// Builds a URL from an absolute URL or a path relative to `baseURL`.
    /// Paths are used as given (already percent-encoded), so GitLab project
    /// ids such as `group%2Fproject` survive.
    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        let text: String
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            text = path
        } else {
            let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
            text = base + (path.hasPrefix("/") ? path : "/" + path)
        }
        guard var components = URLComponents(string: text) else { return baseURL }
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { components.queryItems = (components.queryItems ?? []) + items }
        return components.url ?? baseURL
    }

    /// Sends a request; `body` is JSON-encoded.
    @discardableResult
    public func send(_ method: String, _ path: String, query: [String: String?] = [:], body: (any Encodable & Sendable)? = nil,
                     accept: String = "application/json", useCache: Bool = true) async throws -> Response {
        let target = url(path, query: query)
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("LemonSeedStudio", forHTTPHeaderField: "User-Agent")
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        if let t = try await token() { request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(body)
        }
        let cacheable = method == "GET" && useCache
        if cacheable, let cached = etags[target] {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch {
            throw ForgeError.transport(error.localizedDescription)
        }
        guard let http = urlResponse as? HTTPURLResponse else { throw ForgeError.transport("not an HTTP response") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
        updateRateLimit(headers)

        var body = data
        if http.statusCode == 304, let cached = etags[target] {
            body = cached.data
        } else if cacheable, (200..<300).contains(http.statusCode), let etag = headers["etag"] {
            etags[target] = (etag, data)
        }
        let status = http.statusCode == 304 ? 200 : http.statusCode
        guard (200..<300).contains(status) else { throw mapError(status: status, data: data, headers: headers) }
        return Response(data: body, status: status, headers: headers, nextURL: Self.nextLink(headers["link"]))
    }

    public func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [String: String?] = [:]) async throws -> T {
        let response = try await send("GET", path, query: query)
        return try decode(type, response.data)
    }

    /// Follows `Link: rel="next"` up to `maxPages`.
    public func getAll<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [String: String?] = [:], maxPages: Int = 10) async throws -> [T] {
        var results: [T] = []
        var response = try await send("GET", path, query: query)
        results += try decode([T].self, response.data)
        var pages = 1
        while let next = response.nextURL, pages < maxPages {
            response = try await send("GET", next.absoluteString)
            results += try decode([T].self, response.data)
            pages += 1
        }
        return results
    }

    public func post<T: Decodable & Sendable>(_ type: T.Type, _ path: String, body: (any Encodable & Sendable)?) async throws -> T {
        try decode(type, try await send("POST", path, body: body).data)
    }

    public func put<T: Decodable & Sendable>(_ type: T.Type, _ path: String, body: (any Encodable & Sendable)?) async throws -> T {
        try decode(type, try await send("PUT", path, body: body).data)
    }

    /// GraphQL query with variables; returns the `data` member.
    public func graphQL<T: Decodable & Sendable>(_ type: T.Type, url: URL, query: String, variables: [String: GraphQLValue] = [:]) async throws -> T {
        let response = try await send("POST", url.absoluteString, body: GraphQLBody(query: query, variables: variables), useCache: false)
        let envelope = try decode(GraphQLEnvelope<T>.self, response.data)
        if let errors = envelope.errors, !errors.isEmpty {
            throw ForgeError.validation(errors.map(\.message).joined(separator: "; "))
        }
        guard let data = envelope.data else { throw ForgeError.decoding("GraphQL response without data") }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw ForgeError.decoding("\(T.self): \(error)")
        }
    }

    private func updateRateLimit(_ headers: [String: String]) {
        let remaining = headers["x-ratelimit-remaining"] ?? headers["ratelimit-remaining"]
        let limit = headers["x-ratelimit-limit"] ?? headers["ratelimit-limit"]
        let reset = headers["x-ratelimit-reset"] ?? headers["ratelimit-reset"]
        if remaining == nil && limit == nil { return }
        rateLimit = RateLimit(limit: limit.flatMap(Int.init), remaining: remaining.flatMap(Int.init),
                              resetAt: reset.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) })
    }

    private func mapError(status: Int, data: Data, headers: [String: String]) -> ForgeError {
        struct Message: Decodable { var message: String?; var error: String?; var errorDescription: String? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parsed = try? decoder.decode(Message.self, from: data)
        // GitLab sends {"message": {"field": ["error"]}} for validation errors.
        let rawText = String(decoding: data.prefix(500), as: UTF8.self)
        let message = parsed?.message ?? parsed?.errorDescription ?? parsed?.error ?? rawText
        switch status {
        case 401: return .unauthorized
        case 403, 429:
            if headers["x-ratelimit-remaining"] == "0" || headers["ratelimit-remaining"] == "0" || status == 429 {
                return .rateLimited(resetAt: rateLimit.resetAt)
            }
            return .forbidden(message)
        case 404: return .notFound
        case 409, 422: return .validation(message)
        default: return .http(status: status, message: message)
        }
    }

    static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces[1...].contains(where: { $0 == "rel=\"next\"" }) else { continue }
            let link = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: link)
        }
        return nil
    }
}

struct GraphQLBody: Encodable, Sendable {
    var query: String
    var variables: [String: GraphQLValue]
}

struct GraphQLEnvelope<T: Decodable>: Decodable {
    struct Message: Decodable { var message: String }
    var data: T?
    var errors: [Message]?
}

/// JSON values for GraphQL variables.
public enum GraphQLValue: Encodable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

/// Decodes and ignores any JSON body.
public struct EmptyResponse: Decodable, Sendable {
    public init(from decoder: any Decoder) throws {}
}
