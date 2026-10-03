import SwiftUI

/// The 4 pt grid every Studio dimension sits on.
public enum Grid {
    public static let unit: CGFloat = 4

    /// Rounds up to the next multiple of 4 pt.
    public static func snapUp(_ value: CGFloat) -> CGFloat {
        (value / unit).rounded(.up) * unit
    }

    /// Rounds to the nearest multiple of 4 pt.
    public static func snap(_ value: CGFloat) -> CGFloat {
        (value / unit).rounded() * unit
    }
}

/// Spacing tokens.
public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

/// Corner radii. Concentric by construction: an inset child uses the
/// parent's radius minus the inset.
public enum Radius {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 6
    public static let m: CGFloat = 10
    public static let l: CGFloat = 14
    public static let xl: CGFloat = 20
    public static let capsule: CGFloat = 999
}

/// Input density. `touch` keeps 44 pt hit targets for fingers and Pencil;
/// `pointer` is the compact layout used when a keyboard or trackpad is
/// attached. `automatic` follows the attached hardware.
public enum Density: String, CaseIterable, Identifiable, Sendable, Codable {
    case automatic, touch, pointer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .touch: "Touch"
        case .pointer: "Compact"
        }
    }
}

/// Layout metrics that depend on density. Views read these instead of
/// hard-coding row heights, so the whole window tightens together.
public struct Metrics: Hashable, Sendable {
    /// Minimum interactive target (Apple's 44 pt for touch and Pencil).
    public var hitTarget: CGFloat
    public var rowHeight: CGFloat
    public var tabHeight: CGFloat
    public var toolbarHeight: CGFloat
    public var statusBarHeight: CGFloat
    public var activityBarWidth: CGFloat
    public var iconSize: CGFloat
    public var indent: CGFloat

    public static let touch = Metrics(hitTarget: 44, rowHeight: 36, tabHeight: 40, toolbarHeight: 52,
                                      statusBarHeight: 28, activityBarWidth: 56, iconSize: 18, indent: 16)
    public static let pointer = Metrics(hitTarget: 28, rowHeight: 26, tabHeight: 34, toolbarHeight: 44,
                                        statusBarHeight: 24, activityBarWidth: 48, iconSize: 16, indent: 14)

    public static func `for`(_ resolved: Density) -> Metrics {
        resolved == .touch ? .touch : .pointer
    }
}
