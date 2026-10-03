import Foundation
import Testing
@testable import GitKit

/// An in-memory Git LFS server (batch API + basic transfers) behind a
/// URLProtocol, one instance per test.
final class FakeLFSServer: @unchecked Sendable {
    let id = UUID().uuidString
    let endpoint = URL(string: "https://lfs.test/repo.git/info/lfs")!
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private(set) var rangeRequests: [String] = []
    private(set) var authorizations: [String] = []
    private(set) var uploads: [String] = []
    /// Require Basic auth with this user:password.
    var requiredAuth: String?

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeLFSProtocol.self]
        config.httpAdditionalHeaders = ["X-Fake-LFS": id]
        FakeLFSProtocol.register(self)
        return URLSession(configuration: config)
    }()

    func put(_ data: Data) { lock.withLock { objects[LFSPointer(content: data).oid] = data } }
    func has(_ oid: String) -> Bool { lock.withLock { objects[oid] != nil } }

    func handle(_ request: URLRequest, body: Data) -> (Int, [String: String], Data) {
        let path = request.url!.path
        if let auth = request.value(forHTTPHeaderField: "Authorization") { lock.withLock { authorizations.append(auth) } }
        if path.hasSuffix("/objects/batch") {
            if let required = requiredAuth,
               request.value(forHTTPHeaderField: "Authorization") != "Basic " + Data(required.utf8).base64EncodedString() {
                return (401, [:], Data(#"{"message":"Credentials needed"}"#.utf8))
            }
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            let operation = json["operation"] as! String
            let reqObjects = json["objects"] as! [[String: Any]]
            let out: [[String: Any]] = reqObjects.map { o in
                let oid = o["oid"] as! String
                let size = o["size"] as! Int
                let href = "https://lfs.test/objects/\(oid)"
                if operation == "download" {
                    guard has(oid) else { return ["oid": oid, "size": size, "error": ["code": 404, "message": "Object does not exist"]] }
                    return ["oid": oid, "size": size, "actions": ["download": ["href": href, "header": ["X-Token": "t"]]]]
                }
                if has(oid) { return ["oid": oid, "size": size] }
                return ["oid": oid, "size": size, "actions": ["upload": ["href": href]]]
            }
            return (200, ["Content-Type": "application/vnd.git-lfs+json"], try! JSONSerialization.data(withJSONObject: ["objects": out]))
        }
        let oid = String(path.split(separator: "/").last!)
        if request.httpMethod == "PUT" {
            lock.withLock { objects[oid] = body; uploads.append(oid) }
            return (200, [:], Data())
        }
        guard let data = lock.withLock({ objects[oid] }) else { return (404, [:], Data()) }
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="),
           let start = Int(range.dropFirst(6).dropLast()) {
            lock.withLock { rangeRequests.append(range) }
            return (206, ["Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"], data.subdata(in: start..<data.count))
        }
        return (200, [:], data)
    }
}

final class FakeLFSProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var servers: [String: FakeLFSServer] = [:]
    static let lock = NSLock()
    static func register(_ s: FakeLFSServer) { lock.withLock { servers[s.id] = s } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Fake-LFS"), let server = Self.lock.withLock({ Self.servers[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let (status, headers, data) = server.handle(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct LFSTests {
    static func payload(_ size: Int, seed: UInt8 = 7) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    @Test func pointerFormat() throws {
        let content = Data("hello lfs\n".utf8)
        let pointer = LFSPointer(content: content)
        #expect(pointer.size == 10)
        #expect(pointer.text.hasPrefix("version https://git-lfs.github.com/spec/v1\noid sha256:"))
        #expect(LFSPointer(data: pointer.data) == pointer)
        #expect(LFSPointer(data: content) == nil)
        #expect(LFSPointer(data: Data("version https://git-lfs.github.com/spec/v1\noid sha256:xyz\nsize 1\n".utf8)) == nil)
    }

    @Test func endpointDerivation() {
        #expect(LFSClient.endpoint(forRemoteURL: "https://github.com/o/r")?.absoluteString == "https://github.com/o/r.git/info/lfs")
        #expect(LFSClient.endpoint(forRemoteURL: "https://gitlab.com/g/s/r.git")?.absoluteString == "https://gitlab.com/g/s/r.git/info/lfs")
        #expect(LFSClient.endpoint(forRemoteURL: "git@github.com:o/r.git")?.absoluteString == "https://github.com/o/r.git/info/lfs")
        #expect(LFSClient.endpoint(forRemoteURL: "ssh://git@git.example.com:2222/o/r.git")?.absoluteString == "https://git.example.com/o/r.git/info/lfs")
        #expect(LFSClient.endpoint(forRemoteURL: "/srv/repo.git") == nil)
        #expect(GitRepository.lfsConfigURL("[lfs]\n\turl = https://lfs.example/x\n") == "https://lfs.example/x")
    }

    /// A repository tracking *.bin with LFS and pointing .lfsconfig at the fake server.
    func lfsRepo(_ server: FakeLFSServer) async throws -> (TempDir, GitRepository, Data) {
        let (dir, repo) = try await makeRepo([
            ".gitattributes": "*.bin filter=lfs diff=lfs merge=lfs -text\n",
            ".lfsconfig": "[lfs]\n\turl = \(server.endpoint.absoluteString)\n",
        ])
        let big = Self.payload(200_000)
        try big.write(to: dir.url.appending(path: "model.bin"))
        try await repo.stageAll()
        try await repo.commit(message: "Add model")
        return (dir, repo, big)
    }

    @Test func cleanFilterStoresPointerAndContent() async throws {
        let server = FakeLFSServer()
        let (dir, repo, big) = try await lfsRepo(server)
        let indexed = try #require(try await repo.indexContents("model.bin"))
        let pointer = try #require(LFSPointer(data: indexed))
        #expect(pointer == LFSPointer(content: big))
        #expect(repo.lfsStore.contains(pointer))
        #expect(try await repo.status().isEmpty)
        #expect(try await repo.lfsFiles().map(\.path) == ["model.bin"])
        // The working tree keeps the real content.
        #expect(try Data(contentsOf: dir.url.appending(path: "model.bin")) == big)
    }

    @Test func pushUploadsThenCloneDownloadsBeforeCheckout() async throws {
        let server = FakeLFSServer()
        let (_, repo, big) = try await lfsRepo(server)
        let bare = TempDir("lfs-server")
        _ = try GitRepository.create(at: bare.url, bare: true)
        try await repo.addRemote("origin", url: bare.url.path)
        let network = NetworkContext(lfsSession: server.session)
        try await repo.push(options: PushOptions(setUpstream: true), network: network)
        #expect(server.has(LFSPointer(content: big).oid))
        #expect(server.uploads.count == 1)
        // Pushing again uploads nothing.
        try await repo.push(network: network)
        #expect(server.uploads.count == 1)

        let dest = TempDir("lfs-clone")
        let clone = try await GitRepository.clone(CloneOptions(url: bare.url.path, destination: dest.url), network: network)
        #expect(try Data(contentsOf: dest.url.appending(path: "model.bin")) == big)
        #expect(try await clone.status().isEmpty)
    }

    @Test func cloneWithoutLFSThenPull() async throws {
        let server = FakeLFSServer()
        let (_, repo, big) = try await lfsRepo(server)
        server.put(big)
        let bare = TempDir("lfs-bare")
        _ = try GitRepository.create(at: bare.url, bare: true)
        try await repo.addRemote("origin", url: bare.url.path)
        try await repo.push(options: PushOptions(lfs: false))

        let dest = TempDir("lfs-pointer-clone")
        var options = CloneOptions(url: bare.url.path, destination: dest.url)
        options.lfs = false
        let clone = try await GitRepository.clone(options, network: NetworkContext(lfsSession: server.session))
        let onDisk = try Data(contentsOf: dest.url.appending(path: "model.bin"))
        #expect(LFSPointer(data: onDisk) != nil)
        let count = try await clone.lfsPull(network: NetworkContext(lfsSession: server.session))
        #expect(count == 1)
        #expect(try Data(contentsOf: dest.url.appending(path: "model.bin")) == big)
        #expect(try await clone.status().isEmpty)
    }

    @Test func downloadResumesPartialFile() async throws {
        let server = FakeLFSServer()
        let content = Self.payload(50_000, seed: 3)
        server.put(content)
        let dir = TempDir("lfs-resume")
        let store = LFSStore(gitDirectory: dir.url)
        let pointer = LFSPointer(content: content)
        let part = store.partialURL(for: pointer.oid)
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.prefix(20_000).write(to: part)
        let client = LFSClient(endpoint: server.endpoint, session: server.session)
        try await client.download([pointer], into: store)
        #expect(server.rangeRequests == ["bytes=20000-"])
        #expect(try store.read(pointer) == content)
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func batchRetriesWithCredentials() async throws {
        let server = FakeLFSServer()
        server.requiredAuth = "alice:token"
        let content = Self.payload(1000)
        server.put(content)
        let store = LFSStore(gitDirectory: TempDir("lfs-auth").url)
        let client = LFSClient(endpoint: server.endpoint, session: server.session,
                               credentials: StaticCredentialProvider(.userPassword(username: "alice", password: "token")))
        try await client.download([LFSPointer(content: content)], into: store)
        #expect(store.contains(LFSPointer(content: content)))
        #expect(server.authorizations.contains("Basic " + Data("alice:token".utf8).base64EncodedString()))
    }

    @Test func missingServerObjectIsReported() async throws {
        let server = FakeLFSServer()
        let store = LFSStore(gitDirectory: TempDir("lfs-missing").url)
        let client = LFSClient(endpoint: server.endpoint, session: server.session)
        await #expect(throws: LFSError.self) { try await client.download([LFSPointer(content: Data("x".utf8))], into: store) }
    }
}
