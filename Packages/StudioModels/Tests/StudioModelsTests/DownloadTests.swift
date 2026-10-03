// The downloader against a local server that behaves like the Hub: range
// chunks, verification, pause and resume, a crash mid-download, corrupt
// bytes, servers that ignore Range, transient errors and gated repos.
//
// These use an in-process URLSession. The background session differs only in
// its configuration, and needs an app to run.

import Foundation
import Testing
@testable import StudioModels

@Suite("Downloader", .serialized)
struct DownloadTests {
    static let chunk: Int64 = 512 << 10
    let big = testBytes(3 * (512 << 10) + 1234, seed: 11)        // four chunks
    let shard = testBytes(2 * (512 << 10), seed: 12)             // exactly two chunks
    let config = Data(#"{"architectures": ["Test"]}"#.utf8)

    var files: [String: Data] {
        ["model-00001-of-00002.safetensors": big, "model-00002-of-00002.safetensors": shard, "config.json": config]
    }

    func request(id: String = "tiny") -> DownloadRequest {
        DownloadRequest(id: id, name: "Tiny", role: .main, origin: .huggingFace, repository: "test/tiny",
                        revision: String(repeating: "b", count: 40), files: [
                            ModelFile(path: "config.json", size: Int64(config.count), gitBlobSHA1: gitBlobSHA1Hex(config)),
                            ModelFile(path: "model-00001-of-00002.safetensors", size: Int64(big.count), sha256: sha256Hex(big)),
                            ModelFile(path: "model-00002-of-00002.safetensors", size: Int64(shard.count), sha256: sha256Hex(shard)),
                        ])
    }

    func downloader(_ location: ModelStoreLocation, _ server: LocalHubServer, token: String? = nil,
                    window: Int? = 3, margin: Int64 = 0) -> ModelDownloader {
        ModelDownloader(registry: ModelRegistry(location: location), endpoint: server.endpoint,
                        configuration: DownloaderConfiguration(session: .foreground, chunkSize: Self.chunk,
                                                               taskWindow: window, maxRetries: 3,
                                                               retryDelay: .milliseconds(20), spaceMargin: margin),
                        token: { token })
    }

    func state(_ d: ModelDownloader, _ id: String = "tiny") async -> ModelRecord.State? {
        await d.registry.record(id)?.state
    }

    func completedChunks(_ d: ModelDownloader, _ path: String) async -> [Int] {
        await d.registry.record("tiny")?.files.first { $0.path == path }?.completedChunks ?? []
    }

    func expectInstalled(_ location: ModelStoreLocation, _ d: ModelDownloader) async throws {
        let dir = location.directory(for: "tiny")
        for (path, data) in files { #expect(try Data(contentsOf: dir.appending(path: path)) == data, "\(path)") }
        #expect(HubOrigin.read(from: dir) == HubOrigin(repository: "test/tiny", revision: String(repeating: "b", count: 40)))
        #expect(ModelStoreLocation.isExcludedFromBackup(dir))
        #expect(!FileManager.default.fileExists(atPath: location.partialDirectory(for: "tiny").path))
        let record = try #require(await d.registry.record("tiny"))
        #expect(record.state == .installed && record.isVerified)
        #expect(record.files.allSatisfy { $0.completedChunks.isEmpty && $0.chunkSize == nil && $0.sha256 != nil })
        // The config had only a git blob id; its SHA-256 is recorded now.
        #expect(record.files.first { $0.path == "config.json" }?.sha256 == sha256Hex(config))
    }

    @Test func downloadsInRangeChunksVerifiesAndInstallsAtomically() async throws {
        let scratch = try Scratch()
        let server = try LocalHubServer(files: files)
        let d = downloader(scratch.location, server)
        let events = await d.events()
        try await d.start(request())
        #expect(await eventually { await state(d) == .installed })
        try await expectInstalled(scratch.location, d)
        // Each chunk exactly once, as a range; the small file as a plain request.
        let ranges = server.ranges(for: "model-00001-of-00002.safetensors").compactMap { $0 }.sorted()
        #expect(ranges == ["bytes=0-524287", "bytes=1048576-1572863", "bytes=1572864-1574097", "bytes=524288-1048575"])
        #expect(server.ranges(for: "config.json") == [nil])
        var sawProgress = false, sawInstalled = false
        for await event in events {
            if case .progress(let p) = event, p.totalBytes == Int64(big.count + shard.count + config.count) { sawProgress = true }
            if case .installed("tiny") = event { sawInstalled = true; break }
        }
        #expect(sawProgress && sawInstalled)
        await #expect(throws: DownloadError.alreadyInstalled("tiny")) { try await d.start(request()) }
    }

    @Test func pauseKeepsFinishedChunksAndResumeFetchesOnlyTheRest() async throws {
        let scratch = try Scratch()
        let server = try LocalHubServer(files: files)
        server.setBehavior { $0.throttle = (32 << 10, .milliseconds(15)) }
        let d = downloader(scratch.location, server, window: 2)
        try await d.start(request())
        #expect(await eventually { await completedChunks(d, "model-00001-of-00002.safetensors").count >= 1 })
        await d.pause("tiny")
        #expect(await state(d) == .paused)
        let doneAtPause = await completedChunks(d, "model-00001-of-00002.safetensors")
        let requestsAtPause = server.requests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == requestsAtPause, "nothing is fetched while paused")

        server.setBehavior { $0.throttle = nil }
        try await d.resume("tiny")
        #expect(await eventually { await state(d) == .installed })
        try await expectInstalled(scratch.location, d)
        let ranges = server.ranges(for: "model-00001-of-00002.safetensors")
        for chunk in doneAtPause {
            let header = ChunkPlan.rangeHeader(of: chunk, size: Int64(big.count), chunkSize: Self.chunk)
            #expect(ranges.filter { $0 == header }.count == 1, "chunk \(chunk) fetched once")
        }
    }

    @Test func aRelaunchResumesFromTheRegistry() async throws {
        let scratch = try Scratch()
        let server = try LocalHubServer(files: files)
        server.setBehavior { $0.throttle = (32 << 10, .milliseconds(15)) }
        let first = downloader(scratch.location, server, window: 2)
        try await first.start(request())
        #expect(await eventually { await completedChunks(first, "model-00001-of-00002.safetensors").count >= 2 })
        // The process dies: in-flight transfers are lost, the registry is not.
        await first.invalidate()
        let done = await completedChunks(first, "model-00001-of-00002.safetensors")
        server.setBehavior { $0.throttle = nil }

        let second = downloader(scratch.location, server)
        await second.restore()
        #expect(await eventually { await state(second) == .installed })
        try await expectInstalled(scratch.location, second)
        let ranges = server.ranges(for: "model-00001-of-00002.safetensors")
        for chunk in done {
            let header = ChunkPlan.rangeHeader(of: chunk, size: Int64(big.count), chunkSize: Self.chunk)
            #expect(ranges.filter { $0 == header }.count == 1, "chunk \(chunk) was not fetched again")
        }
    }

    @Test func corruptBytesFailVerificationAndInstallNothing() async throws {
        let scratch = try Scratch()
        let server = try LocalHubServer(files: files)
        server.setBehavior { $0.corrupt = "model-00002-of-00002.safetensors" }
        let d = downloader(scratch.location, server)
        try await d.start(request())
        #expect(await eventually {
            if case .failed = await state(d) { return true }
            return false
        })
        if case .failed(let message) = await state(d) {
            #expect(message.contains("model-00002-of-00002.safetensors") && message.contains("checksum"))
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.location.directory(for: "tiny").path))
        // The good file stays verified, so a retry fetches only the bad one.
        let record = try #require(await d.registry.record("tiny"))
        #expect(record.files.first { $0.path == "model-00001-of-00002.safetensors" }?.verification == .verified)
        server.setBehavior { $0.corrupt = nil }
        let before = server.ranges(for: "model-00001-of-00002.safetensors").count
        try await d.resume("tiny")
        #expect(await eventually { await state(d) == .installed })
        #expect(server.ranges(for: "model-00001-of-00002.safetensors").count == before)
        try await expectInstalled(scratch.location, d)
    }

    @Test func aServerIgnoringRangeStillProducesTheFile() async throws {
        let scratch = try Scratch()
        let server = try LocalHubServer(files: files)
        server.setBehavior { $0.ignoreRange = true }
        let d = downloader(scratch.location, server, window: 1)
        try await d.start(request())
        #expect(await eventually { await state(d) == .installed })
        try await expectInstalled(scratch.location, d)
    }

    @Test func transientServerErrorsAreRetried() async throws {
        let scratch = try Scratch()
        let server = try LocalHubServer(files: files)
        server.setBehavior { $0.failures = 3 }
        let d = downloader(scratch.location, server)
        try await d.start(request())
        #expect(await eventually { await state(d) == .installed })
        try await expectInstalled(scratch.location, d)
    }

    @Test func gatedRepositoriesNeedTheToken() async throws {
        let scratch = try Scratch()
        let server = try LocalHubServer(files: files)
        server.setBehavior { $0.requiredToken = "hf_secret" }
        let anonymous = downloader(scratch.location, server)
        try await anonymous.start(request())
        #expect(await eventually {
            if case .failed(let m) = await state(anonymous) { return m.contains("401") }
            return false
        })
        await anonymous.cancel("tiny")
        #expect(await anonymous.registry.record("tiny") == nil)
        #expect(!FileManager.default.fileExists(atPath: scratch.location.partialDirectory(for: "tiny").path))

        let signedIn = downloader(scratch.location, server, token: "hf_secret")
        try await signedIn.start(request())
        #expect(await eventually { await state(signedIn) == .installed })
        #expect(server.requests.contains { $0.authorization == "Bearer hf_secret" })
        #expect(HubEndpoint.huggingFace.mayAuthorize(URL(string: "https://huggingface.co/x")))
        #expect(!HubEndpoint.huggingFace.mayAuthorize(URL(string: "https://cas-bridge.xethub.hf.co/x")))
    }

    @Test func notEnoughSpaceIsReportedBeforeAnythingStarts() async throws {
        let scratch = try Scratch()
        let server = try LocalHubServer(files: files)
        let d = downloader(scratch.location, server, margin: 1 << 60)
        await #expect(throws: DownloadError.self) { try await d.start(request()) }
        #expect(await d.registry.record("tiny") == nil)
        #expect(server.requests.isEmpty)
    }

    @Test func repairFetchesOnlyDamagedFiles() async throws {
        let scratch = try Scratch()
        let server = try LocalHubServer(files: files)
        let d = downloader(scratch.location, server)
        try await d.start(request())
        #expect(await eventually { await state(d) == .installed })
        let dir = scratch.location.directory(for: "tiny")
        try FileManager.default.removeItem(at: dir.appending(path: "model-00002-of-00002.safetensors"))
        _ = try await d.registry.reconcile(catalog: ModelCatalog(models: []))
        #expect(await state(d) == .incomplete)
        let before = server.requests.count
        try await d.start(request())
        #expect(await eventually { await state(d) == .installed })
        let fetched = server.requests.dropFirst(before).filter { $0.path.hasPrefix("/cdn/") }.map(\.path)
        #expect(Set(fetched) == ["/cdn/model-00002-of-00002.safetensors"])
        try await expectInstalled(scratch.location, d)
    }
}

/// Against huggingface.co itself: a small LFS file from the pinned DFlash2
/// commit in 64 KiB range chunks (redirect to the CDN, Range there, SHA-256
/// verification), plus a non-LFS file checked by git blob id. Gated:
///
///   STUDIO_MODELS_LIVE=1 swift test --filter LiveHubDownloadTests
@Suite("Live Hub download")
struct LiveHubDownloadTests {
    @Test func rangeChunksFromTheRealHub() async throws {
        guard ProcessInfo.processInfo.environment["STUDIO_MODELS_LIVE"] == "1" else { return }
        let scratch = try Scratch()
        let d = ModelDownloader(registry: ModelRegistry(location: scratch.location),
                                configuration: DownloaderConfiguration(session: .foreground, chunkSize: 64 << 10,
                                                                       taskWindow: 4, spaceMargin: 0))
        let draft = ModelCatalog.bundled().entry(id: "qwen38-27b-dflash2")!
        try await d.start(DownloadRequest(
            id: "live", name: "live", role: .dflash2Draft, origin: .huggingFace,
            repository: draft.repository!, revision: draft.revision!, files: [
                draft.files.first { $0.path == "config.json" }!,
                ModelFile(path: "assets/dflash2-figure.png", size: 286_889,
                          sha256: "6d8dcc9a9472bddb644c881fe83050b5343d09bf5ffb0912e5598e55fe671e99"),
                ModelFile(path: "README.md", size: 5399, gitBlobSHA1: "f753df682b9f4281444f209c4deb14fc3a9894f1"),
            ]))
        #expect(await eventually(timeout: .seconds(120)) {
            let state = await d.registry.record("live")?.state
            if case .failed(let m) = state { Issue.record("failed: \(m)"); return true }
            return state == .installed
        })
        let record = try #require(await d.registry.record("live"))
        #expect(record.state == .installed && record.isVerified)
    }
}
