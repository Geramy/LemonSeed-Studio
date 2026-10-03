import Foundation

/// A command the shell can run in process. Real tools (git, clang, cmake,
/// ninja, wasm runners) register the same way later, through the
/// ToolRegistry; until then this protocol is the registry's Swift face.
public protocol ShellCommand: Sendable {
    var name: String { get }
    /// One line for `help`.
    var summary: String { get }
    /// Usage line, e.g. "ls [-a] [-l] [path ...]".
    var usage: String { get }
    func run(_ arguments: [String], context: inout ShellContext) -> Int32
}

/// What a running command sees: its working directory, the roots it may
/// touch, stdin, and buffers for stdout and stderr.
public struct ShellContext: Sendable {
    public internal(set) var workingDirectory: URL
    /// Directories the session is confined to (the workspace).
    public let roots: [URL]
    public var environment: [String: String]
    public var stdin: String?
    public internal(set) var stdout = ""
    public internal(set) var stderr = ""
    /// Terminal width, for column layout.
    public var columns: Int
    /// Whether output goes to a terminal (enables color).
    public var isTerminal: Bool
    var clearRequested = false
    var requestedDirectory: URL?
    let commandTable: [String: any ShellCommand]

    public mutating func write(_ text: String) { stdout += text }
    public mutating func writeLine(_ text: String = "") { stdout += text + "\n" }
    public mutating func error(_ text: String) { stderr += text + "\n" }
    public mutating func requestClear() { clearRequested = true }
    public mutating func changeDirectory(to url: URL) { requestedDirectory = url }

    public var commands: [any ShellCommand] {
        commandTable.values.sorted { $0.name < $1.name }
    }

    /// Resolves a path argument against the working directory and checks
    /// that it stays inside the session's roots.
    public func resolve(_ path: String) throws -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = workingDirectory.appendingPathComponent(path)
        }
        let standardized = url.standardizedFileURL
        guard isInsideRoots(standardized) else {
            throw FileOperationError.outsideWorkspace(path)
        }
        return standardized
    }

    public func isInsideRoots(_ url: URL) -> Bool {
        let path = Self.canonical(url)
        return roots.contains { root in
            let base = Self.canonical(root)
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// A path for display: relative to the first root, as "~/..." style.
    public func displayPath(_ url: URL) -> String {
        guard let root = roots.first, let relative = FileOperations.relativePath(of: url, to: root) else {
            return url.path
        }
        return relative.isEmpty ? "~" : "~/" + relative
    }

    static func canonical(_ url: URL) -> String {
        // Resolve symlinks of the longest existing prefix (/var -> /private/var).
        var existing = url.standardizedFileURL
        var trailing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in trailing { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    var useColor: Bool { isTerminal }
}

/// The result of running one command line.
public struct ShellOutput: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    /// The user ran `clear`.
    public var clearScreen: Bool
}

/// An in-process shell session: parsing, expansion, pipes, redirection,
/// `;` `&&` `||`, and the built-in commands. It never forks or execs and
/// never changes the process-wide working directory.
public actor BuiltinShell {
    public private(set) var workingDirectory: URL
    public let roots: [URL]
    public private(set) var environment: [String: String]
    public private(set) var history: [String] = []
    public private(set) var lastExitCode: Int32 = 0
    private var previousDirectory: URL?
    private var commands: [String: any ShellCommand]

    public init(root: URL, workingDirectory: URL? = nil, commands: [any ShellCommand] = BuiltinCommands.all) {
        let root = root.standardizedFileURL
        self.roots = [root]
        self.workingDirectory = (workingDirectory ?? root).standardizedFileURL
        self.environment = [
            "HOME": root.path,
            "PWD": (workingDirectory ?? root).standardizedFileURL.path,
            "SHELL": "lsh",
            "TERM": "xterm-256color",
            "USER": "studio",
        ]
        self.commands = Dictionary(commands.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Adds or replaces a command.
    public func register(_ command: any ShellCommand) {
        commands[command.name] = command
    }

    public var commandNames: [String] { commands.keys.sorted() }

    /// The prompt's directory, "~" at the workspace root.
    public var promptPath: String {
        guard let relative = FileOperations.relativePath(of: workingDirectory, to: roots[0]) else { return workingDirectory.path }
        return relative.isEmpty ? "~" : "~/" + relative
    }

    public func setEnvironment(_ name: String, _ value: String) {
        environment[name] = value
    }

    /// Runs one line, e.g. `mkdir -p build && ls | cat > listing.txt`.
    public func run(_ line: String, columns: Int = 80, isTerminal: Bool = false) -> ShellOutput {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, history.last != trimmed { history.append(trimmed) }
        environment["?"] = String(lastExitCode)
        let script: ShellScript
        do {
            script = try ShellParser.parse(line, environment: environment)
        } catch {
            lastExitCode = 2
            return ShellOutput(stdout: "", stderr: "lsh: \(error.localizedDescription)\n", exitCode: 2, clearScreen: false)
        }
        var output = ShellOutput(stdout: "", stderr: "", exitCode: 0, clearScreen: false)
        var status: Int32 = lastExitCode
        for pipeline in script.pipelines {
            switch pipeline.connector {
            case .always: break
            case .ifSuccess where status != 0: continue
            case .ifFailure where status == 0: continue
            default: break
            }
            var input: String?
            for (index, command) in pipeline.commands.enumerated() {
                let isLast = index == pipeline.commands.count - 1
                let result = execute(command, stdin: input, columns: columns, isTerminal: isTerminal && isLast && command.redirect == nil)
                output.stderr += result.stderr
                if result.clearScreen {
                    output.clearScreen = true
                    output.stdout = ""
                }
                if isLast { output.stdout += result.stdout } else { input = result.stdout }
                status = result.exitCode
            }
        }
        output.exitCode = status
        lastExitCode = status
        return output
    }

    private func execute(_ command: ShellScript.Command, stdin: String?, columns: Int, isTerminal: Bool) -> ShellOutput {
        var context = ShellContext(workingDirectory: workingDirectory, roots: roots, environment: environment,
                                   stdin: stdin, columns: columns, isTerminal: isTerminal, commandTable: commands)
        let words = expand(command.words)
        guard let name = words.first else {
            return ShellOutput(stdout: "", stderr: "", exitCode: 0, clearScreen: false)
        }
        let arguments = Array(words.dropFirst())
        var code: Int32
        if name == "cd" {
            code = changeDirectory(arguments, context: &context)
        } else if let tool = commands[name] {
            code = tool.run(arguments, context: &context)
        } else {
            context.error("\(name): not available on iPad (in-process tools only). Type 'help' for the built-in commands.")
            code = 127
        }
        if let redirect = command.redirect {
            let target = expand([redirect.target]).first ?? redirect.target.text
            do {
                let url = try context.resolve(target)
                if redirect.append, let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(context.stdout.utf8))
                } else {
                    try FileOperations.coordinatedWrite(Data(context.stdout.utf8), to: url)
                }
                context.stdout = ""
            } catch {
                context.error("lsh: \(target): \(error.localizedDescription)")
                code = 1
            }
        }
        return ShellOutput(stdout: context.stdout, stderr: context.stderr, exitCode: code, clearScreen: context.clearRequested)
    }

    private func changeDirectory(_ arguments: [String], context: inout ShellContext) -> Int32 {
        let target = arguments.first ?? roots[0].path
        let url: URL
        if target == "-" {
            guard let previous = previousDirectory else {
                context.error("cd: no previous directory")
                return 1
            }
            url = previous
            context.writeLine(context.displayPath(previous))
        } else {
            do { url = try context.resolve(target) } catch {
                context.error("cd: \(target): \(error.localizedDescription)")
                return 1
            }
        }
        guard FileOperations.isDirectory(url) else {
            context.error(FileManager.default.fileExists(atPath: url.path)
                          ? "cd: \(target): Not a directory" : "cd: \(target): No such file or directory")
            return 1
        }
        previousDirectory = workingDirectory
        workingDirectory = url
        environment["PWD"] = url.path
        return 0
    }

    // MARK: Glob expansion

    private func expand(_ words: [ShellScript.Word]) -> [String] {
        var result: [String] = []
        for word in words {
            let hasWildcard = word.text.contains { $0 == "*" || $0 == "?" || $0 == "[" }
            if word.quoted || !hasWildcard {
                result.append(word.text)
                continue
            }
            let matches = expandGlob(word.text)
            if matches.isEmpty { result.append(word.text) } else { result.append(contentsOf: matches) }
        }
        return result
    }

    /// Expands a pattern component by component, like sh: `src/*.c`,
    /// `*/README*`. Hidden files only match patterns that start with '.'.
    private func expandGlob(_ pattern: String) -> [String] {
        let absolute = pattern.hasPrefix("/")
        let components = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var partials: [(display: String, url: URL)] = [(absolute ? "/" : "", absolute ? URL(fileURLWithPath: "/") : workingDirectory)]
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            var next: [(String, URL)] = []
            let wildcard = component.contains { $0 == "*" || $0 == "?" || $0 == "[" }
            for (display, url) in partials {
                let prefix = display.isEmpty || display.hasSuffix("/") ? display : display + "/"
                if !wildcard {
                    let child = url.appendingPathComponent(component)
                    if isLast || FileOperations.isDirectory(child) || component == ".." || component == "." {
                        next.append((prefix + component, child))
                    }
                    continue
                }
                let glob = Glob(component)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                for name in names.sorted() where glob.matches(name) {
                    if name.hasPrefix("."), !component.hasPrefix(".") { continue }
                    let child = url.appendingPathComponent(name)
                    if !isLast, !FileOperations.isDirectory(child) { continue }
                    next.append((prefix + name, child))
                }
            }
            partials = next
            if partials.isEmpty { return [] }
        }
        return partials.map(\.display)
    }
}
