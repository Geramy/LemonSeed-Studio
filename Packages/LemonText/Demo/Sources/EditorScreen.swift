import LemonText
import SwiftUI

enum EditorSource {
    case sample(Sample)
    case file(URL)

    var title: String {
        switch self {
        case .sample(let sample): sample.fileName
        case .file(let url): url.lastPathComponent
        }
    }
}

struct EditorScreen: View {
    let source: EditorSource
    @Binding var theme: EditorTheme
    @State private var model: LemonTextEditorModel
    @State private var loadMessage: String?

    init(source: EditorSource, theme: Binding<EditorTheme>) {
        self.source = source
        _theme = theme
        let language: LemonLanguage
        switch source {
        case .sample(let sample): language = sample.language
        case .file(let url): language = LanguageDetector.language(forFileName: url.lastPathComponent)
        }
        _model = State(initialValue: LemonTextEditorModel(language: language, theme: theme.wrappedValue,
                                                          configuration: .defaults(for: language)))
    }

    var body: some View {
        VStack(spacing: 0) {
            LemonTextEditor(model: model)
                .ignoresSafeArea(.container, edges: .bottom)
            StatusBar(model: model, title: source.title, message: loadMessage)
        }
        .background(Color(uiColor: model.theme.background.uiColor))
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onChange(of: theme) { _, newValue in model.theme = newValue }
        .task { await load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.perform(.find) } label: { Label("Find", systemImage: "magnifyingglass") }
            Button { model.perform(.showGoToLine) } label: { Label("Go to Line", systemImage: "arrow.down.to.line") }
            Menu {
                Toggle("Minimap", isOn: binding(\.showMinimap))
                Toggle("Word Wrap", isOn: binding(\.softWrap))
                Toggle("Invisibles", isOn: binding(\.showInvisibles))
                Toggle("Indentation Guides", isOn: binding(\.showIndentGuides))
                Toggle("Line Numbers", isOn: binding(\.showLineNumbers))
                Divider()
                Button("Fold All") { model.perform(.foldAll) }
                Button("Unfold All") { model.perform(.unfoldAll) }
                Divider()
                Button("Larger Text") { model.configuration.font.size += 1 }
                Button("Smaller Text") { model.configuration.font.size -= 1 }
            } label: {
                Label("View", systemImage: "eye")
            }
            Menu {
                ForEach(EditorTheme.builtIn) { candidate in
                    Button {
                        theme = candidate
                    } label: {
                        if candidate == theme {
                            Label(candidate.name, systemImage: "checkmark")
                        } else {
                            Text(candidate.name)
                        }
                    }
                }
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            Menu {
                Button("Show Sample Diagnostics") { DemoStaging.showDiagnostics(in: model) }
                Button("Inline Suggestion") { DemoStaging.showInlineSuggestion(in: model) }
                Button("Carets on Every Match") { DemoStaging.showMultipleCarets(in: model) }
                Button("Clear Diagnostics") { model.diagnostics = []; model.gutterMarkers = [] }
            } label: {
                Label("Demo", systemImage: "sparkles")
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<EditorConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { model.configuration[keyPath: keyPath] }, set: { model.configuration[keyPath: keyPath] = $0 })
    }

    private func load() async {
        let text: String
        let fileName: String
        switch source {
        case .sample(let sample):
            text = sample.load()
            fileName = sample.fileName
        case .file(let url):
            loadMessage = "Reading…"
            let data = await Task.detached { (try? Data(contentsOf: url)) ?? Data() }.value
            text = String(decoding: data, as: UTF8.self)
            fileName = url.lastPathComponent
        }
        model.load(text: text, fileName: fileName)
        loadMessage = nil
        let options = LaunchOptions.current
        if options.hidesSoftwareKeyboard {
            // Screenshots stand in for an iPad with a Magic Keyboard attached.
            model.controller?.showsSoftwareKeyboard = false
        }
        if let stage = options.stage {
            try? await Task.sleep(for: .milliseconds(900))
            if options.hidesSoftwareKeyboard && !stage.contains("find") && !stage.contains("goto") && !stage.contains("replace") {
                _ = model.controller?.textView.becomeFirstResponder()
            }
            DemoStaging.apply(stage, to: model)
        }
    }
}

struct StatusBar: View {
    let model: LemonTextEditorModel
    let title: String
    let message: String?

    var body: some View {
        let theme = model.theme
        HStack(spacing: 14) {
            if let message {
                Text(message)
            }
            Text("Ln \(model.caretLine), Col \(model.caretColumn)")
            if model.selectionLength > 0 {
                Text("\(model.selectionLength) selected")
            }
            if model.caretCount > 1 {
                Text("\(model.caretCount) carets")
                    .foregroundStyle(Color(uiColor: theme.accent.uiColor))
            }
            if !model.diagnostics.isEmpty {
                let errors = model.diagnostics.filter { $0.severity == .error }.count
                let warnings = model.diagnostics.filter { $0.severity == .warning }.count
                Label("\(errors)", systemImage: "xmark.circle")
                    .foregroundStyle(Color(uiColor: theme.error.uiColor))
                Label("\(warnings)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color(uiColor: theme.warning.uiColor))
            }
            Spacer()
            if model.isHighlighting {
                ProgressView().controlSize(.mini)
                Text("Parsing")
            }
            Text("\(model.lineCount.formatted()) lines")
            Text(model.configuration.insertSpaces ? "Spaces: \(model.configuration.tabWidth)" : "Tabs")
            Text(model.language.displayName)
                .foregroundStyle(Color(uiColor: theme.foreground.uiColor))
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
        .foregroundStyle(Color(uiColor: theme.lineNumber.uiColor))
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Color(uiColor: theme.background.uiColor))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(uiColor: theme.separator.uiColor)).frame(height: 0.5)
        }
    }
}
