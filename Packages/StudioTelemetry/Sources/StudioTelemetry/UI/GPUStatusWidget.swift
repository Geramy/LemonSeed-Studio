// StudioTelemetry: the compact GPU readout for the status bar and sidebar.
//
// Load, VRAM, temperature and power, each with its source (pointer hover,
// VoiceOver). Holding the widget keeps sampling at 1 Hz; the GPU screen
// raises it to 10 Hz while visible.

import SwiftUI

public struct GPUStatusWidget: View {
    public enum Style: Sendable { case pill, card }

    private let service: TelemetryService
    private let style: Style
    private let onOpen: (() -> Void)?

    public init(service: TelemetryService, style: Style = .pill, onOpen: (() -> Void)? = nil) {
        self.service = service
        self.style = style
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            switch style {
            case .pill: GPUStatusPill(state: service.state)
            case .card: GPUStatusCard(state: service.state)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .task { await service.hold(.widget) }
    }
}

/// A one-line status-bar pill.
public struct GPUStatusPill: View {
    public let state: TelemetryState
    @Environment(\.colorScheme) private var scheme

    public init(state: TelemetryState) { self.state = state }

    public var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        let s = state.summary
        HStack(spacing: 10) {
            statusDot(theme)
            Text("GPU").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.inkSecondary)
            if state.availability.isLive {
                item(s.load.map { "\(fmt($0, 0))%" }, theme, help: "load: \(s.loadSource)") {
                    MiniBar(fraction: s.load.map { $0 / 100 }, color: theme.load)
                }
                divider(theme)
                item(s.vram.map { String(format: "%.1f/%.0f GiB", $0.used, $0.total) }, theme, help: "VRAM: \(s.vramSource)")
                divider(theme)
                item(s.temperature.map { String(format: "%.0f°C", $0) }, theme, help: "\(s.temperatureLabel ?? "temperature"): \(s.temperatureSource)")
                divider(theme)
                item(s.power.map { String(format: "%.0f W", $0) }, theme, help: "power: \(s.powerSource)")
            } else {
                Text(shortStatus).font(.system(size: 12)).foregroundStyle(theme.inkSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(theme.surface))
        .overlay(Capsule().strokeBorder(theme.hairline))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GPU")
        .accessibilityValue(accessibilityValue)
    }

    private var shortStatus: String {
        switch state.availability {
        case .starting: return "reading…"
        case .driverNotEnabled: return "driver off"
        case .noDevice: return "not connected"
        case .notRunning: return "idle, no session"
        case .unsupported: return "driver update needed"
        case .error: return "unavailable"
        case .live: return ""
        }
    }

    private var accessibilityValue: String {
        guard state.availability.isLive else { return shortStatus }
        let s = state.summary
        return [s.load.map { "load \(fmt($0, 0)) percent" },
                s.vram.map { String(format: "VRAM %.1f of %.0f gibibytes", $0.used, $0.total) },
                s.temperature.map { String(format: "%@ %.0f degrees", s.temperatureLabel ?? "temperature", $0) },
                s.power.map { String(format: "power %.0f watts", $0) }]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func statusDot(_ theme: TelemetryTheme) -> some View {
        let color: Color = switch state.availability {
        case .live: theme.good
        case .notRunning, .starting: theme.inkMuted
        case .driverNotEnabled, .noDevice: theme.inkMuted
        case .unsupported, .error: theme.warning
        }
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private func divider(_ theme: TelemetryTheme) -> some View {
        Rectangle().fill(theme.hairline).frame(width: 1, height: 12)
    }

    private func item(_ text: String?, _ theme: TelemetryTheme, help: String,
                      @ViewBuilder leading: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 5) {
            leading()
            Text(text ?? "n/a")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(text == nil ? theme.inkMuted : theme.ink)
                .contentTransition(.numericText())
        }
        .help(help)
    }
}

/// A sidebar card: four readouts, a load sparkline, the source.
public struct GPUStatusCard: View {
    public let state: TelemetryState
    @Environment(\.colorScheme) private var scheme

    public init(state: TelemetryState) { self.state = state }

    public var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        let s = state.summary
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cpu").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.ink)
                Text(state.deviceName ?? "GPU").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer()
                if !state.availability.isLive {
                    Text(GPUStatusPill(state: state).accessibilityShortStatus)
                        .font(.system(size: 11)).foregroundStyle(theme.inkMuted)
                }
            }
            if state.availability.isLive {
                Sparkline(points: state.snapshot.core, color: theme.load)
                    .frame(height: 34)
                    .accessibilityHidden(true)
                Grid(horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        cell("Load", s.load.map { "\(fmt($0, 0))%" }, s.load.map { $0 / 100 }, theme.load, theme, s.loadSource)
                        cell("VRAM", s.vram.map { String(format: "%.1f GiB", $0.used) }, s.vram?.fraction, theme.load, theme, s.vramSource)
                    }
                    GridRow {
                        cell(s.temperatureLabel.map { $0.capitalized } ?? "Temp", s.temperature.map { String(format: "%.0f °C", $0) },
                             s.temperature.flatMap { t in s.temperatureLimit.map { t / $0 } }, theme.thermal, theme, s.temperatureSource)
                        cell("Power", s.power.map { String(format: "%.0f W", $0) },
                             s.power.flatMap { p in s.powerCap.map { p / $0 } }, theme.thermal, theme, s.powerSource)
                    }
                }
            }
            Text(state.sourceName).font(TelemetryFont.source).foregroundStyle(theme.inkMuted).lineLimit(1)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.hairline))
    }

    private func cell(_ label: String, _ value: String?, _ fraction: Double?, _ color: Color,
                      _ theme: TelemetryTheme, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(theme.inkMuted)
            Text(value ?? "n/a").font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? theme.inkMuted : theme.ink)
                .contentTransition(.numericText())
            MiniBar(fraction: fraction, color: color).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(source)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Source: \(source)")
    }
}

extension GPUStatusPill {
    var accessibilityShortStatus: String { shortStatus }
}

struct MiniBar: View {
    let fraction: Double?
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                if let f = fraction { Capsule().fill(color).frame(width: max(min(f, 1), 0) * geo.size.width) }
            }
        }
        .frame(minWidth: 22, maxHeight: 4)
        .frame(height: 4)
        .animation(.smooth(duration: 0.4), value: fraction)
    }
}

/// A 0–100 % sparkline of the last minute; no axes (the card is a glance).
struct Sparkline: View {
    let points: [SeriesPoint]
    let color: Color
    var window: Double = 60

    var body: some View {
        Canvas { context, size in
            let pts = points.compactMap { p -> CGPoint? in
                guard let v = p.value, p.age <= window else { return nil }
                return CGPoint(x: size.width * CGFloat(1 - p.age / window),
                               y: size.height * CGFloat(1 - min(max(v / 100, 0), 1)))
            }
            guard pts.count > 1 else { return }
            var line = Path()
            line.addLines(pts)
            var area = line
            area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.14)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
