import UIKit
import Observation
import os
#if canImport(LSEKit)
import LSEKit
#endif

private let powerLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "power")

/// The GPU's power as the engine reports it (lse_status "power").
enum GPUPowerState: String, Sendable {
    case active, suspending, suspended, resuming, lost, unknown

    var isPaused: Bool { self == .suspending || self == .suspended || self == .resuming }
}

/// Puts the GPU in low power when the app leaves the foreground and wakes it
/// when the app comes back, through LSE (lse_power_prepare / resume, the
/// mac_linuxgpu HSA runtime's mac_hsa_agent_* calls), and recovers from a
/// device lost to a host sleep by reopening the engine.
///
/// - willResignActive / didEnterBackground: inside a background task, wait
///   briefly for a generation in flight to finish (bounded), then prepare
///   for low power: the driver unmaps every queue and keeps device memory.
///   A generation still running pauses and continues after resume.
/// - didBecomeActive: resume. A lost device (the iPad slept with the GPU
///   attached and its memory went with it) closes and reopens the engine:
///   "GPU was reset by sleep; reloading model…". Chats are kept; their KV
///   sessions are gone, so the next message re-reads the conversation.
@MainActor
@Observable
final class EnginePower {
    private(set) var state: GPUPowerState = .unknown
    private(set) var lastTransition: String?
    /// Set while the engine reloads after a device loss.
    private(set) var recovering = false

    /// How long to let a running generation finish before suspending.
    static let generationGrace: Duration = .seconds(8)
    /// How long the runtime waits for packets already submitted.
    static let drainMilliseconds: UInt32 = 2000

    @ObservationIgnored private weak var engine: EngineService?
    @ObservationIgnored private weak var gpu: GPUCoordinator?
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static var isAvailable: Bool {
        #if canImport(LSEKit)
        LSEEngine.supportsPower
        #else
        false
        #endif
    }

    func start(engine: EngineService, gpu: GPUCoordinator) {
        self.engine = engine
        self.gpu = gpu
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

    /// Reads the state from lse_status; a loss noticed here (the iPad slept
    /// while the app was active) recovers too.
    func refresh() {
        guard let engine, engine.phase == .ready else {
            if engine?.phase != .ready, !recovering { state = .unknown }
            return
        }
        let power = engine.status()["power"] as? [String: Any]
        let next = GPUPowerState(rawValue: power?["state"] as? String ?? "") ?? .unknown
        if next != state { state = next }
        if next == .lost { recoverFromLoss(reason: "lse_status reports the device lost") }
    }

    // MARK: Background

    private func willLeaveForeground() {
        guard Self.isAvailable, !prepared, let engine, engine.phase == .ready else { return }
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
            guard !Task.isCancelled else { self.endBackgroundTask(); return }
            #if canImport(LSEKit)
            if let lse = engine.box.engine {
                let drain = Self.drainMilliseconds
                let result = await Task.detached { lse.prepareLowPower(drainMilliseconds: drain) }.value
                self.state = GPUPowerState(rawValue: result.state.rawValue) ?? .unknown
                self.lastTransition = result.error.map { "prepare failed: \($0)" } ?? "suspended for the background"
                powerLog.log("prepare low power: \(result.state.rawValue, privacy: .public) \(result.error ?? "", privacy: .public)")
                if result.error != nil, result.state != .lost { self.prepared = false }
            }
            #endif
            self.endBackgroundTask()
        }
    }

    private func didBecomeActive() {
        guard Self.isAvailable, let engine else { return }
        guard prepared else {
            refresh()
            return
        }
        prepared = false
        transition?.cancel()
        transition = Task { [weak self] in
            guard let self else { return }
            #if canImport(LSEKit)
            guard let lse = engine.box.engine else { return }
            let result = await Task.detached { lse.resumeFromLowPower() }.value
            self.state = GPUPowerState(rawValue: result.state.rawValue) ?? .unknown
            powerLog.log("resume: \(result.state.rawValue, privacy: .public) \(result.error ?? "", privacy: .public)")
            if result.state == .lost {
                self.recoverFromLoss(reason: result.error ?? "the device was lost while suspended")
            } else {
                self.lastTransition = result.error.map { "resume failed: \($0)" } ?? "resumed"
            }
            #endif
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Device lost

    /// Closes the engine and opens it again with the same configuration:
    /// lse_close gives the memory back, and the next lse_open's hsa_init
    /// probes the device afresh.
    func recoverFromLoss(reason: String) {
        guard !recovering, let engine, let launch = engine.launch ?? gpu?.currentLaunch() else { return }
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
}
