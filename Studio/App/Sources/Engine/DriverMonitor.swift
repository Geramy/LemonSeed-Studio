import SwiftUI
import Observation
import SystemExtensions
import StudioCore
import StudioDesign
import StudioTelemetry
import os

private let driverLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "driver")

/// Watches the embedded GPU driver: whether this build carries the dext,
/// whether it is enabled in Settings › General › Drivers, and whether its
/// "MacLinuxGPU" service is running (IOServiceGetMatchingServices with
/// IOServiceNameMatching, as the proof of life does). It never opens the
/// device.
@MainActor
@Observable
final class DriverMonitor {
    nonisolated static let serviceName = "MacLinuxGPU"
    nonisolated static let dextBundleID = "com.geramyloveless.LemonSeedStudio.AMDGpuDriver"

    struct Service: Equatable {
        var className: String
        var registryID: UInt64
        var userServerName: String
        var matchCount: Int
    }

    /// "1.0 (12)" when the dext is in the bundle, nil when this build has none.
    private(set) var embeddedDext: String?
    /// From OSSystemExtensionsWorkspace; nil when it cannot tell.
    private(set) var isEnabled: Bool?
    private(set) var service: Service?
    private(set) var lookupError: String?
    private(set) var lastChecked: Date?

    /// Called after every refresh (the driver's service appeared or went).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var notifyPort: IONotificationPortRef?
    @ObservationIgnored private var iterators: [io_iterator_t] = []

    init() {
        refresh()
        watch()
    }

    var engineState: EngineState {
        if let service {
            return .deviceMatched("\(service.className) · registry 0x\(String(service.registryID, radix: 16))")
        }
        if embeddedDext == nil { return .unknown }
        if isEnabled == false { return .driverNotEnabled }
        // Enabled, or unknown (the system did not say): the driver is not
        // running, which also happens after a new build is installed until
        // the GPU is reconnected.
        return .noDevice
    }

    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    func refresh() {
        embeddedDext = Self.describeEmbeddedDext()
        isEnabled = Self.queryEnabled()
        lookup()
        lastChecked = Date()
        onChange?()
    }

    // MARK: Bundle

    static func describeEmbeddedDext() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("SystemExtensions/\(dextBundleID).dext")
        guard let bundle = Bundle(url: url) else { return nil }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: Enablement

    nonisolated static func queryEnabled() -> Bool? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        do {
            let extensions = try OSSystemExtensionsWorkspace.shared.systemExtensions(forApplicationWithBundleID: bundleID)
            guard let ours = extensions.first(where: { $0.bundleIdentifier == dextBundleID }) else { return nil }
            return ours.isEnabled
        } catch {
            driverLog.error("system extension query failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #endif
    }

    // MARK: IOKit

    private func lookup() {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching(Self.serviceName), &iterator)
        guard kr == KERN_SUCCESS else {
            service = nil
            lookupError = String(format: "IOServiceGetMatchingServices failed: 0x%08x", UInt32(bitPattern: kr))
            return
        }
        defer { IOObjectRelease(iterator) }
        lookupError = nil
        var first: io_service_t = 0
        var count = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            count += 1
            if first == 0 { first = entry } else { IOObjectRelease(entry) }
        }
        guard first != 0 else {
            service = nil
            return
        }
        defer { IOObjectRelease(first) }
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(first, &registryID)
        var name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(first, &name)
        let server = IORegistryEntryCreateCFProperty(first, "IOUserServerName" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? "unknown"
        let className = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        service = Service(className: className, registryID: registryID, userServerName: server, matchCount: count)
        driverLog.log("driver service found: registry \(registryID)")
    }

    /// Match and terminate notifications keep the state current as the
    /// driver is enabled or the GPU is plugged in or out.
    private func watch() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            guard let refcon else { return }
            let monitor = Unmanaged<DriverMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(port, type, IOServiceNameMatching(Self.serviceName), callback, context, &iterator)
            if kr == KERN_SUCCESS {
                while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
                iterators.append(iterator)
            }
        }
    }
}

/// The app's built-in telemetry provider until the telemetry package plugs
/// in: engine state from the driver monitor, no GPU numbers ("n/a").
@MainActor
@Observable
final class DriverTelemetryProvider: TelemetryProviding {
    let id = "com.geramyloveless.LemonSeedStudio.driver-state"
    let displayName = "GPU driver state"
    let driver: DriverMonitor

    init(driver: DriverMonitor) {
        self.driver = driver
    }

    var engineState: EngineState { driver.engineState }
    var summary: StudioCore.GPUSummary? { nil }

    func refresh() { driver.refresh() }

    func makeGPUView(context: (any WorkspaceContext)?) -> AnyView {
        AnyView(ScrollView { EngineStatusView(driver: driver).padding(.horizontal, Space.m).padding(.bottom, Space.l) })
    }
}

/// The engine status panel: the driver and device state machine, with the
/// next step for each state.
struct EngineStatusView: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let driver: DriverMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            stateCard
            detailsCard
            Button {
                driver.refresh()
            } label: {
                Label("Check Again", systemImage: StudioSymbol.refresh)
            }
            .buttonStyle(.studioSecondary)
            .accessibilityIdentifier("engine.refresh")
            if let checked = driver.lastChecked {
                Text("Checked \(checked.formatted(date: .omitted, time: .standard))")
                    .font(.studio(type.micro + 1))
                    .foregroundStyle(theme.palette.textTertiary.color)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("engine.status")
    }

    private var stateCard: some View {
        let (symbol, color, title, message) = presentation
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(color)
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.studio(type.body + 1, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary.color)
            }
            Text(message)
                .font(.studio(type.caption + 0.5))
                .foregroundStyle(theme.palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(color.opacity(0.25), lineWidth: 1))
        .accessibilityIdentifier("engine.state")
    }

    private var presentation: (String, Color, String, String) {
        let p = theme.palette
        switch driver.engineState {
        case .deviceMatched(let detail):
            return ("checkmark.seal.fill", p.success.color, "Driver running",
                    "The MacLinuxGPU service matched an AMD GPU (\(detail)). The engine starts the GPU when it loads a model.")
        case .driverNotEnabled:
            return ("switch.2", p.warning.color, "Enable the driver",
                    "Open Settings › General › Drivers (or Settings › Apps › LemonSeed Studio › Drivers) and turn on LemonSeed Studio's AMD GPU driver.")
        case .noDevice:
            return ("cable.connector", p.info.color, "GPU driver not running",
                    "The driver is not running. Check that it is on in Settings › General › Drivers and that the powered enclosure is connected to the Thunderbolt port (through a dock: a Thunderbolt downstream port). After installing a new build, unplug the GPU and plug it back in so the updated driver starts.")
        case .unknown:
            if driver.isSimulator {
                return ("ipad.landscape", p.textTertiary.color, "Simulator build",
                        "The GPU driver ships only in iPad device builds. On an iPad, enable it in Settings › General › Drivers. Everything else in the Studio works without it.")
            }
            return ("questionmark.circle", p.textTertiary.color, "Driver not included",
                    "This build does not embed the GPU driver. Everything else in the Studio works without it.")
        case .initializing(let detail):
            return ("hourglass", p.warning.color, "Starting the GPU", detail)
        case .ready(let detail):
            return ("bolt.fill", p.success.color, "GPU ready", detail)
        case .quarantined(let cause):
            return ("exclamationmark.shield.fill", p.error.color, "GPU quarantined", cause)
        case .faulted(let cause):
            return ("xmark.octagon.fill", p.error.color, "GPU fault", cause)
        case .disconnected(let detail):
            return ("cable.connector.slash", p.warning.color, "GPU disconnected", detail)
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            row("Embedded driver", driver.embeddedDext.map { "\(DriverMonitor.dextBundleID) \($0)" } ?? "not in this build")
            row("Enabled in Settings", driver.isEnabled.map { $0 ? "yes" : "no" } ?? "n/a")
            row("Service “\(DriverMonitor.serviceName)”", driver.service.map {
                "\($0.className), registry 0x\(String($0.registryID, radix: 16)), \($0.matchCount) match\($0.matchCount == 1 ? "" : "es")"
            } ?? (driver.lookupError ?? "not running"))
            if let server = driver.service?.userServerName {
                row("Driver process", server == DriverMonitor.dextBundleID ? server
                    : server == "unknown" ? "\(DriverMonitor.dextBundleID) (its registry properties are hidden from apps)"
                    : "\(server) (not this app's driver)")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedSurface()
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.studio(type.micro + 1, weight: .semibold))
                .foregroundStyle(theme.palette.textTertiary.color)
            Text(value)
                .font(.system(size: type.caption, design: .monospaced))
                .foregroundStyle(theme.palette.textPrimary.color)
                .textSelection(.enabled)
        }
    }
}

/// The GPU monitor in its own window (Stage Manager, external display).
struct GPUMonitorWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            Group {
                if let provider = app.services.telemetry as? StudioTelemetryProvider {
                    GPUMonitorView(service: provider.service)
                } else {
                    app.services.telemetry.makeGPUView(context: nil)
                }
            }
                .navigationTitle("GPU")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: StudioSymbol.refresh) { app.services.telemetry.refresh() }
                    }
                }
        }
        .modifier(StudioEnvironment())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gpu.monitorWindow")
        .onActiveWindowScene { scene in
            app.replaceRestoredGPUMonitorIfResetting(scene.session) { openWindow(id: StudioScenes.workspace) }
        }
    }
}

