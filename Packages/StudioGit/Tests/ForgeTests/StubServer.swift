import Foundation
@testable import Forge

/// An in-process HTTP stub: a URLSession whose requests are answered by
/// registered handlers. Each server has its own session, so tests run in
/// parallel without sharing routes.
final class StubServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
        var path: String { url.path(percentEncoded: true) }
        var query: [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var form: [String: String] {
            Dictionary(uniqueKeysWithValues: String(decoding: body, as: UTF8.self).split(separator: "&").map { pair in
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                return (kv[0], kv.count > 1 ? kv[1] : "")
            })
        }
    }

    struct Response {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            var h = ["Content-Type": "application/json"]
            h.merge(headers) { $1 }
            return Response(status: status, headers: h, body: Data(text.utf8))
        }
        static func text(_ text: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain"], body: Data(text.utf8))
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    let id = UUID().uuidString
    let session: URLSession
    private let lock = NSLock()
    private var routes: [(method: String, path: String, handler: Handler)] = []
    private var log: [Request] = []

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub-Server": id]
        session = URLSession(configuration: config)
        StubURLProtocol.register(self)
    }

    /// Registers a handler for `method` and an exact URL path.
    func on(_ method: String, _ path: String, _ handler: @escaping Handler) {
        lock.withLock { routes.append((method, path, handler)) }
    }

    func on(_ method: String, _ path: String, json: String, status: Int = 200, headers: [String: String] = [:]) {
        on(method, path) { _ in .json(json, status: status, headers: headers) }
    }

    var requests: [Request] { lock.withLock { log } }
    func requests(_ method: String, _ path: String) -> [Request] { requests.filter { $0.method == method && $0.path == path } }

    fileprivate func respond(to request: Request) -> Response {
        lock.withLock { log.append(request) }
        let handler = lock.withLock { routes.last { $0.method == request.method && $0.path == request.path }?.handler }
        return handler?(request) ?? .json(#"{"message":"no stub for \#(request.method) \#(request.path)"}"#, status: 404)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: StubServer) {
        lock.withLock { servers[server.id] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Stub-Server"),
              let server = Self.lock.withLock({ Self.servers[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let req = StubServer.Request(method: request.httpMethod ?? "GET", url: url,
                                     headers: request.allHTTPHeaderFields ?? [:], body: body)
        let res = server.respond(to: req)
        let http = HTTPURLResponse(url: url, statusCode: res.status, httpVersion: "HTTP/1.1", headerFields: res.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: res.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
