import SwiftUI
import StudioCore
import StudioDesign
import StudioModels

/// GPU › Engine: driver state, the engine (model, load settings, start and
/// stop, last generation speed) and its log.
struct EnginePanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let provider: StudioTelemetryProvider
    @State private var showLog = false

    private var engine: EngineService { provider.engine }
    private var gpu: GPUCoordinator { app.gpu }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            engineCard
            if let timings = engine.lastTimings { timingsCard(timings) }
            EngineStatusView(driver: provider.driver)
            logCard
        }
        .task {
            while !Task.isCancelled {
                if engine.phase == .ready { engine.refreshTimings() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("engine.panel")
    }

    // MARK: Engine

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: Space.s + 2) {
            HStack(spacing: Space.s) {
                StatusDot(phaseColor, live: engine.phase == .ready)
                Text("LemonSeed Engine")
                    .font(.studio(type.body + 1, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary.color)
                Spacer()
                Text(EngineService.engineVersion)
                    .font(.system(size: type.micro + 1, design: .monospaced))
                    .foregroundStyle(theme.palette.textTertiary.color)
            }
            Text(engine.statusLine)
                .font(.studio(type.caption + 0.5))
                .foregroundStyle(phaseTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("engine.statusLine")
            if case .loading = engine.phase {
                if let p = engine.loadProgress {
                    ProgressView(value: p).tint(theme.palette.accent.color)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(theme.palette.accent.color)
                }
            }

            Divider().overlay(theme.palette.hairline.color)

            modelRow
            if let launch = engine.launch ?? gpu.currentLaunch() {
                settingsSummary(launch)
            }

            HStack(spacing: Space.s) {
                switch engine.phase {
                case .ready:
                    Button { engine.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.studioSecondary)
                        .accessibilityIdentifier("engine.stop")
                    Button {
                        if let launch = gpu.currentLaunch() { engine.reload(launch) }
                    } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .buttonStyle(.studioSecondary)
                        .accessibilityIdentifier("engine.reload")
                case .loading, .stopping:
                    Button { engine.stop() } label: { Label("Stop", systemImage: "stop") }
                        .buttonStyle(.studioSecondary)
                default:
                    Button { gpu.startIfPossible() } label: {
                        Label("Start", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.studioPrimary)
                    .disabled(!EngineService.isAvailable || gpu.selectedModel == nil)
                    .accessibilityIdentifier("engine.start")
                }
                Spacer()
                if let model = gpu.selectedModel {
                    Button { app.loadSettingsModelID = model.id } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.studioSecondary)
                        .accessibilityIdentifier("engine.loadSettings")
                }
            }
            Toggle(isOn: Binding(get: { engine.autoStart }, set: { engine.autoStart = $0 })) {
                Text("Start the engine when the app opens")
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.textSecondary.color)
            }
            .tint(theme.palette.accent.color)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedSurface()
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Model")
                .font(.studio(type.micro + 1, weight: .semibold))
                .foregroundStyle(theme.palette.textTertiary.color)
            if gpu.mainModels.isEmpty {
                Text("none installed")
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.textSecondary.color)
            } else {
                Picker("Model", selection: Binding(get: { gpu.selectedModel?.id ?? "" },
                                                   set: { gpu.selectedModelID = $0 })) {
                    ForEach(gpu.mainModels) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .lineLimit(1)
                .tint(theme.palette.accent.color)
                .accessibilityIdentifier("engine.model")
            }
        }
    }

    private func settingsSummary(_ launch: EngineLaunch) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            summaryRow("Draft", launch.draftID.map { "DFlash2 · \($0)" } ?? (launch.mtpEnabled ? "MTP depth \(launch.mtpDepth)" : "none"))
            summaryRow("K/V cache", "\(launch.kvCacheDType) · \(launch.kvLength.formatted()) tokens")
            summaryRow("Batch", "\(launch.batchSize) / ubatch \(launch.ubatchSize)")
            summaryRow("Sampling", launch.temperature.map { String(format: "temperature %.2f", $0) } ?? "model default")
            if let total = provider.vramTotalBytes {
                summaryRow("GPU VRAM", ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory)
                           + (provider.summary == nil ? " (last reading)" : ""))
            }
            if let seconds = engine.loadSeconds {
                summaryRow("Load time", String(format: "%.1f s", seconds))
            }
            if let held = engine.deviceBytes, engine.phase == .ready {
                summaryRow("Engine VRAM", ByteCountFormatter.string(fromByteCount: Int64(held.live), countStyle: .memory)
                           + " (peak " + ByteCountFormatter.string(fromByteCount: Int64(held.peak), countStyle: .memory) + ")")
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.studio(type.micro + 1, weight: .semibold))
                .foregroundStyle(theme.palette.textTertiary.color)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(size: type.caption, design: .monospaced))
                .foregroundStyle(theme.palette.textPrimary.color)
                .lineLimit(2)
        }
    }

    private func timingsCard(_ t: EngineTimings) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Last generation")
                .font(.studio(type.caption, weight: .semibold))
                .foregroundStyle(theme.palette.textTertiary.color)
            HStack(spacing: Space.l) {
                metric(t.decodePerSecond.map { String(format: "%.1f", $0) } ?? "n/a", "decode tok/s")
                metric(t.promptPerSecond.map { String(format: "%.0f", $0) } ?? "n/a", "prefill tok/s")
                metric(t.acceptance.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a", "draft accept")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedSurface()
        .accessibilityIdentifier("engine.timings")
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: type.body + 4, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.palette.textPrimary.color)
            Text(label)
                .font(.studio(type.micro + 1))
                .foregroundStyle(theme.palette.textTertiary.color)
        }
    }

    private var logCard: some View {
        DisclosureGroup(isExpanded: $showLog) {
            ScrollView {
                Text(engine.log.suffix(300).joined(separator: "\n"))
                    .font(.system(size: type.micro + 1, design: .monospaced))
                    .foregroundStyle(theme.palette.textSecondary.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        } label: {
            Text("Engine log (\(engine.log.count) lines)")
                .font(.studio(type.caption, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary.color)
        }
        .tint(theme.palette.textSecondary.color)
        .padding(Space.m)
        .elevatedSurface()
    }

    private var phaseColor: Color {
        switch engine.phase {
        case .ready: theme.palette.success.color
        case .loading, .stopping, .waiting: theme.palette.warning.color
        case .failed: theme.palette.error.color
        case .idle: theme.palette.textTertiary.color
        }
    }

    private var phaseTextColor: Color {
        if case .failed = engine.phase { return theme.palette.error.color }
        return theme.palette.textSecondary.color
    }
}

/// GPU › Diagnostics: the proof-of-life probe and bring-up report, with the
/// engine's state on top.
struct DiagnosticsScreen: View {
    let engine: EngineService

    var body: some View {
        #if LEMONSEED_DEVICE
        ProbeDiagnosticsView(engineActive: engineActive,
                             engineSection: AnyView(EngineDiagnosticsSection(engine: engine)),
                             extraReport: { "\n\n" + DiagnosticsReport.engine(engine) })
            .environmentObject(ProbeModel.shared)
        #else
        StudioEmptyState(symbol: StudioSymbol.gpu, title: "Diagnostics need an iPad",
                         message: "The driver probe and GPU bring-up run only in device builds.")
        #endif
    }

    private var engineActive: Bool {
        switch engine.phase {
        case .loading, .ready, .stopping: true
        default: false
        }
    }
}

private struct EngineDiagnosticsSection: View {
    let engine: EngineService

    var body: some View {
        Section("Engine") {
            LabeledContent("Engine", value: EngineService.engineVersion)
            LabeledContent("State", value: engine.statusLine)
            if let launch = engine.launch {
                LabeledContent("Model", value: launch.modelID)
                LabeledContent("Draft", value: launch.draftID ?? "none")
                LabeledContent("K/V", value: "\(launch.kvCacheDType) × \(launch.kvLength)")
            }
            if let seconds = engine.loadSeconds {
                LabeledContent("Load", value: String(format: "%.1f s", seconds))
            }
        }
    }
}

enum DiagnosticsReport {
    @MainActor
    static func engine(_ engine: EngineService) -> String {
        var lines = ["== Engine ==", "engine: \(EngineService.engineVersion)", "state: \(engine.statusLine)"]
        if let l = engine.launch {
            lines.append("model: \(l.modelID) draft: \(l.draftID ?? "none") kv: \(l.kvCacheDType)/\(l.kvLength) batch: \(l.batchSize)/\(l.ubatchSize)")
        }
        if let data = try? JSONSerialization.data(withJSONObject: engine.status(), options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            lines.append("status: \(text)")
        }
        lines.append("== Engine log (last 60) ==")
        lines.append(contentsOf: engine.log.suffix(60))
        return lines.joined(separator: "\n")
    }
}
