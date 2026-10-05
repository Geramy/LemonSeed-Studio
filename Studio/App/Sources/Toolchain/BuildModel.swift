import Foundation
import Observation
import StudioCore
import StudioToolchain

/// One window's builds: what the Build panel shows and what Build (⌘B) and
/// Run (⌘R) do. The project builds from its studio-build.json when it has
/// one, otherwise the C or C++ file in the editor is built on its own.
@MainActor
@Observable
final class BuildModel {
    enum State: Equatable {
        case idle
        case building
        case built(succeeded: Bool)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var title = ""
    private(set) var log = ""
    private(set) var output: URL?
    private(set) var arguments: [String] = []
    private(set) var target: CompileTarget = .wasip1
    private(set) var milliseconds: Double = 0
    private(set) var errorCount = 0
    private(set) var warningCount = 0
    /// The runner the module will use, and why, after a successful build.
    private(set) var runner: (runner: WasmRunner, reason: String)?

    @ObservationIgnored private weak var controller: WorkspaceController?

    init(controller: WorkspaceController) {
        self.controller = controller
    }

    var root: URL? { controller?.workspace.rootURL }

    /// What Build builds now, for the panel's header.
    var subject: String {
        guard let root else { return "" }
        if FileManager.default.fileExists(atPath: root.appending(path: ProjectManifest.fileName).path) {
            return "Project · \(ProjectManifest.fileName)"
        }
        if let file = buildableFile { return "File · \(file.lastPathComponent)" }
        return "Nothing to build"
    }

    /// What single files (no studio-build.json) are built for, remembered
    /// across launches.
    private(set) var fileTarget: CompileTarget = {
        UserDefaults.standard.string(forKey: BuildModel.fileTargetKey).flatMap(CompileTarget.init(rawValue:)) ?? .wasip1
    }()
    static let fileTargetKey = "build.fileTarget"

    /// Bumped when the manifest's target changes here, so the panel rereads it.
    private var manifestRevision = 0

    var hasManifest: Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.appending(path: ProjectManifest.fileName).path)
    }

    /// What Build builds for: the manifest's target for a project, the
    /// remembered choice for a single file.
    var currentTarget: CompileTarget {
        _ = manifestRevision
        guard let root, hasManifest else { return fileTarget }
        return (try? ProjectManifest.load(from: root))?.target ?? .wasip1
    }

    /// The targets this build of the app has libraries for.
    var availableTargets: [CompileTarget] {
        ToolchainService.shared.resources?.availableTargets ?? []
    }

    /// Chooses the target: written into studio-build.json for a project,
    /// remembered for single files.
    func choose(_ target: CompileTarget) {
        guard let root else { return }
        if hasManifest {
            do {
                try ProjectManifest.setTarget(target, in: root)
                manifestRevision += 1
                controller?.workspace.output.append("Target set to \(target.rawValue) in \(ProjectManifest.fileName)", channel: "Build")
            } catch {
                state = .failed(error.localizedDescription)
            }
        } else {
            fileTarget = target
            UserDefaults.standard.set(target.rawValue, forKey: Self.fileTargetKey)
        }
    }

    var buildableFile: URL? {
        guard let url = controller?.activeDocument?.url else { return nil }
        return ["c", "cc", "cpp", "cxx", "c++", "cp"].contains(url.pathExtension.lowercased()) ? url : nil
    }

    var isBuilding: Bool { state == .building }

    func build() async -> Bool {
        guard let controller, let root, !isBuilding else { return false }
        state = .building
        log = ""
        runner = nil
        controller.workspace.output.append("Build started", channel: "Build")
        do {
            // The editor's unsaved changes are what the user means to build.
            try await controller.workspace.saveAll()
            let build = try await ToolchainService.shared.build(file: buildableFile, root: root, fileTarget: fileTarget)
            title = build.title
            log = build.log
            output = build.output
            arguments = build.arguments
            target = build.target
            milliseconds = build.milliseconds
            errorCount = build.diagnostics.filter { $0.level == .error || $0.level == .fatal }.count
            warningCount = build.diagnostics.filter { $0.level == .warning }.count
            ToolchainService.shared.publish(build.diagnostics, root: root, to: controller.workspace.diagnostics)
            if build.succeeded, let data = try? Data(contentsOf: build.output),
               let info = try? WasmModuleInfo(data: data) {
                runner = WasmRunner.choose(for: info)
            }
            state = .built(succeeded: build.succeeded)
            controller.workspace.output.append(
                (build.succeeded ? "Build succeeded: " : "Build failed: ") + build.title
                    + String(format: " (%.0f ms)", build.milliseconds) + (build.log.isEmpty ? "" : "\n" + build.log),
                channel: "Build")
            return build.succeeded
        } catch {
            state = .failed(error.localizedDescription)
            controller.workspace.output.append("Build failed: \(error.localizedDescription)", channel: "Build")
            return false
        }
    }

    /// Builds, then runs the program in the terminal (stdin and output there).
    func run() async {
        guard let controller, let root else { return }
        guard await build(), let output else { return }
        let relative = FileOperations.relativePath(of: output, to: root) ?? output.path
        let line = (["run", relative] + arguments).map(Self.quote).joined(separator: " ")
        controller.show(.terminal)
        (controller.ensureTerminal() as? CommandRunningSession)?.send(line: line)
    }

    static func quote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:,@+".contains($0) } && !s.isEmpty
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
