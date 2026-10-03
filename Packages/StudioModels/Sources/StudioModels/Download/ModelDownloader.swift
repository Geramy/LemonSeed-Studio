// StudioModels: the downloader.
//
// A background URLSession carries every transfer, so downloads continue
// while the app is suspended and are handed back when it relaunches. Each
// large file is fetched as HTTP range chunks (ChunkPlan). Finished chunks
// are written into a part file under Documents/Models/.partial/<id>/ and
// recorded in the registry. An interrupted chunk resumes from its URLSession
// resume data, or else is fetched again on its own.
//
// SHA-256 is computed while the file assembles. Chunks feed the hash in
// order as the contiguous prefix grows. Once every file matches its pinned
// digest, the staging directory is renamed into Documents/Models/<id>/ (the
// same volume, so the rename is atomic). The directory is excluded from
// backup, and hf-origin.json records where it came from.
//
// The background session needs the app delegate to forward
// application(_:handleEventsForBackgroundURLSession:completionHandler:) to
// `handleBackgroundEvents`, and the downloader to be created at launch.

import Foundation
import Synchronization

public struct DownloadRequest: Sendable, Hashable {
    public var id: String
    public var name: String
    public var role: ModelRole
    public var origin: ModelRecord.Origin
    public var catalogID: String?
    public var repository: String
    public var revision: String
    public var files: [ModelFile]
    public var traits: ModelTraits?
    /// Space the model needs beyond its files once installed, e.g. LSE's Q8
    /// conversion beside a BF16 DFlash2 source.
    public var extraBytes: Int64

    public init(id: String, name: String, role: ModelRole, origin: ModelRecord.Origin, catalogID: String? = nil,
                repository: String, revision: String, files: [ModelFile], traits: ModelTraits? = nil,
                extraBytes: Int64 = 0) {
        self.id = id
        self.name = name
        self.role = role
        self.origin = origin
        self.catalogID = catalogID
        self.repository = repository
        self.revision = revision
        self.files = files
        self.traits = traits
        self.extraBytes = extraBytes
    }

    public init?(catalog entry: CatalogEntry) {
        guard entry.isDownloadable, let repository = entry.repository, let revision = entry.revision else {
            return nil
        }
        self.init(id: entry.id, name: entry.name, role: entry.role, origin: .catalog, catalogID: entry.id,
                  repository: repository, revision: revision, files: entry.files,
                  extraBytes: entry.lseConversion?.outputBytes ?? 0)
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct DownloadProgress: Sendable, Hashable {
    public var id: String
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double

    public var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }

    /// Seconds left at the current rate, or nil before a rate is known.
    public var eta: TimeInterval? {
        guard bytesPerSecond > 1 else { return nil }
        return Double(max(0, totalBytes - receivedBytes)) / bytesPerSecond
    }
}

public enum DownloadEvent: Sendable, Hashable {
    case progress(DownloadProgress)
    case stateChanged(String, ModelRecord.State)
    case installed(String)
    case failed(String, String)
}

public enum DownloadError: Error, LocalizedError, Hashable {
    case insufficientSpace(needed: Int64, available: Int64)
    case notDownloadable(String)
    case alreadyInstalled(String)

    public var errorDescription: String? {
        switch self {
        case let .insufficientSpace(needed, available):
            let f = ByteCountFormatter()
            return "Not enough space: \(f.string(fromByteCount: needed)) needed, \(f.string(fromByteCount: available)) available."
        case .notDownloadable(let id):
            return "\(id) is not on Hugging Face. Copy it to the iPad from a Mac instead."
        case .alreadyInstalled(let id):
            return "\(id) is already installed."
        }
    }
}

public struct DownloaderConfiguration: Sendable {
    public enum Session: Sendable, Hashable {
        /// Survives suspension and relaunch. The identifier must be stable.
        case background(identifier: String)
        /// For tests and previews: an ordinary in-process session.
        case foreground
    }

    public var session: Session
    public var chunkSize: Int64
    public var maxConnectionsPerHost: Int
    /// Chunk tasks kept in flight per model. Nil hands every chunk to the
    /// session at once. Background sessions want that: tasks created while
    /// the app is in the background are deferred by the system.
    public var taskWindow: Int?
    public var maxRetries: Int
    public var retryDelay: Duration
    /// Free space kept in reserve beyond what a download needs.
    public var spaceMargin: Int64

    public init(session: Session, chunkSize: Int64 = ChunkPlan.defaultChunkSize, maxConnectionsPerHost: Int = 4,
                taskWindow: Int? = nil, maxRetries: Int = 5, retryDelay: Duration = .seconds(2),
                spaceMargin: Int64 = 1 << 30) {
        self.session = session
        self.chunkSize = chunkSize
        self.maxConnectionsPerHost = maxConnectionsPerHost
        self.taskWindow = taskWindow
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.spaceMargin = spaceMargin
    }

    public static func background(identifier: String) -> DownloaderConfiguration {
        DownloaderConfiguration(session: .background(identifier: identifier))
    }
}

// MARK: - Session delegate

/// What the URLSession delegate reports, reduced to Sendable values and
/// delivered in order to the downloader.
enum SessionEvent: Sendable {
    case wrote(ChunkKey, task: Int, bytes: Int64)
    case landed(ChunkKey, task: Int, file: URL, status: Int, contentRange: String?)
    case completed(ChunkKey, task: Int, error: TaskFailure?)
}

struct TaskFailure: Sendable, Hashable {
    var domain: String
    var code: Int
    var message: String
    var resumeData: Data?

    var isCancellation: Bool { domain == NSURLErrorDomain && code == NSURLErrorCancelled }
}

final class SessionBridge: NSObject, URLSessionDownloadDelegate, Sendable {
    let events: AsyncStream<SessionEvent>.Continuation
    let landing: URL
    let endpoint: HubEndpoint
    let backgroundCompletion = Mutex<(@Sendable () -> Void)?>(nil)

    init(events: AsyncStream<SessionEvent>.Continuation, landing: URL, endpoint: HubEndpoint) {
        self.events = events
        self.landing = landing
        self.endpoint = endpoint
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let key = ChunkKey(encoded: downloadTask.taskDescription) else { return }
        // The file is deleted when this returns, so move it now.
        let kept = landing.appending(path: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: kept)
        } catch {
            return  // completed(...) follows; the chunk is retried
        }
        let http = downloadTask.response as? HTTPURLResponse
        events.yield(.landed(key, task: downloadTask.taskIdentifier, file: kept, status: http?.statusCode ?? 0,
                             contentRange: http?.value(forHTTPHeaderField: "Content-Range")))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = ChunkKey(encoded: downloadTask.taskDescription) else { return }
        events.yield(.wrote(key, task: downloadTask.taskIdentifier, bytes: totalBytesWritten))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let key = ChunkKey(encoded: task.taskDescription) else { return }
        let failure = error.map { error -> TaskFailure in
            let ns = error as NSError
            return TaskFailure(domain: ns.domain, code: ns.code, message: ns.localizedDescription,
                               resumeData: ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
        }
        events.yield(.completed(key, task: task.taskIdentifier, error: failure))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        // The token is for the Hub only, never for the CDN it redirects to.
        var request = request
        if !endpoint.mayAuthorize(request.url) { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        return request
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletion.withLock { h -> (@Sendable () -> Void)? in
            defer { h = nil }
            return h
        }
        if let handler { DispatchQueue.main.async { handler() } }
    }
}

// MARK: - Downloader

public actor ModelDownloader {
    public nonisolated let registry: ModelRegistry
    public nonisolated let endpoint: HubEndpoint
    public nonisolated let configuration: DownloaderConfiguration
    nonisolated let location: ModelStoreLocation
    nonisolated let token: @Sendable () -> String?
    nonisolated let bridge: SessionBridge
    nonisolated let session: URLSession

    private var tasks: [ChunkKey: URLSessionDownloadTask] = [:]
    private var inflight: [ChunkKey: Int64] = [:]
    private var hashers: [String: OrderedHasher] = [:]
    private var retries: [ChunkKey: Int] = [:]
    private var fileRetries: [String: Int] = [:]
    private var meters: [String: SpeedMeter] = [:]
    private var jobs: [String: ModelRecord] = [:]
    private var observers: [UUID: AsyncStream<DownloadEvent>.Continuation] = [:]
    private var restoreTask: Task<Void, Never>?

    public init(registry: ModelRegistry, endpoint: HubEndpoint = .huggingFace,
                configuration: DownloaderConfiguration, token: @escaping @Sendable () -> String? = { nil }) {
        self.registry = registry
        self.endpoint = endpoint
        self.configuration = configuration
        self.location = registry.location
        self.token = token
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        bridge = SessionBridge(events: continuation,
                               landing: registry.location.partialRoot.appending(path: ".landing"),
                               endpoint: endpoint)
        let config: URLSessionConfiguration
        switch configuration.session {
        case .background(let identifier):
            config = .background(withIdentifier: identifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
        case .foreground:
            config = .default
        }
        config.httpMaximumConnectionsPerHost = configuration.maxConnectionsPerHost
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: bridge, delegateQueue: queue)
        Task { await self.consume(stream) }
    }

    /// Download events, for as long as the stream is held.
    public func events() -> AsyncStream<DownloadEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadEvent.self, bufferingPolicy: .bufferingNewest(256))
        let token = UUID()
        observers[token] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropObserver(token) } }
        return stream
    }

    private func dropObserver(_ token: UUID) { observers[token] = nil }

    private func emit(_ event: DownloadEvent) {
        for c in observers.values { c.yield(event) }
    }

    /// Hands the system's completion handler to the session delegate; it is
    /// called once the relaunched session has delivered its events.
    public nonisolated func handleBackgroundEvents(completion: @escaping @Sendable () -> Void) {
        bridge.backgroundCompletion.withLock { $0 = completion }
    }

    /// Tears the session down, as a crash would. For tests.
    public func invalidate() {
        session.invalidateAndCancel()
        tasks.removeAll()
        inflight.removeAll()
    }

    // MARK: Restore after launch

    /// Reattaches tasks still running in the background session, finishes
    /// files whose chunks all landed while the app was gone, and reschedules
    /// whatever is missing. Safe to call more than once.
    public func restore() async {
        if let restoreTask { return await restoreTask.value }
        let task = Task { await self.performRestore() }
        restoreTask = task
        await task.value
    }

    private func performRestore() async {
        for task in await session.allTasks {
            guard let download = task as? URLSessionDownloadTask,
                  let key = ChunkKey(encoded: task.taskDescription) else { continue }
            tasks[key] = download
            inflight[key] = download.countOfBytesReceived
        }
        let records = await registry.all()
        let active = Set(records.filter { $0.state.isTransferring }.map(\.id))
        for (key, task) in tasks where !active.contains(key.model) {
            task.cancel()
            tasks[key] = nil
        }
        for record in records where record.state.isTransferring {
            jobs[record.id] = record
            if record.state != .downloading {
                _ = try? await registry.update(record.id) { $0.state = .downloading }
                jobs[record.id]?.state = .downloading
            }
            await advance(record.id)
        }
    }

    // MARK: Commands

    public func start(_ request: DownloadRequest) async throws {
        await restore()
        if let existing = await registry.record(request.id) {
            switch existing.state {
            case .installed:
                throw DownloadError.alreadyInstalled(request.id)
            case .queued, .downloading, .verifying:
                return
            case .paused, .failed:
                try await resume(request.id)
                return
            case .incomplete, .missing:
                try await repair(existing, request: request)
                return
            }
        }
        var record = ModelRecord(id: request.id, name: request.name, role: request.role, origin: request.origin,
                                 catalogID: request.catalogID, repository: request.repository,
                                 revision: request.revision, files: request.files.map { ModelRecord.File($0) },
                                 traits: request.traits, state: .downloading)
        for i in record.files.indices {
            record.files[i].chunkSize = ChunkPlan.chunkSize(forFileOfSize: record.files[i].size,
                                                             preferred: configuration.chunkSize)
        }
        try checkSpace(for: record, extra: request.extraBytes)
        try prepareStaging(record)
        try await registry.upsert(record)
        jobs[record.id] = record
        emit(.stateChanged(record.id, .downloading))
        await advance(record.id)
    }

    /// Re-fetches the missing or damaged files of an installed model.
    private func repair(_ existing: ModelRecord, request: DownloadRequest) async throws {
        var record = existing
        let dir = location.directory(for: record.directoryName)
        record.files = record.files.map { file in
            var file = file
            let present = FileStamp.of(dir.appending(path: file.path))?.size == file.size
            if !present || file.verification == .mismatch || file.verification == .missing {
                file.chunkSize = ChunkPlan.chunkSize(forFileOfSize: file.size, preferred: configuration.chunkSize)
                file.completedChunks = []
                file.verification = .unverified
            }
            return file
        }
        record.repository = record.repository ?? request.repository
        record.revision = record.revision ?? request.revision
        record.state = .downloading
        try checkSpace(for: record, extra: 0)
        try prepareStaging(record)
        try await registry.upsert(record)
        jobs[record.id] = record
        emit(.stateChanged(record.id, .downloading))
        await advance(record.id)
    }

    public func resume(_ id: String) async throws {
        await restore()
        guard var record = await registry.record(id) else { throw RegistryError.unknownModel(id) }
        switch record.state {
        case .paused, .failed: break
        default: return
        }
        try checkSpace(for: record, extra: 0)
        try prepareStaging(record)
        record = try await registry.update(id) { $0.state = .downloading }
        jobs[id] = record
        retries = retries.filter { $0.key.model != id }
        emit(.stateChanged(id, .downloading))
        await advance(id)
    }

    /// Stops transfers, keeping finished chunks and resume data.
    public func pause(_ id: String) async {
        await restore()
        guard let record = await registry.record(id), record.state.isTransferring else { return }
        jobs[id]?.state = .paused
        _ = try? await registry.update(id) { $0.state = .paused }
        await stopTasks(of: id, keepResumeData: true)
        emit(.stateChanged(id, .paused))
    }

    /// Stops transfers and discards everything downloaded. A model that was
    /// being repaired stays installed but incomplete; otherwise it is removed.
    public func cancel(_ id: String) async {
        await restore()
        jobs[id] = nil
        await stopTasks(of: id, keepResumeData: false)
        try? FileManager.default.removeItem(at: location.partialDirectory(for: id))
        hashers = hashers.filter { !$0.key.hasPrefix(id + "/") }
        guard let record = await registry.record(id) else { return }
        if FileManager.default.fileExists(atPath: location.directory(for: record.directoryName).path) {
            _ = try? await registry.update(id) { r in
                r.state = .incomplete
                for i in r.files.indices { r.files[i].chunkSize = nil; r.files[i].completedChunks = [] }
            }
            emit(.stateChanged(id, .incomplete))
        } else {
            try? await registry.remove(id)
        }
    }

    private func stopTasks(of id: String, keepResumeData: Bool) async {
        let mine = tasks.filter { $0.key.model == id }
        for (key, task) in mine {
            tasks[key] = nil
            inflight[key] = nil
            if keepResumeData, let data = await task.cancelByProducingResumeData() {
                try? writeResumeData(data, for: key)
            } else if !keepResumeData {
                task.cancel()
            }
        }
    }

    // MARK: Scheduling

    /// Starts tasks for chunks that are neither written nor in flight, or
    /// finishes the model when every file is verified.
    private func advance(_ id: String) async {
        guard let record = jobs[id], record.state == .downloading else { return }
        let downloading = record.files.filter { $0.chunkSize != nil }
        if downloading.allSatisfy({ $0.verification == .verified }) {
            await install(id)
            return
        }
        // Files whose chunks all landed (e.g. while the app was gone) are verified now.
        for file in downloading where file.verification != .verified {
            let chunkSize = file.chunkSize!
            if ChunkPlan.remaining(size: file.size, chunkSize: chunkSize, completed: file.completedChunks).isEmpty {
                await finishFile(id, path: file.path)
                if jobs[id]?.state != .downloading { return }
            }
        }
        guard let record = jobs[id] else { return }
        if record.files.filter({ $0.chunkSize != nil }).allSatisfy({ $0.verification == .verified }) {
            await install(id)
            return
        }
        var budget = configuration.taskWindow.map { $0 - tasks.keys.filter { $0.model == id }.count } ?? Int.max
        for file in record.files where file.chunkSize != nil && file.verification != .verified {
            for chunk in ChunkPlan.remaining(size: file.size, chunkSize: file.chunkSize!, completed: file.completedChunks) {
                guard budget > 0 else { return }
                let key = ChunkKey(model: id, path: file.path, chunk: chunk)
                if tasks[key] != nil { continue }
                createTask(key, file: file, record: record)
                budget -= 1
            }
        }
    }

    private func createTask(_ key: ChunkKey, file: ModelRecord.File, record: ModelRecord) {
        let task: URLSessionDownloadTask
        let resumeURL = resumeDataURL(key)
        if let data = try? Data(contentsOf: resumeURL) {
            try? FileManager.default.removeItem(at: resumeURL)
            task = session.downloadTask(withResumeData: data)
        } else {
            let url = endpoint.resolve(repository: file.sourceRepository ?? record.repository ?? "",
                                       revision: file.sourceRevision ?? record.revision ?? "main",
                                       path: file.sourcePath ?? file.path)
            var request = URLRequest(url: url)
            if let range = ChunkPlan.rangeHeader(of: key.chunk, size: file.size, chunkSize: file.chunkSize!) {
                request.setValue(range, forHTTPHeaderField: "Range")
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let token = token(), endpoint.mayAuthorize(url) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            task = session.downloadTask(with: request)
        }
        let range = ChunkPlan.range(of: key.chunk, size: file.size, chunkSize: file.chunkSize!)
        task.taskDescription = key.encoded
        task.countOfBytesClientExpectsToReceive = range.upperBound - range.lowerBound
        tasks[key] = task
        inflight[key] = 0
        task.resume()
    }

    // MARK: Session events

    private func consume(_ stream: AsyncStream<SessionEvent>) async {
        await restore()
        for await event in stream {
            switch event {
            case let .wrote(key, task, bytes):
                guard tasks[key]?.taskIdentifier == task else { continue }
                inflight[key] = bytes
                emitProgress(key.model)
            case let .landed(key, task, file, status, contentRange):
                guard tasks[key]?.taskIdentifier == task else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                await landed(key, file: file, status: status, contentRange: contentRange)
            case let .completed(key, task, failure):
                guard tasks[key]?.taskIdentifier == task else { continue }
                // A task still registered here finished without its file being
                // processed (landed events clear it), so it needs another go.
                tasks[key] = nil
                inflight[key] = nil
                if let data = failure?.resumeData { try? writeResumeData(data, for: key) }
                await retry(key, message: failure?.message ?? "\(key.path): download did not arrive", retryable: true)
            }
        }
    }

    private func landed(_ key: ChunkKey, file landedURL: URL, status: Int, contentRange: String?) async {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: landedURL) }
        // This task is done; its completion event is ignored from here on.
        tasks[key] = nil
        inflight[key] = nil
        guard var record = jobs[key.model], record.state == .downloading,
              let index = record.files.firstIndex(where: { $0.path == key.path }),
              let chunkSize = record.files[index].chunkSize else { return }
        let file = record.files[index]
        let expected = ChunkPlan.range(of: key.chunk, size: file.size, chunkSize: chunkSize)
        let received = FileStamp.of(landedURL)?.size ?? -1
        var whole = false
        switch status {
        case 206:
            guard let parsed = ChunkPlan.parseContentRange(contentRange), parsed.range == expected,
                  received == expected.upperBound - expected.lowerBound else {
                return await retry(key, message: "\(file.path): unexpected range in the response", retryable: true)
            }
        case 200:
            // No Range header was sent, or the server ignored it and sent everything.
            guard received == file.size else {
                return await retry(key, message: "\(file.path): \(received) bytes received, \(file.size) expected",
                                   retryable: true)
            }
            whole = true
        case 401, 403:
            return await fail(key.model, message: "\(file.path): HTTP \(status). The repository may be gated; add a Hugging Face token with access.")
        case 404:
            return await fail(key.model, message: "\(file.path): not found at revision \(record.revision ?? "?")")
        default:
            return await retry(key, message: "\(file.path): HTTP \(status)", retryable: status >= 500 || status == 429 || status == 0)
        }
        let part = partURL(key.model, key.path)
        do {
            if whole {
                try? fm.removeItem(at: part)
                try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: landedURL, to: part)
            } else {
                try Self.write(landedURL, into: part, at: expected.lowerBound)
            }
        } catch {
            return await retry(key, message: "\(file.path): \(error.localizedDescription)", retryable: true)
        }
        try? fm.removeItem(at: resumeDataURL(key))
        retries[key] = nil
        let all = Array(0..<ChunkPlan.count(size: file.size, chunkSize: chunkSize))
        let completed = whole ? all : Array(Set(file.completedChunks + [key.chunk])).sorted()
        record.files[index].completedChunks = completed
        jobs[key.model] = record
        _ = try? await registry.update(key.model) { r in
            if let i = r.files.firstIndex(where: { $0.path == key.path }) { r.files[i].completedChunks = completed }
        }
        if whole {
            // Other chunk tasks for this file are now redundant.
            for (other, task) in tasks where other.model == key.model && other.path == key.path {
                task.cancel()
                tasks[other] = nil
                inflight[other] = nil
            }
        }
        // Feed the hash with whatever contiguous prefix is now on disk.
        let hashKey = key.model + "/" + key.path
        var hasher = hashers[hashKey] ?? OrderedHasher()
        try? hasher.catchUp(from: part, to: ChunkPlan.contiguousEnd(size: file.size, chunkSize: chunkSize,
                                                                    completed: completed))
        hashers[hashKey] = hasher
        emitProgress(key.model, force: true)
        if ChunkPlan.remaining(size: file.size, chunkSize: chunkSize, completed: completed).isEmpty {
            await finishFile(key.model, path: key.path)
        }
        await advance(key.model)
    }

    /// Checks a fully assembled file against its digest.
    private func finishFile(_ id: String, path: String) async {
        guard var record = jobs[id], let index = record.files.firstIndex(where: { $0.path == path }) else { return }
        let file = record.files[index]
        let part = partURL(id, path)
        let hashKey = id + "/" + path
        var hasher = hashers[hashKey] ?? OrderedHasher()
        hashers[hashKey] = nil
        var ok = false
        var sha: String?
        do {
            try hasher.catchUp(from: part, to: file.size)
            sha = hasher.digest()
            if let expected = file.sha256 {
                ok = expected == sha
            } else if let blob = file.gitBlobSHA1 {
                ok = try FileDigest.gitBlobSHA1(of: part) == blob
            } else {
                ok = FileStamp.of(part)?.size == file.size
            }
        } catch {
            ok = false
        }
        if ok {
            let sha = sha
            record.files[index].verification = .verified
            record.files[index].sha256 = file.sha256 ?? sha
            jobs[id] = record
            _ = try? await registry.update(id) { r in
                if let i = r.files.firstIndex(where: { $0.path == path }) {
                    r.files[i].verification = .verified
                    r.files[i].sha256 = r.files[i].sha256 ?? sha
                }
            }
            return
        }
        // A mismatch means bad bytes somewhere: start the file over, once.
        try? FileManager.default.removeItem(at: part)
        let attempts = fileRetries[hashKey, default: 0] + 1
        fileRetries[hashKey] = attempts
        record.files[index].completedChunks = []
        record.files[index].verification = attempts > 1 ? .mismatch : .unverified
        jobs[id] = record
        _ = try? await registry.update(id) { r in
            if let i = r.files.firstIndex(where: { $0.path == path }) {
                r.files[i].completedChunks = []
                r.files[i].verification = attempts > 1 ? .mismatch : .unverified
            }
        }
        if attempts > 1 {
            await fail(id, message: "\(path) does not match its published checksum")
        }
    }

    private func install(_ id: String) async {
        guard var record = jobs[id] else { return }
        let fm = FileManager.default
        let staging = stagingURL(id)
        let dest = location.directory(for: record.directoryName)
        record.state = .verifying
        jobs[id] = record
        do {
            try fm.createDirectory(at: location.modelsRoot, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest.path) {
                try fm.moveItem(at: staging, to: dest)
            } else {
                for file in record.files where file.chunkSize != nil {
                    let target = dest.appending(path: file.path)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.moveItem(at: staging.appending(path: file.path), to: target)
                }
            }
            if let repository = record.repository, let revision = record.revision {
                try HubOrigin(repository: repository, revision: revision).write(to: dest)
            }
            try ModelStoreLocation.excludeFromBackup(dest)
        } catch {
            return await fail(id, message: "Could not install: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: location.partialDirectory(for: id))
        jobs[id] = nil
        meters[id] = nil
        let now = Date()
        _ = try? await registry.update(id) { r in
            r.state = .installed
            r.verifiedAt = now
            for i in r.files.indices {
                if r.files[i].chunkSize != nil { r.files[i].verification = .verified }
                r.files[i].chunkSize = nil
                r.files[i].completedChunks = []
                r.files[i].stamp = FileStamp.of(dest.appending(path: r.files[i].path))
            }
        }
        emit(.installed(id))
        emit(.stateChanged(id, .installed))
    }

    private func retry(_ key: ChunkKey, message: String, retryable: Bool) async {
        let attempt = retries[key, default: 0] + 1
        retries[key] = attempt
        guard retryable, attempt <= configuration.maxRetries else {
            return await fail(key.model, message: message)
        }
        tasks[key] = nil
        inflight[key] = nil
        let delay = configuration.retryDelay * (1 << min(attempt - 1, 6))
        try? await Task.sleep(for: delay)
        guard let record = jobs[key.model], record.state == .downloading, tasks[key] == nil,
              let file = record.files.first(where: { $0.path == key.path }), file.chunkSize != nil,
              !file.completedChunks.contains(key.chunk) else { return }
        createTask(key, file: file, record: record)
    }

    private func fail(_ id: String, message: String) async {
        guard jobs[id]?.state == .downloading || jobs[id]?.state == .verifying else { return }
        jobs[id]?.state = .failed(message)
        _ = try? await registry.update(id) { $0.state = .failed(message) }
        await stopTasks(of: id, keepResumeData: true)
        emit(.failed(id, message))
        emit(.stateChanged(id, .failed(message)))
    }

    // MARK: Progress

    private func emitProgress(_ id: String, force: Bool = false) {
        guard let record = jobs[id] else { return }
        var total: Int64 = 0, received: Int64 = 0
        for file in record.files where file.chunkSize != nil {
            total += file.size
            for chunk in file.completedChunks {
                let r = ChunkPlan.range(of: chunk, size: file.size, chunkSize: file.chunkSize!)
                received += r.upperBound - r.lowerBound
            }
        }
        for (key, bytes) in inflight where key.model == id { received += bytes }
        var meter = meters[id] ?? SpeedMeter()
        let emitNow = meter.sample(received) || force
        meters[id] = meter
        if emitNow {
            emit(.progress(DownloadProgress(id: id, receivedBytes: min(received, total), totalBytes: total,
                                            bytesPerSecond: meter.rate)))
        }
    }

    public func progress(of id: String) -> DownloadProgress? {
        guard let record = jobs[id] else { return nil }
        var total: Int64 = 0, received: Int64 = 0
        for file in record.files where file.chunkSize != nil {
            total += file.size
            received += Int64(file.completedChunks.count) * file.chunkSize!
        }
        return DownloadProgress(id: id, receivedBytes: min(received, total), totalBytes: total,
                                bytesPerSecond: meters[id]?.rate ?? 0)
    }

    // MARK: Files

    private func stagingURL(_ id: String) -> URL {
        location.partialDirectory(for: id).appending(path: "files", directoryHint: .isDirectory)
    }

    private func partURL(_ id: String, _ path: String) -> URL { stagingURL(id).appending(path: path) }

    private func resumeDataURL(_ key: ChunkKey) -> URL {
        let name = key.path.replacingOccurrences(of: "/", with: "%2F") + ".\(key.chunk).resume"
        return location.partialDirectory(for: key.model).appending(path: "resume").appending(path: name)
    }

    private func writeResumeData(_ data: Data, for key: ChunkKey) throws {
        let url = resumeDataURL(key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func prepareStaging(_ record: ModelRecord) throws {
        try location.prepare()
        let staging = stagingURL(record.id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try ModelStoreLocation.excludeFromBackup(location.partialDirectory(for: record.id))
        for file in record.files where file.chunkSize != nil {
            let part = staging.appending(path: file.path)
            try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: part.path) {
                FileManager.default.createFile(atPath: part.path, contents: nil)
            }
        }
    }

    private func checkSpace(for record: ModelRecord, extra: Int64) throws {
        var remaining: Int64 = extra
        for file in record.files where file.chunkSize != nil {
            let done = file.completedChunks.reduce(Int64(0)) { sum, chunk in
                let r = ChunkPlan.range(of: chunk, size: file.size, chunkSize: file.chunkSize!)
                return sum + (r.upperBound - r.lowerBound)
            }
            remaining += file.size - done
        }
        guard let available = location.availableCapacity() else { return }
        let needed = remaining + configuration.spaceMargin
        if available < needed { throw DownloadError.insufficientSpace(needed: needed, available: available) }
    }

    /// Copies a landed chunk into the part file at `offset` and flushes it.
    static func write(_ chunk: URL, into part: URL, at offset: Int64) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) {
            try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: part.path, contents: nil)
        }
        let out = try FileHandle(forWritingTo: part)
        defer { try? out.close() }
        try out.seek(toOffset: UInt64(offset))
        try FileDigest.stream(chunk, range: nil) { data, _ in try out.write(contentsOf: data) }
        try out.synchronize()
    }
}

/// Transfer rate, smoothed over half-second samples.
struct SpeedMeter {
    private var lastBytes: Int64 = -1
    private var lastTime = ContinuousClock.now
    private(set) var rate: Double = 0

    /// Records a reading; returns true when a new sample was taken.
    mutating func sample(_ bytes: Int64) -> Bool {
        let now = ContinuousClock.now
        if lastBytes < 0 {
            lastBytes = bytes
            lastTime = now
            return true
        }
        let elapsed = now - lastTime
        guard elapsed >= .milliseconds(500) else { return false }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let instant = Double(max(0, bytes - lastBytes)) / seconds
        rate = rate == 0 ? instant : 0.3 * instant + 0.7 * rate
        lastBytes = bytes
        lastTime = now
        return true
    }
}
