// StudioTelemetry: panel chrome, meters, source captions and the rolling chart.
//
// The cross-platform counterparts of amdgpu_mtopg's Views.swift components
// (Panel, TimeSeriesChart, Meter, SourceCaption), without AppKit. The chart
// keeps mtopg's time alignment (each point placed by its age, "now" at the
// right edge, gaps over 3 s break the line, short gaps bridged with a
// Catmull-Rom curve) and adds frame-rate scrolling between samples and a
// scrub crosshair.
//
// MIT License (amdgpu_mtopg); see THIRD_PARTY.md.

import SwiftUI

// MARK: - Panel

struct Panel<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.uppercased())
                    .font(TelemetryFont.panelTitle)
                    .tracking(0.8)
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
    }
}

extension Panel where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// A panel's current reading: large tabular digits, unit beside, "n/a" when
/// the source produced nothing.
struct HeroReading: View {
    let value: Double?
    var unit = "%"
    var places = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if let value, value.isFinite {
                Text(fmt(value, places))
                    .font(TelemetryFont.hero)
                    .foregroundStyle(theme.ink)
                    .contentTransition(.numericText(value: value))
                Text(unit).font(TelemetryFont.heroUnit).foregroundStyle(theme.inkSecondary)
            } else {
                Text("n/a").font(TelemetryFont.hero).foregroundStyle(theme.inkMuted)
            }
        }
        .animation(.snappy(duration: 0.25), value: value)
    }
}

// MARK: - Source caption

/// Names where a readout comes from. The summary is always visible; the
/// detail is the long form (pointer hover, VoiceOver, or tap to expand).
struct SourceCaption: View {
    let summary: String
    var detail: String = ""
    var warn = false
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: warn ? "exclamationmark.triangle.fill" : "scope")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(warn ? theme.serious : theme.inkMuted)
                Text(summary)
                    .font(TelemetryFont.source)
                    .foregroundStyle(theme.inkMuted)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if !detail.isEmpty { withAnimation(.snappy) { expanded.toggle() } } }
        .help(detail.isEmpty ? summary : detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source: \(summary)")
        .accessibilityHint(detail)
    }
}

// MARK: - Meter

/// A labeled horizontal meter. The fill carries severity (series color, then
/// warning, then critical, with an icon); the track is the same hue, faint.
struct Meter: View {
    let label: String
    let value: Double?
    let maxValue: Double?
    let text: String
    var color: Color
    var source: String? = nil
    var severity = false
    @Environment(\.colorScheme) private var scheme

    private var fraction: Double? {
        guard let value, let maxValue, maxValue > 0, value.isFinite else { return nil }
        return min(max(value / maxValue, 0), 1)
    }

    var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        let fill = severity ? theme.severity(fraction ?? 0, base: color) : color
        let alarming = severity && (fraction ?? 0) >= 0.8
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).font(TelemetryFont.label).foregroundStyle(theme.inkSecondary).lineLimit(1)
                if alarming {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(fill)
                        .accessibilityLabel("near limit")
                }
                Spacer(minLength: 6)
                Text(text).font(TelemetryFont.value).foregroundStyle(value == nil && text == "n/a" ? theme.inkMuted : theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(scheme == .dark ? 0.18 : 0.14))
                    if let fraction {
                        Capsule().fill(fill)
                            .frame(width: max(fraction * geo.size.width, fraction > 0 ? 4 : 0))
                    }
                }
            }
            .frame(height: 6)
            .animation(.smooth(duration: 0.45), value: fraction)
            if let source {
                Text(source).font(TelemetryFont.source).foregroundStyle(theme.inkMuted).lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text)
        .accessibilityHint(source.map { "Source: \($0)" } ?? "")
        .help(source ?? label)
    }
}

// MARK: - DPM level chips

/// pp_dpm_* levels as chips, the current one (upstream's "*") filled.
struct LevelChips: View {
    let levels: [DPMLevel]
    var text: (DPMLevel) -> String = { $0.mhz.map { fmtInt($0) } ?? $0.text }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        FlowLayout(spacing: 4) {
            ForEach(levels) { level in
                HStack(spacing: 3) {
                    if level.label == "S" {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 8))
                    }
                    Text(text(level)).font(.system(size: 10.5, weight: level.active ? .semibold : .regular).monospacedDigit())
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundStyle(level.active ? theme.lemonInk : theme.inkSecondary)
                .background(Capsule().fill(level.active ? theme.lemon : theme.surfaceRaised))
                .overlay(Capsule().strokeBorder(level.active ? .clear : theme.hairline, lineWidth: 1))
                .accessibilityLabel("level \(level.label): \(level.text)\(level.active ? ", current" : "")")
            }
        }
    }
}

/// Wraps children onto as many rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    enum Tone { case good, warning, critical, neutral }
    let text: String
    let tone: Tone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        let (color, icon): (Color, String) = switch tone {
        case .good: (theme.good, "checkmark.circle.fill")
        case .warning: (theme.warning, "exclamationmark.triangle.fill")
        case .critical: (theme.critical, "xmark.octagon.fill")
        case .neutral: (theme.inkMuted, "circle.dashed")
        }
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.ink).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(scheme == .dark ? 0.16 : 0.12)))
    }
}

// MARK: - Rolling time-series chart

/// A rolling-window chart of a 0–100 % series. `points` carry their age at
/// `capturedAt`; while `live`, the chart keeps scrolling at the display's
/// frame rate between samples, so 10 Hz data moves smoothly.
struct TimeSeriesChart: View {
    let points: [SeriesPoint]
    let capturedAt: Date
    var windowSeconds: Double = 60
    let color: Color
    let live: Bool
    let emptyCaption: String
    var seriesName: String = ""

    @State private var scrubX: CGFloat?
    @Environment(\.colorScheme) private var scheme

    private var hasData: Bool { points.contains { $0.value != nil } }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !live || !hasData)) { timeline in
            let drift = min(max(timeline.date.timeIntervalSince(capturedAt), 0), 1.5)
            GeometryReader { geo in
                let geometry = ChartGeometry(size: geo.size, window: windowSeconds)
                let shifted = points.map { SeriesPoint(age: $0.age + (live ? drift : 0), value: $0.value) }
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        draw(&context, geometry: geometry, points: shifted)
                    }
                    if let scrubX, hasData, let hit = geometry.nearest(to: scrubX, in: shifted) {
                        crosshair(hit, geometry: geometry)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): scrubX = p.x
                    case .ended: scrubX = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { scrubX = $0.location.x }
                    .onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { scrubX = nil } })
            }
        }
        .overlay {
            if !hasData {
                emptyOverlay
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(seriesName)
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let values = points.compactMap(\.value)
        guard let last = values.last, let lo = values.min(), let hi = values.max() else { return emptyCaption }
        return "now \(fmt(last, 0)) percent; last minute between \(fmt(lo, 0)) and \(fmt(hi, 0)) percent"
    }

    private var emptyOverlay: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        return Text(emptyCaption)
            .font(.system(size: 12))
            .foregroundStyle(theme.inkMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .padding(.leading, ChartGeometry.leftMargin)
            .allowsHitTesting(false)
    }

    private func draw(_ context: inout GraphicsContext, geometry g: ChartGeometry, points: [SeriesPoint]) {
        let theme = TelemetryTheme.forScheme(scheme)
        let plot = g.plot
        guard plot.width > 20, plot.height > 20 else { return }

        // Grid: hairlines at 25 % steps, a firmer baseline.
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = g.y(fraction * 100)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(fraction == 0 ? theme.baseline : theme.grid), lineWidth: 1)
            if fraction == 0 || fraction == 0.5 || fraction == 1 {
                let label = Text("\(Int(fraction * 100))%").font(TelemetryFont.axis).foregroundStyle(theme.inkMuted)
                context.draw(context.resolve(label), at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
            }
        }
        // Time axis.
        for step in 0...4 {
            let age = windowSeconds * Double(step) / 4
            let x = g.x(age: age)
            let text = step == 0 ? "now" : "−\(Int(age))s"
            let label = Text(text).font(TelemetryFont.axis).foregroundStyle(theme.inkMuted)
            let anchor: UnitPoint = step == 0 ? .bottomTrailing : (step == 4 ? .bottomLeading : .bottom)
            context.draw(context.resolve(label), at: CGPoint(x: x, y: g.size.height), anchor: anchor)
        }
        guard points.contains(where: { $0.value != nil }) else { return }

        // In-window finite points, oldest first, split into runs at gaps > 3 s.
        let pts = points.compactMap { p -> (CGPoint, Double)? in
            guard let v = p.value, v.isFinite, p.age <= windowSeconds + 1 else { return nil }
            return (CGPoint(x: g.x(age: p.age), y: g.y(v)), p.age)
        }.sorted { $0.1 > $1.1 }
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        var lastAge: Double?
        for (point, age) in pts {
            if let lastAge, lastAge - age > 3.0 {
                runs.append(current)
                current = []
            }
            current.append(point)
            lastAge = age
        }
        if !current.isEmpty { runs.append(current) }

        var line = Path()
        var area = Path()
        for run in runs {
            guard let first = run.first else { continue }
            if run.count == 1 {
                line.addEllipse(in: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3))
                continue
            }
            line.move(to: first)
            area.move(to: CGPoint(x: first.x, y: plot.maxY))
            area.addLine(to: first)
            for i in 0..<(run.count - 1) {
                let p0 = i > 0 ? run[i - 1] : run[i]
                let p1 = run[i], p2 = run[i + 1]
                let p3 = i + 2 < run.count ? run[i + 2] : p2
                // Catmull-Rom to cubic Bézier, control points kept inside the plot.
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clampY(p1.y + (p2.y - p0.y) / 6, plot))
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clampY(p2.y - (p3.y - p1.y) / 6, plot))
                line.addCurve(to: p2, control1: c1, control2: c2)
                area.addCurve(to: p2, control1: c1, control2: c2)
            }
            area.addLine(to: CGPoint(x: run[run.count - 1].x, y: plot.maxY))
            area.closeSubpath()
        }
        var clipped = context
        clipped.clip(to: Path(plot.insetBy(dx: 0, dy: -2)))
        clipped.fill(area, with: .linearGradient(
            Gradient(colors: [color.opacity(scheme == .dark ? 0.30 : 0.22), color.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
        clipped.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        // The newest point: an 8 pt dot with a surface ring.
        if let newest = pts.last?.0, plot.insetBy(dx: -1, dy: -6).contains(newest) {
            let ring = CGRect(x: newest.x - 6, y: newest.y - 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: ring), with: .color(theme.surface))
            context.fill(Path(ellipseIn: ring.insetBy(dx: 2, dy: 2)), with: .color(color))
        }
    }

    private func clampY(_ y: CGFloat, _ plot: CGRect) -> CGFloat { min(max(y, plot.minY), plot.maxY) }

    @ViewBuilder
    private func crosshair(_ hit: (point: CGPoint, sample: SeriesPoint), geometry g: ChartGeometry) -> some View {
        let theme = TelemetryTheme.forScheme(scheme)
        Path { p in
            p.move(to: CGPoint(x: hit.point.x, y: g.plot.minY))
            p.addLine(to: CGPoint(x: hit.point.x, y: g.plot.maxY))
        }
        .stroke(theme.inkMuted.opacity(0.7), lineWidth: 1)
        .allowsHitTesting(false)
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(theme.surface, lineWidth: 2).padding(-2))
            .position(hit.point)
            .allowsHitTesting(false)
        let onRight = hit.point.x < g.plot.midX
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.sample.value.map { "\(fmt($0, 0)) %" } ?? "n/a")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.ink)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 2)
                Text(seriesName).font(.system(size: 11)).foregroundStyle(theme.inkSecondary)
            }
            Text(String(format: "%.1f s ago", hit.sample.age)).font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.inkMuted)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surfaceRaised)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hairline))
        .fixedSize()
        .position(x: hit.point.x + (onRight ? 70 : -70), y: g.plot.minY + 34)
        .allowsHitTesting(false)
    }
}

/// Maps ages and percentages onto the chart's plot rectangle.
struct ChartGeometry {
    static let leftMargin: CGFloat = 36
    let size: CGSize
    let window: Double

    var plot: CGRect {
        CGRect(x: Self.leftMargin, y: 8, width: max(size.width - Self.leftMargin - 4, 0),
               height: max(size.height - 8 - 20, 0))
    }

    func x(age: Double) -> CGFloat { plot.maxX - plot.width * CGFloat(age / window) }
    func y(_ percent: Double) -> CGFloat { plot.minY + plot.height * CGFloat(1 - min(max(percent / 100, 0), 1)) }

    func nearest(to xPos: CGFloat, in points: [SeriesPoint]) -> (point: CGPoint, sample: SeriesPoint)? {
        let age = Double((plot.maxX - min(max(xPos, plot.minX), plot.maxX)) / max(plot.width, 1)) * window
        guard let best = points.filter({ $0.value != nil && $0.age <= window })
            .min(by: { abs($0.age - age) < abs($1.age - age) }), let v = best.value else { return nil }
        return (CGPoint(x: x(age: best.age), y: y(v)), best)
    }
}
