import Foundation
import StudioCore
import StudioToolchain

/// `clang`, `clang++`, `cc` and `c++` in the terminal: the in-process clang,
/// compiling to wasm32-wasip1 unless the command line names another target
/// (`--target=wasm32-wasip1-threads`, or `-pthread`). Everything else is
/// clang's own command line.
struct ClangCommand: AsyncShellCommand {
    let name: String
    var cxx: Bool { name == "clang++" || name == "c++" }
    var summary: String { cxx ? "Compile C++ to WebAssembly (clang++, wasm32-wasip1)" : "Compile C to WebAssembly (clang, wasm32-wasip1)" }
    var usage: String { "\(name) [clang options] file... [-o out.wasm]" }

    func run(_ arguments: [String], context: inout ShellContext, io: ShellIO) async -> Int32 {
        let service = await ToolchainService.shared
        guard let compiler = await service.compiler else {
            io.error("\(name): \(await service.unavailableReason ?? "unavailable")\n")
            return 127
        }
        if arguments.isEmpty {
            io.error("\(name): no input files\n")
            return 1
        }
        // Paths on the command line must stay inside the workspace.
        for path in Self.outputPaths(arguments) {
            do { _ = try context.resolve(path) } catch {
                io.error("\(name): \(path): \(error.localizedDescription)\n")
                return 1
            }
        }
        let driver: [String]
        do {
            driver = try compiler.driverArguments(arguments, cxx: cxx, workingDirectory: context.workingDirectory)
        } catch {
            io.error("\(name): error: \(error.localizedDescription)\n")
            return 1
        }
        let result = await compiler.run(arguments: driver, output: context.workingDirectory)
        if !result.log.isEmpty {
            // clang prints diagnostics and -v output to stderr, --version to stdout.
            if arguments.contains("--version") || arguments.contains("-dumpversion") { io.write(result.log) } else { io.error(result.log) }
        }
        return result.exitCode
    }

    /// The -o argument, which must not escape the workspace.
    static func outputPaths(_ arguments: [String]) -> [String] {
        var out: [String] = []
        for (i, a) in arguments.enumerated() {
            if a == "-o", i + 1 < arguments.count { out.append(arguments[i + 1]) }
            else if a.hasPrefix("-o"), a.count > 2 { out.append(String(a.dropFirst(2))) }
        }
        return out
    }
}

/// `run program.wasm [args...]`: runs a WASI program with stdin, stdout and
/// stderr on the terminal, its files confined to the current directory, and
/// returns its exit code. The runner is chosen from the module's imports
/// (WebKit's JIT for pure computation, WAMR for stdin, files, sockets and
/// threads); `--runner wamr|webkit` overrides it.
struct RunCommand: AsyncShellCommand {
    let name = "run"
    let summary = "Run a WebAssembly (WASI) program"
    let usage = "run [--runner wamr|webkit] program.wasm [args...]"

    func run(_ arguments: [String], context: inout ShellContext, io: ShellIO) async -> Int32 {
        var args = arguments
        var forced: WasmRunner?
        if args.first == "--runner" {
            guard args.count >= 2, let r = WasmRunner(rawValue: args[1].lowercased()) else {
                io.error("run: --runner takes wamr or webkit\n")
                return 2
            }
            forced = r
            args.removeFirst(2)
        } else if let first = args.first, first.hasPrefix("--runner=") {
            guard let r = WasmRunner(rawValue: String(first.dropFirst(9)).lowercased()) else {
                io.error("run: --runner takes wamr or webkit\n")
                return 2
            }
            forced = r
            args.removeFirst()
        }
        guard let path = args.first else {
            io.error("usage: \(usage)\n")
            return 2
        }
        let program: URL
        do { program = try context.resolve(path) } catch {
            io.error("run: \(path): \(error.localizedDescription)\n")
            return 1
        }
        let input = WasmInput()
        let pump = Task {
            while let data = await io.readInput() { input.write(data) }
            input.close()
        }
        defer { pump.cancel() }
        let directory = context.workingDirectory
        let live = io.isLive
        do {
            let outcome = try await ToolchainService.shared.run(
                program, arguments: Array(args.dropFirst()), directory: directory, runner: forced, input: input
            ) { chunk in
                if chunk.stream == .stderr { io.error(chunk.text) } else { io.write(chunk.text) }
            }
            let r = outcome.result
            if live {
                var line = "\u{1B}[2m[\(outcome.runner.title): \(outcome.reason) · exit \(r.exitCode) · \(Int(r.totalMilliseconds.rounded())) ms]\u{1B}[0m\n"
                if !r.unsupportedImports.isEmpty {
                    line = "\u{1B}[33mnot available in WebKit: \(r.unsupportedImports.joined(separator: ", ")) (try --runner wamr)\u{1B}[0m\n" + line
                }
                io.error(line)
            }
            if let error = r.error {
                io.error("run: \(program.lastPathComponent): \(error)\n")
                return r.exitCode >= 0 ? r.exitCode : 1
            }
            return r.exitCode
        } catch {
            io.error("run: \(error.localizedDescription)\n")
            return 1
        }
    }
}

enum ToolchainCommands {
    static var all: [any ShellCommand] {
        [ClangCommand(name: "clang"), ClangCommand(name: "clang++"), ClangCommand(name: "cc"), ClangCommand(name: "c++"),
         RunCommand()]
    }
}
