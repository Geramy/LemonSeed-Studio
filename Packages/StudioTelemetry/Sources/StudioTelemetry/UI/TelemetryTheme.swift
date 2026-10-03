// StudioTelemetry: colors and type for the GPU screen.
//
// amdgpu_mtopg's Palette was one dark, btop-style set. The Studio needs a
// light and a dark theme, each stepped for its own surface rather than
// flipped. Series colors take the first three slots of a CVD-validated
// categorical order (blue, orange, aqua: worst adjacent CVD ΔE 9.2 light /
// 9.4 dark); status colors are reserved for state and always ship with an
// icon and a label. Text never wears a series color.
//
// When StudioDesign's tokens land, `TelemetryTheme` maps onto them.

import SwiftUI

public struct TelemetryTheme: Sendable {
    public var page: Color
    public var surface: Color
    public var surfaceRaised: Color
    public var hairline: Color
    public var grid: Color
    public var baseline: Color
    public var ink: Color
    public var inkSecondary: Color
    public var inkMuted: Color
    /// The Studio's lemon accent, for brand and selection (not data).
    public var lemon: Color
    public var lemonInk: Color

    // Series (data marks only).
    public var load: Color
    public var thermal: Color
    public var memory: Color

    // Status (state only; always with an icon and a label).
    public var good = Color(hex: 0x0ca30c)
    public var warning = Color(hex: 0xfab219)
    public var serious = Color(hex: 0xec835a)
    public var critical = Color(hex: 0xd03b3b)

    public static let dark = TelemetryTheme(
        page: Color(hex: 0x0e0e0d), surface: Color(hex: 0x1a1a19), surfaceRaised: Color(hex: 0x242422),
        hairline: Color.white.opacity(0.09), grid: Color(hex: 0x2c2c2a), baseline: Color(hex: 0x4a4a46),
        ink: .white, inkSecondary: Color(hex: 0xc3c2b7), inkMuted: Color(hex: 0x8f8d86),
        lemon: Color(hex: 0xf5d547), lemonInk: Color(hex: 0x1a1600),
        load: Color(hex: 0x3987e5), thermal: Color(hex: 0xd95926), memory: Color(hex: 0x199e70))

    public static let light = TelemetryTheme(
        page: Color(hex: 0xf3f2ee), surface: Color(hex: 0xfcfcfb), surfaceRaised: Color(hex: 0xffffff),
        hairline: Color.black.opacity(0.09), grid: Color(hex: 0xe6e5df), baseline: Color(hex: 0xc3c2b7),
        ink: Color(hex: 0x0b0b0b), inkSecondary: Color(hex: 0x52514e), inkMuted: Color(hex: 0x7c7a74),
        lemon: Color(hex: 0xf2c230), lemonInk: Color(hex: 0x2a2100),
        load: Color(hex: 0x2a78d6), thermal: Color(hex: 0xeb6834), memory: Color(hex: 0x1baf7a))

    public static func forScheme(_ scheme: ColorScheme) -> TelemetryTheme {
        scheme == .dark ? .dark : .light
    }

    /// Severity of a reading against its scale, for meter fills.
    public func severity(_ fraction: Double, base: Color) -> Color {
        switch fraction {
        case ..<0.80: return base
        case ..<0.92: return warning
        default: return critical
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

/// Type ramp: SF Pro for reading, tabular digits for numbers, SF Mono for
/// sources (sysfs paths and register names are code).
enum TelemetryFont {
    static let panelTitle = Font.system(size: 11.5, weight: .semibold).width(.expanded)
    static let hero = Font.system(size: 30, weight: .semibold, design: .default).monospacedDigit()
    static let heroUnit = Font.system(size: 15, weight: .medium)
    static let value = Font.system(size: 13, weight: .medium).monospacedDigit()
    static let label = Font.system(size: 13)
    static let small = Font.system(size: 11.5).monospacedDigit()
    static let source = Font.system(size: 10, design: .monospaced)
    static let axis = Font.system(size: 10).monospacedDigit()
}
