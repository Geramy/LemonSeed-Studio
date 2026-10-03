import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ProbeModel
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Driver") {
                    LabeledContent("Embedded driver", value: model.state.embeddedDext)
                    LabeledContent("Driver service") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(model.state.serviceFound ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(model.state.service)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if !model.state.serviceFound {
                        Text("Turn the driver on in Settings > General > Drivers (or Settings > Apps > LemonSeed Studio > Drivers), then connect the powered AMD GPU enclosure to this iPad's Thunderbolt port.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if model.probing {
                        HStack {
                            ProgressView()
                            Text("Probing...")
                        }
                    } else if model.results.isEmpty {
                        Text("Probe reads identity and BAR layout only. It does not initialize the GPU.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.results) { result in
                        ResultRow(result: result)
                    }
                } header: {
                    Text("Probe")
                } footer: {
                    if let last = model.lastProbe {
                        Text("Last probe \(last.formatted(date: .omitted, time: .standard))")
                    }
                }

                Section {
                    if model.bringingUp || model.driverBusy {
                        HStack {
                            ProgressView()
                            Text(model.bringUpProgress.isEmpty ? "Initializing..." : model.bringUpProgress)
                                .font(.system(.footnote, design: .monospaced))
                        }
                    } else if model.bringUpResults.isEmpty {
                        Text("Initialize GPU runs the upstream amdgpu probe inside the driver and serves it the bundled firmware. It takes control of the GPU.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.bringUpResults) { result in
                        ResultRow(result: result)
                    }
                    if let log = model.driverLog {
                        DisclosureGroup("Driver log (\(log.text.utf8.count) bytes, \(log.errorLines.count) error lines)") {
                            ScrollView {
                                Text(log.text)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 420)
                        }
                    }
                } header: {
                    Text("GPU bring-up")
                } footer: {
                    if let last = model.lastBringUp {
                        Text("Last bring-up \(last.formatted(date: .omitted, time: .standard))")
                    }
                }
            }
            .navigationTitle("LemonSeed Studio")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    Button(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc") {
                        model.copyReport()
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                    Button("Probe", systemImage: "bolt.horizontal") { model.probe() }
                        .disabled(model.probing || model.bringingUp || model.driverBusy)
                    Button("Initialize GPU", systemImage: "cpu") { model.bringUp() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.probing || model.bringingUp || model.driverBusy || !model.state.serviceFound)
                }
            }
        }
    }
}

private struct ResultRow: View {
    let result: ProbeResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(result.step).font(.subheadline.weight(.semibold))
                Text(result.detail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(result.outcome == .failed ? Color.red : Color.primary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch result.outcome {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}
