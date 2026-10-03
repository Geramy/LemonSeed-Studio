import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#endif

/// Monospace families for code. SF Mono is the default; JetBrains Mono
/// (OFL-1.1) ships in this package.
public enum CodeFontFamily: String, CaseIterable, Identifiable, Sendable, Codable {
    case sfMono = "sf-mono"
    case jetBrainsMono = "jetbrains-mono"
    case menlo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sfMono: "SF Mono"
        case .jetBrainsMono: "JetBrains Mono"
        case .menlo: "Menlo"
        }
    }

    /// PostScript names for regular, medium, bold and italic, or nil for the
    /// system monospaced design.
    fileprivate var postScriptNames: (regular: String, medium: String, bold: String, italic: String)? {
        switch self {
        case .sfMono: nil
        case .jetBrainsMono: ("JetBrainsMono-Regular", "JetBrainsMono-Medium", "JetBrainsMono-Bold", "JetBrainsMono-Italic")
        case .menlo: ("Menlo-Regular", "Menlo-Regular", "Menlo-Bold", "Menlo-Italic")
        }
    }
}

/// The code font: family and size, with a line height snapped to the 4 pt
/// baseline grid so gutters, carets and rows line up across panes.
public struct CodeFont: Hashable, Sendable {
    public enum Weight: Sendable { case regular, medium, bold }

    public var family: CodeFontFamily
    public var size: CGFloat
    /// Line spacing as a multiple of the size, before snapping.
    public var lineSpacing: CGFloat

    public static let sizeRange: ClosedRange<CGFloat> = 9...28
    public static let `default` = CodeFont(family: .sfMono, size: 14)

    public init(family: CodeFontFamily, size: CGFloat, lineSpacing: CGFloat = 1.5) {
        self.family = family
        self.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        self.lineSpacing = lineSpacing
    }

    /// Line height rounded up to a multiple of 4 pt.
    public var lineHeight: CGFloat {
        Grid.snapUp(size * lineSpacing)
    }

    public func font(_ weight: Weight = .regular, italic: Bool = false) -> Font {
        FontRegistry.registerBundledFonts()
        guard let names = family.postScriptNames else {
            let base = Font.system(size: size, weight: weight.swiftUI, design: .monospaced)
            return italic ? base.italic() : base
        }
        let name = italic ? names.italic : (weight == .bold ? names.bold : weight == .medium ? names.medium : names.regular)
        return .custom(name, fixedSize: size)
    }

    #if canImport(UIKit)
    public func uiFont(_ weight: Weight = .regular) -> UIFont {
        FontRegistry.registerBundledFonts()
        if let names = family.postScriptNames {
            let name = weight == .bold ? names.bold : weight == .medium ? names.medium : names.regular
            if let font = UIFont(name: name, size: size) { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: weight.uiKit)
    }
    #endif
}

private extension CodeFont.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .bold: .semibold
        }
    }

    #if canImport(UIKit)
    var uiKit: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .bold: .semibold
        }
    }
    #endif
}

/// UI type scale. Sizes follow input density: touch sizes when no keyboard
/// or trackpad is attached, tighter "pointer" sizes when one is.
public struct TypeScale: Hashable, Sendable {
    /// Window and panel titles.
    public var title: CGFloat
    /// List rows, tree rows, menus.
    public var body: CGFloat
    /// Tab titles, buttons, field labels.
    public var label: CGFloat
    /// Status bar, breadcrumbs, secondary rows.
    public var caption: CGFloat
    /// Section headers (uppercase, tracked).
    public var micro: CGFloat

    public static let touch = TypeScale(title: 20, body: 15, label: 14, caption: 12.5, micro: 11)
    public static let pointer = TypeScale(title: 17, body: 13, label: 12.5, caption: 11.5, micro: 10)

    public static func `for`(_ density: Density) -> TypeScale {
        density == .touch ? .touch : .pointer
    }
}

public extension Font {
    /// The Studio's UI font: SF Pro at a size from the type scale.
    static func studio(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Uppercase section header style (pair with `.tracking(0.6)`).
    static func studioSection(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    /// Tabular digits for gutters, positions and counters.
    static func studioNumeric(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

/// Registers the fonts bundled in this package with Core Text, once.
public enum FontRegistry {
    private static let registration: Void = {
        guard let folder = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        let fonts = files.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }()

    public static func registerBundledFonts() {
        _ = registration
    }

    /// The bundled font license texts, by file name.
    public static func bundledLicenses() -> [(name: String, text: String)] {
        guard let folder = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { (url.deletingPathExtension().lastPathComponent, $0) }
            }
    }
}
