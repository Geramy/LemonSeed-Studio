import SwiftUI

/// The lemon outline: an ellipse drawn to a point at each end, with small nubs.
public struct LemonShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.0, 0.5))
        path.addLine(to: p(0.05, 0.47))
        path.addCurve(to: p(0.5, 0.04), control1: p(0.09, 0.2), control2: p(0.27, 0.04))
        path.addCurve(to: p(0.95, 0.47), control1: p(0.73, 0.04), control2: p(0.91, 0.2))
        path.addLine(to: p(1.0, 0.5))
        path.addLine(to: p(0.95, 0.53))
        path.addCurve(to: p(0.5, 0.96), control1: p(0.91, 0.8), control2: p(0.73, 0.96))
        path.addCurve(to: p(0.05, 0.53), control1: p(0.27, 0.96), control2: p(0.09, 0.8))
        path.closeSubpath()
        return path
    }
}

/// A leaf: two arcs meeting at points.
public struct LeafShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX, y: rect.maxY)
        let end = CGPoint(x: rect.maxX, y: rect.minY)
        path.move(to: start)
        path.addQuadCurve(to: end, control: CGPoint(x: rect.minX + rect.width * 0.05, y: rect.minY + rect.height * 0.05))
        path.addQuadCurve(to: start, control: CGPoint(x: rect.maxX - rect.width * 0.05, y: rect.maxY - rect.height * 0.05))
        path.closeSubpath()
        return path
    }
}

/// The LemonSeed mark: a tilted lemon with a leaf, in the theme's accent.
public struct LemonMark: View {
    @Environment(\.theme) private var theme
    private let size: CGFloat

    public init(size: CGFloat = 28) {
        self.size = size
    }

    public var body: some View {
        let fill = theme.palette.accentFill
        ZStack {
            LemonShape()
                .fill(LinearGradient(colors: [fill.mixed(with: RGBA(0xFFFFFF), 0.35).color, fill.color,
                                              fill.mixed(with: RGBA(0xC07A00), 0.35).color],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size * 0.7)
                .overlay {
                    // A soft highlight along the upper curve.
                    LemonShape()
                        .trim(from: 0.12, to: 0.36)
                        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: max(1, size / 18), lineCap: .round))
                        .padding(size * 0.1)
                        .frame(width: size, height: size * 0.7)
                }
            LeafShape()
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.8, blue: 0.35), Color(red: 0.25, green: 0.6, blue: 0.3)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.34, height: size * 0.26)
                .offset(x: size * 0.3, y: -size * 0.33)
        }
        .rotationEffect(.degrees(-24))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
