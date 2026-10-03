import Foundation
import Observation

/// The registry the shell asks for editors, Git, the agent, telemetry and
/// terminals. It starts with the built-in fallbacks; packages replace them
/// at launch:
///
/// ```swift
/// // Studio/App/StudioPlugins.swift
/// services.register(editor: LemonTextEditorProvider())
/// services.git = StudioGitProvider()
/// services.agent = StudioAgentProvider(endpoint: settings.lseEndpoint)
/// services.telemetry = StudioTelemetryProvider()
/// services.terminal = SwiftTermTerminalProvider()
/// ```
@MainActor
@Observable
public final class StudioServices {
    public static let shared = StudioServices()

    /// Editor providers, in registration order.
    public private(set) var editors: [any EditorProviding]
    public var git: any GitProviding
    public var agent: any AgentProviding
    public var telemetry: any TelemetryProviding
    public var terminal: (any TerminalProviding)?

    public init(editors: [any EditorProviding] = [PlainTextEditorProvider()],
                git: any GitProviding = HeadFileGitProvider(),
                agent: any AgentProviding = EndpointAgentProvider(),
                telemetry: any TelemetryProviding = PlaceholderTelemetryProvider(),
                terminal: (any TerminalProviding)? = nil) {
        self.editors = editors
        self.git = git
        self.agent = agent
        self.telemetry = telemetry
        self.terminal = terminal
    }

    /// Adds an editor provider, replacing one with the same id.
    public func register(editor: any EditorProviding) {
        editors.removeAll { $0.id == editor.id }
        editors.append(editor)
    }

    /// The highest-priority editor for `document`. The built-in plain editor
    /// is the last resort, so there is always one.
    public func editor(for document: EditorDocument) -> any EditorProviding {
        var best: (provider: any EditorProviding, priority: Int)?
        for provider in editors {
            guard let priority = provider.priority(for: document) else { continue }
            if best == nil || priority > best!.priority { best = (provider, priority) }
        }
        return best?.provider ?? PlainTextEditorProvider.shared
    }
}
