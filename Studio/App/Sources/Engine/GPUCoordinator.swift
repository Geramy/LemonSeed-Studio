import Foundation
import Observation
import os
import StudioModels

private let gpuLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "gpu")

/// Ties the driver, the models and the engine together.
///
/// On launch it reconciles Documents/Models, then starts the engine with the
/// selected model as soon as the driver's service is present (auto-start).
/// The engine's own GPU bring-up (LSE's HSA runtime) brings the GPU up only
/// when it is not up yet, so starting is safe whether or not an earlier run
/// left the GPU initialized.
@MainActor
@Observable
final class GPUCoordinator {
    let driver: DriverMonitor
    let engine: EngineService
    let library: ModelLibrary

    /// The main model the engine runs. Defaults to the installed Q4.
    var selectedModelID: String? {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "engine.modelID") }
    }

    private(set) var bootstrapped = false

    init(driver: DriverMonitor, engine: EngineService, library: ModelLibrary) {
        self.driver = driver
        self.engine = engine
        self.library = library
        selectedModelID = UserDefaults.standard.string(forKey: "engine.modelID")
        engine.launchResolver = { [weak self] in self?.currentLaunch() }
        driver.onChange = { [weak self] in self?.driverChanged() }
    }

    /// Installed main models, the Q4 first.
    var mainModels: [ModelRecord] {
        library.installedModels
            .filter { $0.state == .installed }
            .sorted { a, b in
                let aq = a.id.localizedCaseInsensitiveContains("q4"), bq = b.id.localizedCaseInsensitiveContains("q4")
                return aq != bq ? aq : a.id < b.id
            }
    }

    var selectedModel: ModelRecord? {
        if let id = selectedModelID, let record = library.record(id), record.role == .main, record.state == .installed {
            return record
        }
        if let forced = LaunchArguments.value("--lse-model"), let record = library.record(forced) { return record }
        return mainModels.first
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await library.start()
        gpuLog.log("models: \(self.library.records.map { "\($0.id)[\($0.state)]" }.joined(separator: ", "), privacy: .public)")
        if engine.autoStart || LaunchArguments.has("--selftest") { startIfPossible() }
    }

    /// Starts the engine if a driver service and a model are present.
    func startIfPossible() {
        guard EngineService.isAvailable else {
            engine.markUnavailable()
            return
        }
        switch engine.phase {
        case .loading, .ready, .stopping: return
        default: break
        }
        guard driver.service != nil else {
            engine.markWaiting(driver.isEnabled == false
                               ? "Turn the GPU driver on in Settings › General › Drivers."
                               : "Waiting for the GPU: connect the powered enclosure.")
            return
        }
        guard currentLaunch() != nil else {
            engine.markWaiting("No model installed. Open Models to add one.")
            return
        }
        engine.start()
    }

    private func driverChanged() {
        guard bootstrapped else { return }
        if driver.service != nil {
            if case .waiting = engine.phase, engine.autoStart || LaunchArguments.has("--selftest") { startIfPossible() }
        }
    }

    /// The launch for the selected model with its stored load settings.
    func currentLaunch() -> EngineLaunch? {
        guard let model = selectedModel else { return nil }
        return launch(for: model)
    }

    func launch(for model: ModelRecord) -> EngineLaunch? {
        let settings = library.loadSettings(for: model.id)
        return EngineLaunch(model: model, settings: settings, library: library)
    }

    /// Persists new settings for a model and reloads the engine with them
    /// when that model is the one running (or selected).
    func apply(_ settings: ModelLoadSettings, to modelID: String) {
        Task {
            await library.setLoadSettings(settings, for: modelID)
            guard let model = library.record(modelID) else { return }
            if selectedModel?.id != modelID { selectedModelID = modelID }
            guard let launch = launch(for: model) else { return }
            gpuLog.log("apply load settings for \(modelID, privacy: .public): kv \(launch.kvCacheDType, privacy: .public)/\(launch.kvLength)")
            engine.reload(launch)
        }
    }
}

extension EngineLaunch {
    /// The engine configuration for an installed main model: its stored load
    /// settings (or the standard preset) and, with DFlash2 on, the chosen
    /// installed draft.
    @MainActor
    init?(model: ModelRecord, settings: ModelLoadSettings, library: ModelLibrary) {
        guard model.state == .installed, model.role == .main else { return nil }
        var draft: ModelRecord?
        if settings.dflash2Enabled {
            if let id = settings.draftID, let record = library.record(id), record.state == .installed {
                draft = record
            } else {
                draft = library.linkedDraft(of: model)
            }
            if let forced = LaunchArguments.value("--lse-draft"), let record = library.record(forced) { draft = record }
        }
        self.init(modelID: model.id, modelName: model.name, modelDirectory: library.directory(of: model))
        draftID = draft?.id
        draftDirectory = draft.map { library.directory(of: $0) }
        kvCacheDType = settings.kvCacheDType.rawValue
        kvLength = Int32(settings.kvLength)
        batchSize = UInt32(settings.batchSize)
        ubatchSize = UInt32(settings.ubatchSize)
        temperature = Float(settings.temperature)
        maxTokens = Int32(settings.maxTokens)
        mtpEnabled = settings.mtpEnabled
        mtpDepth = UInt32(settings.mtpDepth)
    }
}

/// Process launch arguments (`--selftest`, `--screenshots`, `--lse-model X`).
enum LaunchArguments {
    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }
    static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
        if let match = args.first(where: { $0.hasPrefix(flag + "=") }) { return String(match.dropFirst(flag.count + 1)) }
        return nil
    }
}
