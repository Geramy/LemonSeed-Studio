#if DEBUG
import Foundation
import Network

/// One HTTP/1.1 request, as the development server reads it.
struct DevRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func json() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }
}

/// A response: a whole body, or a stream of server-sent events.
enum DevResponse: Sendable {
    case data(status: Int, contentType: String, body: Data)
    /// `text/event-stream`: the producer writes events, then finishes.
    case stream(@MainActor @Sendable (DevEventSink) async -> Void)

    static func json(_ object: Any, status: Int = 200) -> DevResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return .data(status: status, contentType: "application/json", body: data)
    }

    static func error(_ message: String, status: Int = 400) -> DevResponse {
        json(["error": message], status: status)
    }
}

/// Writes server-sent events to one connection.
final class DevEventSink: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var isClosed = false

    init(connection: NWConnection) { self.connection = connection }

    /// Whether the client has gone (writes failed) or the stream finished.
    var closed: Bool { lock.withLock { isClosed } }

    /// One `data:` event carrying an already serialized JSON object.
    func send(json data: Data) async {
        var frame = Data("data: ".utf8)
        frame.append(data)
        frame.append(Data("\n\n".utf8))
        await write(frame)
    }

    func write(_ data: Data) async {
        guard !closed else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.lock.withLock { self?.isClosed = true } }
                c.resume()
            })
        }
    }

    func finish() {
        let wasClosed = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return isClosed
        }
        guard !wasClosed else { return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}

extension DevEventSink {
    /// One `data:` event carrying a JSON object (built on the main actor).
    @MainActor
    func send(_ object: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        await send(json: data)
    }
}

/// Reads one request per connection (Connection: close), hands it to the
/// router, writes the answer.
final class DevHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: @Sendable (DevRequest) async -> DevResponse
    private var buffer = Data()
    private static let maxRequest = 16 << 20

    init(connection: NWConnection, handler: @escaping @Sendable (DevRequest) async -> DevResponse) {
        self.connection = connection
        self.handler = handler
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connection.cancel() }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let request = self.parse() {
                Task { await self.respond(to: request) }
            } else if complete || error != nil || self.buffer.count > Self.maxRequest {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }

    /// A complete request, once the headers and Content-Length bytes are in.
    private func parse() -> DevRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        let body = buffer[bodyStart..<(bodyStart + length)]
        let target = String(requestLine[1])
        let components = URLComponents(string: "http://device" + target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return DevRequest(method: String(requestLine[0]).uppercased(), path: components?.path ?? target,
                          query: query, headers: headers, body: Data(body))
    }

    private func respond(to request: DevRequest) async {
        switch await handler(request) {
        case .data(let status, let type, let body):
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(type)\r\n"
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var data = Data(head.utf8)
            data.append(body)
            connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [connection] _ in connection.cancel() })
        case .stream(let produce):
            let sink = DevEventSink(connection: connection)
            await sink.write(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8))
            await produce(sink)
            await sink.write(Data("data: [DONE]\n\n".utf8))
            sink.finish()
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
#endif
