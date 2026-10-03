import Foundation
import StudioCore
import StudioTerminal
import LemonText

/// Where packages plug into the Studio.
///
/// Each subsystem implements one StudioCore protocol and is registered here
/// at launch. To add a package:
///
/// 1. In Studio/project.yml, add it under `packages:` (a local `path:`) and
///    as a `- package: Name` dependency of the LemonSeedStudio target.
/// 2. Register its provider below. Registration replaces the built-in
///    fallback; nothing else in the shell changes.
///
///    | Package          | Protocol            | Registration                                  |
///    |------------------|---------------------|-----------------------------------------------|
///    | LemonText        | EditorProviding     | `services.register(editor: …)`                |
///    | StudioGit        | GitProviding        | `services.git = …`                            |
///    | StudioAgent      | AgentProviding      | `services.agent = …` (endpoint: settings.lseEndpointURL) |
///    | StudioTelemetry  | TelemetryProviding  | `services.telemetry = …`                      |
///    | (terminal)       | TerminalProviding   | `services.terminal = …`                       |
///
/// 3. Optionally contribute palette and menu commands with
///    `AppModel.shared.commands.register(StudioCommand(...))`.
@MainActor
enum StudioPlugins {
    static func register(into services: StudioServices, settings: AppSettings, driver: DriverMonitor) {
        // The editor: LemonText for every loaded text document. The plain
        // text view stays registered as the last resort.
        if LaunchOptions.editor != "plain" {
            services.register(editor: LemonTextEditorProvider())
        }

        // Built into the shell.
        services.terminal = SwiftTermTerminalProvider()
        services.telemetry = DriverTelemetryProvider(driver: driver)
        services.agent = EndpointAgentProvider(endpoint: settings.lseEndpointURL)

        // Packages register here, e.g.:
        // services.git = StudioGitProvider()
        // services.agent = StudioAgentProvider(endpoint: settings.lseEndpointURL)
        // services.telemetry = StudioTelemetryProvider(fallback: driver)
    }
}

extension ShellTerminalSession: CommandRunningSession {}
