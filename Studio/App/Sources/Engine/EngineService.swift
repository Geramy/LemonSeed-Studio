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
    /// The user's sampling overrides, sent with each request (nil fields:
    /// the model's defaults). Not engine options: the engine keeps the
    /// model's own temperature, and sets no output limit.
    var sampling = SamplingOverrides()
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

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { writeStatusFile() } }
    }

    /// Documents/engine-status.json: the engine's phase, model and memory,
    /// rewritten when the phase changes, so the Mac can read the state with
    /// `devicectl device copy from` without driving the UI.
    private func writeStatusFile() {
        var object: [String: Any] = ["phase": "\(phase)", "statusLine": statusLine,
                                     "updated": ISO8601DateFormatter().string(from: Date()),
                                     "engine": EngineService.engineVersion]
        if let launch {
            object["model"] = launch.modelID
            object["draft"] = launch.draftID ?? NSNull()
            object["kv"] = "\(launch.kvCacheDType)/\(launch.kvLength)"
        }
        if let loadSeconds { object["loadSeconds"] = loadSeconds }
        if phase == .ready { object["memory"] = memoryLine() }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("engine-status.json")
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    private(set) var loadProgress: Double?
    private(set) var launch: EngineLaunch?
    private(set) var loadSeconds: Double?
    private(set) var lastTimings: EngineTimings?
    /// Device memory the engine holds (lse_status "memory": live and peak).
    private(set) var deviceBytes: (live: UInt64, peak: UInt64)?
    private(set) var log: [String] = []
    private(set) var startedAt: Date?

    /// Whether this process can open a second engine after closing one.
    /// LSE before 48c88ff did not return a closed engine's device memory, so
    /// a second lse_open ran out of VRAM; with such an engine set this to
    /// false and the app opens the engine at most once per launch. Either
    /// way a second lse_open never runs while one engine is open or opening.
    static let canReopenInProcess = true
    /// An engine was opened (or opening was attempted) in this process.
    private(set) var openedInThisProcess = false
    /// Settings that need an app restart to load (see canReopenInProcess).
    private(set) var restartRequired: EngineLaunch?

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

    static var engineVersion: String { EngineOpener.standard.version }

    /// How engines are opened (LSE; a fake in tests).
    let opener: EngineOpener
    /// Whether this service can open an engine at all.
    var canStart: Bool { opener.isAvailable }
    /// Set while something outside the app rules out starting (the GPU is
    /// disconnected): start() waits with this reason instead.
    var blockedReason: String?

    /// Thread-safe holder the chat transport reads from engine threads.
    let box = EngineBox()
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var pendingLaunch: EngineLaunch?
    @ObservationIgnored private var stopAfterLoad = false
    @ObservationIgnored var launchResolver: (() -> EngineLaunch?)?

    init(opener: EngineOpener = .standard) {
        self.opener = opener
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

    /// Shown while the engine reloads after the GPU lost its memory.
    private(set) var recoveryNotice: String?

    /// Requests the engine is running now (lse_status requests.active).
    var activeRequests: Int {
        guard phase == .ready, let requests = status()["requests"] as? [String: Any] else { return 0 }
        return requests["active"] as? Int ?? 0
    }

    /// The GPU's memory went with a host sleep: close the engine and open it
    /// again with the same configuration. Chats stay; their KV is gone.
    func recoverAfterDeviceLoss(_ launch: EngineLaunch) {
        recoveryNotice = "GPU was reset by sleep; reloading model…"
        engineLog.log("device lost: reloading \(launch.modelID, privacy: .public)")
        switch phase {
        case .ready:
            pendingLaunch = launch
            stop()
        case .loading, .stopping:
            pendingLaunch = launch
        default:
            start(launch)
        }
    }

    var statusLine: String {
        if let recoveryNotice, phase != .ready {
            if case .failed(let why) = phase { return "\(recoveryNotice) Failed: \(why)" }
            return recoveryNotice
        }
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
            // Never a second lse_open while one engine is open or opening:
            // the request waits until this one has finished (and closes).
            if launch != self.launch {
                if Self.canReopenInProcess { pendingLaunch = launch } else { requireRestart(for: launch) }
            }
            return
        case .ready:
            if launch == self.launch { return }
            guard Self.canReopenInProcess else { requireRestart(for: launch); return }
            pendingLaunch = launch
            stop()
            return
        default:
            break
        }
        if openedInThisProcess && !Self.canReopenInProcess {
            requireRestart(for: launch)
            return
        }
        if let blockedReason {
            self.launch = launch
            phase = .waiting(blockedReason)
            return
        }
        guard opener.isAvailable else {
            self.launch = launch
            phase = .failed("This build has no GPU engine (simulator).")
            return
        }
        openedInThisProcess = true
        restartRequired = nil
        self.launch = launch
        stopAfterLoad = false
        phase = .loading("Starting the GPU")
        loadProgress = nil
        loadSeconds = nil
        log.removeAll()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollLoadStatus() }
        }
        let opener = self.opener
        let started = Date()
        engineLog.log("engine open: \(launch.modelID, privacy: .public) draft \(launch.draftID ?? "none", privacy: .public) kv \(launch.kvCacheDType, privacy: .public)/\(launch.kvLength)")
        Task {
            do {
                let opened = try await opener.open(launch)
                box.set(opened)
                recoveryNotice = nil
                loadSeconds = Date().timeIntervalSince(started)
                startedAt = Date()
                phase = .ready
                engineLog.log("engine ready in \(self.loadSeconds ?? 0) s")
            } catch {
                // An open that failed because the GPU went away waits for it.
                phase = blockedReason.map { .waiting($0) } ?? .failed(String(describing: error))
                engineLog.error("engine open failed: \(String(describing: error), privacy: .public)")
            }
            statusTimer?.invalidate()
            statusTimer = nil
            loadProgress = nil
            if stopAfterLoad {
                stopAfterLoad = false
                stop()
            } else if let next = pendingLaunch {
                pendingLaunch = nil
                if next != self.launch || phase != .ready { reload(next) }
            }
        }
    }

    /// Stops the engine and releases the model and the GPU session. A load
    /// in progress cannot be interrupted; the engine stops once it finishes.
    func stop() {
        if case .loading = phase {
            pendingLaunch = nil
            stopAfterLoad = true
            return
        }
        guard let engine = box.take() else {
            if phase != .stopping { phase = .idle }
            return
        }
        phase = .stopping
        Task.detached {
            engine.close()
            await MainActor.run {
                self.phase = self.blockedReason.map { .waiting($0) } ?? .idle
                self.startedAt = nil
                if let next = self.pendingLaunch {
                    self.pendingLaunch = nil
                    self.start(next)
                }
            }
        }
    }

    /// The GPU went away (unplugged, or its driver service terminated): no
    /// further call reaches the engine; it is closed (the runtime's errors
    /// from the removed device are expected), and the service waits with
    /// `reason` until the GPU is back. Chats and files are untouched.
    func closeAfterDisconnect(reason: String) {
        blockedReason = reason
        recoveryNotice = nil
        pendingLaunch = nil
        box.markLost()
        if case .loading = phase {
            // lse_open cannot be interrupted; it fails or finishes on its
            // own, and then closes.
            stopAfterLoad = true
            return
        }
        guard let engine = box.take() else {
            phase = .waiting(reason)
            return
        }
        phase = .stopping
        engineLog.log("GPU disconnected: closing the engine")
        Task.detached {
            engine.close()
            await MainActor.run {
                self.startedAt = nil
                self.phase = .waiting(self.blockedReason ?? reason)
            }
        }
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

    private func requireRestart(for launch: EngineLaunch) {
        restartRequired = launch
        engineLog.log("engine reload deferred to the next launch: \(launch.modelID, privacy: .public) \(launch.kvCacheDType, privacy: .public)/\(launch.kvLength)")
    }

    /// Restarts with new settings (Apply in the load settings sheet). While
    /// the engine cannot reopen in process, the settings wait for the next
    /// launch instead (they are already saved).
    func reload(_ launch: EngineLaunch) {
        if openedInThisProcess && !Self.canReopenInProcess {
            if launch != self.launch || phase != .ready { requireRestart(for: launch) }
            return
        }
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
        let status = opener.loadStatus()
        let phaseName = status["phase"] as? String ?? ""
        let detail = status["detail"] as? String ?? ""
        loadProgress = status["progress"] as? Double
        let text = [phaseName, detail].filter { !$0.isEmpty }.joined(separator: ": ")
        if case .loading = phase { phase = .loading(text.isEmpty ? "Starting the GPU" : text) }
    }

    func append(_ line: String) {
        #if DEBUG
        DevLog.shared.append(line, source: "lse")
        #endif
        log.append(line)
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    /// Engine status JSON (counters, last timings).
    func status() -> [String: Any] {
        // Nothing reaches an engine whose device is gone.
        if box.isLost { return lastStatus }
        if let engine = box.engine {
            let s = engine.status()
            lastStatus = s
            return s
        }
        return opener.loadStatus()
    }

    @ObservationIgnored private var lastStatus: [String: Any] = [:]

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
    /// DFlash2, bf16 KV, 32768, batch/ubatch 1024).
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
        // Always set: without it the engine's context is 4096.
        c.kvLength = launch.kvLength
        // The model's own sampling defaults and no operator cap on replies.
        c.temperature = nil
        c.maxTokens = 0
        c.batchSize = launch.batchSize
        c.ubatchSize = launch.ubatchSize
        c.servedName = launch.servedName
        return c
    }
    #endif

    // MARK: Sessions

    /// Whether the engine answered the session-close route; nil until tried
    /// (engines without lse_session_close only).
    @ObservationIgnored private var sessionCloseSupported: Bool?

    /// Releases a chat's KV session in the engine. With per-session KV
    /// (lse_session_close linked) this calls the engine directly; an older
    /// engine is asked through its `DELETE /v1/lse/sessions/{id}` route once,
    /// and not again if it does not know it.
    func closeSession(_ id: String) {
        guard phase == .ready, !box.isLost else { return }
        if opener.supportsSessions, let engine = box.engine {
            sessionCloseSupported = true
            Task.detached {
                let closed = engine.closeSession(id)
                engineLog.log("lse_session_close \(id, privacy: .public): \(closed ? "released" : "no such session")")
            }
            return
        }
        guard sessionCloseSupported != false else { return }
        let box = self.box
        Task.detached {
            let response = try? box.perform(method: "DELETE", path: "/v1/lse/sessions/\(id)", body: nil) { _ in true }
            let status = response?.status ?? 0
            await MainActor.run {
                if status == 404 || status == 405 { self.sessionCloseSupported = false }
                else if (200..<300).contains(status) { self.sessionCloseSupported = true }
                engineLog.log("close session \(id, privacy: .public): \(status)")
            }
        }
    }

    var supportsSessionClose: Bool {
        opener.supportsSessions || sessionCloseSupported == true
    }

    /// Device memory live/peak from lse_status, as text.
    func memoryLine() -> String {
        guard let m = status()["memory"] as? [String: Any],
              let live = (m["device_bytes"] as? NSNumber)?.uint64Value else { return "n/a" }
        let peak = (m["device_peak_bytes"] as? NSNumber)?.uint64Value ?? live
        let f = { (b: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }
        return "\(f(live)) live, \(f(peak)) peak"
    }

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
    private var current: (any EngineHandle)?
    private var lost = false
    private var opened = 0
    private var lostHandler: (@Sendable (String, Int) -> Void)?

    /// Counts engines set; a loss reported for an older one is stale.
    var generation: Int { lock.withLock { opened } }

    /// The open engine; nil when none is open or its device is gone.
    var engine: (any EngineHandle)? { lock.withLock { lost ? nil : current } }
    var isLost: Bool { lock.withLock { lost } }
    /// A new engine: requests reach it again.
    func set(_ engine: (any EngineHandle)?) {
        lock.withLock {
            current = engine
            lost = false
            if engine != nil { opened += 1 }
        }
    }
    func take() -> (any EngineHandle)? { lock.withLock { defer { current = nil }; return current } }
    /// The device is gone: from now on no request reaches the engine
    /// (they answer device_lost at once) until a new one is set.
    func markLost() { lock.withLock { lost = true } }
    /// Told when a request fails because the device was lost.
    /// The handler gets the reason and the generation of the engine that
    /// failed.
    func onDeviceLost(_ handler: (@Sendable (String, Int) -> Void)?) { lock.withLock { lostHandler = handler } }

    static let deviceLostBody = Data(#"{"error":{"message":"The GPU is disconnected. Plug it back in to continue.","type":"device_lost","code":"device_lost"}}"#.utf8)

    /// Whether a failed response says the device went away.
    static func isDeviceLoss(_ response: ClosureChatTransport.Response) -> Bool {
        if refusalCode(response) == "device_lost" { return true }
        guard !(200..<300).contains(response.status) else { return false }
        let text = String(decoding: response.body, as: UTF8.self).lowercased()
        return text.contains("device_lost") || text.contains("device lost") || text.contains("hsa_status_error_fatal")
    }

    static let unavailable = Data(#"{"error":{"message":"The GPU engine is not running. Start it from the GPU panel.","type":"engine_unavailable"}}"#.utf8)

    /// One request, blocking until its final event. Relative OpenAI paths
    /// ("chat/completions", "models") are LSE's "/v1/…" routes.
    /// The engine's code for a refused request: "suspended" (the GPU is in
    /// low power; nothing started, retry after resume) or "device_lost".
    static func refusalCode(_ response: ClosureChatTransport.Response) -> String? {
        guard response.status == 503,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }

    /// How long a request waits for a suspended GPU to resume before it
    /// gives up (a short app switch resumes well within it).
    static let suspendedRetryLimit: TimeInterval = 90

    /// One request, blocking until its final event. A refusal because the
    /// GPU is suspended (the engine started nothing) is retried once a
    /// second until it resumes; a device lost starts the engine's recovery.
    func perform(method: String, path: String, body: Data?,
                 emit: @Sendable (Data) -> Bool) throws -> ClosureChatTransport.Response {
        let started = Date()
        let engineGeneration = generation
        while true {
            let response = try performOnce(method: method, path: path, body: body, emit: emit)
            switch Self.refusalCode(response) {
            case "suspended" where Date().timeIntervalSince(started) < Self.suspendedRetryLimit:
                Thread.sleep(forTimeInterval: 1)
                continue
            default:
                if Self.isDeviceLoss(response), let handler = lock.withLock({ lostHandler }) {
                    handler("a request failed: the device was lost", engineGeneration)
                }
                return response
            }
        }
    }

    private func performOnce(method: String, path: String, body: Data?,
                             emit: @Sendable (Data) -> Bool) throws -> ClosureChatTransport.Response {
        if isLost { return .init(status: 503, body: Self.deviceLostBody) }
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
        // The engine may keep its handler (and with it emitBox) a moment
        // after the final event; drop `emit` before leaving, so nothing
        // escapes the withoutActuallyEscaping block.
        emitBox.clear()
        return state.response
        }
    }
}

/// Holds `emit` while `perform` blocks. The engine may hold its handler a
/// little past the final event, so the closure is cleared before `perform`
/// returns; later calls see nil and answer false (stop).
private final class UnsafeEmit: @unchecked Sendable {
    private let lock = NSLock()
    private var body: ((Data) -> Bool)?
    init(_ body: @escaping @Sendable (Data) -> Bool) { self.body = body }
    /// Under the lock, so `clear` waits for a call in progress and no
    /// copy of the closure outlives it.
    func call(_ data: Data) -> Bool {
        lock.withLock { body?(data) ?? false }
    }
    func clear() { lock.withLock { body = nil } }
}
