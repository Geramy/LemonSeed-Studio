// StudioTelemetry: the GPU screen.
//
// amdgpu_mtopg's MacLinuxGPU panels (LinuxViews.swift) for iPad: GPU load,
// memory activity, VRAM/GTT, clocks, sensors, throttling and the PCIe link,
// plus where the data comes from. Three columns in landscape on a 13" iPad,
// two in a half-width window, one in a narrow one; every readout keeps
// mtopg's provenance caption.
//
// MIT License (amdgpu_mtopg); see THIRD_PARTY.md.

import SwiftUI

public struct GPUMonitorView: View {
    private let service: TelemetryService
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    public init(service: TelemetryService) {
        self.service = service
    }

    public var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        let state = service.state
        ZStack {
            theme.page.ignoresSafeArea()
            switch state.availability {
            case .live:
                GPUDashboard(state: state, onSelect: { service.select(device: $0) })
            case .starting:
                ProgressView().controlSize(.large).tint(theme.inkMuted)
            default:
                GPUEmptyStateView(state: state)
            }
        }
        .animation(.smooth(duration: 0.35), value: state.availability)
        .task { await service.hold(.screen) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            service.setForeground(phase != .background)
        }
    }
}

/// The live panels. Separate from GPUMonitorView so previews and snapshot
/// tests can render a fixed state.
public struct GPUDashboard: View {
    public let state: TelemetryState
    var onSelect: (UInt64) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    public init(state: TelemetryState) {
        self.state = state
    }

    init(state: TelemetryState, onSelect: @escaping (UInt64) -> Void) {
        self.state = state
        self.onSelect = onSelect
    }

    private var linux: LinuxSnapshot { state.snapshot }
    private var theme: TelemetryTheme { .forScheme(scheme) }
    private var live: Bool { state.sampleRate != .paused }

    public var body: some View {
        GeometryReader { geo in
            let columns = geo.size.width >= 1000 ? 3 : (geo.size.width >= 640 ? 2 : 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    grid(columns: columns, width: geo.size.width - (columns == 1 ? 28 : 44))
                }
                .padding(.horizontal, columns == 1 ? 14 : 22)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func grid(columns: Int, width: CGFloat) -> some View {
        switch columns {
        case 3:
            let column = max((width - 28) / 3, 0)
            row(height: 300) { loadPanel.frame(width: column * 2 + 14); memoryActivityPanel.frame(width: column) }
            // Balanced columns rather than rows: the sensor list is long.
            HStack(alignment: .top, spacing: 14) {
                stack { vramPanel; throttlePanel; pciePanel }.frame(width: column)
                stack { clocksPanel; sourcePanel }.frame(width: column)
                stack { sensorsPanel }.frame(width: column)
            }
            .fixedSize(horizontal: false, vertical: true)
        case 2:
            row(height: 280) { loadPanel }
            row(height: 280) { memoryActivityPanel; vramPanel }
            row { clocksPanel; sensorsPanel }
            row { throttlePanel; pciePanel }
            row { sourcePanel }
        default:
            VStack(spacing: 14) {
                loadPanel.frame(height: 260)
                memoryActivityPanel.frame(height: 260)
                vramPanel; clocksPanel; sensorsPanel; throttlePanel; pciePanel; sourcePanel
            }
        }
    }

    /// Panels stacked in a column; the last one stretches to the row's height.
    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) { content() }.frame(maxHeight: .infinity, alignment: .top)
    }

    /// Panels side by side, all as tall as the tallest.
    private func row<Content: View>(height: CGFloat? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) { content() }
            .frame(height: height)
            .fixedSize(horizontal: false, vertical: height == nil)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.lemon)
                Image(systemName: "cpu").font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.lemonInk)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.deviceName ?? "AMD GPU")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .help(state.deviceNameSource ?? "")
                Text(identityLine)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 12)
            if state.devices.count > 1 {
                Menu {
                    ForEach(state.devices) { d in
                        Button(d.label) { onSelect(d.registryID) }
                    }
                } label: {
                    Label(state.device?.label ?? "GPU", systemImage: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            StatusBadge(text: linux.status, tone: linux.statusOK ? .good : .warning)
            sourceTag
        }
    }

    private var identityLine: String {
        var parts: [String] = []
        if !linux.deviceLine.isEmpty { parts.append(linux.deviceLine) }
        if !linux.linkLine.isEmpty {
            // pci-sysfs prints "32.0 GT/s PCIe"; say PCIe once in the header.
            parts.append(linux.linkLine.replacingOccurrences(of: " PCIe x", with: " x"))
        }
        if let b = linux.build, b > 0 { parts.append("runtime ABI \(b)") }
        if let p = linux.perfLevel { parts.append("perf level \(p)") }
        if let d = state.device { parts.append("registry \(d.label)") }
        return parts.joined(separator: "  ·  ")
    }

    private var sourceTag: some View {
        let recorded = state.sourceName.hasPrefix("recorded")
        return HStack(spacing: 6) {
            Image(systemName: recorded ? "play.rectangle.on.rectangle" : "dot.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
            Text(recorded ? "Recorded" : "Live")
                .font(.system(size: 12, weight: .semibold))
            Text("\(state.sampleRate.rawValue) Hz").font(.system(size: 12).monospacedDigit())
                .foregroundStyle(theme.inkSecondary)
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .overlay(Capsule().strokeBorder(theme.lemon, lineWidth: 1.5))
        .help(state.sourceName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recorded ? "Recorded" : "Live") data, \(state.sourceName), \(state.sampleRate.rawValue) hertz")
    }

    // MARK: Charts

    private var loadPanel: some View {
        Panel("GPU Load", accessory: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(linux.coreHardware ? "GRBM sampled" : "SMU average")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.inkSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(theme.surfaceRaised))
                    .overlay(Capsule().strokeBorder(theme.hairline))
                HeroReading(value: linux.coreCurrent)
            }
        }) {
            TimeSeriesChart(points: linux.core, capturedAt: state.capturedAt, color: theme.load, live: live,
                            emptyCaption: "No GFX activity sample yet", seriesName: "GPU load")
            SourceCaption(summary: linux.coreSummary, detail: linux.coreDetail)
        }
    }

    private var memoryActivityPanel: some View {
        Panel("Memory Activity", accessory: { HeroReading(value: linux.memoryCurrent) }) {
            TimeSeriesChart(points: linux.memory, capturedAt: state.capturedAt, color: theme.memory, live: live,
                            emptyCaption: "No memory activity sample yet", seriesName: "Memory activity")
            SourceCaption(summary: linux.memorySummary, detail: linux.memoryDetail)
        }
    }

    // MARK: Readouts

    private func usageMeter(_ label: String, _ pair: UsagePair?, color: Color, source: String) -> some View {
        Meter(label: label, value: pair?.used, maxValue: pair?.total,
              text: pair.map { String(format: "%.2f / %.2f GiB", $0.used, $0.total) } ?? "n/a",
              color: color, source: source)
    }

    private var vramPanel: some View {
        Panel("VRAM / GTT", accessory: {
            HeroReading(value: linux.vram.map { $0.fraction * 100 })
        }) {
            VStack(alignment: .leading, spacing: 14) {
                usageMeter("VRAM", linux.vram, color: theme.load, source: "mem_info_vram_used / _total")
                usageMeter("VRAM CPU-visible", linux.visibleVram, color: theme.load, source: "mem_info_vis_vram_used / _total")
                usageMeter("GTT (system memory)", linux.gtt, color: theme.thermal, source: "mem_info_gtt_used / _total")
                if let e = linux.memoryError {
                    SourceCaption(summary: e, warn: true)
                }
                Spacer(minLength: 0)
                SourceCaption(summary: "sysfs mem_info_*: TTM VRAM/GTT manager usage",
                              detail: "The TTM managers' own accounting, read through the observer's SysfsRead. The percentage above is VRAM used over VRAM total.")
            }
        }
    }

    private var clocksPanel: some View {
        Panel("Clocks", accessory: {
            Text("MHz").font(.system(size: 11)).foregroundStyle(theme.inkMuted)
        }) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(linux.clocks) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name.capitalized).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.ink)
                                .frame(width: 70, alignment: .leading)
                            clockValue("cur", row.current)
                            clockValue("avg", row.average)
                            Spacer(minLength: 0)
                        }
                        if !row.levels.isEmpty {
                            LevelChips(levels: row.levels)
                        } else if let e = row.levelsError {
                            Text(e).font(TelemetryFont.source).foregroundStyle(theme.inkMuted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
                SourceCaption(summary: "cur/avg: \(linux.metricsFormat); levels: pp_dpm_sclk/mclk/socclk/fclk, current filled",
                              detail: "gpu_metrics current_* and average_*_frequency, decoded by the blob's own header with the upstream struct layout. Some SMU generations fill current_* from averages; the panel shows what the driver reports. The chips are the pp_dpm_* levels, with upstream's current-level mark filled; S is deep sleep.")
            }
        }
    }

    private func clockValue(_ label: String, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(theme.inkMuted)
            Text(value.map { fmtInt($0) } ?? "n/a")
                .font(TelemetryFont.value)
                .foregroundStyle(value == nil ? theme.inkMuted : theme.ink)
                .contentTransition(.numericText())
        }
        .frame(width: 84, alignment: .leading)
    }

    private var sensorsPanel: some View {
        Panel("Sensors", accessory: {
            Text("hwmon").font(TelemetryFont.source).foregroundStyle(theme.inkMuted)
        }) {
            VStack(alignment: .leading, spacing: 12) {
                if linux.sensors.isEmpty {
                    Text("no hwmon device found").font(TelemetryFont.label).foregroundStyle(theme.inkMuted)
                }
                ForEach(linux.sensors) { row in
                    switch row.kind {
                    case .clock:
                        HStack {
                            Text(row.label).font(TelemetryFont.label).foregroundStyle(theme.inkSecondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(row.text).font(TelemetryFont.value).foregroundStyle(theme.ink)
                                Text(row.source).font(TelemetryFont.source).foregroundStyle(theme.inkMuted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    default:
                        Meter(label: row.label, value: row.value, maxValue: row.maxValue, text: row.text,
                              color: row.kind == .temperature || row.kind == .power ? theme.thermal : theme.load,
                              source: row.source,
                              severity: row.kind == .temperature || row.kind == .power)
                    }
                }
                Spacer(minLength: 0)
                SourceCaption(summary: "hwmon: the driver's own labels; power against power1_cap",
                              detail: "The hwmon directory found by listing hwmon/: temp*_input with the driver's temp*_label and temp*_crit, power1_average/power1_input against power1_cap, fan1_input, in*_input and freq*_input. Units follow the hwmon sysfs ABI.")
            }
        }
    }

    private var throttlePanel: some View {
        Panel("Throttling", accessory: {
            Text("gpu_metrics").font(TelemetryFont.source).foregroundStyle(theme.inkMuted)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                if let bits = linux.throttleIndependent {
                    if linux.throttleActive.isEmpty {
                        StatusBadge(text: "None active", tone: .good)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(linux.throttleActive, id: \.self) { StatusBadge(text: $0, tone: .warning) }
                        }
                    }
                    Text(String(format: "indep_throttle_status  0x%016llx", bits))
                        .font(TelemetryFont.source).foregroundStyle(theme.inkSecondary)
                } else {
                    StatusBadge(text: "indep_throttle_status not reported", tone: .neutral)
                }
                if let raw = linux.throttleRaw {
                    Text(String(format: "throttle_status  0x%08llx", raw))
                        .font(TelemetryFont.source).foregroundStyle(theme.inkSecondary)
                }
                Spacer(minLength: 0)
                SourceCaption(summary: "bit names: SMU_THROTTLER_* (amdgpu_smu.h); throttle_status bits are ASIC-specific",
                              detail: "gpu_metrics indep_throttle_status decoded with the ASIC-independent SMU_THROTTLER_* bits; throttle_status is the raw, ASIC-specific word.")
            }
        }
    }

    private var pciePanel: some View {
        Panel("PCIe Link") {
            VStack(alignment: .leading, spacing: 8) {
                if linux.pcie.isEmpty {
                    Text("link status not reported").font(TelemetryFont.label).foregroundStyle(theme.inkMuted)
                }
                ForEach(linux.pcie) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).font(TelemetryFont.label).foregroundStyle(theme.inkSecondary)
                        Spacer()
                        Text(row.text).font(TelemetryFont.value).foregroundStyle(theme.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !linux.pcieLevels.isEmpty {
                    Text("pp_dpm_pcie").font(TelemetryFont.source).foregroundStyle(theme.inkMuted).padding(.top, 2)
                    LevelChips(levels: linux.pcieLevels, text: { $0.text.replacingOccurrences(of: "GT/s,", with: " GT/s") })
                }
                Spacer(minLength: 0)
                SourceCaption(summary: "endpoint: pci-sysfs current/max_link_*; through Thunderbolt, the card's link to the enclosure",
                              detail: "current_link_speed/width and max_link_* are the card's own link registers, which through Thunderbolt describe the link to the enclosure's bridge, not the whole path to the host. The SMU row is gpu_metrics pcie_link_speed/width.")
            }
        }
    }

    private var sourcePanel: some View {
        Panel("Data Source") {
            VStack(alignment: .leading, spacing: 7) {
                sourceRow("transport", state.sourceName)
                ForEach(state.sourceDetails.filter { $0.label != "fixture" }) { sourceRow($0.label, $0.text) }
                sourceRow("gpu_metrics", linux.metricsFormat.replacingOccurrences(of: "gpu_metrics ", with: ""))
                sourceRow("sampling", "\(state.sampleRate.rawValue) Hz; GRBM ×\(LinuxTransport.grbmSamplesPerRefresh) per refresh; sysfs 1 Hz")
                if let name = state.deviceName, let src = state.deviceNameSource {
                    sourceRow("name", "\(name), from \(src)")
                }
                Spacer(minLength: 0)
                SourceCaption(summary: "read-only observer of MacLinuxGPU (upstream amdgpu sysfs and AMDGPU_INFO), after amdgpu_mtopg",
                              detail: "The observer client never claims PCI, joins a session or touches queues, and the monitor submits no GPU work.")
            }
        }
    }

    private func sourceRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(theme.inkMuted).frame(width: 82, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
