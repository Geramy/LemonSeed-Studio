import UIKit
import Observation
import os

private let awakeLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "keepawake")

/// Keeps the iPad from sleeping while the GPU is in use: a sleeping iPad
/// suspends the app, and a suspended client in the middle of a GPU session
/// is how the driver ends up quarantined or the device lost.
///
/// The idle timer is off while any of these hold: the driver's service is
/// attached, the engine is loading or loaded, a generation is running, the
/// Diagnostics bring-up runs, or the development remote control was used in
/// the last ten minutes. While a generation runs the app also holds a
/// background-task assertion, so a brief app switch does not suspend it in
/// the middle of a request. Settings › GPU Driver › "Keep iPad awake while
/// the GPU is in use" turns the idle-timer part off.
@MainActor
@Observable
final class KeepAwake {
    static let devClientWindow: TimeInterval = 10 * 60

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "keepAwakeWhileGPUInUse")
            evaluate()
        }
    }
    private(set) var reasons: [String] = []
    private(set) var isHoldingAwake = false

    /// Other parts of the app that need the iPad awake (the Diagnostics
    /// bring-up), by name.
    @ObservationIgnored private var holds: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var background: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var active = true
    @ObservationIgnored private weak var app: AppModel?

    init() {
        enabled = UserDefaults.standard.object(forKey: "keepAwakeWhileGPUInUse") as? Bool ?? true
    }

    func start(app: AppModel) {
        self.app = app
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.active = true
                self?.evaluate()
            }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.active = false
                self?.evaluate()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    func hold(_ name: String) { holds.insert(name); evaluate() }
    func release(_ name: String) { holds.remove(name); evaluate() }

    /// Whether a generation (an agent turn or any engine request) is running.
    private func generating(_ app: AppModel) -> Bool {
        if (app.services.agent as? StudioAgentProvider)?.isGenerating == true { return true }
        guard app.engine.phase == .ready,
              let requests = app.engine.status()["requests"] as? [String: Any],
              let active = requests["active"] as? Int else { return false }
        return active > 0
    }

    func evaluate() {
        guard let app else { return }
        var why: [String] = []
        if app.driver.service != nil { why.append("driver attached") }
        switch app.engine.phase {
        case .loading: why.append("engine loading")
        case .ready: why.append("engine loaded")
        case .stopping: why.append("engine stopping")
        default: break
        }
        let isGenerating = generating(app)
        if isGenerating { why.append("generating") }
        #if DEBUG
        if let last = DevServer.shared.lastRequestAt, Date().timeIntervalSince(last) < Self.devClientWindow {
            why.append("remote control in use")
        }
        #endif
        why.append(contentsOf: holds.sorted())
        if why != reasons { reasons = why }

        let awake = enabled && active && !why.isEmpty
        if awake != isHoldingAwake {
            isHoldingAwake = awake
            UIApplication.shared.isIdleTimerDisabled = awake
            awakeLog.log("idle timer \(awake ? "off" : "on", privacy: .public): \(why.joined(separator: ", "), privacy: .public)")
        }

        // A background-task assertion for the length of a generation.
        if isGenerating && background == .invalid {
            background = UIApplication.shared.beginBackgroundTask(withName: "LemonSeed generation") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        } else if !isGenerating && background != .invalid {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }
}
