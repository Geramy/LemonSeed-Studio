import StudioAgent
import StudioAgentUI
import SwiftUI

@main
struct AgentDemoApp: App {
    @State private var demo = DemoEnvironment()

    var body: some Scene {
        WindowGroup {
            DemoRootView(demo: demo)
                .agentTheme(.standard)
                .tint(AgentTheme.standard.accent)
        }
    }
}

/// Launch configuration: sample workspace, engine or script, and the
/// initial surface (for screenshots).
@MainActor @Observable
final class DemoEnvironment {
    let workspace: LocalWorkspace
    let model: AgentViewModel
    let explainer: InlineExplainer
    let screen: String
    let autoPrompt: String?

    init() {
        let defaults = UserDefaults.standard
        let root = DemoWorkspace.prepare(reset: defaults.bool(forKey: "resetWorkspace"))
        workspace = LocalWorkspace(rootURL: root, displayName: "mathx")
        var endpoint = EndpointConfiguration()
        if let url = defaults.string(forKey: "endpoint").flatMap(URL.init(string:)) { endpoint.baseURL = url }
        if let model = defaults.string(forKey: "model") { endpoint.model = model }
        let client: any LLMClient = defaults.bool(forKey: "scripted")
            ? ScriptedLLMClient(DemoScript.replies, delay: .milliseconds(28))
            : OpenAICompatibleClient(configuration: endpoint)
        let mode = defaults.string(forKey: "mode").flatMap(PermissionMode.init(rawValue:)) ?? .review
        let config = AgentConfiguration(endpoint: endpoint, thinking: .low, permissionMode: mode)
        model = AgentViewModel(workspace: workspace, client: client, configuration: config)
        explainer = InlineExplainer(client: defaults.bool(forKey: "scripted")
                                        ? ScriptedLLMClient([DemoScript.explanation], delay: .milliseconds(20))
                                        : client,
                                    model: endpoint.model, contextWindow: endpoint.contextWindow,
                                    outputLimit: endpoint.maxOutputTokens)
        screen = defaults.string(forKey: "screen") ?? "chat"
        autoPrompt = defaults.string(forKey: "autoPrompt")
    }
}

enum DemoWorkspace {
    /// Copies the bundled sample into Documents (visible in Files) once.
    static func prepare(reset: Bool) -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appending(path: "mathx", directoryHint: .isDirectory)
        if reset { try? fm.removeItem(at: dest) }
        if !fm.fileExists(atPath: dest.path), let src = Bundle.main.url(forResource: "SampleWorkspace", withExtension: nil) {
            try? fm.copyItem(at: src, to: dest)
        }
        return dest
    }
}
