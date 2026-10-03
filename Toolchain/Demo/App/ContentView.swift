import StudioToolchain
import SwiftUI

struct ContentView: View {
  @State private var model = DemoModel()

  var body: some View {
    NavigationStack {
      HStack(spacing: 0) {
        editor
          .frame(maxWidth: .infinity)
        Divider()
        sidePanel
          .frame(width: 440)
      }
      .navigationTitle("Toolchain Spike")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbar }
    }
    .task {
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("-inject-error") {
        // For screenshots of the diagnostics path.
        model.source = model.source.replacingOccurrences(
          of: "    return 0;", with: "    return undeclared_total + \"oops\";")
      }
      if arguments.contains("-autorun") {
        await model.buildAndRunAll()
      }
      if arguments.contains("-clangd-spike") {
        await model.measureClangd()
      }
    }
  }

  // MARK: - Editor

  private var editor: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("hello.c", systemImage: "doc.text")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text("gnu17 · wasm32-wasip1 · -O2")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      Divider()
      TextEditor(text: $model.source)
        .font(.system(size: 14, design: .monospaced))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 10)
      if !model.diagnostics.isEmpty {
        Divider()
        diagnosticsList
      }
    }
    .background(Color(.systemBackground))
  }

  private var diagnosticsList: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(model.diagnostics, id: \.self) { d in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: d.level == .warning ? "exclamationmark.triangle.fill" : d.level == .note ? "info.circle" : "xmark.octagon.fill")
            .foregroundStyle(d.level == .warning ? .orange : d.level == .note ? .secondary : Color.red)
          Text(d.line > 0 ? "\(d.line):\(d.column)" : "—")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          Text(d.message)
            .font(.callout)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemBackground))
  }

  // MARK: - Side panel

  private var sidePanel: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          statusCard
          timingSection("Build (in-process clang + wasm-ld)", model.buildTimings, systemImage: "hammer")
          timingSection("Run · WKWebView (JIT, out of process)", model.webKitTimings, systemImage: "safari")
          timingSection("Run · WAMR fast interpreter (in process)", model.wamrTimings, systemImage: "cpu")
          if !model.clangdTimings.isEmpty {
            timingSection("clangd in process · medium.cpp", model.clangdTimings, systemImage: "memorychip")
          }
        }
        .padding(16)
      }
      .frame(maxHeight: 560)
      Divider()
      consoleView
    }
    .background(Color(.secondarySystemBackground))
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      row("Compiler", model.compilerStatus)
      row("WAMR", WAMRRunner.version)
      row("Program", model.wasm.map { "hello.wasm, \($0.count.formatted()) bytes, \(model.wasmOrigin)" } ?? "not built yet")
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
      Text(value).font(.caption.monospaced()).lineLimit(2)
    }
  }

  @ViewBuilder
  private func timingSection(_ title: String, _ timings: [DemoModel.Timing], systemImage: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
      if timings.isEmpty {
        Text("—").font(.caption).foregroundStyle(.secondary)
      } else {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
          ForEach(timings) { t in
            GridRow {
              Text(t.label).font(.caption).foregroundStyle(.secondary)
              Text(t.value).font(.caption.monospacedDigit())
            }
          }
        }
      }
    }
  }

  private var consoleView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(model.console) { line in
            Text(line.text.trimmingCharacters(in: .newlines))
              .font(.system(size: 12, design: .monospaced))
              .foregroundStyle(color(for: line.kind))
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .id(line.id)
          }
        }
        .padding(12)
      }
      .background(Color.black.opacity(0.88))
      .onChange(of: model.console.last?.text) {
        if let last = model.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
      }
    }
  }

  private func color(for kind: DemoModel.ConsoleLine.Kind) -> Color {
    switch kind {
    case .info: Color(white: 0.6)
    case .stdout: .white
    case .stderr: .yellow
    case .error: Color(red: 1, green: 0.45, blue: 0.4)
    }
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      Button("Build", systemImage: "hammer") { Task { await model.build() } }
      Button("Run in WebKit", systemImage: "play.fill") { Task { await model.runWebKit() } }
      Button("Run in WAMR", systemImage: "play") { Task { await model.runWAMR() } }
      Button("Build & Run Both", systemImage: "forward.fill") { Task { await model.buildAndRunAll() } }
      Button("Measure clangd", systemImage: "memorychip") { Task { await model.measureClangd() } }
      Button("Clear", systemImage: "trash") { model.clearConsole() }
    }
  }
}
