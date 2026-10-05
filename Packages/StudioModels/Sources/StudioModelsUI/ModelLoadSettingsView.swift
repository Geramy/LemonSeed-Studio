// StudioModelsUI: per-model load settings, with a GPU memory fit check.
//
//   .sheet(item: $model) { record in
//       ModelLoadSettingsView(modelID: record.id, library: library,
//                             estimator: ConfigMemoryEstimator(), vramTotalBytes: vram) { settings in
//           reloadEngine(record.id, settings)
//       }
//   }
//
// Apply & Reload stores the settings in the registry first, then calls
// onApply and dismisses. The VRAM figure comes from the caller (the GPU
// driver knows it); without one the bar shows the estimate and no verdict.

import StudioModels
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct ModelLoadSettingsView: View {
    let modelID: String
    let displayName: String
    let library: ModelLibrary
    let estimator: any ModelMemoryEstimating
    let vramTotalBytes: UInt64?
    let onApply: (ModelLoadSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var settings: ModelLoadSettings
    @State private var summary: ModelConfigSummary?
    @State private var estimate: ModelMemoryEstimate?
    @State private var estimateError: String?
    /// The model's sampling defaults, as the engine reads them (nil until
    /// read, or when this build has no engine to ask).
    @State private var generationDefaults: ModelGenerationDefaults?
    @State private var confirmingOverflow = false
    @State private var applying = false

    /// - Parameters:
    ///   - modelID: the registry id of an installed main model.
    ///   - displayName: the title; the model's name when nil.
    ///   - estimator: sizes the load; ConfigMemoryEstimator until LSE reports its own.
    ///   - vramTotalBytes: the GPU's memory, or nil when unknown (no fit verdict).
    ///   - onApply: called with the settings once they are stored.
    public init(modelID: String, displayName: String? = nil, library: ModelLibrary,
                estimator: any ModelMemoryEstimating = ConfigMemoryEstimator(), vramTotalBytes: UInt64?,
                onApply: @escaping (ModelLoadSettings) -> Void) {
        self.modelID = modelID
        self.displayName = displayName ?? library.record(modelID)?.name ?? modelID
        self.library = library
        self.estimator = estimator
        self.vramTotalBytes = vramTotalBytes
        self.onApply = onApply
        _settings = State(initialValue: library.loadSettings(for: modelID))
        _summary = State(initialValue: library.configSummary(for: modelID))
    }

    private var record: ModelRecord? { library.record(modelID) }
    private var hasMTPModule: Bool { record.flatMap(library.mtpModuleDirectory(of:)) != nil }
    private var fit: MemoryFit { estimate?.fit(vramTotalBytes: vramTotalBytes) ?? .unknown }

    public var body: some View {
        NavigationStack {
            Form {
                memorySection
                kvSection
                prefillSection
                speculationSection
                samplingSection
                resetSection
            }
            .formStyle(.grouped)
            .navigationTitle(displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("loadSettings.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply & Reload", action: apply)
                        .disabled(applying || record == nil)
                        .accessibilityIdentifier("loadSettings.apply")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if confirmingOverflow { overflowConfirmation }
            }
            .animation(.default, value: confirmingOverflow)
            .onChange(of: settings) { confirmingOverflow = false }
            .task(id: settings) { await refreshEstimate() }
            .task { await loadGenerationDefaults() }
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("GPU memory").font(.headline)
                    Spacer()
                    FitVerdictLabel(fit: fit, hasEstimate: estimate != nil)
                }
                if let estimate {
                    MemoryFitBar(estimate: estimate, vramTotalBytes: vramTotalBytes)
                    MemoryLegend(estimate: estimate)
                    if let note = fitNote(estimate) {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(fit == .wontFit ? Color.red : Color.secondary)
                            .accessibilityIdentifier("loadSettings.fitWarning")
                    }
                    if estimate.isApproximate {
                        Label("Estimate from config.json (approximate)", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("loadSettings.approximate")
                    } else {
                        Label("Estimate: \(estimate.source)", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("loadSettings.estimateSource")
                    }
                } else if let estimateError {
                    Label(estimateError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func fitNote(_ estimate: ModelMemoryEstimate) -> String? {
        guard let vram = vramTotalBytes, vram > 0 else { return nil }
        switch fit {
        case .wontFit:
            var advice = "lower the context length"
            if settings.kvCacheDType != .fp8 && settings.kvCacheDType != .bf8 { advice += " or use FP8 K/V" }
            return "Won't fit: needs about \(GB.string(estimate.totalBytes)) of \(GB.string(vram)). To load it, \(advice)."
        case .tight:
            return "Tight fit: about \(GB.string(vram - min(vram, estimate.totalBytes))) left for anything else."
        case .fits, .unknown:
            return nil
        }
    }

    // MARK: K/V cache

    private var contextChoices: [Int] { ModelLoadSettings.contextLengthChoices(maxContext: summary?.maxContext) }

    private var kvSection: some View {
        Section {
            Picker("K/V cache type", selection: $settings.kvCacheDType) {
                ForEach(ModelLoadSettings.KVCacheDType.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("loadSettings.kvDType")

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context length")
                    Spacer()
                    Text(Tokens.string(settings.kvLength))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("loadSettings.kvLengthValue")
                }
                let choices = contextChoices
                if choices.count > 1 {
                    Slider(value: contextIndex(choices), in: 0...Double(choices.count - 1), step: 1) {
                        Text("Context length")
                    } minimumValueLabel: {
                        Text(Tokens.short(choices[0])).font(.caption2).monospacedDigit()
                    } maximumValueLabel: {
                        Text(Tokens.short(choices[choices.count - 1])).font(.caption2).monospacedDigit()
                    }
                    .accessibilityValue(Tokens.string(settings.kvLength))
                    .accessibilityIdentifier("loadSettings.kvLength")
                }
            }
        } header: {
            Text("K/V cache")
        } footer: {
            Text(kvFooter)
        }
    }

    private var kvFooter: String {
        var text = "The longest conversation the model can hold."
        if let max = summary?.maxContext { text += " This model supports up to \(max.formatted()) tokens." }
        if let summary, summary.linearAttentionLayers > 0 {
            text += " Only its \(summary.fullAttentionLayers) full-attention layers keep a cache that grows with it."
        }
        text += " FP8 and BF8 store about half of BF16."
        return text
    }

    private func contextIndex(_ choices: [Int]) -> Binding<Double> {
        Binding {
            let nearest = choices.indices.min { abs(choices[$0] - settings.kvLength) < abs(choices[$1] - settings.kvLength) }
            return Double(nearest ?? 0)
        } set: { value in
            let i = min(max(Int(value.rounded()), 0), choices.count - 1)
            if settings.kvLength != choices[i] { settings.kvLength = choices[i] }
        }
    }

    // MARK: Prefill

    private var prefillSection: some View {
        Section {
            Picker("Batch size", selection: $settings.batchSize) {
                ForEach(ModelLoadSettings.batchSizeChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("loadSettings.batchSize")
            .onChange(of: settings.batchSize) { _, batch in
                if settings.ubatchSize > batch { settings.ubatchSize = batch }
            }
            Picker("Micro-batch size", selection: $settings.ubatchSize) {
                ForEach(ModelLoadSettings.batchSizeChoices.filter { $0 <= settings.batchSize }, id: \.self) {
                    Text("\($0)").tag($0)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("loadSettings.ubatchSize")
        } header: {
            Text("Prompt processing")
        } footer: {
            Text("Tokens taken per prompt batch, and per GPU pass within it. Larger passes read prompts faster and need more working memory.")
        }
    }

    // MARK: Speculative decoding

    private var drafts: [ModelRecord] { library.compatibleDrafts(for: modelID) }

    private var speculationSection: some View {
        Section {
            Toggle("DFlash2 draft", isOn: Binding {
                settings.dflash2Enabled
            } set: { on in
                settings.dflash2Enabled = on
                if on {
                    settings.mtpEnabled = false
                    if settings.draftID == nil { settings.draftID = record?.linkedDraftID ?? drafts.first?.id }
                }
            })
            .accessibilityIdentifier("loadSettings.dflash2")
            if settings.dflash2Enabled {
                if drafts.isEmpty {
                    Text("No compatible DFlash2 draft is installed. The model loads without one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Draft", selection: Binding {
                        settings.draftID ?? record?.linkedDraftID
                    } set: { settings.draftID = $0 }) {
                        if (settings.draftID ?? record?.linkedDraftID) == nil {
                            Text("Choose…").tag(String?.none)
                        }
                        ForEach(drafts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("loadSettings.draft")
                }
            }
            if summary?.hasMTP == true {
                Toggle("Multi-token prediction (MTP)", isOn: Binding {
                    settings.mtpEnabled
                } set: { on in
                    settings.mtpEnabled = on
                    if on { settings.dflash2Enabled = false }
                })
                .disabled(!hasMTPModule)
                .accessibilityIdentifier("loadSettings.mtp")
                if settings.mtpEnabled {
                    Stepper(value: $settings.mtpDepth, in: ModelLoadSettings.mtpDepthRange) {
                        LabeledContent("Draft depth", value: "\(settings.mtpDepth)")
                    }
                    .accessibilityIdentifier("loadSettings.mtpDepth")
                }
                if !hasMTPModule {
                    Text("The model declares MTP layers but no module is installed in its mtp/ folder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Speculative decoding")
        } footer: {
            Text("LSE runs one drafter at a time: turning one on turns the other off.")
        }
    }

    // MARK: Sampling

    /// Each field is the model's own default (from its generation config,
    /// as the engine reads it) until the user overrides it; only overrides
    /// are sent with requests. There is no output limit to set.
    private var samplingSection: some View {
        Section {
            SamplingOverrideRow(title: "Temperature", key: "temperature", value: $settings.temperature,
                                modelDefault: generationDefaults?.temperature, sources: generationDefaults?.sources,
                                range: ModelLoadSettings.temperatureRange, step: 0.05, digits: 2)
            SamplingOverrideRow(title: "Top-k", key: "top_k",
                                value: Binding { settings.topK.map(Double.init) } set: { settings.topK = $0.map { Int($0.rounded()) } },
                                modelDefault: generationDefaults?.topK.map(Double.init), sources: generationDefaults?.sources,
                                range: Double(ModelLoadSettings.topKRange.lowerBound)...Double(ModelLoadSettings.topKRange.upperBound),
                                step: 1, digits: 0, offAt: 0)
            SamplingOverrideRow(title: "Top-p", key: "top_p", value: $settings.topP,
                                modelDefault: generationDefaults?.topP, sources: generationDefaults?.sources,
                                range: ModelLoadSettings.probabilityRange, step: 0.01, digits: 2, offAt: 1)
            SamplingOverrideRow(title: "Min-p", key: "min_p", value: $settings.minP,
                                modelDefault: generationDefaults?.minP, sources: generationDefaults?.sources,
                                range: ModelLoadSettings.probabilityRange, step: 0.01, digits: 2, offAt: 0)
            DisclosureGroup("Advanced") {
                SamplingOverrideRow(title: "Presence penalty", key: "presence_penalty", value: $settings.presencePenalty,
                                    modelDefault: generationDefaults?.presencePenalty, sources: generationDefaults?.sources,
                                    range: ModelLoadSettings.presencePenaltyRange, step: 0.05, digits: 2, offAt: 0)
                SamplingOverrideRow(title: "Repetition penalty", key: "repetition_penalty", value: $settings.repetitionPenalty,
                                    modelDefault: generationDefaults?.repetitionPenalty, sources: generationDefaults?.sources,
                                    range: ModelLoadSettings.repetitionPenaltyRange, step: 0.01, digits: 2, offAt: 1)
            }
            .accessibilityIdentifier("loadSettings.samplingAdvanced")
        } header: {
            Text("Sampling")
        } footer: {
            Text("Each value is the model\u{2019}s own default unless you override it. Replies have no output limit: they run until the model finishes or the context is full.")
        }
    }

    // MARK: Reset and launch line

    private var resetSection: some View {
        Section {
            Button("Reset to defaults", systemImage: "arrow.counterclockwise") {
                settings = library.defaultLoadSettings(for: modelID)
            }
            .disabled(settings == library.defaultLoadSettings(for: modelID))
            .accessibilityIdentifier("loadSettings.reset")
            if let record {
                DisclosureGroup("LSE arguments") {
                    Text(launch(record).commandLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func launch(_ record: ModelRecord) -> LSELaunchConfiguration {
        library.preset.configuration(model: library.directory(of: record), settings: settings,
                                     dflash2Draft: library.draft(of: record, settings: settings).map(library.directory(of:)),
                                     mtpModule: library.mtpModuleDirectory(of: record))
    }

    // MARK: Applying

    private var overflowConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("These settings probably won't fit in GPU memory", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            if let estimate, let vram = vramTotalBytes {
                Text("About \(GB.string(estimate.totalBytes)) needed of \(GB.string(vram)). Loading may fail.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Keep editing") { confirmingOverflow = false }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("loadSettings.keepEditing")
                Spacer()
                Button("Load anyway") { Task { await commit() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("loadSettings.confirmApply")
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("loadSettings.overflowConfirmation")
    }

    private func apply() {
        if fit == .wontFit && !confirmingOverflow {
            confirmingOverflow = true
            return
        }
        Task { await commit() }
    }

    private func commit() async {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        let chosen = settings
        guard await library.setLoadSettings(chosen, for: modelID) else { return }
        onApply(library.loadSettings(for: modelID))
        dismiss()
    }

    private func loadGenerationDefaults() async {
        guard let record else { return }
        let estimator = estimator
        let directory = library.directory(of: record)
        generationDefaults = await Task.detached(priority: .userInitiated) {
            estimator.generationDefaults(modelDirectory: directory)
        }.value
    }

    private func refreshEstimate() async {
        guard let record else { return }
        // Let a dragged slider settle before re-reading the checkpoint.
        if estimate != nil {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        }
        let estimator = estimator
        let modelDirectory = library.directory(of: record)
        let draftDirectory = library.draft(of: record, settings: settings).map(library.directory(of:))
        let chosen = settings
        let result = await Task.detached(priority: .userInitiated) {
            Result { try estimator.estimate(modelDirectory: modelDirectory, draftDirectory: draftDirectory,
                                            settings: chosen) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let value):
            estimate = value
            estimateError = nil
        case .failure(let error):
            estimate = nil
            estimateError = error.localizedDescription
        }
    }
}

// MARK: - Fit bar

/// Weights, K/V, draft and workspace stacked against the GPU's memory.
struct MemoryFitBar: View {
    let estimate: ModelMemoryEstimate
    let vramTotalBytes: UInt64?

    var body: some View {
        let vram = vramTotalBytes.flatMap { $0 > 0 ? $0 : nil }
        let scale = Double(max(estimate.totalBytes, vram ?? 0, 1))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    HStack(spacing: 2) {
                        ForEach(MemoryPart.allCases) { part in
                            let bytes = part.bytes(in: estimate)
                            if bytes > 0 {
                                Rectangle()
                                    .fill(part.color)
                                    .frame(width: max(2, width * Double(bytes) / scale - 2))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    if let vram, estimate.totalBytes > vram {
                        // Where the GPU's memory ends.
                        Rectangle()
                            .fill(.primary)
                            .frame(width: 2, height: proxy.size.height + 8)
                            .offset(x: width * Double(vram) / scale - 1)
                    }
                }
            }
            .frame(height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("GPU memory")
            .accessibilityValue(summary(vram))
            .accessibilityIdentifier("loadSettings.fitBar")

            Text(summary(vram))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ vram: UInt64?) -> String {
        guard let vram else { return "\(GB.string(estimate.totalBytes)) needed · GPU VRAM unknown" }
        let share = Double(estimate.totalBytes) / Double(vram)
        return "\(GB.string(estimate.totalBytes)) of \(GB.string(vram)) (\(share.formatted(.percent.precision(.fractionLength(0)))))"
    }
}

struct MemoryLegend: View {
    let estimate: ModelMemoryEstimate

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(MemoryPart.allCases) { part in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 10, height: 10)
                    Text(part.label)
                    Spacer(minLength: 4)
                    Text(GB.string(part.bytes(in: estimate)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("loadSettings.legend")
    }
}

struct FitVerdictLabel: View {
    let fit: MemoryFit
    let hasEstimate: Bool

    var body: some View {
        Group {
            switch fit {
            case .fits: Label("Fits", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .tight: Label("Tight", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .wontFit: Label("Won't fit", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .unknown:
                Label(hasEstimate ? "GPU VRAM unknown" : "Estimating…", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityIdentifier("loadSettings.verdict")
    }
}

/// The estimate's parts, in stacking order, with fixed colors (categorical
/// slots 1 to 4, stepped separately for light and dark).
enum MemoryPart: CaseIterable, Identifiable {
    case weights, kv, draft, workspace

    var id: Self { self }

    var label: String {
        switch self {
        case .weights: "Weights"
        case .kv: "K/V cache"
        case .draft: "Draft"
        case .workspace: "Workspace"
        }
    }

    func bytes(in e: ModelMemoryEstimate) -> UInt64 {
        switch self {
        case .weights: e.weightsBytes
        case .kv: e.kvCacheBytes
        case .draft: e.draftBytes
        case .workspace: e.workspaceBytes
        }
    }

    var color: Color {
        switch self {
        case .weights: .adaptive(light: 0x2A78D6, dark: 0x3987E5)
        case .kv: .adaptive(light: 0xEB6834, dark: 0xD95926)
        case .draft: .adaptive(light: 0x1BAF7A, dark: 0x199E70)
        case .workspace: .adaptive(light: 0xEDA100, dark: 0xC98500)
        }
    }
}

// MARK: - Formatting

/// Memory sizes in binary gigabytes, the way GPU memory is quoted.
enum GB {
    static func string(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / Double(1 << 30)
        return gb >= 10 ? "\(gb.formatted(.number.precision(.fractionLength(1)))) GB"
            : "\(gb.formatted(.number.precision(.fractionLength(2)))) GB"
    }
}

enum Tokens {
    static func string(_ n: Int) -> String { "\(n.formatted()) tokens" }

    static func short(_ n: Int) -> String { n % 1024 == 0 ? "\(n / 1024)K" : n.formatted() }
}

extension Color {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
        #elseif canImport(AppKit)
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
        #else
        Color(red: Double((light >> 16) & 0xFF) / 255, green: Double((light >> 8) & 0xFF) / 255,
              blue: Double(light & 0xFF) / 255)
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#elseif canImport(AppKit)
extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// One sampling field: "Model default (value)" until overridden, then a
/// slider for the override. `offAt` names the value that turns it off.
struct SamplingOverrideRow: View {
    let title: String
    /// LSE's field name, for the default's source.
    let key: String
    @Binding var value: Double?
    let modelDefault: Double?
    let sources: [String: String]?
    let range: ClosedRange<Double>
    let step: Double
    let digits: Int
    var offAt: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding { value != nil } set: { value = $0 ? (value ?? start) : nil }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("loadSettings.\(key).override")
            if let current = value {
                HStack {
                    Slider(value: Binding { current } set: { value = ($0 / step).rounded() * step }, in: range, step: step) {
                        Text(title)
                    }
                    Text(format(current)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                }
                .accessibilityIdentifier("loadSettings.\(key)")
            }
        }
    }

    private var start: Double { min(max(modelDefault ?? range.lowerBound, range.lowerBound), range.upperBound) }

    private var subtitle: String {
        if let value { return "Override: \(format(value))" + (value == offAt ? " (off)" : "") }
        guard let modelDefault else { return "Model default" }
        var text = "Model default (\(format(modelDefault))" + (modelDefault == offAt ? ", off" : "") + ")"
        if let source = sources?[key] { text += " · " + Self.sourceLabel(source) }
        return text
    }

    private func format(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(digits))) }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "generation_config.json", "config.json": "from " + source
        case "server_option": "set by the engine"
        default: "LSE default"
        }
    }
}
