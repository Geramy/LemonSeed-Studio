import SwiftUI
import UIKit
import Observation
import GameController
import StudioCore
import StudioDesign
import StudioModels

/// App-wide state shared by every window: settings, the workspace library,
/// the provider registry, the command registry and input density.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    let library = WorkspaceLibrary.standard()
    let services = StudioServices.shared
    let commands = CommandRegistry()
    let input = InputMonitor()
    let driver = DriverMonitor()
    /// Documents/Models and the Hugging Face catalog (StudioModels).
    let models = ModelLibrary.standard()
    /// LSE in this process, on the GPU the driver serves.
    let engine = EngineService()
    let gpu: GPUCoordinator
    /// The GPU sidebar's page ("Monitor", "Engine", "Diagnostics").
    var gpuPage = UserDefaults.standard.string(forKey: "StudioGPUPage") ?? "Engine"
    /// The model whose load settings sheet is open.
    var loadSettingsModelID: String?
    /// The full Models screen (catalog, downloads, Hugging Face search).
    var isModelsManagerPresented = false
    let keyboard = KeyboardMonitor.shared
    let textInput = TextInputCoordinator.shared
    /// The most recently active window's router: the menu bar's fallback
    /// target when no window has published a focused scene value.
    var activeRouter: SceneRouter?
    /// The launch-argument project opens in the first window only.
    @ObservationIgnored var claimedLaunchProject = false
    @ObservationIgnored private var discardedRestoredWindows = false

    /// With -StudioResetState, starts from a single window: windows restored
    /// from earlier runs (Stage Manager keeps them) are discarded, so
    /// automation always drives the window it launched.
    func discardRestoredWindowsIfResetting() {
        guard LaunchOptions.resetState, !discardedRestoredWindows else { return }
        discardedRestoredWindows = true
        let application = UIApplication.shared
        let keep = application.connectedScenes.first { $0.activationState == .foregroundActive }
            ?? application.connectedScenes.first
        for session in application.openSessions where session != keep?.session {
            application.requestSceneSessionDestruction(session, options: nil)
        }
    }

    private init() {
        gpu = GPUCoordinator(driver: driver, engine: engine, library: models)
        EngineService.shared = engine
        StudioPlugins.register(into: services, settings: settings, driver: driver, engine: engine)
        StudioCommands.register(into: commands)
        FontRegistry.registerBundledFonts()
        SampleContent.installIfRequested(library: library)
        if let forced = LaunchOptions.hardwareKeyboard { keyboard.override = forced }
    }

    /// The density views lay out with (never `.automatic`).
    var resolvedDensity: Density {
        if let forced = LaunchOptions.density { return forced }
        switch settings.density {
        case .automatic: return input.hasPointer || keyboard.hasHardwareKeyboard ? .pointer : .touch
        case .touch, .pointer: return settings.density
        }
    }
}

/// User settings, persisted in UserDefaults. Launch arguments override any
/// key for one run (`-themeID lemon-light`), which screenshots and UI tests use.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var themeID: String { didSet { defaults.set(themeID, forKey: "themeID") } }
    var matchSystemAppearance: Bool { didSet { defaults.set(matchSystemAppearance, forKey: "matchSystemAppearance") } }
    var lightThemeID: String { didSet { defaults.set(lightThemeID, forKey: "lightThemeID") } }
    var darkThemeID: String { didSet { defaults.set(darkThemeID, forKey: "darkThemeID") } }
    var codeFontFamily: CodeFontFamily { didSet { defaults.set(codeFontFamily.rawValue, forKey: "codeFontFamily") } }
    var codeFontSize: Double { didSet { defaults.set(codeFontSize, forKey: "codeFontSize") } }
    var density: Density { didSet { defaults.set(density.rawValue, forKey: "density") } }
    var showActivityBar: Bool { didSet { defaults.set(showActivityBar, forKey: "showActivityBar") } }
    var lseEndpoint: String { didSet { defaults.set(lseEndpoint, forKey: "lseEndpoint") } }
    var editor: EditorSettings {
        didSet { if let data = try? JSONEncoder().encode(editor) { defaults.set(data, forKey: "editorSettings") } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        themeID = defaults.string(forKey: "themeID") ?? Theme.lemonDark.id
        matchSystemAppearance = defaults.object(forKey: "matchSystemAppearance") as? Bool ?? false
        lightThemeID = defaults.string(forKey: "lightThemeID") ?? Theme.lemonLight.id
        darkThemeID = defaults.string(forKey: "darkThemeID") ?? Theme.lemonDark.id
        codeFontFamily = defaults.string(forKey: "codeFontFamily").flatMap(CodeFontFamily.init(rawValue:)) ?? .sfMono
        codeFontSize = defaults.object(forKey: "codeFontSize") as? Double ?? 14
        density = defaults.string(forKey: "density").flatMap(Density.init(rawValue:)) ?? .automatic
        showActivityBar = defaults.object(forKey: "showActivityBar") as? Bool ?? true
        lseEndpoint = defaults.string(forKey: "lseEndpoint") ?? ModelEndpointProbe.defaultEndpoint.absoluteString
        editor = defaults.data(forKey: "editorSettings").flatMap { try? JSONDecoder().decode(EditorSettings.self, from: $0) } ?? EditorSettings()
    }

    func theme(for scheme: ColorScheme) -> Theme {
        if matchSystemAppearance {
            return Theme.named(scheme == .dark ? darkThemeID : lightThemeID) ?? (scheme == .dark ? .lemonDark : .lemonLight)
        }
        return Theme.named(themeID) ?? .lemonDark
    }

    var codeFont: CodeFont {
        CodeFont(family: codeFontFamily, size: codeFontSize)
    }

    var lseEndpointURL: URL {
        URL(string: lseEndpoint.trimmingCharacters(in: .whitespaces)) ?? ModelEndpointProbe.defaultEndpoint
    }

    func adjustFontSize(by delta: Double) {
        codeFontSize = min(max(codeFontSize + delta, CodeFont.sizeRange.lowerBound), CodeFont.sizeRange.upperBound)
    }

    /// Cycles through the built-in themes (⌘K ⌘T's quick switch).
    func cycleTheme() {
        let themes = Theme.builtIn
        let index = themes.firstIndex { $0.id == themeID } ?? 0
        matchSystemAppearance = false
        themeID = themes[(index + 1) % themes.count].id
    }
}

/// Tracks whether a hardware keyboard or a pointer is attached, which
/// switches the automatic density between touch and compact.
@MainActor
@Observable
final class InputMonitor {
    private(set) var hasKeyboard = GCKeyboard.coalesced != nil
    private(set) var hasPointer = GCMouse.current != nil

    var hasPointerOrKeyboard: Bool { hasKeyboard || hasPointer }

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect, .GCMouseDidConnect, .GCMouseDidDisconnect] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    private func update() {
        hasKeyboard = GCKeyboard.coalesced != nil
        hasPointer = GCMouse.current != nil
    }
}

/// Launch arguments for automation (screenshots, UI tests). Each is read
/// from UserDefaults' argument domain, e.g. `-StudioOpenProject demo`.
enum LaunchOptions {
    private static var defaults: UserDefaults { .standard }

    /// A project folder (in Documents/Projects) to open in the first window.
    static var openProject: String? { defaults.string(forKey: "StudioOpenProject") }
    /// Files to open: "a.swift;b.md" in one pane, "|" starts a new pane to the right.
    static var openFiles: String? { defaults.string(forKey: "StudioOpenFiles") }
    static var sidebar: String? { defaults.string(forKey: "StudioSidebar") }
    static var panel: String? { defaults.string(forKey: "StudioPanel") }
    static var search: String? { defaults.string(forKey: "StudioSearch") }
    static var palette: String? { defaults.string(forKey: "StudioPalette") }
    static var paletteQuery: String? { defaults.string(forKey: "StudioPaletteQuery") }
    static var terminalCommand: String? { defaults.string(forKey: "StudioTerminalCommand") }
    static var revealPath: String? { defaults.string(forKey: "StudioReveal") }
    static var showSettings: Bool { defaults.bool(forKey: "StudioShowSettings") }
    /// Copies a folder into Projects on launch (for demos): "name=/abs/path".
    static var sampleProject: String? { defaults.string(forKey: "StudioSampleProject") }
    /// Starts with an empty library and no restored windows (UI tests).
    static var resetState: Bool { defaults.bool(forKey: "StudioResetState") }
    /// Runs the in-shell keyboard replay (see KeyboardStress).
    static var keyboardStress: Bool { defaults.bool(forKey: "StudioKeyboardStress") }
    /// Publishes the active document's text as an accessibility element (UI tests).
    static var exposeEditorText: Bool { defaults.bool(forKey: "StudioExposeEditorText") }
    /// "plain" runs with only the built-in editor (tests of the fallback).
    static var editor: String? { defaults.string(forKey: "StudioEditor") }
    static var density: Density? { defaults.string(forKey: "StudioDensity").flatMap(Density.init(rawValue:)) }
    /// Forces hardware-keyboard detection: YES or NO.
    static var hardwareKeyboard: Bool? { defaults.object(forKey: "StudioHardwareKeyboard") == nil ? nil : defaults.bool(forKey: "StudioHardwareKeyboard") }
}

/// Demo content for screenshots and UI tests.
enum SampleContent {
    @MainActor
    static func installIfRequested(library: WorkspaceLibrary) {
        if LaunchOptions.resetState {
            for reference in library.recents { library.remove(reference.id) }
        }
        guard let spec = LaunchOptions.sampleProject else { return }
        let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
        let fm = FileManager.default
        let name = parts[0]
        let destination = library.projectsFolder.appendingPathComponent(name)
        if parts.count == 2 {
            guard !fm.fileExists(atPath: destination.path) else { return }
            try? fm.copyItem(at: URL(fileURLWithPath: parts[1]), to: destination)
        } else {
            // A small generated project when no source folder is given.
            try? fm.removeItem(at: destination)
            let files: [String: String] = [
                "README.md": "# \(name)\n\nA sample workspace.\n",
                "Sources/main.c": "#include <stdio.h>\n\nint main(void) {\n    printf(\"Hello, iPad\\n\");\n    return 0;\n}\n",
                "Sources/util.h": "#pragma once\n\nint add(int a, int b);\n",
                "Sources/util.c": "#include \"util.h\"\n\nint add(int a, int b) { return a + b; }\n",
                "Makefile": "all:\n\tcc -o hello Sources/main.c Sources/util.c\n",
                ".gitignore": "hello\n*.o\n",
            ]
            for (path, text) in files {
                let url = destination.appendingPathComponent(path)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(text.utf8).write(to: url)
            }
        }
    }
}
