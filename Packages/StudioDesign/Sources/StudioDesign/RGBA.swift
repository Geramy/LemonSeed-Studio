import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A theme color stored as sRGB components, so themes are plain value types
/// that can be compared, serialized and handed to UIKit views (the terminal)
/// as well as SwiftUI.
public struct RGBA: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `RGBA(0xF2D04B)`; an optional alpha in 0...1.
    public init(_ hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (the `#` is optional).
    public init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 6 {
            self.init(UInt32(value))
        } else {
            self.init(UInt32(value >> 8), alpha: Double(value & 0xFF) / 255)
        }
    }

    public func opacity(_ alpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Linear blend towards `other`; `amount` 0 keeps self, 1 gives other.
    public func mixed(with other: RGBA, _ amount: Double) -> RGBA {
        let t = min(max(amount, 0), 1)
        return RGBA(red: red + (other.red - red) * t,
                    green: green + (other.green - green) * t,
                    blue: blue + (other.blue - blue) * t,
                    alpha: alpha + (other.alpha - alpha) * t)
    }

    /// `#RRGGBB`, ignoring alpha.
    public var hexString: String {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    #if canImport(UIKit)
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    #endif

    // MARK: Contrast (WCAG 2.x)

    /// Relative luminance of the opaque color.
    public var luminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The color composited over an opaque background.
    public func composited(over background: RGBA) -> RGBA {
        RGBA(red: red * alpha + background.red * (1 - alpha),
             green: green * alpha + background.green * (1 - alpha),
             blue: blue * alpha + background.blue * (1 - alpha))
    }

    /// WCAG contrast ratio, 1...21, of this color drawn over `background`.
    public func contrast(against background: RGBA) -> Double {
        let fg = composited(over: background).luminance
        let bg = background.luminance
        return (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
    }
}

extension RGBA: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color.Resolved(colorSpace: .sRGB, red: Float(red), green: Float(green),
                       blue: Float(blue), opacity: Float(alpha))
    }
}
