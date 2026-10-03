import SwiftUI
import StudioAgent
import StudioCore
import StudioDesign

enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance, editor, keyboard, accounts, model, engine, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .editor: "Editor"
        case .keyboard: "Keyboard Shortcuts"
        case .accounts: "Accounts"
        case .model: "Model Endpoint"
        case .engine: "GPU Driver"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .editor: "character.cursor.ibeam"
        case .keyboard: "keyboard"
        case .accounts: "person.crop.circle"
        case .model: StudioSymbol.agent
        case .engine: StudioSymbol.gpu
        case .about: "info.circle"
        }
    }
}

/// Settings: theme, fonts, editor options, keymap, accounts, the model
/// endpoint, the GPU driver, and about/licenses.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var page: SettingsPage?

    init(page: SettingsPage = .appearance) {
        _page = State(initialValue: page)
    }

    var body: some View {
        // A fixed page list beside the page, at any sheet width: a split
        // view would collapse to a stack in a narrow sheet and hide the list.
        HStack(spacing: 0) {
            NavigationStack {
                List(SettingsPage.allCases, selection: $page) { page in
                    Label(page.title, systemImage: page.symbol)
                        .tag(page)
                        // One element per row, so the identifier is not shared with the icon.
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.page.\(page.rawValue)")
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .scrollContentBackground(.hidden)
                .background(theme.palette.chrome.color)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("settings.done")
                    }
                }
            }
            .frame(width: 240)
            Hairline(.vertical)
            NavigationStack {
                Group {
                    switch page ?? .appearance {
                    case .appearance: AppearanceSettings()
                    case .editor: EditorSettingsPage()
                    case .keyboard: KeyboardSettings()
                    case .accounts: AccountsSettings()
                    case .model: ModelSettings()
                    case .engine: EngineSettings()
                    case .about: AboutSettings()
                    }
                }
                .navigationTitle((page ?? .appearance).title)
                .navigationBarTitleDisplayMode(.inline)
            }
            .id(page)
        }
        .presentationSizing(.page)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings")
    }
}

/// Grouped form styling shared by the settings pages.
private struct SettingsForm<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .scrollContentBackground(.hidden)
            .background(theme.palette.canvas.color)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var settings = app.settings
        SettingsForm {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.m)], spacing: Space.m) {
                    ForEach(Theme.builtIn) { candidate in
                        ThemeCard(candidate: candidate,
                                  isSelected: !settings.matchSystemAppearance && settings.themeID == candidate.id) {
                            settings.matchSystemAppearance = false
                            settings.themeID = candidate.id
                        }
                    }
                }
                .padding(.vertical, Space.s)
            } header: {
                Text("Theme")
            }
            Section {
                Toggle("Match System Appearance", isOn: $settings.matchSystemAppearance)
                    .accessibilityIdentifier("settings.matchSystem")
                if settings.matchSystemAppearance {
                    Picker("Light", selection: $settings.lightThemeID) {
                        ForEach(Theme.builtIn.filter { $0.appearance == .light }) { Text($0.name).tag($0.id) }
                    }
                    Picker("Dark", selection: $settings.darkThemeID) {
                        ForEach(Theme.builtIn.filter { $0.appearance == .dark }) { Text($0.name).tag($0.id) }
                    }
                }
            }
            Section {
                Picker("Density", selection: $settings.density) {
                    ForEach(Density.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("settings.density")
                Toggle("Show Activity Bar", isOn: $settings.showActivityBar)
            } footer: {
                Text("Automatic uses touch-sized targets, and switches to the compact layout when a keyboard or trackpad is attached.")
            }
        }
    }
}

private struct ThemeCard: View {
    @Environment(\.theme) private var current
    let candidate: Theme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s) {
                preview
                    .frame(height: 86)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .strokeBorder(isSelected ? current.palette.accent.color : current.palette.hairline.color,
                                      lineWidth: isSelected ? 2 : 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name)
                        .font(.studio(13, weight: .semibold))
                        .foregroundStyle(current.palette.textPrimary.color)
                    Text(candidate.summary)
                        .font(.studio(11))
                        .foregroundStyle(current.palette.textSecondary.color)
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityIdentifier("settings.theme.\(candidate.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A miniature window in the theme's colors.
    private var preview: some View {
        let p = candidate.palette
        let s = candidate.syntax
        return HStack(spacing: 0) {
            p.chrome.color.frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                codeLine([(s.keyword, 18), (s.type, 26), (s.plain, 12)])
                codeLine([(s.plain, 8), (s.function, 30), (s.punctuation, 6), (s.string, 22)])
                codeLine([(s.plain, 8), (s.keyword, 14), (s.number, 10)])
                codeLine([(s.comment, 44)])
                codeLine([(s.plain, 8), (s.property, 20), (s.operator, 6), (s.constant, 16)])
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(p.editor.color)
        }
        .overlay(alignment: .bottom) { p.accentFill.color.frame(height: 3) }
    }

    private func codeLine(_ runs: [(RGBA, CGFloat)]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                Capsule().fill(run.0.color).frame(width: run.1, height: 4)
            }
        }
    }
}

// MARK: - Editor

private struct EditorSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var settings = app.settings
        SettingsForm {
            Section("Font") {
                Picker("Family", selection: $settings.codeFontFamily) {
                    ForEach(CodeFontFamily.allCases) { family in
                        Text(family.displayName).tag(family)
                    }
                }
                .accessibilityIdentifier("settings.fontFamily")
                Stepper(value: $settings.codeFontSize, in: Double(CodeFont.sizeRange.lowerBound)...Double(CodeFont.sizeRange.upperBound), step: 1) {
                    LabeledContent("Size", value: "\(Int(settings.codeFontSize)) pt")
                }
                .accessibilityIdentifier("settings.fontSize")
                Text("func greet(_ name: String) -> String {\n    return \"Hello, \\(name)\" // 0O il1 {}\n}")
                    .font(settings.codeFont.font())
                    .lineSpacing(settings.codeFont.lineHeight - settings.codeFont.size * 1.2)
                    .foregroundStyle(theme.syntax.plain.color)
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.editor.color, in: RoundedRectangle(cornerRadius: Radius.s))
            }
            Section("Indentation") {
                Picker("Tab Width", selection: $settings.editor.tabWidth) {
                    ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Insert Spaces", isOn: $settings.editor.insertSpaces)
            }
            Section("Display") {
                Toggle("Word Wrap", isOn: $settings.editor.wordWrap)
                Toggle("Line Numbers", isOn: $settings.editor.showLineNumbers)
                Toggle("Minimap", isOn: $settings.editor.showMinimap)
                Toggle("Highlight Current Line", isOn: $settings.editor.highlightCurrentLine)
                Toggle("Show Invisibles", isOn: $settings.editor.showInvisibles)
                Toggle("Font Ligatures", isOn: $settings.editor.ligatures)
            }
            Section {
                Toggle("Save When Closing Tabs", isOn: $settings.editor.autosave)
                Toggle("Trim Trailing Whitespace on Save", isOn: $settings.editor.trimTrailingWhitespace)
            } header: {
                Text("Saving")
            } footer: {
                Text("Editors read these options through the environment; the built-in editor uses the font and colors.")
            }
        }
    }
}

// MARK: - Keyboard

private struct KeyboardSettings: View {
    @Environment(AppModel.self) private var app
    @State private var filter = ""

    var body: some View {
        let conflicts = app.commands.conflicts
        SettingsForm {
            Section {
                ForEach(filtered, id: \.id) { command in
                    HStack {
                        Label(command.paletteTitle, systemImage: command.symbol ?? StudioSymbol.command)
                        Spacer()
                        if let shortcut = command.shortcut {
                            if conflicts[shortcut] != nil {
                                Image(systemName: StudioSymbol.warning).foregroundStyle(.orange)
                            }
                            KeyCaps(shortcut.description)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("A VS Code-compatible keymap. An editable keymap file is planned. Hold ⌘ to see the shortcuts available in any window.")
            }
        }
        .searchable(text: $filter, prompt: "Filter commands")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.keyboard")
    }

    private var filtered: [StudioCommand] {
        let all = app.commands.commands.sorted { $0.paletteTitle.localizedStandardCompare($1.paletteTitle) == .orderedAscending }
        guard !filter.isEmpty else { return all }
        let matcher = FuzzyMatcher(filter)
        return all.filter { matcher.match($0.paletteTitle) != nil || ($0.shortcut?.description.contains(filter) ?? false) }
    }
}

// MARK: - Accounts

private struct AccountsSettings: View {
    var body: some View {
        SettingsForm {
            Section {
                account("GitHub", symbol: "chevron.left.forwardslash.chevron.right", detail: "github.com and GitHub Enterprise")
                account("GitLab", symbol: "chevron.left.forwardslash.chevron.right", detail: "gitlab.com and self-hosted GitLab")
            } footer: {
                Text("Sign-in, SSH keys in the Secure Enclave and multiple accounts arrive with the Git package. Credentials are kept in the Keychain on this iPad only.")
            }
        }
    }

    private func account(_ name: String, symbol: String, detail: String) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading) {
                    Text(name)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
            Spacer()
            Button("Sign In") {}
                .disabled(true)
        }
    }
}

// MARK: - Model endpoint

private struct ModelSettings: View {
    @Environment(AppModel.self) private var app
    @State private var result: String?
    @State private var checking = false

    var body: some View {
        @Bindable var settings = app.settings
        SettingsForm {
            Section {
                Picker("Default thinking", selection: $settings.agentThinking) {
                    ForEach(ThinkingLevel.pickerLevels, id: \.self) { level in
                        Text(level == .modelDefault ? "Default (model decides)" : level.title).tag(level)
                    }
                }
                .accessibilityIdentifier("settings.thinking")
            } header: {
                Text("Agent")
            } footer: {
                Text("The thinking level new chats start with (reasoning_effort: Off is none, Max is xhigh; Default sends nothing). Each chat keeps its own level; change it from the brain button in the composer.")
            }
            Section {
                TextField("http://127.0.0.1:8080/v1", text: $settings.lseEndpoint)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("settings.endpoint")
                HStack {
                    Button(checking ? "Checking…" : "Test Connection") { test() }
                        .disabled(checking)
                        .accessibilityIdentifier("settings.testEndpoint")
                    Spacer()
                    if let result {
                        Text(result).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                Button("Restore Default") { settings.lseEndpoint = ModelEndpointProbe.defaultEndpoint.absoluteString }
            } header: {
                Text("LemonSeed Engine (OpenAI-compatible)")
            } footer: {
                Text("The default reaches lse-server on this machine. From the iPad simulator, 127.0.0.1 is the Mac running it. On an iPad with the GPU attached, the engine runs in the app and this endpoint is optional.")
            }
        }
        .onChange(of: settings.lseEndpoint) { _, _ in result = nil }
    }

    private func test() {
        checking = true
        let url = app.settings.lseEndpointURL
        Task {
            do {
                let models = try await ModelEndpointProbe(baseURL: url).models()
                result = models.isEmpty ? "Reachable, no model loaded" : "Serving \(models.joined(separator: ", "))"
            } catch {
                result = "Not reachable"
            }
            checking = false
            if let agent = app.services.agent as? EndpointAgentProvider { agent.endpoint = url }
            await app.services.agent.refresh()
        }
    }
}

// MARK: - Engine

private struct EngineSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            EngineStatusView(driver: app.driver)
                .padding(Space.l)
        }
        .background(Color(.systemGroupedBackground).opacity(0))
    }
}

// MARK: - About

private struct AboutSettings: View {
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsForm {
            Section {
                HStack(spacing: Space.l) {
                    LemonMark(size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LemonSeed Studio").font(.title3.weight(.semibold))
                        Text("Version \(version) (\(build))").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Space.s)
            }
            Section("Open Source") {
                ForEach(Licenses.all) { entry in
                    NavigationLink {
                        ScrollView {
                            Text(entry.text)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .navigationTitle(entry.title)
                    } label: {
                        Label(entry.title, systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("settings.license.\(entry.title)")
                }
            }
        }
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
}

/// Third-party notices: every THIRD_PARTY.md the build collected into the
/// bundle's Licenses folder, plus the bundled fonts' licenses.
enum Licenses {
    struct Entry: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    static var all: [Entry] {
        var entries: [Entry] = []
        if let folder = Bundle.main.url(forResource: "Licenses", withExtension: nil),
           let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let title = file.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "-THIRD_PARTY", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                entries.append(Entry(title: title, text: text))
            }
        }
        for font in FontRegistry.bundledLicenses() {
            entries.append(Entry(title: font.name.replacingOccurrences(of: "-", with: " "), text: font.text))
        }
        return entries
    }
}
