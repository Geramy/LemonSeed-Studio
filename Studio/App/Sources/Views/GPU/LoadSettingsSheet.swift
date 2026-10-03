import SwiftUI
import StudioModels
import StudioModelsUI

/// The memory estimate the load settings sheet uses.
///
/// The engine is the authority on what a configuration allocates; until the
/// linked LSE exposes `lse_model_info` (and its estimate), the estimate is
/// StudioModels' config.json fallback, which the sheet labels approximate.
enum EngineMemoryEstimator {
    static var preferred: any ModelMemoryEstimating { ConfigMemoryEstimator() }
}

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
