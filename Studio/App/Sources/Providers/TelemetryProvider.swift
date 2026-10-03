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
                    GPUMonitorView(service: provider.service)
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

