// StudioTelemetry demo: the GPU screen and widgets on recorded fixtures.

import StudioTelemetry
import SwiftUI

@main
struct TelemetryDemoApp: App {
    @State private var model = DemoModel()

    var body: some Scene {
        WindowGroup {
            DemoRoot(model: model)
                .preferredColorScheme(model.theme.scheme)
        }
    }
}

enum DemoTheme: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

enum DemoScenario: String, CaseIterable, Identifiable {
    case live, notRunning, noDevice, driverNotEnabled, predatesObserverReads
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live replay"
        case .notRunning: "No GPU session"
        case .noDevice: "No GPU connected"
        case .driverNotEnabled: "Driver not enabled"
        case .predatesObserverReads: "Older driver"
        }
    }
}

enum DemoLayout: String { case studio, screen, widgets }

@MainActor
@Observable
final class DemoModel {
    var fixture: String
    var scenario: DemoScenario
    var theme: DemoTheme
    let layout: DemoLayout
    let iokit: Bool
    private(set) var service: TelemetryService

    init() {
        let defaults = UserDefaults.standard   // launch arguments: -fixture r9700-load ...
        fixture = defaults.string(forKey: "fixture") ?? ObserverFixture.bundledNames.first ?? "r9700-idle"
        scenario = defaults.string(forKey: "scenario").flatMap(DemoScenario.init(rawValue:)) ?? .live
        theme = defaults.string(forKey: "theme").flatMap(DemoTheme.init(rawValue:)) ?? .system
        layout = defaults.string(forKey: "layout").flatMap(DemoLayout.init(rawValue:)) ?? .studio
        iokit = defaults.string(forKey: "source") == "iokit"
        service = TelemetryService.fixture()
        rebuild()
    }

    func rebuild() {
        if iokit {
            service = TelemetryService(directory: IOKitObserverDirectory())
            return
        }
        guard let f = try? ObserverFixture.bundled(fixture) else { return }
        switch scenario {
        case .live:
            service = TelemetryService(directory: FixtureObserverDirectory(fixture: f))
        case .notRunning:
            service = TelemetryService(directory: FixtureObserverDirectory(fixture: f, scenario: .notRunning))
        case .noDevice:
            service = TelemetryService(directory: FixtureObserverDirectory(fixture: f, scenario: .noDevice))
        case .driverNotEnabled:
            service = TelemetryService(directory: FixtureObserverDirectory(fixture: f, scenario: .noDevice),
                                       driverEnabled: { false })
        case .predatesObserverReads:
            service = TelemetryService(directory: FixtureObserverDirectory(fixture: f, scenario: .predatesObserverReads))
        }
    }
}

struct DemoRoot: View {
    @Bindable var model: DemoModel
    @State private var showScreen = true

    var body: some View {
        switch model.layout {
        case .screen:
            GPUMonitorView(service: model.service).id(ObjectIdentifier(model.service))
        case .widgets:
            widgets
        case .studio:
            studio
        }
    }

    /// The Studio's arrangement in miniature: sidebar card, GPU screen,
    /// status bar pill.
    private var studio: some View {
        NavigationSplitView {
            List {
                Section("Workspace") {
                    Label("Files", systemImage: "folder")
                    Label("Search", systemImage: "magnifyingglass")
                    Label("Source Control", systemImage: "arrow.triangle.branch")
                    Label("GPU", systemImage: "cpu").foregroundStyle(.primary)
                }
                Section("GPU") {
                    GPUStatusWidget(service: model.service, style: .card) { showScreen = true }
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("LemonSeed")
        } detail: {
            VStack(spacing: 0) {
                GPUMonitorView(service: model.service)
                statusBar
            }
            .toolbar { controls }
            .navigationTitle("GPU")
            .navigationBarTitleDisplayMode(.inline)
        }
        .id(ObjectIdentifier(model.service))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label("main", systemImage: "arrow.triangle.branch").font(.system(size: 12))
            Text("Ln 42, Col 7").font(.system(size: 12).monospacedDigit())
            Spacer()
            GPUStatusWidget(service: model.service, style: .pill) { showScreen = true }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.bar)
    }

    private var widgets: some View {
        VStack(spacing: 24) {
            GPUStatusWidget(service: model.service, style: .pill)
            GPUStatusWidget(service: model.service, style: .card).frame(width: 300)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .id(ObjectIdentifier(model.service))
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Recording", selection: $model.fixture) {
                    ForEach(ObserverFixture.bundledNames, id: \.self) { Text($0).tag($0) }
                }
                Picker("Scenario", selection: $model.scenario) {
                    ForEach(DemoScenario.allCases) { Text($0.title).tag($0) }
                }
                Picker("Theme", selection: $model.theme) {
                    ForEach(DemoTheme.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            } label: {
                Label("Demo", systemImage: "slider.horizontal.3")
            }
            .onChange(of: model.fixture) { model.rebuild() }
            .onChange(of: model.scenario) { model.rebuild() }
        }
    }
}
