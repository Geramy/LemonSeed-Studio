import Foundation

/// The state one command sees while it runs. Commands are synchronous library
/// calls on the shell's task; long-running ones should poll `isCancelled`.
public final class ShellContext {
    public let args: [String]
    public let stdin: String
    public internal(set) var stdout = ""
    public internal(set) var stderr = ""
    public let fileSystem: WorkspaceFileSystem
    /// Current directory (inside the jail).
    public internal(set) var cwd: URL

    init(args: [String], stdin: String, fileSystem: WorkspaceFileSystem, cwd: URL) {
        self.args = args
        self.stdin = stdin
        self.fileSystem = fileSystem
        self.cwd = cwd
    }

    public var isCancelled: Bool { Task.isCancelled }

    public func out(_ s: String) { stdout += s }
    public func outLine(_ s: String) { stdout += s + "\n" }
    public func err(_ s: String) { stderr += s + "\n" }

    /// Resolves an argument relative to the current directory, inside the jail.
    public func resolve(_ path: String) throws -> URL {
        if path.hasPrefix("/") { return try fileSystem.resolve(path) }
        let rel = fileSystem.relativePath(of: cwd)
        return try fileSystem.resolve(rel.isEmpty ? path : rel + "/" + path)
    }

    /// Display form of a path relative to the current directory.
    public func display(_ url: URL) -> String {
        let rel = fileSystem.relativePath(of: url)
        let base = fileSystem.relativePath(of: cwd)
        if base.isEmpty { return rel.isEmpty ? "." : rel }
        if rel.hasPrefix(base + "/") { return String(rel.dropFirst(base.count + 1)) }
        return "/" + rel
    }
}

/// A command the in-process shell can run.
public protocol ShellCommand: Sendable {
    var info: ShellCommandInfo { get }
    /// Overrides the static class for argument-dependent commands.
    func classify(arguments: [String]) -> ShellCommandClass
    /// Returns the exit status.
    func run(_ ctx: ShellContext) throws -> Int32
}

extension ShellCommand {
    public func classify(arguments: [String]) -> ShellCommandClass { info.commandClass }
}

/// A closure-backed command, for registering library entry points.
public struct ClosureCommand: ShellCommand {
    public let info: ShellCommandInfo
    private let body: @Sendable (ShellContext) throws -> Int32

    public init(_ name: String, synopsis: String, class commandClass: ShellCommandClass,
                body: @escaping @Sendable (ShellContext) throws -> Int32) {
        info = ShellCommandInfo(name: name, synopsis: synopsis, commandClass: commandClass)
        self.body = body
    }

    public func run(_ ctx: ShellContext) throws -> Int32 { try body(ctx) }
}

/// A minimal POSIX-flavored shell that runs registered commands in process.
public struct InProcessShell: ShellProviding {
    private var registry: [String: any ShellCommand]

    public init(commands: [any ShellCommand] = BuiltinCommands.all) {
        registry = Dictionary(commands.map { ($0.info.name, $0) }, uniquingKeysWith: { _, b in b })
    }

    /// Adds or replaces a command (Toolchain registers clang, cmake, ninja…).
    public mutating func register(_ command: any ShellCommand) {
        registry[command.info.name] = command
    }

    public var commands: [ShellCommandInfo] {
        registry.values.map(\.info).sorted { $0.name < $1.name }
    }

    public func classify(_ commandLine: String) -> ShellCommandClass {
        guard let list = try? ShellSyntax.parse(commandLine) else { return .unknown }
        var worst = ShellCommandClass.readOnly
        for pipeline in list.pipelines {
            for cmd in pipeline.commands {
                guard let name = cmd.name, let c = registry[name] else { return .unknown }
                worst = max(worst, c.classify(arguments: cmd.words.dropFirst().map(\.text)))
                for r in cmd.redirects {
                    if case .stdoutTo(let target, _) = r, target != "/dev/null" { worst = max(worst, .mutating) }
                }
            }
        }
        return worst
    }

    public func run(_ commandLine: String, fileSystem: WorkspaceFileSystem, timeout: Duration,
                    output: @escaping @Sendable (String) -> Void) async -> ShellResult {
        let list: ShellSyntax.CommandList
        do { list = try ShellSyntax.parse(commandLine) } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            output(msg + "\n")
            return ShellResult(exitCode: 2, output: msg + "\n")
        }
        let registry = registry
        return await withTaskGroup(of: ShellResult?.self) { group in
            group.addTask {
                Self.execute(list, registry: registry, fileSystem: fileSystem, output: output)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return Task.isCancelled ? nil : ShellResult(exitCode: 124, output: "", timedOut: true)
            }
            var result = ShellResult(exitCode: 1, output: "")
            if let first = await group.next(), let r = first {
                result = r
            }
            group.cancelAll()
            return result
        }
    }

    static func execute(_ list: ShellSyntax.CommandList, registry: [String: any ShellCommand],
                        fileSystem: WorkspaceFileSystem, output: @Sendable (String) -> Void) -> ShellResult {
        var transcript = ""
        var status: Int32 = 0
        var cwd = fileSystem.root
        for (index, pipeline) in list.pipelines.enumerated() {
            if index > 0 {
                switch list.connectors[index - 1] {
                case .and where status != 0: continue
                case .or where status == 0: continue
                default: break
                }
            }
            if Task.isCancelled { return ShellResult(exitCode: 130, output: transcript) }
            var stdin = ""
            for (stage, cmd) in pipeline.commands.enumerated() {
                let isLast = stage == pipeline.commands.count - 1
                let (code, out, err, newCwd) = runSimple(cmd, stdin: stdin, cwd: cwd,
                                                         registry: registry, fileSystem: fileSystem)
                status = code
                if pipeline.commands.count == 1 { cwd = newCwd }
                if !err.isEmpty { transcript += err; output(err) }
                if isLast {
                    if !out.isEmpty { transcript += out; output(out) }
                } else {
                    stdin = out
                }
            }
        }
        return ShellResult(exitCode: status, output: transcript)
    }

    private static func runSimple(_ cmd: ShellSyntax.SimpleCommand, stdin: String, cwd: URL,
                                  registry: [String: any ShellCommand],
                                  fileSystem: WorkspaceFileSystem) -> (Int32, String, String, URL) {
        guard let name = cmd.name else { return (0, "", "", cwd) }
        guard let command = registry[name] else {
            let known = registry.keys.sorted().joined(separator: " ")
            return (127, "", "\(name): command not found. Available: \(known)\n", cwd)
        }
        let probe = ShellContext(args: [], stdin: "", fileSystem: fileSystem, cwd: cwd)
        var args: [String] = []
        for w in cmd.words.dropFirst() {
            if w.globbable, Glob.isPattern(w.text) {
                let matches = expand(w.text, ctx: probe)
                args += matches.isEmpty ? [w.text] : matches
            } else {
                args.append(w.text)
            }
        }
        var input = stdin
        var outTarget: (String, Bool)?
        var mergeErr = false
        var discardErr = false
        for r in cmd.redirects {
            switch r {
            case .stdinFrom(let path):
                do { input = try fileSystem.readText(try probe.resolve(path)) } catch {
                    return (1, "", "\(name): \(path): \(describe(error))\n", cwd)
                }
            case .stdoutTo(let path, let append): outTarget = (path, append)
            case .stderrToStdout: mergeErr = true
            case .stderrDiscard: discardErr = true
            }
        }
        let ctx = ShellContext(args: args, stdin: input, fileSystem: fileSystem, cwd: cwd)
        var code: Int32
        do { code = try command.run(ctx) } catch {
            ctx.err("\(name): \(describe(error))")
            code = 1
        }
        var out = ctx.stdout
        var err = discardErr ? "" : ctx.stderr
        if mergeErr { out = err + out; err = "" }
        if let (path, append) = outTarget, path != "/dev/null" {
            do {
                let url = try probe.resolve(path)
                let existing = append ? ((try? fileSystem.readText(url)) ?? "") : ""
                try fileSystem.writeText(existing + out, to: url)
                out = ""
            } catch {
                return (1, "", err + "\(name): \(path): \(describe(error))\n", ctx.cwd)
            }
        } else if outTarget != nil {
            out = ""
        }
        return (code, out, err, ctx.cwd)
    }

    static func expand(_ pattern: String, ctx: ShellContext) -> [String] {
        let base = ctx.fileSystem.relativePath(of: ctx.cwd)
        let full = base.isEmpty ? pattern : base + "/" + pattern
        let glob = Glob(full.contains("/") ? full : "./" + full)
        let candidates = ctx.fileSystem.walkFiles(under: ctx.cwd)
        var dirs = Set<String>()
        for f in candidates {
            var parts = f.split(separator: "/").dropLast()
            while !parts.isEmpty { dirs.insert(parts.joined(separator: "/")); parts = parts.dropLast() }
        }
        let depth = full.split(separator: "/").count
        let hits = (candidates + dirs.sorted()).filter {
            (full.contains("**") || $0.split(separator: "/").count == depth) && glob.matches($0)
        }
        return hits.sorted().map { ctx.display(ctx.fileSystem.root.appending(path: $0)) }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
