import LemonText
import SwiftUI

/// Runs ``EditorBenchmark`` on a document in the app's Documents folder and writes the results to
/// `Documents/lemontext-benchmark.json`.
struct BenchmarkView: View {
    let fileName: String
    let theme: EditorTheme
    @State private var model: LemonTextEditorModel
    @State private var status = "Waiting for the editor"
    @State private var result: EditorBenchmark.Result?
    @State private var errorMessage: String?

    init(fileName: String, theme: EditorTheme) {
        self.fileName = fileName
        self.theme = theme
        _model = State(initialValue: LemonTextEditorModel(language: .c, theme: theme))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LemonTextEditor(model: model)
                .ignoresSafeArea(.container, edges: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Label(result == nil ? status : "Benchmark complete", systemImage: result == nil ? "speedometer" : "checkmark.seal")
                    .font(.headline)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if let result {
                    ResultSummary(result: result)
                }
            }
            .padding(16)
            .frame(maxWidth: 420, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(20)
        }
        .navigationTitle("Benchmark: \(fileName)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await run() }
    }

    private func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documents.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            errorMessage = "Copy \(fileName) into the app's Documents folder first (see docs/benchmarks/lemontext.md)."
            return
        }
        while model.controller == nil || model.controller?.view.window == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let controller = model.controller else { return }
        // Let the app settle before measuring.
        try? await Task.sleep(for: .seconds(1))
        let benchmark = EditorBenchmark(controller: controller)
        do {
            let result = try await benchmark.run(fileURL: fileURL) { status = $0 }
            self.result = result
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            try data.write(to: documents.appendingPathComponent("lemontext-benchmark.json"), options: .atomic)
            print("LEMONTEXT_BENCHMARK_DONE")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ResultSummary: View {
    let result: EditorBenchmark.Result

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            row("Lines", result.lineCount.formatted())
            row("First screen", String(format: "%.0f ms", result.openToFirstScreenMilliseconds))
            row("Highlighted", String(format: "%.0f ms", result.openToHighlightedMilliseconds))
            ForEach(result.scroll, id: \.name) { scroll in
                row("Scroll", String(format: "%.0f fps, p99 work %.1f ms", scroll.averageFPS, scroll.frameWorkMilliseconds.p99))
            }
            row("Typing p99", String(format: "%.2f ms", result.typingMilliseconds.p99))
            row("Memory", String(format: "%.0f MB peak", result.memoryPeakMB))
        }
        .font(.callout.monospacedDigit())
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
