import SwiftUI
import Observation
import StudioCore
import StudioDesign
import StudioAgent
import StudioAgentUI

/// The coding agent (StudioAgent) on the in-process engine.
///
/// Each workspace window gets its own `AgentViewModel` over the workspace
/// folder. The model client is StudioAgent's `OpenAICompatibleClient` with a
/// `ClosureChatTransport` into LSE (`lse_request`), so chat, tools and
/// sessions run with no socket and no HTTP.
@MainActor
@Observable
final class StudioAgentProvider: AgentProviding {
    let id = "com.geramyloveless.LemonSeedStudio.agent"
    let displayName = "LemonSeed agent (in-process LSE)"
    let engine: EngineService

    @ObservationIgnored private var models: [URL: AgentViewModel] = [:]
    @ObservationIgnored private var configurationKey: String?

    init(engine: EngineService) {
        self.engine = engine
    }

    var status: AgentStatus {
        let name = engine.launch?.modelName
        let backend = "on-device GPU"
        switch engine.phase {
        case .ready:
            if models.values.contains(where: \.isRunning) {
                return AgentStatus(state: .working("Generating"), modelName: name, backend: backend)
            }
            return AgentStatus(state: .idle, modelName: name, backend: backend)
        case .loading(let what):
            return AgentStatus(state: .connecting, modelName: nil, backend: what)
        case .waiting(let why):
            return AgentStatus(state: .unavailable(why), backend: backend)
        case .failed(let why):
            return AgentStatus(state: .unavailable(why), backend: backend)
        case .idle, .stopping:
            return AgentStatus(state: .unavailable("The engine is stopped."), backend: backend)
        }
    }

    /// The agent configuration for the engine as currently loaded.
    func configuration() -> AgentConfiguration {
        var endpoint = EndpointConfiguration(model: engine.servedName, toolProtocol: .native,
                                             contextWindow: engine.contextWindow, maxOutputTokens: 2048)
        endpoint.requestTimeout = 1800
        return AgentConfiguration(endpoint: endpoint, thinking: AppModel.shared.settings.agentThinking, permissionMode: .review,
                                  temperature: engine.launch?.temperature.map(Double.init))
    }

    func client() -> OpenAICompatibleClient {
        OpenAICompatibleClient(configuration: configuration().endpoint, transport: engine.chatTransport())
    }

    /// The view model for a workspace folder (one per folder, kept while the
    /// app runs; rebuilt when the engine's model or context changes).
    func viewModel(for root: URL, displayName: String) -> AgentViewModel {
        let key = "\(engine.servedName)|\(engine.contextWindow)"
        if key != configurationKey {
            // The served model or window changed: sessions keep their files,
            // but the next message starts with the new configuration.
            configurationKey = key
            models.removeAll()
        }
        if let existing = models[root] { return existing }
        let workspace = LocalWorkspace(rootURL: root, displayName: displayName, securityScoped: true)
        let model = AgentViewModel(workspace: workspace, client: client(), configuration: configuration())
        let engine = self.engine
        model.onSessionDeleted = { id in engine.closeSession(id) }
        model.refreshSessions()
        models[root] = model
        return model
    }

    /// Whether any chat is generating.
    var isGenerating: Bool { models.values.contains(where: \.isRunning) }

    func makePanel(context: any WorkspaceContext) -> AnyView {
        connect(viewModel(for: context.rootURL, displayName: context.displayName), to: context)
        return AnyView(StudioAgentPanel(provider: self, root: context.rootURL, name: context.displayName))
    }

    /// The chat of a workspace folder if one exists (does not create it).
    func existingModel(for root: URL) -> AgentViewModel? { models[root] }

    /// Files the agent changed in this workspace that wait for Accept/Deny.
    func pendingPaths(for root: URL) -> Set<String> { models[root]?.pendingPaths ?? [] }

    /// Ties a chat's review to the IDE: accepted files open in the editor,
    /// and every change on disk refreshes the explorer, open documents and
    /// source control.
    func connect(_ model: AgentViewModel, to context: any WorkspaceContext) {
        weak var weakContext = context as AnyObject as? WorkspaceController
        let root = context.rootURL
        model.onOpenFile = { path in
            guard let controller = weakContext else { return }
            controller.open(root.appending(path: path), at: nil)
        }
        model.onFilesChanged = { paths in
            guard let controller = weakContext else { return }
            let urls = paths.map { root.appending(path: $0) }
            Task {
                for directory in Set(urls.map { $0.deletingLastPathComponent() }) {
                    await controller.workspace.tree.reload(directory: directory)
                }
                for url in urls { await controller.workspace.openDocument(at: url)?.fileDidChangeOnDisk() }
                controller.workspace.rebuildIndex()
                await controller.refreshGitStatus()
            }
        }
    }

    func refresh() async {
        for model in models.values { await model.checkEngine() }
    }
}

/// The AI sidebar: the agent panel once the engine runs, its state before.
private struct StudioAgentPanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let provider: StudioAgentProvider
    let root: URL
    let name: String

    var body: some View {
        Group {
            if provider.engine.phase == .ready {
                AgentPanel(model: provider.viewModel(for: root, displayName: name))
                    .agentTheme(AgentTheme.studio(theme))
                    .id(provider.engine.servedName + "\(provider.engine.contextWindow)")
            } else {
                EngineGate(engine: provider.engine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.panel")
    }
}

/// Shown in place of a model-backed panel until the engine is ready.
struct EngineGate: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(AppModel.self) private var app
    let engine: EngineService

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                if case .loading = engine.phase {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.studio(type.body, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary.color)
            }
            Text(engine.statusLine)
                .font(.studio(type.caption))
                .foregroundStyle(theme.palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let progress = engine.loadProgress {
                ProgressView(value: progress)
                    .tint(theme.palette.accent.color)
            }
            switch engine.phase {
            case .idle, .failed, .waiting:
                Button {
                    engine.start()
                } label: {
                    Label("Start Engine", systemImage: "bolt.fill")
                }
                .buttonStyle(.studioPrimary)
                .disabled(!EngineService.isAvailable)
                .accessibilityIdentifier("engine.start")
            default:
                EmptyView()
            }
            Text("The agent runs on the GPU attached to this iPad, inside the app: LemonSeed Engine with the model chosen in Models.")
                .font(.studio(type.caption))
                .foregroundStyle(theme.palette.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch engine.phase {
        case .idle: "Engine stopped"
        case .waiting: "Waiting"
        case .loading: "Loading the model"
        case .ready: "Ready"
        case .stopping: "Stopping"
        case .failed: "Engine failed"
        }
    }

    private var symbol: String {
        switch engine.phase {
        case .failed: "xmark.octagon.fill"
        case .waiting: "hourglass"
        default: "bolt.slash"
        }
    }

    private var color: Color {
        switch engine.phase {
        case .failed: theme.palette.error.color
        case .waiting: theme.palette.warning.color
        default: theme.palette.textTertiary.color
        }
    }
}

extension AgentTheme {
    /// The agent views in the Studio theme's colors.
    static func studio(_ theme: Theme) -> AgentTheme {
        let p = theme.palette
        let s = theme.syntax
        var t = AgentTheme.standard
        t.accent = p.accent.color
        t.onAccent = p.textOnAccent.color
        t.background = p.chrome.color
        t.surface = p.editor.color
        t.elevatedSurface = p.elevated.color
        t.codeBackground = p.editor.color
        t.hairline = p.hairline.color
        t.primaryText = p.textPrimary.color
        t.secondaryText = p.textSecondary.color
        t.tertiaryText = p.textTertiary.color
        t.userBubble = p.accentWash.color
        t.addition = p.added.color
        t.deletion = p.deleted.color
        t.warning = p.warning.color
        t.danger = p.error.color
        t.success = p.success.color
        t.syntaxKeyword = s.keyword.color
        t.syntaxString = s.string.color
        t.syntaxComment = s.comment.color
        t.syntaxNumber = s.number.color
        return t
    }
}
