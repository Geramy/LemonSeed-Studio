import Foundation

/// `glob(pattern, path?)`: files whose path matches a glob.
public struct GlobTool: AgentTool {
    public init() {}
    public let name = "glob"
    public let description = """
    Find files by glob pattern, e.g. "**/*.c", "src/**/*.{h,hpp}", "*Test*". A pattern without "/" \
    matches file names at any depth. Returns workspace-relative paths, sorted.
    """
    public let promptSnippet = "find files by name pattern"
    public var parameters: JSONValue {
        ["type": "object",
         "properties": [
            "pattern": ["type": "string", "description": "Glob pattern"],
            "path": ["type": "string", "description": "Directory to search (default: the root)"],
         ],
         "required": ["pattern"]]
    }

    public func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect { .read }

    public func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let args = ToolArguments(arguments, tool: name)
        let pattern = try args.string("pattern")
        let dir = try context.fileSystem.resolve(try args.optionalString("path") ?? ".")
        let base = context.fileSystem.relativePath(of: dir)
        let glob = Glob(pattern)
        var hits: [String] = []
        for rel in context.fileSystem.walkFiles(under: dir) {
            try Task.checkCancellation()
            let local = base.isEmpty ? rel : String(rel.dropFirst(base.count + 1))
            if glob.matches(local) { hits.append(rel) }
        }
        if hits.isEmpty { return ToolOutput(text: "No files match \(pattern).") }
        let limit = 1000
        var text = hits.prefix(limit).joined(separator: "\n")
        if hits.count > limit { text += "\n[\(hits.count - limit) more not shown; narrow the pattern.]" }
        return ToolOutput(text: text, details: ["count": .int(hits.count)])
    }
}

/// `grep(pattern, …)`: regular-expression search with ripgrep-style output.
public struct GrepTool: AgentTool {
    public init() {}
    public let name = "grep"
    public let description = """
    Search file contents with a regular expression (ICU syntax; set literal for plain text). \
    Output lines are "path:line:text". Optionally restrict to files matching a glob, show context lines, \
    or ignore case. Binary files, .git and build outputs are skipped.
    """
    public let promptSnippet = "search file contents by regular expression"
    public var parameters: JSONValue {
        ["type": "object",
         "properties": [
            "pattern": ["type": "string", "description": "Regular expression (or plain text with literal=true)"],
            "path": ["type": "string", "description": "File or directory to search (default: the root)"],
            "glob": ["type": "string", "description": "Only search files matching this glob, e.g. \"*.c\""],
            "ignoreCase": ["type": "boolean", "description": "Case-insensitive match"],
            "literal": ["type": "boolean", "description": "Treat pattern as plain text"],
            "context": ["type": "integer", "description": "Lines of context around each match (0-5)"],
            "limit": ["type": "integer", "description": "Maximum matches (default 200)"],
         ],
         "required": ["pattern"]]
    }

    public func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect { .read }

    public func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let args = ToolArguments(arguments, tool: name)
        let pattern = try args.string("pattern")
        let matcher: LineMatcher
        do {
            matcher = try LineMatcher(pattern: pattern, literal: try args.optionalBool("literal") ?? false,
                                      ignoreCase: try args.optionalBool("ignoreCase") ?? false)
        } catch {
            throw ToolError("Invalid regular expression \"\(pattern)\". Set literal=true to search plain text.")
        }
        let target = try context.fileSystem.resolve(try args.optionalString("path") ?? ".")
        let glob = try args.optionalString("glob").map(Glob.init)
        let ctx = min(5, max(0, try args.optionalInt("context") ?? 0))
        let limit = min(1000, max(1, try args.optionalInt("limit") ?? OutputLimits.searchResults))

        let files = context.fileSystem.isDirectory(target)
            ? context.fileSystem.walkFiles(under: target)
            : [context.fileSystem.relativePath(of: target)]
        var out: [String] = []
        var matches = 0
        var filesWithMatches = 0
        scan: for rel in files {
            try Task.checkCancellation()
            if let glob, !glob.matches(rel) { continue }
            guard let text = try? context.fileSystem.readText(context.fileSystem.root.appending(path: rel)) else { continue }
            let lines = LineDiff.lines(text)
            var lastPrinted = -1
            var any = false
            for (i, line) in lines.enumerated() where matcher.matches(line) {
                if !any { any = true; filesWithMatches += 1 }
                let from = max(lastPrinted + 1, i - ctx)
                if ctx > 0, lastPrinted >= 0, from > lastPrinted + 1 { out.append("--") }
                for j in from..<i { out.append("\(rel)-\(j + 1)-\(OutputLimits.clipLine(lines[j]))") }
                out.append("\(rel):\(i + 1):\(OutputLimits.clipLine(line))")
                lastPrinted = i
                if ctx > 0 {
                    for j in (i + 1)..<min(lines.count, i + 1 + ctx) where !matcher.matches(lines[j]) {
                        out.append("\(rel)-\(j + 1)-\(OutputLimits.clipLine(lines[j]))")
                        lastPrinted = j
                    }
                }
                matches += 1
                if matches >= limit { break scan }
            }
        }
        if matches == 0 { return ToolOutput(text: "No matches for \(pattern).", details: ["matches": 0]) }
        var text = out.joined(separator: "\n")
        if matches >= limit { text += "\n[Stopped at \(limit) matches; narrow the search.]" }
        return ToolOutput(text: text, details: ["matches": .int(matches), "files": .int(filesWithMatches)])
    }
}

/// `bash(command, timeout?)`: the Studio shell.
public struct BashTool: AgentTool {
    public let commandSummary: String

    public init(shell: any ShellProviding) {
        commandSummary = shell.commands.map(\.synopsis).joined(separator: "\n")
    }

    public let name = "bash"
    public var description: String {
        """
        Run a command line in the workspace's built-in shell. It supports pipes (|), &&, ||, ;, \
        redirection (>, >>, <, 2>&1) and globs, but it is not a full Unix shell: there are no variables, \
        command substitution, scripts, network or other programs. The working directory starts at the \
        workspace root. Output keeps the last \(OutputLimits.shellTailBytes / 1024) KB. Available commands:
        \(commandSummary)
        """
    }
    public let promptSnippet = "run commands in the built-in shell (listed in its description)"
    public var parameters: JSONValue {
        ["type": "object",
         "properties": [
            "command": ["type": "string", "description": "The command line to run"],
            "timeout": ["type": "integer", "description": "Seconds before the command is stopped (default 60)"],
         ],
         "required": ["command"]]
    }

    public func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect {
        let command = arguments["command"]?.stringValue ?? ""
        return .shell(command: command, commandClass: context.shell.classify(command))
    }

    public func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let args = ToolArguments(arguments, tool: name)
        let command = try args.string("command")
        let timeout = min(600, max(1, try args.optionalInt("timeout") ?? 60))
        let result = await context.shell.run(command, fileSystem: context.fileSystem,
                                             timeout: .seconds(timeout), output: context.progress)
        try Task.checkCancellation()
        let (tail, truncated) = OutputLimits.tail(result.output)
        var text = tail.isEmpty ? "(no output)" : tail
        if result.timedOut { text += "\n[Stopped after \(timeout) s.]" }
        if result.exitCode != 0 { text += "\n[exit code \(result.exitCode)]" }
        return ToolOutput(text: text, isError: result.exitCode != 0,
                          details: ["exitCode": .int(Int(result.exitCode)), "truncated": .bool(truncated)])
    }
}

/// The default tool set.
public enum DefaultTools {
    public static func all(shell: any ShellProviding) -> [any AgentTool] {
        [ReadTool(), WriteTool(), EditTool(), ListTool(), GlobTool(), GrepTool(), BashTool(shell: shell)]
    }

    /// The read-only subset (used by explain and by the read-only tier).
    public static func readOnly(shell: any ShellProviding) -> [any AgentTool] {
        [ReadTool(), ListTool(), GlobTool(), GrepTool()]
    }
}
