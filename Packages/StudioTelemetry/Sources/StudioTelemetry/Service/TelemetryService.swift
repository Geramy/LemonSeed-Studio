// StudioTelemetry: the sampling service behind the GPU screen and widget.
//
// Replaces amdgpu_mtopg's GPUSampler (App.swift). Sampling runs on its own
// serial queue (TelemetrySampler's executor): the GRBM spacing sleep and
// every IOKit call stay off the main thread and off the cooperative pool.
// The rate follows demand: 10 Hz while a GPU screen is visible, 1 Hz for the
// status widget alone, paused otherwise or in the background.
//
// MIT License (amdgpu_mtopg); see THIRD_PARTY.md.

import Foundation
import Observation

/// Owns the transport and the history; isolated to the telemetry queue.
actor TelemetrySampler {
    private let queue = DispatchSerialQueue(label: "com.geramyloveless.LemonSeedStudio.telemetry", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let directory: any ObserverDirectory
    private let transport: LinuxTransport
    private let history = LinuxHistory()
    private let clock: NanosecondClock
    private var selected: UInt64?
    private let driverEnabled: (@Sendable () -> Bool?)?

    init(directory: any ObserverDirectory, clock: @escaping NanosecondClock = uptimeNanoseconds,
         driverEnabled: (@Sendable () -> Bool?)? = nil) {
        self.directory = directory
        self.clock = clock
        self.driverEnabled = driverEnabled
        self.transport = LinuxTransport(directory: directory, clock: clock)
    }

    func select(_ registryID: UInt64?) {
        if registryID != selected { history.reset() }
        selected = registryID
    }

    func refresh() -> TelemetryState {
        var state = TelemetryState()
        state.sourceName = directory.sourceName
        state.sourceDetails = directory.sourceDetails
        let devices = directory.devices()
        state.devices = devices
        transport.forget(except: Set(devices.map(\.registryID)))
        guard !devices.isEmpty else {
            history.reset()
            state.availability = driverEnabled?() == false ? .driverNotEnabled : .noDevice
            state.capturedAt = Date()
            return state
        }
        let device = devices.first { $0.registryID == selected } ?? devices[0]
        if device.registryID != selected {
            history.reset()
            selected = device.registryID
        }
        state.device = device
        let sample = transport.read(registry: device.registryID)
        let now = clock()
        history.add(sample, nowNs: now)
        let snap = makeLinuxSnapshot(sample, history: history, nowNs: now)
        state.snapshot = snap
        state.summary = GPUSummary(snap)
        state.capturedAt = Date()
        if let name = PCINames.name(deviceLine: snap.deviceLine) {
            state.deviceName = name
            state.deviceNameSource = PCINames.source
        }
        if sample.error != nil {
            state.availability = .error(snap.status)
        } else if sample.unsupported {
            state.availability = .unsupported(snap.status)
        } else if !snap.statusOK {
            state.availability = .notRunning(snap.status)
        } else {
            state.availability = .live
        }
        return state
    }

    func close() {
        transport.closeAll()
        history.reset()
    }
}

/// Stands in for a fixture that is not bundled: no device, and a source
/// line that says why.
struct MissingFixtureDirectory: ObserverDirectory {
    let name: String
    var sourceName: String { "no recorded fixture \(name) bundled (Tools/capture_fixtures.sh)" }
    func devices() -> [ObserverDevice] { [] }
    func openObserver(registryID: UInt64) throws -> any ObserverConnection { throw ObserverError.noSuchDevice(registryID) }
}

@MainActor
@Observable
public final class TelemetryService {
    public private(set) var state = TelemetryState()

    @ObservationIgnored private let sampler: TelemetrySampler
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var demand: [TelemetrySampleRate: Int] = [:]
    @ObservationIgnored private var foreground = true

    public let sourceName: String

    /// - Parameters:
    ///   - directory: IOKitObserverDirectory on hardware, FixtureObserverDirectory
    ///     in the simulator, previews and tests.
    ///   - driverEnabled: the host's knowledge of driver enablement
    ///     (OSSystemExtensionsWorkspace on iPadOS), used to tell "driver not
    ///     enabled" from "no GPU" when no service is found.
    public init(directory: any ObserverDirectory, driverEnabled: (@Sendable () -> Bool?)? = nil) {
        sampler = TelemetrySampler(directory: directory, driverEnabled: driverEnabled)
        sourceName = directory.sourceName
        state.sourceName = directory.sourceName
    }

    /// A service replaying a bundled fixture recorded on real hardware.
    /// Without that fixture it says so instead of showing anything.
    public static func fixture(_ name: String? = nil, scenario: FixtureScenario = .live) -> TelemetryService {
        let name = name ?? ObserverFixture.bundledNames.first ?? "r9700-idle"
        guard let fixture = try? ObserverFixture.bundled(name) else {
            return TelemetryService(directory: MissingFixtureDirectory(name: name))
        }
        return TelemetryService(directory: FixtureObserverDirectory(fixture: fixture, scenario: scenario))
    }

    public var sampleRate: TelemetrySampleRate {
        guard foreground else { return .paused }
        return demand.filter { $0.value > 0 }.keys.max() ?? .paused
    }

    /// Keeps sampling at `rate` (at least) until the calling task is
    /// cancelled. Views call it from `.task`, so it ends with the view.
    public func hold(_ rate: TelemetrySampleRate) async {
        demand[rate, default: 0] += 1
        reschedule()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3600)) } catch { break }
        }
        demand[rate, default: 1] -= 1
        reschedule()
    }

    /// Pause in the background; resume in the foreground.
    public func setForeground(_ active: Bool) {
        guard active != foreground else { return }
        foreground = active
        reschedule()
    }

    public func select(device registryID: UInt64) {
        Task { await sampler.select(registryID) }
    }

    /// One refresh now, whatever the rate (tests, previews, snapshots).
    public func refreshNow() async {
        state = await sampler.refresh()
        state.sampleRate = sampleRate
    }

    private func reschedule() {
        let rate = sampleRate
        state.sampleRate = rate
        loop?.cancel()
        loop = nil
        guard let interval = rate.interval else { return }
        loop = Task { [weak self, sampler] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                let next = await sampler.refresh()
                guard let self, !Task.isCancelled else { return }
                var updated = next
                updated.sampleRate = rate
                self.state = updated
                deadline = deadline.advanced(by: interval)
                if deadline < clock.now { deadline = clock.now }
                do { try await Task.sleep(until: deadline, clock: clock) } catch { return }
            }
        }
    }
}
