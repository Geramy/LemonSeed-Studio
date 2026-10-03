import SwiftUI
import StudioCore
import StudioDesign
import StudioModels
import StudioModelsUI

/// The Models sidebar: the installed models, which one the engine runs and
/// with what load settings. The full Models screen (catalog, downloads,
/// Hugging Face search) opens as a page sheet.
struct ModelsSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                if app.models.installedModels.isEmpty {
                    Text("No models on this iPad yet.")
                        .font(.studio(type.body, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary.color)
                }
                ForEach(app.models.installedModels) { model in
                    ModelCard(model: model)
                }
                if !app.models.installedDrafts.isEmpty {
                    Text("Drafts")
                        .font(.studio(type.caption, weight: .semibold))
                        .foregroundStyle(theme.palette.textTertiary.color)
                    ForEach(app.models.installedDrafts) { draft in
                        HStack(spacing: Space.s) {
                            Image(systemName: "hare")
                                .foregroundStyle(theme.palette.accent.color)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(draft.name)
                                    .font(.studio(type.caption, weight: .medium))
                                    .foregroundStyle(theme.palette.textPrimary.color)
                                Text(stateText(draft))
                                    .font(.studio(type.micro + 1))
                                    .foregroundStyle(theme.palette.textTertiary.color)
                            }
                        }
                    }
                }
                Button {
                    app.isModelsManagerPresented = true
                } label: {
                    Label("Manage Models…", systemImage: "square.stack.3d.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.studioSecondary)
                .accessibilityIdentifier("models.manage")
                Text("Download recommended models, search Hugging Face for checkpoints LSE loads, verify and delete. Models live in On My iPad › LemonSeed Studio › Models.")
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.l)
        }
        .accessibilityIdentifier("models.sidebar")
    }

    private func stateText(_ record: ModelRecord) -> String {
        let size = ByteCountFormatter.string(fromByteCount: record.files.reduce(0) { $0 + $1.size }, countStyle: .file)
        return "\(record.state) · \(size)"
    }
}

private struct ModelCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let model: ModelRecord

    var body: some View {
        let settings = app.models.loadSettings(for: model.id)
        let selected = app.gpu.selectedModel?.id == model.id
        let running = selected && app.engine.phase == .ready && app.engine.launch?.modelID == model.id
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                StatusDot(running ? theme.palette.success.color : (selected ? theme.palette.accent.color : theme.palette.textTertiary.color),
                          live: running)
                Text(model.name)
                    .font(.studio(type.body, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary.color)
                Spacer()
                Text(running ? "Running" : (selected ? "Selected" : "\(model.state)"))
                    .font(.studio(type.micro + 1, weight: .medium))
                    .foregroundStyle(theme.palette.textTertiary.color)
            }
            Group {
                Text("\(settings.kvCacheDType.rawValue) K/V · \(settings.kvLength.formatted()) ctx · batch \(settings.batchSize)/\(settings.ubatchSize)")
                Text(settings.dflash2Enabled ? "DFlash2: \(app.models.draft(of: model, settings: settings)?.name ?? "no draft installed")"
                     : (settings.mtpEnabled ? "MTP depth \(settings.mtpDepth)" : "No speculative decoding"))
                Text(String(format: "temperature %.2f · max %d tokens", settings.temperature, settings.maxTokens))
            }
            .font(.system(size: type.micro + 1.5, design: .monospaced))
            .foregroundStyle(theme.palette.textSecondary.color)
            HStack(spacing: Space.s) {
                Button {
                    app.loadSettingsModelID = model.id
                } label: {
                    Label("Load Settings", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.studioSecondary)
                .accessibilityIdentifier("models.loadSettings.\(model.id)")
                if !selected {
                    Button {
                        app.gpu.selectedModelID = model.id
                        if app.engine.phase == .ready, let launch = app.gpu.currentLaunch() { app.engine.reload(launch) }
                    } label: {
                        Label("Use", systemImage: "bolt")
                    }
                    .buttonStyle(.studioSecondary)
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedSurface()
    }
}

/// StudioModels' full screen, with load settings that apply to the engine.
struct ModelsManagerSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ModelsView(library: app.models, embedInNavigation: false,
                       vramTotalBytes: (app.services.telemetry as? StudioTelemetryProvider)?.vramTotalBytes,
                       estimator: EngineMemoryEstimator.preferred,
                       onApplyLoadSettings: { id, settings in app.gpu.apply(settings, to: id) })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { app.isModelsManagerPresented = false }
                    }
                }
        }
        .accessibilityIdentifier("models.screen")
    }
}
