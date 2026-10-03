import SwiftUI

/// The engine screen: pick the model and its DFlash2 drafter from
/// Documents/Models, start and stop the in-process engine, watch its log and
/// run one test completion.
struct LSEView: View {
    @EnvironmentObject private var lse: LSEModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Model", selection: $lse.targetModel) {
                        Text("None").tag(String?.none)
                        ForEach(lse.models, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Picker("DFlash2 drafter", selection: $lse.draftModel) {
                        Text("Off").tag(String?.none)
                        ForEach(lse.models, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Toggle("Also serve HTTP on 127.0.0.1:8080", isOn: $lse.serveHTTP)
                        .disabled(lse.running)
                } header: {
                    Text("Models")
                } footer: {
                    Text("Copy MLX model directories into Documents/Models. Settings: --pool hrx:0 --dialect loom --kv-cache-dtype bf16 --kv-len 32768 --temperature 0.6 --batch-size 1024 --ubatch-size 1024.")
                }

                Section("Engine") {
                    LabeledContent("State", value: stateText)
                    if !lse.loadDetail.isEmpty {
                        Text(lse.loadDetail).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                    if lse.running {
                        Button(lse.testing ? "Running..." : "Test completion") {
                            Task { _ = await lse.testCompletion() }
                        }
                        .disabled(lse.testing)
                    }
                    if !lse.lastResult.isEmpty {
                        Text(lse.lastResult).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }

                Section("Log") {
                    if lse.log.isEmpty {
                        Text("No output yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(lse.log.suffix(400).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("LSE")
            .refreshable { lse.refreshModels() }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Reload models", systemImage: "arrow.clockwise") { lse.refreshModels() }
                    if lse.running {
                        Button("Stop", systemImage: "stop.fill") { lse.stop() }
                    } else {
                        Button("Start", systemImage: "play.fill") { lse.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(lse.targetModel == nil || lse.phase == .loading || lse.phase == .stopping)
                    }
                }
            }
        }
    }

    private var stateText: String {
        switch lse.phase {
        case .idle: return "stopped"
        case .loading: return "loading"
        case .ready: return "ready"
        case .stopping: return "stopping"
        case .failed(let message): return "failed: \(message)"
        }
    }
}
