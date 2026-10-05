import Foundation
import Observation
import StudioCore
import StudioToolchain

/// C and C++ on the iPad: clang and wasm-ld inside the app compile to
/// WebAssembly (WASI), and programs run either in WebKit's JIT or in WAMR's
/// interpreter, chosen from what the module imports. Nothing is downloaded:
/// the compiler, the WASI libraries and both runtimes ship in the app, and
/// every program is one the user wrote and built.
@MainActor
final class ToolchainService {
    static let shared = ToolchainService()

    let resources: ToolchainResources?
    let compiler: Compiler?
    private let wamr = WAMRRunner()
    private var webKitRunner: WebKitRunner?

    init(bundle: Bundle = .main) {
        resources = ToolchainResources.bundled(in: bundle)
        compiler = resources.flatMap { Compiler.isAvailable ? Compiler(resources: $0) : nil }
    }

    /// Why the toolchain cannot run, or nil when it can.
    var unavailableReason: String? {
        if resources == nil { return "The WASI libraries (WASIToolchain) are missing from this build of the app." }
        if !Compiler.isAvailable { return "This build of the app has no compiler: \(Compiler.version)" }
        return nil
    }

    var version: String { "\(Compiler.version), \(WAMRRunner.version)" }

    // MARK: Running

    struct RunOutcome: Sendable {
        var result: WasmRunResult
        var runner: WasmRunner
        var reason: String
    }

    enum RunError: Error, LocalizedError {
        case unreadable(String, String)
        case notWasm(String, String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let path, let why): "\(path): \(why)"
            case .notWasm(let path, let why): "\(path): \(why)"
            }
        }
    }

    /// Runs a WASI program. `runner` nil chooses from the module's imports
    /// (WebKit for pure computation, WAMR for stdin, files, sockets and
    /// threads). `directory` is all the program can reach of the file system.
    func run(_ program: URL, arguments: [String], directory: URL, runner forced: WasmRunner? = nil,
             input: WasmInput? = nil, output: @escaping WasmOutputHandler) async throws -> RunOutcome {
        let data: Data
        do { data = try Data(contentsOf: program) } catch {
            throw RunError.unreadable(program.lastPathComponent, error.localizedDescription)
        }
        let info: WasmModuleInfo
        do { info = try WasmModuleInfo(data: data) } catch {
            throw RunError.notWasm(program.lastPathComponent, error.localizedDescription)
        }
        let choice = WasmRunner.choose(for: info)
        let runner = forced ?? choice.runner
        let reason = forced == nil ? choice.reason : "chosen with --runner"
        let argv = [program.lastPathComponent] + arguments
        let environment = ["PWD": "/", "HOME": "/", "TERM": "xterm-256color"]
        switch runner {
        case .wamr:
            let result = await wamr.run(wasm: data, arguments: argv, environment: environment,
                                        preopenDirectory: directory, input: input, allowNetwork: true,
                                        output: output)
            return RunOutcome(result: result, runner: .wamr, reason: reason)
        case .webKit:
            let web = webKitRunner ?? WebKitRunner()
            webKitRunner = web
            let result: WasmRunResult = await withTaskCancellationHandler {
                do {
                    return try await web.run(wasm: data, arguments: argv, environment: environment, output: output)
                } catch {
                    return WasmRunResult(exitCode: -1, error: error.localizedDescription, loadMilliseconds: 0,
                                         instantiateMilliseconds: 0, runMilliseconds: 0, totalMilliseconds: 0)
                }
            } onCancel: {
                Task { @MainActor in web.reset() }
            }
            return RunOutcome(result: result, runner: .webKit, reason: reason)
        }
    }

    // MARK: Building

    /// A build for the Build panel and the Problems list.
    struct Build: Sendable {
        var title: String
        var succeeded: Bool
        var output: URL
        var log: String
        var diagnostics: [StudioToolchain.Diagnostic]
        var milliseconds: Double
        var target: CompileTarget
        var arguments: [String]
    }

    /// Builds the project's studio-build.json when there is one (for its
    /// target), otherwise the single file for `fileTarget`, to
    /// `build/<name>.wasm`.
    func build(file: URL?, root: URL, fileTarget: CompileTarget) async throws -> Build {
        guard let compiler else { throw ToolchainError.unavailable(unavailableReason ?? "") }
        if FileManager.default.fileExists(atPath: root.appending(path: ProjectManifest.fileName).path) {
            let manifest = try ProjectManifest.load(from: root)
            let builder = ProjectBuilder(compiler: compiler, root: root, manifest: manifest)
            let result = try await builder.build()
            var summary = "\(result.compiled) compiled, \(result.upToDate) up to date"
            if result.linked { summary += ", linked" }
            return Build(title: "\(manifest.name) (\(summary))", succeeded: result.succeeded, output: result.output,
                         log: result.log, diagnostics: result.diagnostics, milliseconds: result.milliseconds,
                         target: manifest.target ?? .wasip1, arguments: manifest.args ?? [])
        }
        guard let file else { throw ToolchainError.nothingToBuild }
        let output = root.appending(path: "build/\(file.deletingPathExtension().lastPathComponent).wasm")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = await compiler.compile(sources: [file], output: output, language: SourceLanguage(path: file.path),
                                            extraArguments: ["-Wall"], workingDirectory: root, target: fileTarget)
        return Build(title: file.lastPathComponent, succeeded: result.succeeded, output: output, log: result.log,
                     diagnostics: result.diagnostics, milliseconds: result.totalMilliseconds, target: fileTarget,
                     arguments: [])
    }

    enum ToolchainError: Error, LocalizedError {
        case unavailable(String)
        case nothingToBuild
        var errorDescription: String? {
            switch self {
            case .unavailable(let why): why
            case .nothingToBuild: "Open a C or C++ file, or add a studio-build.json to the project."
            }
        }
    }

    /// The compiler's diagnostics in the workspace's Problems list (source
    /// "clang"), replacing the previous build's.
    func publish(_ diagnostics: [StudioToolchain.Diagnostic], root: URL, to center: DiagnosticsCenter) {
        center.clear(source: "clang")
        var byFile: [URL: [StudioCore.Diagnostic]] = [:]
        for d in diagnostics where !d.file.isEmpty {
            let url = d.file.hasPrefix("/") ? URL(fileURLWithPath: d.file) : root.appending(path: d.file)
            let severity: StudioCore.Diagnostic.Severity = switch d.level {
            case .error, .fatal: .error
            case .warning: .warning
            case .note, .remark: .info
            }
            let position = TextPosition(line: max(1, d.line), column: max(1, d.column))
            byFile[url.standardizedFileURL, default: []].append(
                StudioCore.Diagnostic(url: url, at: position, severity: severity, message: d.message, source: "clang"))
        }
        for (url, list) in byFile { center.set(list, for: url, source: "clang") }
    }
}
