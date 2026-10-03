public import Foundation

/// Git LFS batch API client (basic transfer adapter) over URLSession.
///
/// One batch request covers every object of a checkout, so a clone with
/// many LFS files costs one round trip plus the transfers. Downloads go to
/// `.git/lfs/incomplete/<oid>.part` and resume with an HTTP Range request
/// when interrupted.
public struct LFSClient: Sendable {
    public var endpoint: URL
    public var session: URLSession
    public var credentials: any CredentialProvider
    /// Concurrent transfers.
    public var concurrency = 4

    public init(endpoint: URL, session: URLSession = .shared, credentials: any CredentialProvider = NoCredentials()) {
        self.endpoint = endpoint
        self.session = session
        self.credentials = credentials
    }

    /// `https://host/owner/repo(.git)/info/lfs` for HTTPS and SSH remotes.
    public static func endpoint(forRemoteURL url: String) -> URL? {
        var https: String?
        if url.hasPrefix("https://") || url.hasPrefix("http://") {
            https = url
        } else if url.hasPrefix("ssh://"), let u = URL(string: url), let host = u.host {
            https = "https://\(host)\(u.path)"
        } else if let at = url.firstIndex(of: "@"), let colon = url.firstIndex(of: ":"), at < colon, !url.contains("://") {
            let host = url[url.index(after: at)..<colon]
            https = "https://\(host)/\(url[url.index(after: colon)...])"
        }
        guard var base = https else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix(".git") { base += ".git" }
        return URL(string: base + "/info/lfs")
    }

    // MARK: Batch API

    struct BatchRequest: Encodable {
        struct Object: Encodable { var oid: String; var size: Int }
        struct Ref: Encodable { var name: String }
        var operation: String
        var transfers = ["basic"]
        var ref: Ref?
        var objects: [Object]
        var hashAlgo = "sha256"

        enum CodingKeys: String, CodingKey { case operation, transfers, ref, objects, hashAlgo = "hash_algo" }
    }

    struct BatchResponse: Decodable {
        struct Action: Decodable {
            var href: URL
            var header: [String: String]?
        }
        struct ObjectError: Decodable { var code: Int; var message: String }
        struct Object: Decodable {
            var oid: String
            var size: Int
            var actions: [String: Action]?
            var error: ObjectError?
        }
        var objects: [Object]
    }

    func batch(_ operation: String, _ pointers: [LFSPointer], ref: String?) async throws -> [BatchResponse.Object] {
        var request = URLRequest(url: endpoint.appending(path: "objects/batch"))
        request.httpMethod = "POST"
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Accept")
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(BatchRequest(
            operation: operation, ref: ref.map { .init(name: $0) },
            objects: pointers.map { .init(oid: $0.oid, size: $0.size) }))
        let (data, status) = try await sendAuthenticated(request)
        guard (200..<300).contains(status) else {
            throw LFSError.server(status: status, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder().decode(BatchResponse.self, from: data).objects
    }

    /// Sends a request with Basic auth from the credential provider, retrying
    /// once after a 401 with the next credential.
    private func sendAuthenticated(_ base: URLRequest) async throws -> (Data, Int) {
        var attempt = 1
        var request = base
        while true {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 401, attempt <= 2 else { return (data, status) }
            let ask = CredentialRequest(url: endpoint.absoluteString, host: endpoint.host, usernameFromURL: nil,
                                        allowed: .userPassword, attempt: attempt)
            guard case .userPassword(let user, let password)? = try await credentials.credential(for: ask) else {
                return (data, status)
            }
            let basic = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
            attempt += 1
        }
    }

    // MARK: Transfers

    /// Downloads every pointer not in `store`. Returns the oids downloaded.
    @discardableResult
    public func download(_ pointers: [LFSPointer], into store: LFSStore, ref: String? = nil,
                         progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [String] {
        let missing = Array(Set(pointers.filter { !store.contains($0) }))
        guard !missing.isEmpty else { return [] }
        let objects = try await batch("download", missing, ref: ref)
        let done = Counter()
        let total = objects.count
        try await forEachConcurrently(objects) { object in
            if let e = object.error { throw LFSError.object(oid: object.oid, code: e.code, message: e.message) }
            guard let action = object.actions?["download"] else { return }
            try await fetch(action, pointer: LFSPointer(oid: object.oid, size: object.size), store: store)
            progress?(done.increment(), total)
        }
        return objects.map(\.oid)
    }

    private func fetch(_ action: BatchResponse.Action, pointer: LFSPointer, store: LFSStore) async throws {
        let part = store.partialURL(for: pointer.oid)
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        var have = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.intValue ?? 0
        if have >= pointer.size { have = 0; try? FileManager.default.removeItem(at: part) }
        var request = URLRequest(url: action.href)
        for (k, v) in action.header ?? [:] { request.setValue(v, forHTTPHeaderField: k) }
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let (temp, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LFSError.server(status: status, message: "download of \(pointer.oid.prefix(12)) failed")
        }
        if status == 206, have > 0 {
            let handle = try FileHandle(forWritingTo: part)
            try handle.seekToEnd()
            try handle.write(contentsOf: try Data(contentsOf: temp))
            try handle.close()
            try? FileManager.default.removeItem(at: temp)
        } else {
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: temp, to: part)
        }
        try store.adopt(part, as: pointer)
    }

    /// Uploads objects the server does not have yet. Returns the oids sent.
    @discardableResult
    public func upload(_ pointers: [LFSPointer], from store: LFSStore, ref: String? = nil) async throws -> [String] {
        let unique = Array(Set(pointers))
        guard !unique.isEmpty else { return [] }
        let local = unique.filter { store.contains($0) }
        if local.count != unique.count {
            throw LFSError.missingObjects(unique.filter { !store.contains($0) }.map(\.oid))
        }
        let objects = try await batch("upload", local, ref: ref)
        let sent = OIDList()
        try await forEachConcurrently(objects) { object in
            if let e = object.error { throw LFSError.object(oid: object.oid, code: e.code, message: e.message) }
            guard let upload = object.actions?["upload"] else { return } // already on the server
            let pointer = LFSPointer(oid: object.oid, size: object.size)
            var request = URLRequest(url: upload.href)
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            for (k, v) in upload.header ?? [:] { request.setValue(v, forHTTPHeaderField: k) }
            let (_, response) = try await session.upload(for: request, fromFile: store.url(for: pointer.oid))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw LFSError.server(status: status, message: "upload of \(pointer.oid.prefix(12)) failed")
            }
            if let verify = object.actions?["verify"] {
                var v = URLRequest(url: verify.href)
                v.httpMethod = "POST"
                v.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
                for (k, val) in verify.header ?? [:] { v.setValue(val, forHTTPHeaderField: k) }
                v.httpBody = try JSONEncoder().encode(BatchRequest.Object(oid: pointer.oid, size: pointer.size))
                let (_, vr) = try await session.data(for: v)
                let vs = (vr as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(vs) else { throw LFSError.server(status: vs, message: "verify failed") }
            }
            sent.append(pointer.oid)
        }
        return sent.all
    }

    private func forEachConcurrently<T: Sendable>(_ items: [T], _ body: @escaping @Sendable (T) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<min(concurrency, items.count) {
                if let item = iterator.next() { group.addTask { try await body(item) } }
            }
            while try await group.next() != nil {
                if let item = iterator.next() { group.addTask { try await body(item) } }
            }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int { lock.withLock { n += 1; return n } }
}

private final class OIDList: @unchecked Sendable {
    private let lock = NSLock()
    private var oids: [String] = []
    func append(_ oid: String) { lock.withLock { oids.append(oid) } }
    var all: [String] { lock.withLock { oids } }
}
