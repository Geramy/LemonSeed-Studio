import Foundation
import Observation
import UIKit
import os
import StudioAgent
#if canImport(LSEKit)
import LSEKit
#endif

private let engineLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "engine")

/// What the engine loads: a main model, its optional DFlash2 draft or MTP
/// module, and the lse_config values that size it on the GPU.
struct EngineLaunch: Equatable, Sendable {
    var modelID: String
    var modelName: String
    var modelDirectory: URL
    var draftID: String?
    var draftDirectory: URL?
    var kvCacheDType = "bf16"
    var kvLength: Int32 = 32768
    var batchSize: UInt32 = 1024
    var ubatchSize: UInt32 = 1024
    var temperature: Float? = 0.6
    var maxTokens: Int32 = 4096
    var mtpEnabled = false
    var mtpDepth: UInt32 = 3
    /// The engine's served model name (what requests put in "model").
    var servedName = "qwen-q4"
}

/// Timings of the last generation, from LSE's `timings` / `last_timings`.
struct EngineTimings: Equatable, Sendable {
    var promptTokens: Int?
    var promptPerSecond: Double?
    var decodeTokens: Int?
    var decodePerSecond: Double?
    var acceptance: Double?

    init?(_ json: [String: Any]?) {
        guard let json else { return nil }
        promptTokens = json["prompt_n"] as? Int ?? json["prompt_tokens"] as? Int
        promptPerSecond = json["prompt_per_second"] as? Double
        decodeTokens = json["predicted_n"] as? Int ?? json["decode_n"] as? Int ?? json["completion_tokens"] as? Int
        decodePerSecond = json["decode_per_second"] as? Double ?? json["predicted_per_second"] as? Double
        acceptance = json["acceptance_rate"] as? Double
        if promptPerSecond == nil && decodePerSecond == nil { return nil }
    }
}

/// The GPU engine: LemonSeed Engine (LSE) running inside this process on the
/// GPU the embedded driver serves.
///
/// Starting the engine is the whole GPU bring-up: LSE's HSA runtime opens a
/// session on the driver, hands the bundled firmware over, places the host
/// window and runs InitDevice when the GPU is not up yet, then loads the
/// model. The service starts it on launch (when enabled) as soon as the
/// driver's service is present, and restarts it when the load settings
/// change. Requests go through `lse_request` only; there is no socket.
@MainActor
@Observable
final class EngineService {
    enum Phase: Equatable {
        /// Not started (auto-start off, or stopped).
        case idle
        /// Waiting for something outside the app: the driver, the GPU, a model.
        case waiting(String)
        case loading(String)
        case ready
        case stopping
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var loadProgress: Double?
    private(set) var launch: EngineLaunch?
    private(set) var loadSeconds: Double?
    private(set) var lastTimings: EngineTimings?
    /// Device memory the engine holds (lse_status "memory": live and peak).
    private(set) var deviceBytes: (live: UInt64, peak: UInt64)?
    private(set) var log: [String] = []
    private(set) var startedAt: Date?

    /// Start the engine when the app launches (Settings › GPU).
    var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: "engine.autoStart") }
    }

    /// Whether this build carries the engine at all (device builds).
    static var isAvailable: Bool {
        #if canImport(LSEKit)
        true
        #else
        false
        #endif
    }

    static var engineVersion: String {
        #if canImport(LSEKit)
        "LSE \(LSEEngine.version) (ABI \(LSEEngine.abiVersion))"
        #else
        "not in this build"
        #endif
    }

    /// Thread-safe holder the chat transport reads from engine threads.
    let box = EngineBox()
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var pendingLaunch: EngineLaunch?
    @ObservationIgnored private var stopAfterLoad = false
    @ObservationIgnored var launchResolver: (() -> EngineLaunch?)?

    init() {
        autoStart = UserDefaults.standard.object(forKey: "engine.autoStart") as? Bool ?? true
        #if canImport(LSEKit)
        LSEEngine.setLogHandler { line in
            engineLog.log("\(line, privacy: .public)")
            Task { @MainActor in EngineService.shared?.append(line) }
        }
        #endif
    }

    /// Set by AppModel; the log handler is process-wide.
    nonisolated(unsafe) static weak var shared: EngineService?

    var isRunning: Bool { phase == .ready }
    var servedName: String { launch?.servedName ?? "qwen-q4" }
    var contextWindow: Int { Int(launch?.kvLength ?? 32768) }

    var statusLine: String {
        switch phase {
        case .idle: return "Engine stopped"
        case .waiting(let why): return why
        case .loading(let what):
            if let p = loadProgress { return "\(what) \(Int(p * 100))%" }
            return what
        case .ready: return "\(launch?.modelName ?? "Model") ready"
        case .stopping: return "Stopping…"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    // MARK: Lifecycle

    /// Starts LSE with `launch`, or with the resolver's choice (the selected
    /// model and its stored load settings). While loading, the request waits
    /// for the load to finish; while running another configuration, the
    /// engine restarts.
    func start(_ requested: EngineLaunch? = nil) {
        guard let launch = requested ?? launchResolver?() else {
            phase = .waiting("No model installed. Open Models to add one.")
            return
        }
        switch phase {
        case .loading, .stopping:
            pendingLaunch = launch
            return
        case .ready:
            if launch == self.launch { return }
            pendingLaunch = launch
            stop()
            return
        default:
            break
        }
        #if canImport(LSEKit)
        self.launch = launch
        stopAfterLoad = false
        phase = .loading("Starting the GPU")
        loadProgress = nil
        loadSeconds = nil
        log.removeAll()
        UIApplication.shared.isIdleTimerDisabled = true
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollLoadStatus() }
        }
        let config = Self.configuration(for: launch)
        let started = Date()
        engineLog.log("engine open: \(launch.modelID, privacy: .public) draft \(launch.draftID ?? "none", privacy: .public) kv \(launch.kvCacheDType, privacy: .public)/\(launch.kvLength)")
        Task {
            do {
                let opened = try await LSEEngine.open(config)
                box.set(opened)
                loadSeconds = Date().timeIntervalSince(started)
                startedAt = Date()
                phase = .ready
                engineLog.log("engine ready in \(self.loadSeconds ?? 0) s")
            } catch {
                phase = .failed(String(describing: error))
                engineLog.error("engine open failed: \(String(describing: error), privacy: .public)")
            }
            statusTimer?.invalidate()
            statusTimer = nil
            loadProgress = nil
            UIApplication.shared.isIdleTimerDisabled = false
            if stopAfterLoad {
                stopAfterLoad = false
                stop()
            } else if let next = pendingLaunch {
                pendingLaunch = nil
                if next != self.launch || phase != .ready { reload(next) }
            }
        }
        #else
        self.launch = launch
        phase = .failed("This build has no GPU engine (simulator).")
        #endif
    }

    /// Stops the engine and releases the model and the GPU session. A load
    /// in progress cannot be interrupted; the engine stops once it finishes.
    func stop() {
        if case .loading = phase {
            pendingLaunch = nil
            stopAfterLoad = true
            return
        }
        #if canImport(LSEKit)
        guard let engine = box.take() else {
            if phase != .stopping { phase = .idle }
            return
        }
        phase = .stopping
        Task.detached {
            engine.close()
            await MainActor.run {
                self.phase = .idle
                self.startedAt = nil
                if let next = self.pendingLaunch {
                    self.pendingLaunch = nil
                    self.start(next)
                }
            }
        }
        #else
        phase = .idle
        #endif
    }

    /// Not started because something outside the app is missing.
    func markWaiting(_ reason: String) {
        switch phase {
        case .idle, .waiting, .failed: phase = .waiting(reason)
        default: break
        }
    }

    func markUnavailable() {
        phase = .failed("This build has no GPU engine (simulator).")
    }

    /// Restarts with new settings (Apply in the load settings sheet).
    func reload(_ launch: EngineLaunch) {
        switch phase {
        case .loading, .stopping:
            stopAfterLoad = false
            pendingLaunch = launch
        case .ready:
            pendingLaunch = launch
            stop()
        default:
            start(launch)
        }
    }

    private func pollLoadStatus() {
        #if canImport(LSEKit)
        let status = LSEEngine.loadStatus()
        let phaseName = status["phase"] as? String ?? ""
        let detail = status["detail"] as? String ?? ""
        loadProgress = status["progress"] as? Double
        let text = [phaseName, detail].filter { !$0.isEmpty }.joined(separator: ": ")
        if case .loading = phase { phase = .loading(text.isEmpty ? "Starting the GPU" : text) }
        #endif
    }

    func append(_ line: String) {
        log.append(line)
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    /// Engine status JSON (counters, last timings).
    func status() -> [String: Any] {
        #if canImport(LSEKit)
        if let engine = box.engine { return engine.status() }
        return LSEEngine.loadStatus()
        #else
        return [:]
        #endif
    }

    func refreshTimings() {
        let status = status()
        if let memory = status["memory"] as? [String: Any],
           let live = (memory["device_bytes"] as? NSNumber)?.uint64Value {
            deviceBytes = (live, (memory["device_peak_bytes"] as? NSNumber)?.uint64Value ?? live)
        }
        let engine = status["engine"] as? [String: Any]
        if let t = EngineTimings(engine?["last_timings"] as? [String: Any]) { lastTimings = t }
    }

    // MARK: Configuration

    #if canImport(LSEKit)
    /// The lse-server settings (LSELaunchPreset.standard by default: Q4 +
    /// DFlash2, bf16 KV, 32768, batch/ubatch 1024, temperature 0.6).
    static func configuration(for launch: EngineLaunch) -> LSEEngine.Configuration {
        var c = LSEEngine.Configuration(model: launch.modelDirectory.path)
        if let draft = launch.draftDirectory {
            c.dflash2 = true
            c.dflash2Model = draft.path
        }
        if launch.mtpEnabled {
            c.mtpDepth = launch.mtpDepth
        } else {
            c.noMTP = true
        }
        c.pool = "hrx:0"
        c.dialect = "loom"
        c.kvCacheDType = launch.kvCacheDType
        c.kvLength = launch.kvLength
        c.temperature = launch.temperature
        c.maxTokens = launch.maxTokens
        c.batchSize = launch.batchSize
        c.ubatchSize = launch.ubatchSize
        c.servedName = launch.servedName
        return c
    }
    #endif

    // MARK: Chat transport

    /// StudioAgent's in-process transport: requests go to the engine through
    /// `lse_request`; streamed chunks are the SSE payloads without framing.
    func chatTransport() -> ClosureChatTransport {
        let box = self.box
        return ClosureChatTransport { method, path, body, emit in
            try box.perform(method: method, path: path, body: body, emit: emit)
        }
    }
}

/// The open engine, shared with request threads.
final class EngineBox: @unchecked Sendable {
    private let lock = NSLock()
    #if canImport(LSEKit)
    private var current: LSEEngine?

    var engine: LSEEngine? { lock.withLock { current } }
    func set(_ engine: LSEEngine?) { lock.withLock { current = engine } }
    func take() -> LSEEngine? { lock.withLock { defer { current = nil }; return current } }
    #else
    var engine: AnyObject? { nil }
    func take() -> AnyObject? { nil }
    #endif

    static let unavailable = Data(#"{"error":{"message":"The GPU engine is not running. Start it from the GPU panel.","type":"engine_unavailable"}}"#.utf8)

    /// One request, blocking until its final event. Relative OpenAI paths
    /// ("chat/completions", "models") are LSE's "/v1/…" routes.
    func perform(method: String, path: String, body: Data?,
                 emit: @Sendable (Data) -> Bool) throws -> ClosureChatTransport.Response {
        #if canImport(LSEKit)
        guard let engine else { return .init(status: 503, body: Self.unavailable) }
        let route = path.hasPrefix("/") ? path : "/v1/" + path
        final class State: @unchecked Sendable {
            let lock = NSLock()
            let done = DispatchSemaphore(value: 0)
            var id: UInt64 = 0
            var cancelled = false
            var response = ClosureChatTransport.Response(status: 200)
        }
        let state = State()
        return try withoutActuallyEscaping(emit) { emit in
        let emitBox = UnsafeEmit(emit)
        let id = try engine.request(method: method, path: route, body: body) { event in
            switch event {
            case .chunk(let data):
                if !emitBox.call(data) {
                    let id: UInt64? = state.lock.withLock {
                        if state.cancelled { return nil }
                        state.cancelled = true
                        return state.id == 0 ? nil : state.id
                    }
                    if let id { engine.cancel(id) }
                }
            case .done:
                state.done.signal()
            case .response(let status, let data):
                state.response = .init(status: status, body: data)
                state.done.signal()
            case .error(let status, let data):
                state.response = .init(status: status, body: data)
                state.done.signal()
            }
        }
        let cancelNow = state.lock.withLock { () -> Bool in
            state.id = id
            return state.cancelled
        }
        if cancelNow { engine.cancel(id) }
        state.done.wait()
        return state.response
        }
        #else
        return .init(status: 503, body: Self.unavailable)
        #endif
    }
}

/// `emit` lives exactly as long as `perform` blocks, which outlives every
/// event callback of the request.
private final class UnsafeEmit: @unchecked Sendable {
    private let body: (Data) -> Bool
    init(_ body: @escaping @Sendable (Data) -> Bool) { self.body = body }
    func call(_ data: Data) -> Bool { body(data) }
}
