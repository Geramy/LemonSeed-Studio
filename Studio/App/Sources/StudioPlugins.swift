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
    static func register(into services: StudioServices, settings: AppSettings, driver: DriverMonitor,
                         engine: EngineService) {
        // The editor: LemonText for every loaded text document. The plain
        // text view stays registered as the last resort.
        if LaunchOptions.editor != "plain" {
            services.register(editor: LemonTextEditorProvider())
        }

        // Built into the shell, with the C/C++ toolchain's clang, clang++, cc,
        // c++ and run commands.
        BuiltinShell.extraCommands = ToolchainCommands.all
        services.terminal = SwiftTermTerminalProvider()

        // StudioTelemetry's GPU monitor over the driver monitor and the engine.
        services.telemetry = StudioTelemetryProvider(driver: driver, engine: engine)
        // StudioAgent on the in-process engine (lse_request, no HTTP).
        services.agent = StudioAgentProvider(engine: engine)
        // StudioGit: libgit2, GitHub/GitLab accounts, the Source Control panel.
        services.git = StudioGitProvider()
    }
}

extension ShellTerminalSession: CommandRunningSession {}
