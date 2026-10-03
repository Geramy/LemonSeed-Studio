import Foundation
import LSE
#if canImport(LSEEstimate)
import LSEEstimate
#endif

/// The Lemon Seed Engine running inside this process.
///
/// One engine holds one loaded model. Requests are the OpenAI-compatible JSON
/// requests the engine's HTTP server takes (`/v1/chat/completions`,
/// `/v1/completions`, `/v1/models`, ...), answered with the same JSON, without
/// a socket. Optionally the same engine also serves that HTTP API.
public final class LSEEngine: @unchecked Sendable {
    /// Every option of the `lse-server` command line. Nil means its default.
    public struct Configuration: Sendable {
        public var model: String
        public var servedName: String?
        public var tokenizerRepo: String?
        public var mtpPath: String?
        public var mtpDepth: UInt32 = 3
        public var noMTP = false
        public var dflash2 = false
        public var dflash2Model: String?
        public var flashPrefillV2: Bool?
        public var attentionPrefill: String?
        public var attentionDecode: String?
        public var attentionCalibration: String?
        public var kvCacheDType: String?
        public var kvLength: Int32 = 0
        public var batchSize: UInt32 = 1024
        public var ubatchSize: UInt32 = 1024
        public var temperature: Float?
        public var maxTokens: Int32 = 4096
        public var pool: String?
        public var dialect: String?
        public var cacheDirectory: String?
        public var host = "127.0.0.1"
        public var port: Int32 = 8080
        public var apiKey: String?

        public init(model: String) { self.model = model }
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let status: Int
        public let body: String
        public init(status: Int, body: String) { self.status = status; self.body = body }
        public var description: String {
            if let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return "\(status): \(message)"
            }
            return "\(status): \(body)"
        }
    }

    public struct OpenError: Error, CustomStringConvertible, Sendable {
        public let invalidConfiguration: Bool
        public let message: String
        public init(invalidConfiguration: Bool, message: String) {
            self.invalidConfiguration = invalidConfiguration
            self.message = message
        }
        public var description: String { message }
    }

    public static var version: String { String(cString: lse_version()) }
    public static var abiVersion: UInt32 { lse_abi_version() }

    private let handle: OpaquePointer
    private let lock = NSLock()
    private var closed = false

    private init(handle: OpaquePointer) { self.handle = handle }

    deinit { close() }

    /// Opens the devices and loads the model. Blocks a background thread for
    /// as long as loading takes; watch `LSEEngine.loadStatus()` meanwhile.
    public static func open(_ configuration: Configuration) async throws -> LSEEngine {
        try await Task.detached(priority: .userInitiated) {
            try openBlocking(configuration)
        }.value
    }

    public static func openBlocking(_ c: Configuration) throws -> LSEEngine {
        try withCConfig(c) { cfg in
            var err: UnsafeMutablePointer<CChar>?
            guard let engine = lse_open(&cfg, &err) else {
                let message = err.map { String(cString: $0) } ?? "the engine did not open"
                lse_free(err)
                throw OpenError(invalidConfiguration: lse_last_error() == LSE_ERR_INVALID_ARGUMENT,
                                message: message)
            }
            return LSEEngine(handle: engine)
        }
    }

    /// Runs `body` with `c` as an lse_config whose strings live for the call.
    static func withCConfig<T>(_ c: Configuration, _ body: (inout lse_config) throws -> T) rethrows -> T {
        var cfg = lse_config()
        lse_config_init(&cfg)
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func cString(_ s: String?) -> UnsafePointer<CChar>? {
            guard let s else { return nil }
            let p = strdup(s)!
            strings.append(p)
            return UnsafePointer(p)
        }
        cfg.model = cString(c.model)
        cfg.served_name = cString(c.servedName)
        cfg.tokenizer_repo = cString(c.tokenizerRepo)
        cfg.mtp_path = cString(c.mtpPath)
        cfg.mtp_depth = c.mtpDepth
        cfg.no_mtp = c.noMTP ? 1 : 0
        cfg.dflash2 = c.dflash2 ? 1 : 0
        cfg.dflash2_model = cString(c.dflash2Model)
        cfg.flashprefill_v2 = c.flashPrefillV2.map { $0 ? 1 : 0 } ?? -1
        cfg.attention_prefill = cString(c.attentionPrefill)
        cfg.attention_decode = cString(c.attentionDecode)
        cfg.attention_calibration = cString(c.attentionCalibration)
        cfg.kv_cache_dtype = cString(c.kvCacheDType)
        cfg.kv_len = c.kvLength
        cfg.batch_size = c.batchSize
        cfg.ubatch_size = c.ubatchSize
        if let t = c.temperature {
            cfg.has_temperature = 1
            cfg.temperature = t
        }
        cfg.max_tokens = c.maxTokens
        cfg.pool = cString(c.pool)
        cfg.dialect = cString(c.dialect)
        cfg.cache_dir = cString(c.cacheDirectory)
        cfg.host = cString(c.host)
        cfg.port = c.port
        cfg.api_key = cString(c.apiKey)
        return try body(&cfg)
    }

    // MARK: Model info and memory estimates

    /// An lse_model_info or lse_estimate failure.
    public struct InspectError: Error, CustomStringConvertible, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
        public var description: String { message }
    }

    /// Whether the linked engine has lse_model_info and lse_estimate (LSE
    /// 0.5). Without them, callers use their own estimates.
    public static var supportsEstimates: Bool {
        #if canImport(LSEEstimate)
        true
        #else
        false
        #endif
    }

    #if canImport(LSEEstimate)
    private static func decodeJSON(_ result: lse_result, _ json: UnsafeMutablePointer<CChar>?,
                                   _ err: UnsafeMutablePointer<CChar>?, what: String) throws -> [String: Any] {
        defer { lse_free(json); lse_free(err) }
        guard result == LSE_OK, let json else {
            throw InspectError(message: err.map { String(cString: $0) } ?? "\(what) failed (\(result.rawValue))")
        }
        let data = Data(bytes: json, count: strlen(json))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InspectError(message: "\(what) returned no JSON object")
        }
        return object
    }
    #endif

    /// lse_model_info: what LSE's loader makes of a model directory (kind,
    /// layers, max context, KV bytes per token per format, weights' VRAM,
    /// MTP and DFlash2 facts). Reads config.json and safetensors headers only.
    public static func modelInfo(_ model: String) throws -> [String: Any] {
        #if canImport(LSEEstimate)
        var json: UnsafeMutablePointer<CChar>?
        var err: UnsafeMutablePointer<CChar>?
        let result = lse_model_info(model, &json, &err)
        return try decodeJSON(result, json, err, what: "lse_model_info")
        #else
        throw InspectError(message: "this LSE build has no lse_model_info")
        #endif
    }

    /// lse_estimate: what `lse_open` with `configuration` would allocate on
    /// the device, by component. `options` takes context_tokens, sequences,
    /// device_arch, kv_storage and device_memory_bytes (which adds "fits"
    /// and "max_kv_len"). Opens no device.
    public static func estimate(_ configuration: Configuration, options: [String: Any] = [:]) throws -> [String: Any] {
        #if canImport(LSEEstimate)
        let optionsJSON = options.isEmpty ? nil
            : String(data: try JSONSerialization.data(withJSONObject: options), encoding: .utf8)
        return try withCConfig(configuration) { cfg in
            var json: UnsafeMutablePointer<CChar>?
            var err: UnsafeMutablePointer<CChar>?
            let result = lse_estimate(&cfg, optionsJSON, &json, &err)
            return try decodeJSON(result, json, err, what: "lse_estimate")
        }
        #else
        throw InspectError(message: "this LSE build has no lse_estimate")
        #endif
    }

    /// Cancels every request, stops HTTP and releases the model and device.
    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { lse_close(handle) }
    }

    // MARK: Requests

    /// One event of a request, as the engine delivers it.
    public enum Event: Sendable {
        case response(status: Int, body: Data)
        case chunk(Data)
        case done
        case error(status: Int, body: Data)
    }

    private final class RequestBox {
        let handler: (Event) -> Void
        init(_ handler: @escaping (Event) -> Void) { self.handler = handler }
    }

    /// Starts a request. `handler` runs on an engine thread for every event;
    /// the last one is `.response`, `.done` or `.error`.
    @discardableResult
    public func request(method: String, path: String, body: Data?,
                        handler: @escaping (Event) -> Void) throws -> UInt64 {
        let box = Unmanaged.passRetained(RequestBox(handler))
        var id: lse_request_id = 0
        let result: lse_result = (body ?? Data()).withUnsafeBytes { raw in
            let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
            return lse_request(handle, method, path, body == nil ? nil : base, raw.count,
                               { user, _, event, status, data, length in
                let box = Unmanaged<RequestBox>.fromOpaque(user!)
                let bytes = data.map { Data(bytes: $0, count: length) } ?? Data()
                let final: Bool
                switch event {
                case LSE_EVENT_CHUNK:
                    box.takeUnretainedValue().handler(.chunk(bytes)); final = false
                case LSE_EVENT_DONE:
                    box.takeUnretainedValue().handler(.done); final = true
                case LSE_EVENT_RESPONSE:
                    box.takeUnretainedValue().handler(.response(status: Int(status), body: bytes)); final = true
                default:
                    box.takeUnretainedValue().handler(.error(status: Int(status), body: bytes)); final = true
                }
                if final { box.release() }
            }, box.toOpaque(), &id)
        }
        guard result == LSE_OK else {
            box.release()
            throw Failure(status: 503, body: "{\"error\":{\"message\":\"the engine is not accepting requests\"}}")
        }
        return id
    }

    /// A non-streaming request: the response body, or a thrown `Failure`.
    private final class PendingID: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UInt64 = 0
        private var cancelled = false
        /// Records the id; true when a cancel already arrived for it.
        func set(_ value: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; id = value; return cancelled }
        /// Marks cancelled; the id when it is already known.
        func cancel() -> UInt64? { lock.lock(); defer { lock.unlock() }; cancelled = true; return id == 0 ? nil : id }
    }

    public func send(method: String = "POST", path: String, json: [String: Any]?) async throws -> Data {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let pending = PendingID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let id = try request(method: method, path: path, body: body) { event in
                        switch event {
                        case .response(_, let data): continuation.resume(returning: data)
                        case .error(let status, let data):
                            continuation.resume(throwing: Failure(status: status, body: String(decoding: data, as: UTF8.self)))
                        case .done: continuation.resume(returning: Data())
                        case .chunk: break
                        }
                    }
                    if pending.set(id) { _ = lse_cancel(handle, id) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { [self] in
            if let id = pending.cancel() { cancel(id) }
        }
    }

    /// A streaming request (`"stream": true` is added): each chunk object as
    /// the HTTP server's SSE stream would carry it.
    public func stream(path: String, json: [String: Any]) -> AsyncThrowingStream<Data, Error> {
        var body = json
        body["stream"] = true
        return AsyncThrowingStream { continuation in
            do {
                let data = try JSONSerialization.data(withJSONObject: body)
                let id = try request(method: "POST", path: path, body: data) { event in
                    switch event {
                    case .chunk(let chunk): continuation.yield(chunk)
                    case .done: continuation.finish()
                    case .response(_, let data): continuation.yield(data); continuation.finish()
                    case .error(let status, let data):
                        continuation.finish(throwing: Failure(status: status, body: String(decoding: data, as: UTF8.self)))
                    }
                }
                continuation.onTermination = { [self] reason in
                    if case .cancelled = reason { cancel(id) }
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func cancel(_ id: UInt64) { _ = lse_cancel(handle, id) }

    // MARK: Status and HTTP

    /// Load phase, progress, request counters and last timings.
    public func status() -> [String: Any] { Self.decodeStatus(handle) }

    /// Load progress while `open` runs (no engine yet).
    public static func loadStatus() -> [String: Any] { decodeStatus(nil) }

    private static func decodeStatus(_ engine: OpaquePointer?) -> [String: Any] {
        var json: UnsafeMutablePointer<CChar>?
        guard lse_status(engine, &json) == LSE_OK, let json else { return [:] }
        defer { lse_free(json) }
        let data = Data(bytes: json, count: strlen(json))
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Also serve the OpenAI-compatible HTTP API from this engine.
    public func startHTTP(host: String? = nil, port: Int32 = 0) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard lse_http_start(handle, host, port, &err) == LSE_OK else {
            let message = err.map { String(cString: $0) } ?? "could not listen"
            lse_free(err)
            throw Failure(status: 500, body: message)
        }
    }

    public func stopHTTP() {
        lse_http_stop(handle)
        _ = lse_http_wait(handle, nil)
    }

    // MARK: Logging

    private final class LogBox: @unchecked Sendable {
        let handler: @Sendable (String) -> Void
        init(_ handler: @escaping @Sendable (String) -> Void) { self.handler = handler }
    }
    private static let logLock = NSLock()
    nonisolated(unsafe) private static var logBox: Unmanaged<LogBox>?

    /// Receives every line the engine logs (what lse-server prints on
    /// stderr). Process-wide; nil stops it.
    public static func setLogHandler(_ handler: (@Sendable (String) -> Void)?) {
        logLock.lock()
        defer { logLock.unlock() }
        let previous = logBox
        if let handler {
            let box = Unmanaged.passRetained(LogBox(handler))
            logBox = box
            lse_set_log_callback({ user, _, line in
                guard let user, let line else { return }
                Unmanaged<LogBox>.fromOpaque(user).takeUnretainedValue().handler(String(cString: line))
            }, box.toOpaque())
        } else {
            logBox = nil
            lse_set_log_callback(nil, nil)
        }
        // The engine swaps the callback under its own lock, so no call into
        // the previous box can start after this point.
        previous?.release()
    }
}
