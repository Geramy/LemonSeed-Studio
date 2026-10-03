import UIKit
import Observation
import os

private let powerLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "power")

/// The GPU's power as the engine reports it (lse_status "power").
enum GPUPowerState: String, Sendable {
    case active, suspending, suspended, resuming, lost, unknown

    var isPaused: Bool { self == .suspending || self == .suspended || self == .resuming }
}

/// The GPU across app lifecycle and hardware events, through LSE
/// (lse_power_prepare / resume over the mac_linuxgpu HSA runtime):
///
/// - Background (willResignActive / didEnterBackground): inside a background
///   task, let a running generation finish for a bounded time, then prepare
///   for low power; device memory is kept. didBecomeActive resumes.
/// - Lost to a sleep (the device's memory went with it; the driver service
///   is still there): close the engine and open it again —
///   "GPU was reset by sleep; reloading model…".
/// - Disconnected (power cause 13, "device removed", or the driver's
///   service went away): close the engine cleanly, stop every call into it,
///   pause telemetry, and show "GPU disconnected — plug it back in to
///   continue". When the IOKit matching notification brings the service
///   back, the engine loads again with the same configuration.
///
/// Chats, files and the editor are never touched; a chat's KV session is
/// gone after a reset, so its next message re-reads the conversation.
@MainActor
@Observable
final class EnginePower {
    /// The driver's cause for a removed device (mac_linuxgpu power_state.h).
    static let causeDeviceRemoved: UInt32 = 13
    static let disconnectedMessage = "GPU disconnected — plug it back in to continue"

    private(set) var state: GPUPowerState = .unknown
    private(set) var lastTransition: String?
    /// Set while the engine reloads after a device loss.
    private(set) var recovering = false
    /// The GPU is unplugged (or its driver service is gone).
    private(set) var disconnected = false

    /// How long to let a running generation finish before suspending.
    static let generationGrace: Duration = .seconds(8)
    /// How long the runtime waits for packets already submitted.
    static let drainMilliseconds: UInt32 = 2000

    @ObservationIgnored private weak var engine: EngineService?
    @ObservationIgnored private var servicePresent: () -> Bool = { true }
    @ObservationIgnored private var currentLaunch: () -> EngineLaunch? = { nil }
    @ObservationIgnored private var setTelemetryActive: (Bool) -> Void = { _ in }
    /// The configuration to load again once the GPU is back.
    @ObservationIgnored private var resumeLaunch: EngineLaunch?
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var isAvailable: Bool { engine?.opener.supportsPower ?? false }

    /// The app's wiring: the coordinator's driver and models, telemetry.
    func start(engine: EngineService, gpu: GPUCoordinator, telemetry: ((Bool) -> Void)?) {
        configure(engine: engine,
                  servicePresent: { [weak gpu] in gpu?.driver.service != nil },
                  currentLaunch: { [weak gpu] in gpu?.currentLaunch() },
                  telemetryActive: telemetry ?? { _ in })
        gpu.serviceObserver = { [weak self] present in self?.driverServiceChanged(present: present) }
        gpu.retryAfterDisconnect = { [weak self] in self?.retryAfterDisconnect() ?? false }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willLeaveForeground() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willLeaveForeground() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didBecomeActive() }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The parts EnginePower needs, injectable for tests.
    func configure(engine: EngineService, servicePresent: @escaping () -> Bool,
                   currentLaunch: @escaping () -> EngineLaunch?, telemetryActive: @escaping (Bool) -> Void) {
        self.engine = engine
        self.servicePresent = servicePresent
        self.currentLaunch = currentLaunch
        self.setTelemetryActive = telemetryActive
        let box = engine.box
        engine.box.onDeviceLost { [weak self] reason, generation in
            Task { @MainActor in
                // Only a loss of the engine that is open now counts; a late
                // report about one already closed is stale.
                guard generation == box.generation, !box.isLost else { return }
                // A failed request does not say why the device went; give
                // the driver's terminate notification a moment first.
                self?.recoverFromLoss(reason: reason, cause: nil, waitForService: true)
            }
        }
    }

    /// Reads the state from lse_status; a loss noticed here (the iPad slept,
    /// or the GPU was unplugged, while the app was active) recovers too.
    func refresh() {
        guard let engine, !disconnected, engine.phase == .ready, !engine.box.isLost else {
            if engine?.phase != .ready, !recovering, !disconnected { state = .unknown }
            return
        }
        let result = powerResult(engine.status()["power"] as? [String: Any])
        if result.state != state { state = result.state }
        if result.state == .lost { recoverFromLoss(reason: "lse_status reports the device lost", cause: result.cause) }
    }

    // MARK: Background

    private func willLeaveForeground() {
        guard isAvailable, !prepared, !disconnected, let engine, engine.phase == .ready,
              let handle = engine.box.engine else { return }
        prepared = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GPU low power") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        transition?.cancel()
        transition = Task { [weak self] in
            guard let self else { return }
            // Let a generation in flight finish, up to the grace period.
            let deadline = ContinuousClock.now + Self.generationGrace
            while engine.activeRequests > 0, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled, !engine.box.isLost else { self.endBackgroundTask(); return }
            let drain = Self.drainMilliseconds
            let result = await Task.detached { handle.prepareLowPower(drainMilliseconds: drain) }.value
            self.state = result.state
            self.lastTransition = result.error.map { "prepare failed: \($0)" } ?? "suspended for the background"
            powerLog.log("prepare low power: \(result.state.rawValue, privacy: .public) \(result.error ?? "", privacy: .public)")
            if result.state == .lost {
                self.recoverFromLoss(reason: result.error ?? "the device was lost", cause: result.cause)
            } else if result.error != nil {
                self.prepared = false
            }
            self.endBackgroundTask()
        }
    }

    private func didBecomeActive() {
        guard isAvailable, let engine else { return }
        guard prepared else {
            refresh()
            return
        }
        prepared = false
        transition?.cancel()
        guard !disconnected, let handle = engine.box.engine else { return }
        transition = Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached { handle.resumeFromLowPower() }.value
            self.state = result.state
            powerLog.log("resume: \(result.state.rawValue, privacy: .public) \(result.error ?? "", privacy: .public)")
            if result.state == .lost {
                self.recoverFromLoss(reason: result.error ?? "the device was lost while suspended", cause: result.cause)
            } else {
                self.lastTransition = result.error.map { "resume failed: \($0)" } ?? "resumed"
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Device lost

    /// The device's memory is gone. Removed (cause 13, or no driver
    /// service): close and wait for it to come back. Otherwise (a sleep):
    /// close and open again now — lse_close gives the memory back and the
    /// next lse_open's hsa_init probes the device afresh.
    /// How long a loss with no cause waits for the driver's service to go
    /// away (an unplug) before it is taken for a sleep and reloads.
    static let serviceGoneGrace: Duration = .milliseconds(1500)

    func recoverFromLoss(reason: String, cause: UInt32? = nil, waitForService: Bool = false) {
        guard let engine, !disconnected else { return }
        if cause == Self.causeDeviceRemoved || !servicePresent() {
            disconnect(reason: reason)
            return
        }
        if waitForService {
            // Stop calling into the engine meanwhile.
            engine.box.markLost()
            Task { [weak self] in
                try? await Task.sleep(for: Self.serviceGoneGrace)
                self?.recoverFromLoss(reason: reason, cause: cause, waitForService: false)
            }
            return
        }
        guard !recovering, !disconnected, let launch = engine.launch ?? currentLaunch() else { return }
        recovering = true
        state = .lost
        lastTransition = "device lost: \(reason)"
        powerLog.log("device lost (\(reason, privacy: .public)); reloading")
        engine.recoverAfterDeviceLoss(launch)
        Task { [weak self] in
            // Done once the engine is up again (or failed).
            while let engine = self?.engine {
                switch engine.phase {
                case .ready, .failed, .idle, .waiting:
                    self?.recovering = false
                    self?.refresh()
                    return
                default:
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// The GPU is gone: stop every call into the engine and telemetry, close
    /// the engine, and wait for the driver service.
    func disconnect(reason: String) {
        guard let engine, !disconnected else { return }
        disconnected = true
        recovering = false
        prepared = false
        transition?.cancel()
        state = .lost
        lastTransition = "disconnected: \(reason)"
        resumeLaunch = engine.launch ?? currentLaunch()
        powerLog.log("GPU disconnected (\(reason, privacy: .public)); closing the engine and waiting for the driver")
        setTelemetryActive(false)
        engine.closeAfterDisconnect(reason: Self.disconnectedMessage)
        // The engine loads again when the driver's service comes back (an
        // IOKit match after the terminate), or when the user starts it.
    }

    /// The user asked to start the engine while it waits for the GPU: try
    /// now if the driver's service is there (the device may be back without
    /// the service having gone away). True when handled here.
    func retryAfterDisconnect() -> Bool {
        guard disconnected else { return false }
        if servicePresent() { reconnect() }
        return true
    }

    /// From the driver's IOKit match/terminate notifications.
    func driverServiceChanged(present: Bool) {
        guard let engine else { return }
        if !present {
            switch engine.phase {
            case .ready, .loading, .stopping:
                disconnect(reason: "the driver's service went away")
            case .failed where state == .lost || recovering || engine.box.isLost:
                // A reload after the loss failed: the GPU really is gone.
                disconnect(reason: "the driver's service went away")
            default:
                break
            }
            return
        }
        guard disconnected else { return }
        reconnect()
    }

    private func reconnect() {
        guard let engine, disconnected else { return }
        // Wait for a close still in progress; the service is back.
        if engine.phase == .stopping {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.reconnect()
            }
            return
        }
        disconnected = false
        state = .unknown
        lastTransition = "reconnected"
        engine.blockedReason = nil
        setTelemetryActive(true)
        powerLog.log("GPU reconnected; loading the engine again")
        if let launch = resumeLaunch ?? currentLaunch() {
            resumeLaunch = nil
            engine.start(launch)
        }
    }
}
