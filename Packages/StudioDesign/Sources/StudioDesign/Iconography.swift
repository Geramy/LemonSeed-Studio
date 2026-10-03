import SwiftUI

/// SF Symbols used across the Studio, in one place so the icon language
/// stays consistent: outlined at rest, filled when selected.
public enum StudioSymbol {
    public static let explorer = "doc.on.doc"
    public static let search = "magnifyingglass"
    public static let sourceControl = "arrow.triangle.branch"
    public static let agent = "sparkle"
    public static let gpu = "cpu"
    public static let extensions = "puzzlepiece.extension"
    public static let settings = "gearshape"
    public static let terminal = "apple.terminal"
    public static let problems = "exclamationmark.triangle"
    public static let output = "text.alignleft"
    public static let build = "hammer"
    public static let run = "play.fill"
    public static let sidebar = "sidebar.left"
    public static let panel = "rectangle.bottomhalf.inset.filled"
    public static let splitRight = "rectangle.split.2x1"
    public static let splitDown = "rectangle.split.1x2"
    public static let close = "xmark"
    public static let dirty = "circle.fill"
    public static let newFile = "doc.badge.plus"
    public static let newFolder = "folder.badge.plus"
    public static let folder = "folder"
    public static let folderOpen = "folder.fill"
    public static let chevronRight = "chevron.right"
    public static let chevronDown = "chevron.down"
    public static let command = "command"
    public static let palette = "square.grid.2x2"
    public static let error = "xmark.octagon.fill"
    public static let warning = "exclamationmark.triangle.fill"
    public static let info = "info.circle.fill"
    public static let check = "checkmark.circle.fill"
    public static let collapseAll = "arrow.down.right.and.arrow.up.left"
    public static let refresh = "arrow.clockwise"
    public static let projects = "square.stack.3d.up"
    public static let recent = "clock.arrow.circlepath"
    public static let filesApp = "folder.badge.person.crop"
}

/// The icon for a file: an SF Symbol and the tint role it is drawn in.
public struct FileIcon: Hashable, Sendable {
    public enum Tint: Hashable, Sendable {
        case accent, secondary, syntax(SyntaxPalette.Role), state(State)
        public enum State: Hashable, Sendable { case success, warning, error, info }
    }

    public var symbol: String
    public var tint: Tint

    public init(symbol: String, tint: Tint) {
        self.symbol = symbol
        self.tint = tint
    }

    public func color(in theme: Theme) -> Color {
        switch tint {
        case .accent: theme.palette.accent.color
        case .secondary: theme.palette.textSecondary.color
        case .syntax(let role): theme.syntax[role].color
        case .state(.success): theme.palette.success.color
        case .state(.warning): theme.palette.warning.color
        case .state(.error): theme.palette.error.color
        case .state(.info): theme.palette.info.color
        }
    }

    public static let folder = FileIcon(symbol: "folder.fill", tint: .syntax(.function))
    public static let folderOpen = FileIcon(symbol: "folder.fill", tint: .syntax(.function))
    public static let generic = FileIcon(symbol: "doc", tint: .secondary)

    /// The icon for a file name, by well-known name first, then extension.
    public static func forFile(named name: String) -> FileIcon {
        let lower = name.lowercased()
        if let special = byName[lower] { return special }
        if lower.hasPrefix("license") || lower.hasPrefix("copying") { return FileIcon(symbol: "checkmark.seal", tint: .syntax(.attribute)) }
        if lower.hasPrefix("readme") { return FileIcon(symbol: "book.closed", tint: .accent) }
        if lower.hasPrefix(".") && !lower.dropFirst().contains(".") { return FileIcon(symbol: "gearshape", tint: .secondary) }
        let ext = (lower as NSString).pathExtension
        return byExtension[ext] ?? .generic
    }

    private static let byName: [String: FileIcon] = [
        "makefile": FileIcon(symbol: "hammer", tint: .syntax(.preprocessor)),
        "cmakelists.txt": FileIcon(symbol: "triangle", tint: .syntax(.constant)),
        "package.swift": FileIcon(symbol: "shippingbox", tint: .syntax(.constant)),
        "dockerfile": FileIcon(symbol: "shippingbox", tint: .syntax(.function)),
        ".gitignore": FileIcon(symbol: "arrow.triangle.branch", tint: .secondary),
        ".gitmodules": FileIcon(symbol: "arrow.triangle.branch", tint: .secondary),
        ".gitattributes": FileIcon(symbol: "arrow.triangle.branch", tint: .secondary),
        "agents.md": FileIcon(symbol: "sparkle", tint: .accent),
    ]

    private static let byExtension: [String: FileIcon] = {
        var map: [String: FileIcon] = [:]
        func add(_ exts: [String], _ symbol: String, _ tint: Tint) {
            for ext in exts { map[ext] = FileIcon(symbol: symbol, tint: tint) }
        }
        add(["swift"], "swift", .syntax(.constant))
        add(["c"], "c.square", .syntax(.function))
        add(["cc", "cpp", "cxx", "c++"], "c.square.fill", .syntax(.type))
        add(["h", "hh", "hpp", "hxx", "inl"], "h.square", .syntax(.property))
        add(["m", "mm"], "m.square", .syntax(.function))
        add(["iig"], "i.square", .syntax(.preprocessor))
        add(["rs"], "r.square", .syntax(.number))
        add(["py"], "p.square", .syntax(.function))
        add(["js", "mjs", "cjs"], "j.square", .syntax(.preprocessor))
        add(["ts", "tsx"], "t.square", .syntax(.function))
        add(["go"], "g.square", .syntax(.type))
        add(["java", "kt"], "j.square.fill", .syntax(.number))
        add(["loom"], "l.square", .accent)
        add(["cl", "hip", "cu", "metal", "glsl", "vert", "frag", "comp", "spv"], "cpu", .syntax(.keyword))
        add(["json", "jsonc"], "curlybraces", .syntax(.number))
        add(["yml", "yaml", "toml", "ini", "cfg", "conf", "plist", "xcconfig", "entitlements"], "list.bullet.indent", .syntax(.attribute))
        add(["md", "markdown", "rst", "txt"], "doc.text", .secondary)
        add(["html", "htm", "xml", "svg"], "chevron.left.forwardslash.chevron.right", .syntax(.tag))
        add(["css", "scss"], "paintbrush", .syntax(.keyword))
        add(["sh", "bash", "zsh", "fish", "command"], "terminal", .state(.success))
        add(["mk", "cmake", "ninja", "gn", "bazel", "bzl"], "hammer", .syntax(.preprocessor))
        add(["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "ico"], "photo", .syntax(.string))
        add(["pdf"], "doc.richtext", .state(.error))
        add(["zip", "gz", "tgz", "xz", "bz2", "tar", "7z"], "doc.zipper", .secondary)
        add(["csv", "tsv"], "tablecells", .syntax(.string))
        add(["mov", "mp4", "m4v"], "film", .secondary)
        add(["wav", "mp3", "m4a", "aac", "flac"], "waveform", .secondary)
        add(["ttf", "otf", "woff", "woff2"], "textformat", .secondary)
        add(["bin", "o", "a", "dylib", "so", "wasm", "hsaco", "elf"], "cube", .secondary)
        add(["patch", "diff"], "plusminus", .syntax(.string))
        add(["lock"], "lock", .secondary)
        add(["py", "pyi"], "p.square", .syntax(.function))
        return map
    }()
}
