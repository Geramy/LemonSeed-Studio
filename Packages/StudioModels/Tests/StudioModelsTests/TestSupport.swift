// Test support: a scratch directory, a local HTTP server that behaves like
// the Hub's resolve endpoint (redirect, Range, ETag), and recorded Hub API
// fixtures.

import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
@testable import StudioModels

final class Scratch: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "studiomodels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var location: ModelStoreLocation { .rooted(at: url) }
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).hexString }

func gitBlobSHA1Hex(_ data: Data) -> String {
    var h = Insecure.SHA1()
    h.update(data: Data("blob \(data.count)\0".utf8))
    h.update(data: data)
    return h.finalize().hexString
}

/// Deterministic pseudo-random bytes.
func testBytes(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(bytes)
}

/// Polls until `condition` holds or the timeout passes.
func eventually(timeout: Duration = .seconds(30), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

// MARK: - Local HTTP server

/// Serves `/<repo>/resolve/<rev>/<path>` as a 302 to `/cdn/<path>`, then
/// the bytes with Range, ETag and Accept-Ranges, like the Hub and its CDN.
final class LocalHubServer: Sendable {
    struct Request: Sendable, Hashable {
        var path: String
        var range: String?
        var authorization: String?
    }

    struct Behavior: Sendable {
        /// Answer range requests with 200 and the whole file.
        var ignoreRange = false
        /// Flip one byte of this file's content.
        var corrupt: String?
        /// Fail this many requests with 500 before serving.
        var failures = 0
        /// Bytes per write and the pause between writes, to keep transfers in flight.
        var throttle: (bytes: Int, every: Duration)?
        /// Answer 401 without "Bearer <token>".
        var requiredToken: String?
    }

    private struct State {
        var files: [String: Data] = [:]
        var behavior = Behavior()
        var log: [Request] = []
    }

    private let listener: NWListener
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "LocalHubServer")
    private let boundPort = Mutex<UInt16>(0)

    init(files: [String: Data]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        state.withLock { $0.files = files }
        let ready = DispatchSemaphore(value: 0)
        let box = Mutex<UInt16>(0)
        listener.stateUpdateHandler = { s in
            if case .ready = s {
                box.withLock { $0 = listener.port?.rawValue ?? 0 }
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        let bound = box.withLock { $0 }
        boundPort.withLock { $0 = bound }
    }

    deinit { listener.cancel() }

    var endpoint: HubEndpoint { HubEndpoint(base: URL(string: "http://127.0.0.1:\(boundPort.withLock { $0 })")!) }

    var requests: [Request] { state.withLock { $0.log } }

    func setBehavior(_ change: (inout Behavior) -> Void) { state.withLock { change(&$0.behavior) } }

    func setFile(_ path: String, _ data: Data) { state.withLock { $0.files[path] = data } }

    /// Byte ranges served for a file, counted per range header.
    func ranges(for file: String) -> [String?] {
        requests.filter { $0.path == "/cdn/" + file }.map(\.range)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(connection, head: head)
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(path: path, range: headers["range"], authorization: headers["authorization"])
        let (behavior, file, fail): (Behavior, Data?, Bool) = state.withLock { s in
            s.log.append(request)
            var fail = false
            if path.hasPrefix("/cdn/"), s.behavior.failures > 0 {
                s.behavior.failures -= 1
                fail = true
            }
            let name = path.hasPrefix("/cdn/") ? String(path.dropFirst(5)) : ""
            return (s.behavior, s.files[name], fail)
        }
        if let resolve = path.range(of: "/resolve/") {
            if let token = behavior.requiredToken, request.authorization != "Bearer \(token)" {
                return send(connection, status: 401, headers: [:], body: Data())
            }
            // /<org>/<name>/resolve/<rev>/<path...>
            let rest = path[resolve.upperBound...]
            let file = rest.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            return send(connection, status: 302, headers: ["Location": "/cdn/" + file], body: Data())
        }
        guard var body = file else { return send(connection, status: 404, headers: [:], body: Data()) }
        if fail { return send(connection, status: 500, headers: [:], body: Data()) }
        if let corrupt = behavior.corrupt, path == "/cdn/" + corrupt, !body.isEmpty {
            body[body.count / 2] ^= 0xff
        }
        let etag = "\"" + sha256Hex(body).prefix(16) + "\""
        var out = ["ETag": etag, "Accept-Ranges": "bytes", "Last-Modified": "Wed, 01 Jan 2025 00:00:00 GMT",
                   "Content-Type": "application/octet-stream"]
        var status = 200
        if let range = headers["range"], !behavior.ignoreRange, let r = Self.parseRange(range, size: body.count) {
            out["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(body.count)"
            body = body.subdata(in: r)
            status = 206
        }
        if method == "HEAD" { return send(connection, status: status, headers: out, body: Data(), length: body.count) }
        send(connection, status: status, headers: out, body: body, throttle: behavior.throttle)
    }

    static func parseRange(_ value: String, size: Int) -> Range<Int>? {
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2, let a = Int(spec[0]) else { return nil }
        let b = Int(spec[1]) ?? (size - 1)
        guard a <= b, a < size else { return nil }
        return a..<min(size, b + 1)
    }

    private func send(_ connection: NWConnection, status: Int, headers: [String: String], body: Data,
                      length: Int? = nil, throttle: (bytes: Int, every: Duration)? = nil) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 206 ? "Partial Content" : "Status")\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(length ?? body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        guard let throttle, body.count > throttle.bytes else {
            connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let delay = Double(throttle.every.components.attoseconds) * 1e-18 + Double(throttle.every.components.seconds)
        func pump(_ offset: Int) {
            let end = min(body.count, offset + throttle.bytes)
            connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { error in
                if error != nil || end == body.count {
                    connection.cancel()
                    return
                }
                self.queue.asyncAfter(deadline: .now() + delay) { pump(end) }
            })
        }
        pump(0)
    }
}

// MARK: - Recorded Hub fixtures

/// Answers from Fixtures/hub, recorded from huggingface.co by
/// `STUDIO_MODELS_RECORD_HUB=1 swift test --filter HubSearchTests`.
struct FixtureTransport: HTTPTransport {
    struct Entry: Codable {
        var key: String
        var status: Int
        var body: String
    }

    let directory: URL
    let entries: [String: Entry]

    init(directory: URL) throws {
        self.directory = directory
        let manifest = try Data(contentsOf: directory.appending(path: "manifest.json"))
        let list = try JSONDecoder().decode([Entry].self, from: manifest)
        entries = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func key(_ request: URLRequest) -> String {
        (request.url?.absoluteString ?? "") + (request.value(forHTTPHeaderField: "Range").map { " " + $0 } ?? "")
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = Self.key(request)
        guard let entry = entries[key] else {
            // Unrecorded requests answer 404, as an unknown repo would.
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let data = try Data(contentsOf: directory.appending(path: entry.body))
        return (data, HTTPURLResponse(url: request.url!, statusCode: entry.status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Passes requests through and writes them as fixtures. JSON bodies are
/// re-serialized compactly to keep the fixtures small.
final class RecordingTransport: HTTPTransport {
    let directory: URL
    let upstream = URLSessionTransport()
    private let entries = Mutex<[FixtureTransport.Entry]>([])

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await upstream.send(request)
        let key = FixtureTransport.key(request)
        let name = sha256Hex(Data(key.utf8)).prefix(20) + ".bin"
        var stored = data
        let isRange = request.value(forHTTPHeaderField: "Range") != nil
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if request.url?.lastPathComponent == "model.safetensors.index.json",
               let index = object as? [String: Any], let map = index["weight_map"] as? [String: Any] {
                stored = Self.compact(["weight_map": Self.decisive(map)])
            } else if isRange, let header = object as? [String: Any] {
                stored = Self.compact(Self.decisive(header))
            } else if !isRange {
                stored = Self.trim(Self.compact(object))
            }
        }
        try stored.write(to: directory.appending(path: String(name)))
        entries.withLock { $0.append(.init(key: key, status: response.statusCode, body: String(name))) }
        return (stored, response)
    }

    static func compact(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Keeps the tensor names the verdict depends on: the layout markers and
    /// anything outside language_model./vision_tower. The thousands of
    /// ordinary layer tensors are dropped to keep fixtures small.
    static func decisive(_ map: [String: Any]) -> [String: Any] {
        let markers: Set<String> = [ModelInspector.gdnMarker, ModelInspector.moeMarker, ModelInspector.denseMarker,
                                    "fc.weight"]
        return map.filter { key, _ in
            markers.contains(key) || key == "__metadata__"
                || !(key.hasPrefix("language_model.") || key.hasPrefix("vision_tower."))
        }.mapValues { _ in [String: Any]() }
    }

    /// Drops chat templates from search summaries: large and never read.
    static func trim(_ data: Data) -> Data {
        guard var list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return data }
        for i in list.indices {
            if var config = list[i]["config"] as? [String: Any] {
                config["tokenizer_config"] = nil
                config["chat_template_jinja"] = nil
                list[i]["config"] = config
            }
            list[i]["widgetData"] = nil
        }
        return (try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])) ?? data
    }

    func finish() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let list = entries.withLock { $0 }.sorted { $0.key < $1.key }
        try encoder.encode(list).write(to: directory.appending(path: "manifest.json"))
    }
}

enum Fixtures {
    static var root: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: root.appending(path: name)) }

    /// The source tree's fixture directory, for recording.
    static func sourceDirectory(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().appending(path: "Fixtures")
    }
}
