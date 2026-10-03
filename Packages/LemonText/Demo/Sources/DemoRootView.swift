import LemonText
import SwiftUI

/// Launch arguments used to stage screenshots and run the benchmark unattended:
/// `-sample <file>`, `-theme dark|light|contrast`, `-stage <name>`, `-fullscreen`, `-benchmark <file in Documents>`.
struct LaunchOptions {
    var sample: String?
    var theme: String?
    var stage: String?
    var fullscreen = false
    var benchmarkFile: String?
    var document: String?
    var hidesSoftwareKeyboard = false

    static let current: LaunchOptions = {
        var options = LaunchOptions()
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        options.sample = value(after: "-sample")
        options.theme = value(after: "-theme")
        options.stage = value(after: "-stage")
        options.fullscreen = arguments.contains("-fullscreen")
        options.benchmarkFile = value(after: "-benchmark")
        options.document = value(after: "-document")
        options.hidesSoftwareKeyboard = arguments.contains("-nokeyboard")
        return options
    }()

    var editorTheme: EditorTheme {
        switch theme {
        case "light": .lemonLight
        case "contrast": .seedHighContrast
        default: .lemonDark
        }
    }
}

enum DemoDestination: Hashable {
    case sample(Sample)
    case document(URL)
    case benchmark
}

struct DemoRootView: View {
    @State private var destination: DemoDestination?
    @State private var columnVisibility: NavigationSplitViewVisibility = LaunchOptions.current.fullscreen ? .detailOnly : .automatic
    @State private var theme = LaunchOptions.current.editorTheme

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $destination) {
                ForEach(Sample.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.samples) { sample in
                            Label(sample.fileName, systemImage: icon(for: sample.language))
                                .tag(DemoDestination.sample(sample))
                        }
                    }
                }
                Section("Documents") {
                    ForEach(Sample.largeDocuments, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc.text.magnifyingglass")
                            .tag(DemoDestination.document(url))
                    }
                    Label("Benchmark", systemImage: "speedometer")
                        .tag(DemoDestination.benchmark)
                }
            }
            .navigationTitle("LemonText")
            .tint(Color(uiColor: theme.accent.uiColor))
        } detail: {
            switch destination {
            case .sample(let sample):
                EditorScreen(source: .sample(sample), theme: $theme)
                    .id(sample.id)
            case .document(let url):
                EditorScreen(source: .file(url), theme: $theme)
                    .id(url)
            case .benchmark:
                BenchmarkView(fileName: LaunchOptions.current.benchmarkFile ?? "sqlite3.c", theme: theme)
            case nil:
                ContentUnavailableView("Choose a file", systemImage: "chevron.left.forwardslash.chevron.right",
                                       description: Text("Pick a sample to open it in LemonText."))
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            let options = LaunchOptions.current
            if options.benchmarkFile != nil {
                destination = .benchmark
            } else if let document = options.document,
                      let url = Sample.largeDocuments.first(where: { $0.lastPathComponent == document }) {
                destination = .document(url)
            } else if let name = options.sample ?? Optional("kernel_queue.cpp"), let sample = Sample.all.first(where: { $0.fileName == name }) {
                destination = .sample(sample)
            }
        }
    }

    private func icon(for language: LemonLanguage) -> String {
        switch language {
        case .c, .cpp, .objectiveC: "c.square"
        case .swift: "swift"
        case .python: "p.square"
        case .javascript, .typescript, .tsx: "curlybraces.square"
        case .rust: "r.square"
        case .go: "g.square"
        case .cmake, .make: "hammer"
        case .markdown: "text.document"
        case .json, .yaml: "list.bullet.indent"
        case .html, .css: "globe"
        case .shell: "terminal"
        case .plainText: "doc.plaintext"
        }
    }
}
