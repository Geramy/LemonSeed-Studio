import SwiftUI
#if canImport(LSEKit)
import LSEKit
#endif
import StudioModels
import StudioModelsUI

/// The memory estimates the load settings sheet and the Models screen use.
///
/// The engine is the authority on what a configuration allocates: with LSE
/// 0.5 or later linked, the fit bar comes from `lse_estimate`, the same
/// sizing `lse_open` does (weights as the loader packs them, the paged KV
/// pool, recurrent state, RoPE, the DFlash2 ring, modelled workspace). Only
/// when the build has no engine, or the linked LSE predates lse_estimate,
/// does StudioModels' config.json fallback (labelled approximate) stand in.
enum EngineMemoryEstimator {
    @MainActor
    static var preferred: any ModelMemoryEstimating {
        #if canImport(LSEKit)
        if LSEEngine.supportsEstimates {
            let vram = (AppModel.shared.services.telemetry as? StudioTelemetryProvider)?.vramTotalBytes
            return LSEMemoryEstimator(deviceMemoryBytes: vram)
        }
        #endif
        return ConfigMemoryEstimator()
    }
}

#if canImport(LSEKit)
/// `lse_estimate` behind StudioModels' estimator protocol.
struct LSEMemoryEstimator: ModelMemoryEstimating {
    /// The GPU's VRAM, for LSE's fit verdict and the largest context that fits.
    var deviceMemoryBytes: UInt64?

    func estimate(modelDirectory: URL, draftDirectory: URL?, settings: ModelLoadSettings) throws -> ModelMemoryEstimate {
        var c = LSEEngine.Configuration(model: modelDirectory.path)
        if settings.dflash2Enabled, let draftDirectory {
            c.dflash2 = true
            c.dflash2Model = draftDirectory.path
        }
        c.noMTP = !settings.mtpEnabled || c.dflash2
        c.mtpDepth = UInt32(settings.mtpDepth)
        c.kvCacheDType = settings.kvCacheDType.rawValue
        c.kvLength = Int32(settings.kvLength)
        c.batchSize = UInt32(settings.batchSize)
        c.ubatchSize = UInt32(settings.ubatchSize)
        c.pool = "hrx:0"
        c.dialect = "loom"
        var options: [String: Any] = ["context_tokens": settings.kvLength]
        if let deviceMemoryBytes, deviceMemoryBytes > 0 { options["device_memory_bytes"] = deviceMemoryBytes }
        let e = try LSEEngine.estimate(c, options: options)
        func bytes(_ key: String) -> UInt64 { (e[key] as? NSNumber)?.uint64Value ?? 0 }
        // The sheet's four segments: weights, K/V (with the DeltaNet state,
        // which the protocol counts there), draft, and everything else the
        // engine reserves (workspace, prefill activation and growth, the
        // device reserve), so the segments add up to LSE's device total.
        let workspace = e["workspace"] as? [String: Any]
        let recurrent = (workspace?["recurrent_state_bytes"] as? NSNumber)?.uint64Value ?? 0
        let weights = bytes("weights_bytes"), kv = bytes("kv_bytes") + recurrent, draft = bytes("draft_bytes")
        let total = max(bytes("device_total_bytes"), weights + kv + draft)
        var source = "lse_estimate (LSE \(LSEEngine.version))"
        if let max = (e["max_kv_len"] as? NSNumber)?.intValue, deviceMemoryBytes != nil {
            source += " · longest context that fits: \(max.formatted()) tokens"
        }
        return ModelMemoryEstimate(weightsBytes: weights, kvCacheBytes: kv, draftBytes: draft,
                                   workspaceBytes: total - weights - kv - draft, totalBytes: total,
                                   isApproximate: false, source: source)
    }
}
#endif

/// GPU › Engine › Load Settings for the selected model. Apply persists the
/// settings in the models registry and reloads the engine with them.
struct LoadSettingsSheet: View {
    @Environment(AppModel.self) private var app
    let model: ModelRecord
    let provider: StudioTelemetryProvider
    let dismiss: () -> Void

    var body: some View {
        ModelLoadSettingsView(modelID: model.id, displayName: model.name, library: app.models,
                              estimator: EngineMemoryEstimator.preferred,
                              vramTotalBytes: provider.vramTotalBytes) { settings in
            app.gpu.apply(settings, to: model.id)
            dismiss()
        }
    }
}
