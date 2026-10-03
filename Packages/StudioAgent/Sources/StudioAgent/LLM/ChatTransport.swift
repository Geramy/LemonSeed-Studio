import Foundation
import Synchronization

/// Moves OpenAI-compatible JSON between the client and an engine.
///
/// The client owns everything about the protocol (encoding requests, decoding
/// `chat.completion.chunk` objects, tool-call extraction); a transport only
/// carries bytes. Two transports exist:
///
/// - `HTTPChatTransport`: an OpenAI-compatible server (lse-server on a Mac,
///   the loopback endpoint, any remote provider). It strips SSE framing.
/// - `ClosureChatTransport`: an in-process engine. LSE's C API
///   `lse_request(engine, method, path, json_body, cb, …)` takes the same
///   request JSON and calls back with the same chunk objects the SSE stream
///   carries, without `data:` framing; the iPad app binds it here.
public protocol ChatTransport: Sendable {
    /// Sends a streaming request. Yields each chunk's JSON payload exactly as
    /// the engine produced it (one `chat.completion.chunk`, an `{"error":…}`
    /// object, or the `[DONE]` sentinel, which may also be omitted).
    /// Cancelling the consumer must stop generation.
    func stream(method: String, path: String, body: Data) -> AsyncThrowingStream<Data, Error>

    /// Sends a plain request and returns the response body. Non-2xx statuses
    /// throw `LLMError.http`.
    func request(method: String, path: String, body: Data?, timeout: TimeInterval) async throws -> Data
}

// MARK: - HTTP

/// HTTP + SSE transport for OpenAI-compatible servers.
public struct HTTPChatTransport: ChatTransport {
    /// Paths are resolved against this URL (".../v1").
    public let baseURL: URL
    public let apiKey: String?
    private let session: URLSession
    private let timeout: TimeInterval

    public init(baseURL: URL, apiKey: String? = nil, timeout: TimeInterval = 900, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = timeout
            c.timeoutIntervalForResource = timeout
            c.waitsForConnectivity = false
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: c)
        }
    }

    func url(_ path: String) -> URL {
        // "/health" lives at the server root, everything else under /v1.
        if path.hasPrefix("/") { return baseURL.deletingLastPathComponent().appending(path: String(path.dropFirst())) }
        return baseURL.appending(path: path)
    }

    private func makeRequest(_ method: String, _ path: String, _ body: Data?, timeout: TimeInterval,
                             streaming: Bool) -> URLRequest {
        var r = URLRequest(url: url(path), timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if streaming { r.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        if let apiKey, !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return r
    }

    public func stream(method: String, path: String, body: Data) -> AsyncThrowingStream<Data, Error> {
        let request = makeRequest(method, path, body, timeout: timeout, streaming: true)
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw LLMError.unreachable("no HTTP response") }
                    guard (200..<300).contains(http.statusCode) else {
                        var body: [UInt8] = []
                        for try await b in bytes {
                            body.append(b)
                            if body.count > 65_536 { break }
                        }
                        throw LLMError.fromResponse(status: http.statusCode, body: Data(body))
                    }
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    line.reserveCapacity(4096)
                    for try await b in bytes {
                        line.append(b)
                        if b == 0x0A {
                            for e in parser.feed(line) { continuation.yield(Data(e.data.utf8)) }
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    for e in parser.feed(line) + parser.finish() { continuation.yield(Data(e.data.utf8)) }
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError {
                    continuation.finish(throwing: LLMError.unreachable(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func request(method: String, path: String, body: Data?, timeout: TimeInterval) async throws -> Data {
        let r = makeRequest(method, path, body, timeout: timeout, streaming: false)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: r) } catch let e as URLError {
            throw LLMError.unreachable(e.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMError.fromResponse(status: status, body: data) }
        return data
    }
}

// MARK: - In process

/// A transport over a blocking, callback-based engine API.
///
/// The handler receives the method, path and JSON body, calls `emit` once
/// per streamed chunk (JSON bytes without `data:` framing) and returns the
/// final status and body. `emit` returns false once the consumer has gone
/// away; the handler should then stop (LSE's chunk callback returns 0 to
/// cancel at the next token). The handler runs on its own thread, never on
/// the caller's executor, because engine calls block.
public struct ClosureChatTransport: ChatTransport {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public init(status: Int = 200, body: Data = Data()) {
            self.status = status
            self.body = body
        }
    }

    public typealias Handler = @Sendable (_ method: String, _ path: String, _ body: Data?,
                                          _ emit: @Sendable (Data) -> Bool) throws -> Response

    private let handler: Handler

    public init(_ handler: @escaping Handler) { self.handler = handler }

    public func stream(method: String, path: String, body: Data) -> AsyncThrowingStream<Data, Error> {
        let handler = handler
        return AsyncThrowingStream { continuation in
            let open = Mutex(true)
            continuation.onTermination = { _ in open.withLock { $0 = false } }
            let thread = Thread {
                do {
                    let response = try handler(method, path, body) { chunk in
                        guard open.withLock({ $0 }) else { return false }
                        continuation.yield(chunk)
                        return true
                    }
                    guard (200..<300).contains(response.status) else {
                        throw LLMError.fromResponse(status: response.status, body: response.body)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.name = "lemonseed.engine-request"
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    public func request(method: String, path: String, body: Data?, timeout: TimeInterval) async throws -> Data {
        let handler = handler
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let thread = Thread {
                do {
                    let r = try handler(method, path, body) { _ in true }
                    guard (200..<300).contains(r.status) else {
                        throw LLMError.fromResponse(status: r.status, body: r.body)
                    }
                    cont.resume(returning: r.body)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            thread.name = "lemonseed.engine-request"
            thread.start()
        }
    }
}

extension LLMError {
    /// Maps a non-2xx response, reading the OpenAI error envelope if present.
    static func fromResponse(status: Int, body: Data) -> LLMError {
        if let json = try? JSONValue.parse(body), let message = json["error"]?["message"]?.stringValue {
            return .http(status: status, message: message)
        }
        return .http(status: status, message: String(decoding: body.prefix(2000), as: UTF8.self))
    }
}
