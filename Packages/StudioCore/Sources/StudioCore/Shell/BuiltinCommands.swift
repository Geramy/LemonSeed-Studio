import Foundation

/// The minimal built-in command set: ls, cd, pwd, cat, mkdir, rm, mv, cp,
/// touch, echo, clear and help. (`cd` is handled by the shell itself since
/// it changes session state; it is listed here for `help`.)
public enum BuiltinCommands {
    public static let all: [any ShellCommand] = [
        LsCommand(), CdCommand(), PwdCommand(), CatCommand(), MkdirCommand(), RmCommand(),
        MvCommand(), CpCommand(), TouchCommand(), EchoCommand(), ClearCommand(), HelpCommand(),
    ]
}

/// Splits leading `-abc` flags from operands; `--` ends flags.
struct ParsedArguments {
    var flags: Set<Character> = []
    var operands: [String] = []

    init(_ arguments: [String], allowed: Set<Character>, context: inout ShellContext, command: String) throws {
        var flagsDone = false
        for argument in arguments {
            if !flagsDone, argument == "--" {
                flagsDone = true
            } else if !flagsDone, argument.hasPrefix("-"), argument.count > 1 {
                for flag in argument.dropFirst() {
                    guard allowed.contains(flag) else {
                        context.error("\(command): invalid option -- '\(flag)'")
                        throw ExitStatus(code: 2)
                    }
                    flags.insert(flag)
                }
            } else {
                operands.append(argument)
            }
        }
    }
}

struct ExitStatus: Error { var code: Int32 }

enum ANSI {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let blue = "\u{1B}[34m"
    static let cyan = "\u{1B}[36m"
    static let yellow = "\u{1B}[33m"
    static let green = "\u{1B}[32m"
    static let red = "\u{1B}[31m"

    static func visibleLength(_ text: String) -> Int {
        var count = 0
        var inEscape = false
        for scalar in text.unicodeScalars {
            if inEscape {
                if scalar == "m" { inEscape = false }
            } else if scalar == "\u{1B}" {
                inEscape = true
            } else {
                count += 1
            }
        }
        return count
    }
}

private func describe(_ error: Error) -> String {
    if let fileError = error as? FileOperationError { return fileError.localizedDescription }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "No such file or directory"
        case NSFileWriteFileExistsError: return "File exists"
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "Permission denied"
        default: break
        }
    }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return String(cString: strerror(Int32(underlying.code)))
    }
    return ns.localizedDescription
}

// MARK: - ls

struct LsCommand: ShellCommand {
    let name = "ls"
    let summary = "List directory contents"
    let usage = "ls [-a] [-l] [-1] [path ...]"

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        let parsed: ParsedArguments
        do { parsed = try ParsedArguments(arguments, allowed: ["a", "l", "1", "A"], context: &context, command: name) } catch {
            return (error as? ExitStatus)?.code ?? 2
        }
        let showAll = parsed.flags.contains("a") || parsed.flags.contains("A")
        let long = parsed.flags.contains("l")
        let onePerLine = parsed.flags.contains("1") || !context.isTerminal
        let operands = parsed.operands.isEmpty ? ["."] : parsed.operands
        var status: Int32 = 0
        var files: [(String, URL)] = []
        var directories: [(String, URL)] = []
        for operand in operands {
            do {
                let url = try context.resolve(operand)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                    context.error("ls: \(operand): No such file or directory")
                    status = 1
                    continue
                }
                if isDir.boolValue { directories.append((operand, url)) } else { files.append((operand, url)) }
            } catch {
                context.error("ls: \(operand): \(describe(error))")
                status = 1
            }
        }
        if !files.isEmpty {
            emit(files.map { ($0.0, $0.1) }, long: long, onePerLine: onePerLine, context: &context)
        }
        for (index, (label, url)) in directories.enumerated() {
            if operands.count > 1 {
                if index > 0 || !files.isEmpty { context.writeLine() }
                context.writeLine("\(label):")
            }
            do {
                var names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                if !showAll { names = names.filter { !$0.hasPrefix(".") } }
                names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                emit(names.map { ($0, url.appendingPathComponent($0)) }, long: long, onePerLine: onePerLine, context: &context)
            } catch {
                context.error("ls: \(label): \(describe(error))")
                status = 1
            }
        }
        return status
    }

    private func decorate(_ name: String, url: URL, context: ShellContext) -> String {
        let isDir = FileOperations.isDirectory(url)
        guard context.useColor else { return name }
        if isDir { return ANSI.bold + ANSI.blue + name + ANSI.reset }
        if name.hasPrefix(".") { return ANSI.dim + name + ANSI.reset }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["sh", "command"].contains(ext) { return ANSI.green + name + ANSI.reset }
        if ["zip", "gz", "tgz", "xz", "tar"].contains(ext) { return ANSI.red + name + ANSI.reset }
        return name
    }

    private func emit(_ entries: [(String, URL)], long: Bool, onePerLine: Bool, context: inout ShellContext) {
        guard !entries.isEmpty else { return }
        if long {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            var rows: [(String, String, String, String)] = []
            for (name, url) in entries {
                let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let isDir = (attributes[.type] as? FileAttributeType) == .typeDirectory
                let perms = (attributes[.posixPermissions] as? Int).map { Self.permissions($0, directory: isDir) } ?? "----------"
                let size = (attributes[.size] as? Int).map(String.init) ?? "-"
                let date = (attributes[.modificationDate] as? Date).map { formatter.string(from: $0) } ?? ""
                rows.append((perms, size, date, decorate(name, url: url, context: context)))
            }
            let sizeWidth = rows.map(\.1.count).max() ?? 1
            let dateWidth = rows.map(\.2.count).max() ?? 1
            for row in rows {
                let size = String(repeating: " ", count: sizeWidth - row.1.count) + row.1
                let date = row.2 + String(repeating: " ", count: dateWidth - row.2.count)
                context.writeLine("\(row.0)  \(size)  \(date)  \(row.3)")
            }
            return
        }
        let decorated = entries.map { decorate($0.0, url: $0.1, context: context) }
        if onePerLine {
            decorated.forEach { context.writeLine($0) }
            return
        }
        // Columns, filled down then across, like ls.
        let width = (entries.map { $0.0.count }.max() ?? 1) + 2
        let perRow = max(1, context.columns / width)
        let rows = (decorated.count + perRow - 1) / perRow
        for row in 0..<rows {
            var line = ""
            for column in 0..<perRow {
                let index = column * rows + row
                guard index < decorated.count else { continue }
                let item = decorated[index]
                let pad = width - ANSI.visibleLength(item)
                let isLastInRow = (column + 1) * rows + row >= decorated.count
                line += item + (isLastInRow ? "" : String(repeating: " ", count: max(1, pad)))
            }
            context.writeLine(line)
        }
    }

    static func permissions(_ mode: Int, directory: Bool) -> String {
        var text = directory ? "d" : "-"
        let symbols: [Character] = ["r", "w", "x"]
        for shift in stride(from: 8, through: 0, by: -1) {
            text.append(mode & (1 << shift) != 0 ? symbols[(8 - shift) % 3] : "-")
        }
        return text
    }
}

// MARK: - cd, pwd

struct CdCommand: ShellCommand {
    let name = "cd"
    let summary = "Change the working directory (cd - returns to the previous one)"
    let usage = "cd [directory | -]"

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        // The shell intercepts cd; this entry exists for help and listing.
        0
    }
}

struct PwdCommand: ShellCommand {
    let name = "pwd"
    let summary = "Print the working directory"
    let usage = "pwd"

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        context.writeLine(context.workingDirectory.path)
        return 0
    }
}

// MARK: - cat

struct CatCommand: ShellCommand {
    let name = "cat"
    let summary = "Print files (or stdin) to the terminal"
    let usage = "cat [-n] [file ...]"

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        let parsed: ParsedArguments
        do { parsed = try ParsedArguments(arguments, allowed: ["n"], context: &context, command: name) } catch {
            return (error as? ExitStatus)?.code ?? 2
        }
        var text = ""
        var status: Int32 = 0
        if parsed.operands.isEmpty {
            text = context.stdin ?? ""
        }
        for operand in parsed.operands {
            do {
                let url = try context.resolve(operand)
                guard !FileOperations.isDirectory(url) else {
                    context.error("cat: \(operand): Is a directory")
                    status = 1
                    continue
                }
                let data = try FileOperations.coordinatedRead(url)
                if FileSniffer.looksBinary(data) {
                    context.error("cat: \(operand): binary file (\(data.count) bytes) not shown")
                    status = 1
                    continue
                }
                text += String(decoding: data, as: UTF8.self)
            } catch {
                context.error("cat: \(operand): \(describe(error))")
                status = 1
            }
        }
        if parsed.flags.contains("n") {
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let width = String(lines.count).count
            text = lines.enumerated().map { index, line in
                let number = String(index + 1)
                return String(repeating: " ", count: width - number.count + 2) + number + "  " + line
            }.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        }
        context.write(text)
        return status
    }
}

// MARK: - mkdir, touch

struct MkdirCommand: ShellCommand {
    let name = "mkdir"
    let summary = "Create directories"
    let usage = "mkdir [-p] directory ..."

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        let parsed: ParsedArguments
        do { parsed = try ParsedArguments(arguments, allowed: ["p"], context: &context, command: name) } catch {
            return (error as? ExitStatus)?.code ?? 2
        }
        guard !parsed.operands.isEmpty else {
            context.error("usage: \(usage)")
            return 2
        }
        var status: Int32 = 0
        for operand in parsed.operands {
            do {
                let url = try context.resolve(operand)
                if FileManager.default.fileExists(atPath: url.path) {
                    if !parsed.flags.contains("p") {
                        context.error("mkdir: \(operand): File exists")
                        status = 1
                    }
                    continue
                }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: parsed.flags.contains("p"))
            } catch {
                context.error("mkdir: \(operand): \(describe(error))")
                status = 1
            }
        }
        return status
    }
}

struct TouchCommand: ShellCommand {
    let name = "touch"
    let summary = "Create empty files or update their modification time"
    let usage = "touch file ..."

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        guard !arguments.isEmpty else {
            context.error("usage: \(usage)")
            return 2
        }
        var status: Int32 = 0
        for operand in arguments {
            do {
                let url = try context.resolve(operand)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                } else {
                    try FileOperations.coordinatedWrite(Data(), to: url)
                }
            } catch {
                context.error("touch: \(operand): \(describe(error))")
                status = 1
            }
        }
        return status
    }
}

// MARK: - rm

struct RmCommand: ShellCommand {
    let name = "rm"
    let summary = "Remove files or directories"
    let usage = "rm [-r] [-f] path ..."

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        let parsed: ParsedArguments
        do { parsed = try ParsedArguments(arguments, allowed: ["r", "R", "f"], context: &context, command: name) } catch {
            return (error as? ExitStatus)?.code ?? 2
        }
        let recursive = parsed.flags.contains("r") || parsed.flags.contains("R")
        let force = parsed.flags.contains("f")
        guard !parsed.operands.isEmpty else {
            if force { return 0 }
            context.error("usage: \(usage)")
            return 2
        }
        var status: Int32 = 0
        for operand in parsed.operands {
            do {
                let url = try context.resolve(operand)
                if context.roots.contains(where: { ShellContext.canonical($0) == ShellContext.canonical(url) }) {
                    context.error("rm: \(operand): refusing to remove the workspace root")
                    status = 1
                    continue
                }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    if !force {
                        context.error("rm: \(operand): No such file or directory")
                        status = 1
                    }
                    continue
                }
                if FileOperations.isDirectory(url), !recursive {
                    context.error("rm: \(operand): is a directory")
                    status = 1
                    continue
                }
                try FileOperations.delete(url)
            } catch {
                context.error("rm: \(operand): \(describe(error))")
                status = 1
            }
        }
        return status
    }
}

// MARK: - mv, cp

/// Shared target logic for mv and cp: `src... dir` or `src dst`.
private func transfer(_ operands: [String], command: String, context: inout ShellContext,
                      perform: (URL, URL) throws -> Void) -> Int32 {
    guard operands.count >= 2 else {
        context.error("usage: \(command) source ... target")
        return 2
    }
    let sources = operands.dropLast()
    let targetArgument = operands.last!
    let target: URL
    do { target = try context.resolve(targetArgument) } catch {
        context.error("\(command): \(targetArgument): \(describe(error))")
        return 1
    }
    let targetIsDirectory = FileOperations.isDirectory(target)
    if sources.count > 1, !targetIsDirectory {
        context.error("\(command): \(targetArgument) is not a directory")
        return 1
    }
    var status: Int32 = 0
    for source in sources {
        do {
            let from = try context.resolve(source)
            guard FileManager.default.fileExists(atPath: from.path) else {
                context.error("\(command): \(source): No such file or directory")
                status = 1
                continue
            }
            let to = targetIsDirectory ? target.appendingPathComponent(from.lastPathComponent) : target
            if to.path == from.path {
                context.error("\(command): \(source) and \(targetArgument) are the same file")
                status = 1
                continue
            }
            if FileOperations.isDirectory(from), to.path.hasPrefix(from.path + "/") {
                context.error("\(command): cannot move '\(source)' into itself")
                status = 1
                continue
            }
            try perform(from, to)
        } catch {
            context.error("\(command): \(source): \(describe(error))")
            status = 1
        }
    }
    return status
}

struct MvCommand: ShellCommand {
    let name = "mv"
    let summary = "Move or rename files and directories"
    let usage = "mv source ... target"

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        let parsed: ParsedArguments
        do { parsed = try ParsedArguments(arguments, allowed: ["f"], context: &context, command: name) } catch {
            return (error as? ExitStatus)?.code ?? 2
        }
        return transfer(parsed.operands, command: name, context: &context) { from, to in
            let fm = FileManager.default
            if fm.fileExists(atPath: to.path) {
                if FileOperations.isDirectory(to) {
                    throw CocoaError(.fileWriteFileExists)
                }
                try fm.removeItem(at: to)
            }
            try fm.moveItem(at: from, to: to)
        }
    }
}

struct CpCommand: ShellCommand {
    let name = "cp"
    let summary = "Copy files (-r for directories)"
    let usage = "cp [-r] source ... target"

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        let parsed: ParsedArguments
        do { parsed = try ParsedArguments(arguments, allowed: ["r", "R", "f"], context: &context, command: name) } catch {
            return (error as? ExitStatus)?.code ?? 2
        }
        let recursive = parsed.flags.contains("r") || parsed.flags.contains("R")
        var skipped: [String] = []
        let status = transfer(parsed.operands, command: name, context: &context) { from, to in
            if FileOperations.isDirectory(from), !recursive {
                skipped.append(from.lastPathComponent)
                return
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: to.path), !FileOperations.isDirectory(to) {
                try fm.removeItem(at: to)
            }
            try FileOperations.copy(from, to: to)
        }
        for name in skipped {
            context.error("cp: \(name) is a directory (not copied; use -r)")
        }
        return skipped.isEmpty ? status : 1
    }
}

// MARK: - echo, clear, help

struct EchoCommand: ShellCommand {
    let name = "echo"
    let summary = "Print arguments"
    let usage = "echo [-n] [text ...]"

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        var arguments = arguments
        var newline = true
        if arguments.first == "-n" {
            newline = false
            arguments.removeFirst()
        }
        context.write(arguments.joined(separator: " ") + (newline ? "\n" : ""))
        return 0
    }
}

struct ClearCommand: ShellCommand {
    let name = "clear"
    let summary = "Clear the terminal"
    let usage = "clear"

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        context.requestClear()
        return 0
    }
}

struct HelpCommand: ShellCommand {
    let name = "help"
    let summary = "List commands, or show one command's usage"
    let usage = "help [command]"

    func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
        if let topic = arguments.first {
            guard let command = context.commandTable[topic] else {
                context.error("help: no command named '\(topic)'")
                return 1
            }
            context.writeLine("\(command.usage)")
            context.writeLine("  \(command.summary)")
            return 0
        }
        let bold = context.useColor ? ANSI.bold : ""
        let dim = context.useColor ? ANSI.dim : ""
        let reset = context.useColor ? ANSI.reset : ""
        context.writeLine("\(bold)LemonSeed shell\(reset) \(dim)runs commands in process; pipes (|), redirection (> >>), ; && || and globs work.\(reset)")
        let width = (context.commands.map { $0.name.count }.max() ?? 4) + 2
        for command in context.commands {
            context.writeLine("  \(bold)\(command.name)\(reset)" + String(repeating: " ", count: width - command.name.count) + command.summary)
        }
        context.writeLine("\(dim)Compilers, git and build tools arrive as in-process tools in later releases.\(reset)")
        return 0
    }
}
