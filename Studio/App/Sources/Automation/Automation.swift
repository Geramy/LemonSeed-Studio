import SwiftUI
import UIKit
import os
import StudioCore
import StudioAgent
import StudioAgentUI

private let automationLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "automation")

/// Scripted checks for remote runs (devicectl … process launch … <args>):
///
///   --selftest     start LSE in-process with the Q4 + DFlash2 preset, time a
///                  completion, run one agent turn that must use the read
///                  tool on a sample workspace, and write
///                  Documents/studio-selftest.txt
///   --screenshots  render each main screen of the key window to
///                  Documents/screenshots/NN-name.png (after the self-test
///                  when both are given)
///   --automation-exit  end the process when done
@MainActor
enum Automation {
    static var selfTest: Bool { LaunchArguments.has("--selftest") }
    static var screenshots: Bool { LaunchArguments.has("--screenshots") }
    static var requested: Bool { selfTest || screenshots }

    static let workspaceName = "Selftest Workspace"
    /// The word the agent can only learn by reading notes/codeword.txt.
    static let codeWord = "MARMALADE-7319"

    private static var started = false
    private static var report: [String] = []

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func startIfRequested(app: AppModel) {
        guard requested, !started else { return }
        started = true
        Task {
            // Let the first window appear and claim its router.
            try? await Task.sleep(for: .seconds(2))
            await app.gpu.bootstrap()
            if selfTest { await runSelfTest(app: app) }
            if screenshots { await captureScreens(app: app) }
            if LaunchArguments.has("--automation-exit") {
                app.engine.stop()
                try? await Task.sleep(for: .seconds(5))
                exit(0)
            }
        }
    }

    // MARK: Self-test

    static func runSelfTest(app: AppModel) async {
        let started = Date()
        report = ["== LemonSeed Studio self-test \(ISO8601DateFormatter().string(from: started))"]
        let bundle = Bundle.main
        report.append("app: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")), \(EngineService.engineVersion)")
        report.append("driver: dext \(app.driver.embeddedDext ?? "not embedded"), enabled \(app.driver.isEnabled.map(String.init) ?? "n/a"), service \(app.driver.service.map { "\($0.className) 0x\(String($0.registryID, radix: 16))" } ?? "not found")")
        report.append("models: " + app.models.records.map { "\($0.id) [\($0.role)] \($0.state)" }.joined(separator: ", "))
        write()

        // 1. The engine with the standard Q4 + DFlash2 preset.
        guard let model = app.gpu.mainModels.first(where: { $0.id.localizedCaseInsensitiveContains("q4") }) ?? app.gpu.mainModels.first,
              let launch = EngineLaunch(model: model, settings: app.models.defaultLoadSettings(for: model.id), library: app.models)
        else {
            fail("no installed main model in Documents/Models")
            return
        }
        report.append("launch: \(launch.modelID) draft=\(launch.draftID ?? "none") kv=\(launch.kvCacheDType)/\(launch.kvLength) batch=\(launch.batchSize)/\(launch.ubatchSize) temp=\(launch.temperature.map { String($0) } ?? "default")")
        app.gpu.selectedModelID = model.id
        if app.engine.launch != launch || app.engine.phase != .ready {
            if app.engine.phase == .ready { app.engine.reload(launch) } else { app.engine.start(launch) }
        }
        let loadStart = Date()
        while true {
            switch app.engine.phase {
            case .ready where app.engine.launch == launch: break
            case .failed(let why):
                report.append("FAIL engine open: \(why)")
                report.append(contentsOf: app.engine.log.suffix(40).map { "  log: \($0)" })
                write()
                return
            default:
                if Date().timeIntervalSince(loadStart) > 1200 {
                    fail("engine did not become ready in 20 minutes (\(app.engine.statusLine))")
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            break
        }
        report.append(String(format: "OK   engine ready: load %.1f s (this launch waited %.1f s)", app.engine.loadSeconds ?? 0,
                             Date().timeIntervalSince(loadStart)))
        write()

        // 2. A plain completion through the agent's transport, for speed.
        await timedCompletion(app: app)

        // 3. One agent turn in the AI panel's view model, on a sample workspace.
        await agentTurn(app: app)

        report.append(String(format: "total %.1f s", Date().timeIntervalSince(started)))
        write()
    }

    private static func timedCompletion(app: AppModel) async {
        let client = OpenAICompatibleClient(configuration: EndpointConfiguration(model: app.engine.servedName),
                                            transport: app.engine.chatTransport())
        let body: [String: Any] = [
            "model": app.engine.servedName,
            "messages": [["role": "user", "content": "Complete this Python function and return only the code:\n\ndef has_close_elements(numbers: list[float], threshold: float) -> bool:\n    \"\"\"Check if in given list of numbers, are any two numbers closer to each other than given threshold.\"\"\"\n"]],
            "max_tokens": 256,
            "temperature": 0.6,
        ]
        for run in 1...2 {
            let started = Date()
            do {
                let data = try await client.transport.request(method: "POST", path: "chat/completions",
                                                              body: try JSONSerialization.data(withJSONObject: body), timeout: 900)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let usage = object["usage"] as? [String: Any] ?? [:]
                let t = object["timings"] as? [String: Any] ?? [:]
                let text = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
                var line = String(format: "OK   completion %d: prompt %d tok @ %.1f tok/s, decode %d tok @ %.1f tok/s",
                                  run, usage["prompt_tokens"] as? Int ?? 0, t["prompt_per_second"] as? Double ?? 0,
                                  usage["completion_tokens"] as? Int ?? 0, t["decode_per_second"] as? Double ?? 0)
                if let a = t["acceptance_rate"] as? Double { line += String(format: ", DFlash2 acceptance %.1f%%", a * 100) }
                line += String(format: ", %.1f s wall", Date().timeIntervalSince(started))
                report.append(line)
                report.append("     text: " + text.prefix(160).replacingOccurrences(of: "\n", with: " "))
            } catch {
                report.append("FAIL completion \(run): \(error)")
            }
            write()
        }
        app.engine.refreshTimings()
    }

    /// The sample workspace: a few files, one of which holds the code word.
    static func prepareWorkspace(app: AppModel) -> URL {
        let root = app.library.projectsFolder.appendingPathComponent(workspaceName, isDirectory: true)
        let files: [String: String] = [
            "README.md": "# Selftest Workspace\n\nA small C project the LemonSeed Studio self-test opens.\nThe release code word is kept in notes/codeword.txt.\n",
            "notes/codeword.txt": "The release code word is \(codeWord).\n",
            "src/main.c": "#include <stdio.h>\n#include \"util.h\"\n\nint main(void) {\n    printf(\"%d\\n\", add(2, 3));\n    return 0;\n}\n",
            "src/util.h": "#pragma once\n\nint add(int a, int b);\n",
            "src/util.c": "#include \"util.h\"\n\nint add(int a, int b) { return a + b; }\n",
            "Makefile": "all:\n\tcc -o hello src/main.c src/util.c\n",
        ]
        let fm = FileManager.default
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        return root
    }

    private static func agentTurn(app: AppModel) async {
        let root = prepareWorkspace(app: app)
        if let router = app.activeRouter, router.controller?.rootURL.standardizedFileURL != root.standardizedFileURL {
            router.openProject(named: workspaceName)
            try? await Task.sleep(for: .seconds(1))
        }
        app.activeRouter?.controller?.show(.agent)
        guard let provider = app.services.agent as? StudioAgentProvider else {
            fail("the agent provider is not StudioAgentProvider")
            return
        }
        let model = provider.viewModel(for: app.activeRouter?.controller?.rootURL ?? root, displayName: workspaceName)
        model.newSession()
        model.mode = .readOnly
        let prompt = "What is the release code word in this project? Use your tools to find and read the file that holds it, then answer with the code word."
        let started = Date()
        model.send(prompt)
        try? await Task.sleep(for: .milliseconds(300))
        while model.isRunning, Date().timeIntervalSince(started) < 900 {
            try? await Task.sleep(for: .milliseconds(300))
        }
        let seconds = Date().timeIntervalSince(started)
        var tools: [String] = []
        var answer = ""
        var errors: [String] = []
        for item in model.items {
            switch item.kind {
            case .tool(let card):
                let path = card.arguments["path"]?.stringValue ?? card.arguments["pattern"]?.stringValue ?? ""
                tools.append("\(card.name)(\(path)) \(card.status)")
            case .assistant(let block):
                if !block.text.isEmpty { answer = block.text }
                if let e = block.errorMessage { errors.append(e) }
            case .notice(let text, let isError):
                if isError { errors.append(text) }
            default:
                break
            }
        }
        let usedRead = model.items.contains { item in
            if case .tool(let card) = item.kind { return card.name == "read" && card.status == .done }
            return false
        }
        let found = answer.contains(codeWord)
        report.append(String(format: "%@ agent turn: %.1f s, tools [%@], read tool used: %@, code word in answer: %@",
                             usedRead && found ? "OK  " : "FAIL", seconds, tools.joined(separator: ", "),
                             usedRead ? "yes" : "no", found ? "yes" : "no"))
        report.append("     prompt: \(prompt)")
        report.append("     answer: " + answer.prefix(400).replacingOccurrences(of: "\n", with: " "))
        if let t = model.stats.lastTimings {
            report.append(String(format: "     last turn: prompt %d tok @ %.1f tok/s, decode %d tok @ %.1f tok/s%@",
                                 t.promptTokens ?? 0, t.promptPerSecond ?? 0, t.decodeTokens ?? 0, t.decodePerSecond ?? 0,
                                 t.acceptanceRate.map { String(format: ", acceptance %.1f%%", $0 * 100) } ?? ""))
        }
        report.append(contentsOf: errors.map { "     error: \($0)" })
        write()
    }

    private static func fail(_ message: String) {
        report.append("FAIL \(message)")
        write()
    }

    private static func write() {
        let text = report.joined(separator: "\n") + "\n"
        automationLog.log("\(report.last ?? "", privacy: .public)")
        try? text.write(to: documents.appendingPathComponent("studio-selftest.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Screenshots

    static func captureScreens(app: AppModel) async {
        let folder = documents.appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Wait for the engine to settle so the status bar shows its state.
        let waitStart = Date()
        while Date().timeIntervalSince(waitStart) < 900 {
            if case .loading = app.engine.phase { try? await Task.sleep(for: .seconds(1)); continue }
            break
        }
        var index = 0
        func shot(_ name: String, delay: Double = 1.6) async {
            try? await Task.sleep(for: .seconds(delay))
            index += 1
            let file = folder.appendingPathComponent(String(format: "%02d-%@.png", index, name))
            if let data = snapshot() {
                try? data.write(to: file)
                automationLog.log("screenshot \(file.lastPathComponent, privacy: .public)")
            }
        }

        let root = prepareWorkspace(app: app)
        guard let router = app.activeRouter else { return }
        if router.controller?.rootURL.standardizedFileURL != root.standardizedFileURL {
            router.openProject(named: workspaceName)
        }
        try? await Task.sleep(for: .seconds(1))
        guard let controller = router.controller else { return }
        controller.open(root.appendingPathComponent("src/main.c"), at: nil)
        if !controller.isSidebarVisible { controller.toggleSidebar() }

        controller.show(SidebarItem.explorer)
        await shot("editor-explorer")
        controller.show(SidebarItem.agent)
        await shot("ai-chat")
        controller.show(SidebarItem.models)
        await shot("models")
        app.isModelsManagerPresented = true
        await shot("models-manager", delay: 2.5)
        app.isModelsManagerPresented = false
        try? await Task.sleep(for: .seconds(1))
        controller.show(SidebarItem.gpu)
        for page in GPUHubView.Page.allCases {
            app.gpuPage = page.rawValue
            await shot("gpu-" + page.rawValue.lowercased(), delay: 2.5)
        }
        app.gpuPage = GPUHubView.Page.engine.rawValue
        if let model = app.gpu.selectedModel {
            app.loadSettingsModelID = model.id
            await shot("load-settings", delay: 2.5)
            app.loadSettingsModelID = nil
            try? await Task.sleep(for: .seconds(1))
        }
        controller.show(SidebarItem.sourceControl)
        await shot("source-control")
        controller.show(SidebarItem.search)
        await shot("search")
        controller.show(PanelTab.terminal)
        await shot("terminal", delay: 2.5)
        controller.show(SidebarItem.explorer)
        router.showSettings()
        await shot("settings")
        router.isSettingsPresented = false
        try? await Task.sleep(for: .seconds(1))
        controller.show(SidebarItem.agent)
        await shot("final")
    }

    /// The key window, as drawn now.
    static func snapshot() -> Data? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
    }
}
