import SwiftUI
import Observation
import StudioCore
import StudioDesign
import StudioTelemetry

/// GPU state for the status bar and the GPU sidebar: the driver monitor
/// (installed, enabled, matched), the engine (starting, ready, failed) and
/// StudioTelemetry's live readout from the driver's observer client.
@MainActor
@Observable
final class StudioTelemetryProvider: TelemetryProviding {
    let id = "com.geramyloveless.LemonSeedStudio.telemetry"
    let displayName = "GPU monitor (StudioTelemetry)"
    let driver: DriverMonitor
    let engine: EngineService
    let service: TelemetryService

    @ObservationIgnored private var sampling: Task<Void, Never>?

    init(driver: DriverMonitor, engine: EngineService) {
        self.driver = driver
        self.engine = engine
        #if targetEnvironment(simulator)
        service = TelemetryService.fixture()
        #else
        service = TelemetryService(directory: IOKitObserverDirectory(), driverEnabled: { DriverMonitor.queryEnabled() })
        #endif
        // The status-bar pill samples at the widget rate for the app's life;
        // the GPU screen raises the rate while it is visible.
        sampling = Task { [service] in await service.hold(.widget) }
    }

    var engineState: EngineState {
        switch engine.phase {
        case .ready:
            return .ready(engine.launch?.modelName ?? "engine running")
        case .loading:
            return .initializing(engine.statusLine)
        case .failed(let why):
            if driver.service != nil { return .faulted(why) }
            return driver.engineState
        case .stopping:
            return .initializing("Stopping")
        case .idle, .waiting:
            if service.state.availability.isLive, let name = driver.service?.className {
                return .ready("GPU up (\(name)); engine stopped")
            }
            return driver.engineState
        }
    }

    var summary: StudioCore.GPUSummary? {
        let state = service.state
        guard state.availability.isLive else { return nil }
        let s = state.summary
        return StudioCore.GPUSummary(
            loadPercent: s.load,
            vramUsedBytes: s.vram.map { UInt64($0.used * 1_073_741_824) },
            vramTotalBytes: s.vram.map { UInt64($0.total * 1_073_741_824) },
            junctionTemperatureC: s.temperature,
            powerWatts: s.power,
            source: state.sourceName)
    }

    /// The GPU's VRAM as last read from the driver (sysfs mem_info_vram_total
    /// through the observer client). Remembered between launches so the load
    /// settings can check the fit before the engine starts the GPU.
    var vramTotalBytes: UInt64? {
        if let total = summary?.vramTotalBytes, total > 0 {
            if UserDefaults.standard.object(forKey: "gpu.vramTotalBytes") as? UInt64 != total {
                UserDefaults.standard.set(total, forKey: "gpu.vramTotalBytes")
            }
            return total
        }
        return (UserDefaults.standard.object(forKey: "gpu.vramTotalBytes") as? NSNumber)?.uint64Value
    }

    func refresh() {
        driver.refresh()
        Task { await service.refreshNow() }
    }

    func makeGPUView(context: (any WorkspaceContext)?) -> AnyView {
        AnyView(GPUHubView(provider: self))
    }
}

/// The GPU sidebar (and the GPU window): live monitor, engine, diagnostics.
struct GPUHubView: View {
    enum Page: String, CaseIterable, Identifiable {
        case monitor = "Monitor", engine = "Engine", diagnostics = "Diagnostics"
        var id: String { rawValue }
    }

    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let provider: StudioTelemetryProvider

    private var page: Binding<Page> {
        Binding(get: { Page(rawValue: app.gpuPage) ?? .engine }, set: { app.gpuPage = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("GPU", selection: page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.s)
            .accessibilityIdentifier("gpu.page")
            Group {
                switch page.wrappedValue {
                case .monitor:
                    AdaptiveGPUMonitor(provider: provider)
                case .engine:
                    ScrollView {
                        EnginePanel(provider: provider)
                            .padding(.horizontal, Space.m)
                            .padding(.bottom, Space.l)
                    }
                case .diagnostics:
                    DiagnosticsScreen(engine: provider.engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


/// GPU › Monitor. StudioTelemetry's full screen needs at least 640 points
/// for its one-column layout without clipping; narrower (the sidebar) shows
/// its sidebar card and the key readouts instead, with the full monitor one
/// tap away in a page sheet.
struct AdaptiveGPUMonitor: View {
    static let fullWidth: CGFloat = 640
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let provider: StudioTelemetryProvider

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= Self.fullWidth {
                GPUMonitorView(service: provider.service)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        GPUStatusWidget(service: provider.service, style: .card) { app.isGPUMonitorPresented = true }
                        readouts
                        Button {
                            app.isGPUMonitorPresented = true
                        } label: {
                            Label("Open GPU Monitor", systemImage: "rectangle.expand.vertical")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.studioSecondary)
                        .accessibilityIdentifier("gpu.openMonitor")
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.bottom, Space.l)
                    .frame(width: geo.size.width, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gpu.monitor")
    }

    /// The numbers the card leaves out, as wrapping label/value rows.
    @ViewBuilder private var readouts: some View {
        let state = provider.service.state
        let s = state.summary
        VStack(alignment: .leading, spacing: Space.s) {
            row("Availability", availability(state.availability))
            if let vram = s.vram {
                row("VRAM", String(format: "%.1f of %.1f GiB (%.0f%%)", vram.used, vram.total, vram.fraction * 100))
            }
            if let p = s.power {
                row("Power", String(format: "%.0f W", p) + (s.powerCap.map { String(format: " of %.0f W cap", $0) } ?? ""))
            }
            if let t = s.temperature {
                row(s.temperatureLabel.map { "Temperature (\($0))" } ?? "Temperature",
                    String(format: "%.0f °C", t) + (s.temperatureLimit.map { String(format: ", limit %.0f °C", $0) } ?? ""))
            }
            if let held = provider.engine.deviceBytes, provider.engine.phase == .ready {
                row("Engine holds", ByteCountFormatter.string(fromByteCount: Int64(held.live), countStyle: .memory))
            }
            row("Source", state.sourceName)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedSurface()
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.studio(type.micro + 1, weight: .semibold))
                .foregroundStyle(theme.palette.textTertiary.color)
            Text(value)
                .font(.system(size: type.caption, design: .monospaced))
                .foregroundStyle(theme.palette.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func availability(_ a: TelemetryAvailability) -> String {
        switch a {
        case .live: "live"
        case .starting: "starting"
        case .driverNotEnabled: "driver not enabled"
        case .noDevice: "no GPU bound to the driver"
        case .notRunning(let why): "not running: \(why)"
        case .unsupported(let why): "unsupported: \(why)"
        case .error(let why): "error: \(why)"
        }
    }
}

/// The full GPU monitor in a page sheet (and in its own window).
struct GPUMonitorSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            Group {
                if let provider = app.services.telemetry as? StudioTelemetryProvider {
                    GPUMonitorView(service: provider.service)
                } else {
                    app.services.telemetry.makeGPUView(context: nil)
                }
            }
            .navigationTitle("GPU Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { app.isGPUMonitorPresented = false }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gpu.monitorSheet")
    }
}
