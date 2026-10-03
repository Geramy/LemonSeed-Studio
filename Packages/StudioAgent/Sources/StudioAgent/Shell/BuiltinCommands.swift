import Foundation

/// The commands every LemonSeed shell has, implemented over the jailed file
/// system. They follow POSIX/GNU behavior for the options listed in each
/// synopsis; anything else is an error rather than a silent difference.
public enum BuiltinCommands {
    public static var all: [any ShellCommand] {
        [echo, pwd, cd, ls, cat, head, tail, wc, grep, find, sort, uniq, mkdir, touch, rm, cp, mv,
         basename, dirname, trueCmd, falseCmd, diff, help]
    }

    struct UsageError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Splits "-abc" style flags from operands; "--" ends options. Options in
    /// `valued` take the following argument (or an attached value: -n5).
    static func options(_ args: [String], allowed: String, valued: String = "",
                        command: String) throws -> (flags: Set<Character>, values: [Character: String], operands: [String]) {
        var flags = Set<Character>()
        var values: [Character: String] = [:]
        var operands: [String] = []
        var i = 0
        var done = false
        while i < args.count {
            let a = args[i]
            if done || !a.hasPrefix("-") || a == "-" || a.count == 1 {
                operands.append(a); i += 1; continue
            }
            if a == "--" { done = true; i += 1; continue }
            var chars = Array(a.dropFirst())
            // "-20" for head/tail.
            if chars.allSatisfy(\.isNumber), valued.contains("n") {
                values["n"] = String(chars); i += 1; continue
            }
            while !chars.isEmpty {
                let c = chars.removeFirst()
                if valued.contains(c) {
                    if !chars.isEmpty { values[c] = String(chars); chars = [] }
                    else if i + 1 < args.count { values[c] = args[i + 1]; i += 1 }
                    else { throw UsageError(message: "\(command): option -\(c) needs a value") }
                } else if allowed.contains(c) {
                    flags.insert(c)
                } else {
                    throw UsageError(message: "\(command): unsupported option -\(c)")
                }
            }
            i += 1
        }
        return (flags, values, operands)
    }

    static func inputs(_ ctx: ShellContext, _ operands: [String]) throws -> [(name: String, text: String)] {
        if operands.isEmpty { return [("-", ctx.stdin)] }
        return try operands.map { op in
            op == "-" ? ("-", ctx.stdin) : (op, try ctx.fileSystem.readText(try ctx.resolve(op)))
        }
    }

    static func lines(_ text: String) -> [Substring] {
        var ls = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { ls.removeLast() }
        return ls
    }

    // MARK: Commands

    static let echo = ClosureCommand("echo", synopsis: "echo [-n] [text…]", class: .readOnly) { ctx in
        var args = ctx.args
        var newline = true
        if args.first == "-n" { newline = false; args.removeFirst() }
        ctx.out(args.joined(separator: " ") + (newline ? "\n" : ""))
        return 0
    }

    static let pwd = ClosureCommand("pwd", synopsis: "pwd", class: .readOnly) { ctx in
        ctx.outLine("/" + ctx.fileSystem.relativePath(of: ctx.cwd))
        return 0
    }

    static let cd = ClosureCommand("cd", synopsis: "cd [dir]  (within the workspace)", class: .readOnly) { ctx in
        let url = try ctx.resolve(ctx.args.first ?? "/")
        guard ctx.fileSystem.isDirectory(url) else { ctx.err("cd: \(ctx.args.first ?? ""): not a directory"); return 1 }
        ctx.cwd = url
        return 0
    }

    static let ls = ClosureCommand("ls", synopsis: "ls [-a] [-l] [-1] [path…]", class: .readOnly) { ctx in
        let o = try options(ctx.args, allowed: "al1F", command: "ls")
        let targets = o.operands.isEmpty ? ["."] : o.operands
        var status: Int32 = 0
        for (n, t) in targets.enumerated() {
            let url = try ctx.resolve(t)
            guard ctx.fileSystem.exists(url) else { ctx.err("ls: \(t): No such file or directory"); status = 1; continue }
            if !ctx.fileSystem.isDirectory(url) { ctx.outLine(ctx.display(url)); continue }
            if targets.count > 1 { ctx.outLine((n > 0 ? "\n" : "") + "\(t):") }
            for name in try ctx.fileSystem.list(url, includeHidden: o.flags.contains("a")) {
                if o.flags.contains("l") {
                    let item = url.appending(path: name.hasSuffix("/") ? String(name.dropLast()) : name)
                    let size = (try? FileManager.default.attributesOfItem(atPath: item.path)[.size] as? Int) ?? 0
                    ctx.outLine(String(format: "%@ %10d  %@", name.hasSuffix("/") ? "d" : "-", size, name))
                } else {
                    ctx.outLine(name)
                }
            }
        }
        return status
    }

    static let cat = ClosureCommand("cat", synopsis: "cat [-n] [file…]", class: .readOnly) { ctx in
        let o = try options(ctx.args, allowed: "n", command: "cat")
        var number = 1
        for input in try inputs(ctx, o.operands) {
            if o.flags.contains("n") {
                for l in lines(input.text) { ctx.outLine(String(format: "%6d\t", number) + l); number += 1 }
            } else {
                ctx.out(input.text)
            }
        }
        return 0
    }

    static let head = ClosureCommand("head", synopsis: "head [-n N] [file…]", class: .readOnly) { ctx in
        let o = try options(ctx.args, allowed: "", valued: "n", command: "head")
        let n = Int(o.values["n"] ?? "10") ?? 10
        let ins = try inputs(ctx, o.operands)
        for (i, input) in ins.enumerated() {
            if ins.count > 1 { ctx.outLine((i > 0 ? "\n" : "") + "==> \(input.name) <==") }
            for l in lines(input.text).prefix(n) { ctx.outLine(String(l)) }
        }
        return 0
    }

    static let tail = ClosureCommand("tail", synopsis: "tail [-n N] [file…]", class: .readOnly) { ctx in
        let o = try options(ctx.args, allowed: "", valued: "n", command: "tail")
        let spec = o.values["n"] ?? "10"
        let ins = try inputs(ctx, o.operands)
        for (i, input) in ins.enumerated() {
            if ins.count > 1 { ctx.outLine((i > 0 ? "\n" : "") + "==> \(input.name) <==") }
            let ls = lines(input.text)
            let selected = spec.hasPrefix("+") ? ls.dropFirst(max(0, (Int(spec.dropFirst()) ?? 1) - 1))
                                               : ls.suffix(Int(spec) ?? 10)
            for l in selected { ctx.outLine(String(l)) }
        }
        return 0
    }

    static let wc = ClosureCommand("wc", synopsis: "wc [-l] [-w] [-c] [file…]", class: .readOnly) { ctx in
        let o = try options(ctx.args, allowed: "lwc", command: "wc")
        let flags = o.flags.isEmpty ? Set("lwc") : o.flags
        var totals = (0, 0, 0)
        let ins = try inputs(ctx, o.operands)
        func row(_ l: Int, _ w: Int, _ c: Int, _ name: String) {
            var parts: [String] = []
            if flags.contains("l") { parts.append(String(format: "%7d", l)) }
            if flags.contains("w") { parts.append(String(format: "%7d", w)) }
            if flags.contains("c") { parts.append(String(format: "%7d", c)) }
            ctx.outLine(parts.joined(separator: " ") + (name == "-" ? "" : " \(name)"))
        }
        for input in ins {
            let l = input.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            let w = input.text.split(whereSeparator: { $0.isWhitespace }).count
            let c = input.text.utf8.count
            totals = (totals.0 + l, totals.1 + w, totals.2 + c)
            row(l, w, c, input.name)
        }
        if ins.count > 1 { row(totals.0, totals.1, totals.2, "total") }
        return 0
    }

    static let grep = ClosureCommand(
        "grep", synopsis: "grep [-rinvclwFE] [-e pattern] pattern [path…]", class: .readOnly
    ) { ctx in
        var o = try options(ctx.args, allowed: "rRinvclwFEsH", valued: "e", command: "grep")
        let pattern: String
        if let e = o.values["e"] { pattern = e } else {
            guard !o.operands.isEmpty else { ctx.err("grep: missing pattern"); return 2 }
            pattern = o.operands.removeFirst()
        }
        let matcher = try LineMatcher(pattern: pattern, literal: o.flags.contains("F"),
                                      ignoreCase: o.flags.contains("i"), wholeWord: o.flags.contains("w"))
        let recursive = o.flags.contains("r") || o.flags.contains("R")
        var files: [(String, String)] = []
        if o.operands.isEmpty && !recursive {
            files = [("-", ctx.stdin)]
        } else {
            for op in o.operands.isEmpty ? ["."] : o.operands {
                let url = try ctx.resolve(op)
                if ctx.fileSystem.isDirectory(url) {
                    guard recursive else { ctx.err("grep: \(op): Is a directory"); continue }
                    for rel in ctx.fileSystem.walkFiles(under: url) {
                        if ctx.isCancelled { return 130 }
                        let f = ctx.fileSystem.root.appending(path: rel)
                        if let t = try? ctx.fileSystem.readText(f) { files.append((ctx.display(f), t)) }
                    }
                } else {
                    do { files.append((op, try ctx.fileSystem.readText(url))) }
                    catch { if !o.flags.contains("s") { ctx.err("grep: \(op): \(InProcessShell.describe(error))") } }
                }
            }
        }
        let showName = files.count > 1 || recursive || o.flags.contains("H")
        var any = false
        for (name, text) in files {
            var count = 0
            for (i, line) in lines(text).enumerated() {
                guard matcher.matches(line) != o.flags.contains("v") else { continue }
                count += 1
                any = true
                if o.flags.contains("l") { break }
                if o.flags.contains("c") { continue }
                var prefix = showName ? "\(name):" : ""
                if o.flags.contains("n") { prefix += "\(i + 1):" }
                ctx.outLine(prefix + line)
            }
            if o.flags.contains("l"), count > 0 { ctx.outLine(name) }
            if o.flags.contains("c") { ctx.outLine((showName ? "\(name):" : "") + "\(count)") }
        }
        return any ? 0 : 1
    }

    static let find = ClosureCommand(
        "find", synopsis: "find [path] [-name glob] [-path glob] [-type f|d] [-maxdepth N]", class: .readOnly
    ) { ctx in
        var start = "."
        var args = ctx.args
        if let first = args.first, !first.hasPrefix("-") { start = first; args.removeFirst() }
        var name: Glob?, path: Glob?, type: String?, maxDepth = Int.max
        var i = 0
        while i < args.count {
            let flag = args[i]
            guard i + 1 < args.count else { throw UsageError(message: "find: \(flag) needs a value") }
            let v = args[i + 1]
            switch flag {
            case "-name", "-iname": name = Glob(v)
            case "-path": path = Glob(v.hasPrefix("./") ? String(v.dropFirst(2)) : v)
            case "-type": type = v
            case "-maxdepth": maxDepth = Int(v) ?? .max
            default: throw UsageError(message: "find: unsupported predicate \(flag)")
            }
            i += 2
        }
        let root = try ctx.resolve(start)
        let base = ctx.fileSystem.relativePath(of: root)
        let files = ctx.fileSystem.walkFiles(under: root)
        var dirs = Set<String>()
        for f in files {
            var parts = f.split(separator: "/").dropLast()
            while !parts.isEmpty {
                let d = parts.joined(separator: "/")
                if base.isEmpty || d.hasPrefix(base + "/") { dirs.insert(d) }
                parts = parts.dropLast()
            }
        }
        var entries: [(String, Bool)] = []
        if type != "d" { entries += files.map { ($0, false) } }
        if type != "f" { entries += dirs.map { ($0, true) } }
        for (rel, _) in entries.sorted(by: { $0.0 < $1.0 }) {
            let local = base.isEmpty ? rel : String(rel.dropFirst(base.count + 1))
            if local.split(separator: "/").count > maxDepth { continue }
            if let name, !name.matches(String(local.split(separator: "/").last ?? "")) { continue }
            if let path, !path.matches(local) { continue }
            ctx.outLine((start == "." ? "./" : start.hasSuffix("/") ? start : start + "/") + local)
        }
        return 0
    }

    static let sort = ClosureCommand("sort", synopsis: "sort [-r] [-n] [-u] [file…]", class: .readOnly) { ctx in
        let o = try options(ctx.args, allowed: "rnu", command: "sort")
        var all = try inputs(ctx, o.operands).flatMap { lines($0.text).map(String.init) }
        if o.flags.contains("n") {
            all.sort { (Double($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0) <
                       (Double($1.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0) }
        } else {
            all.sort()
        }
        if o.flags.contains("r") { all.reverse() }
        if o.flags.contains("u") { var seen = Set<String>(); all = all.filter { seen.insert($0).inserted } }
        for l in all { ctx.outLine(l) }
        return 0
    }

    static let uniq = ClosureCommand("uniq", synopsis: "uniq [-c] [file]", class: .readOnly) { ctx in
        let o = try options(ctx.args, allowed: "c", command: "uniq")
        var prev: Substring?
        var count = 0
        func emit() {
            guard let p = prev else { return }
            ctx.outLine(o.flags.contains("c") ? String(format: "%7d ", count) + p : String(p))
        }
        for l in try inputs(ctx, o.operands).flatMap({ lines($0.text) }) {
            if l == prev { count += 1 } else { emit(); prev = l; count = 1 }
        }
        emit()
        return 0
    }

    static let mkdir = ClosureCommand("mkdir", synopsis: "mkdir [-p] dir…", class: .mutating) { ctx in
        let o = try options(ctx.args, allowed: "p", command: "mkdir")
        for d in o.operands {
            let url = try ctx.resolve(d)
            if ctx.fileSystem.exists(url), !o.flags.contains("p") { ctx.err("mkdir: \(d): File exists"); return 1 }
            try ctx.fileSystem.createDirectory(url)
        }
        return 0
    }

    static let touch = ClosureCommand("touch", synopsis: "touch file…", class: .mutating) { ctx in
        for f in ctx.args {
            let url = try ctx.resolve(f)
            if !ctx.fileSystem.exists(url) { try ctx.fileSystem.writeText("", to: url) }
        }
        return 0
    }

    static let rm = ClosureCommand("rm", synopsis: "rm [-r] [-f] path…", class: .mutating) { ctx in
        let o = try options(ctx.args, allowed: "rRf", command: "rm")
        var status: Int32 = 0
        for p in o.operands {
            let url = try ctx.resolve(p)
            if url == ctx.fileSystem.root { ctx.err("rm: refusing to remove the workspace root"); return 1 }
            guard ctx.fileSystem.exists(url) else {
                if !o.flags.contains("f") { ctx.err("rm: \(p): No such file or directory"); status = 1 }
                continue
            }
            if ctx.fileSystem.isDirectory(url), !(o.flags.contains("r") || o.flags.contains("R")) {
                ctx.err("rm: \(p): is a directory"); status = 1; continue
            }
            try ctx.fileSystem.remove(url)
        }
        return status
    }

    static let cp = ClosureCommand("cp", synopsis: "cp source… dest", class: .mutating) { ctx in
        let o = try options(ctx.args, allowed: "", command: "cp")
        guard o.operands.count >= 2 else { ctx.err("cp: missing destination"); return 1 }
        let dest = try ctx.resolve(o.operands.last!)
        let destIsDir = ctx.fileSystem.isDirectory(dest)
        if o.operands.count > 2, !destIsDir { ctx.err("cp: \(o.operands.last!): not a directory"); return 1 }
        for s in o.operands.dropLast() {
            let src = try ctx.resolve(s)
            try ctx.fileSystem.copy(src, to: destIsDir ? dest.appending(path: src.lastPathComponent) : dest)
        }
        return 0
    }

    static let mv = ClosureCommand("mv", synopsis: "mv source… dest", class: .mutating) { ctx in
        let o = try options(ctx.args, allowed: "f", command: "mv")
        guard o.operands.count >= 2 else { ctx.err("mv: missing destination"); return 1 }
        let dest = try ctx.resolve(o.operands.last!)
        let destIsDir = ctx.fileSystem.isDirectory(dest)
        if o.operands.count > 2, !destIsDir { ctx.err("mv: \(o.operands.last!): not a directory"); return 1 }
        for s in o.operands.dropLast() {
            let src = try ctx.resolve(s)
            guard ctx.fileSystem.exists(src) else { ctx.err("mv: \(s): No such file or directory"); return 1 }
            try ctx.fileSystem.move(src, to: destIsDir ? dest.appending(path: src.lastPathComponent) : dest)
        }
        return 0
    }

    static let basename = ClosureCommand("basename", synopsis: "basename path [suffix]", class: .readOnly) { ctx in
        guard let p = ctx.args.first else { return 1 }
        var name = (p as NSString).lastPathComponent
        if ctx.args.count > 1, name.hasSuffix(ctx.args[1]), name != ctx.args[1] { name.removeLast(ctx.args[1].count) }
        ctx.outLine(name)
        return 0
    }

    static let dirname = ClosureCommand("dirname", synopsis: "dirname path", class: .readOnly) { ctx in
        guard let p = ctx.args.first else { return 1 }
        let d = (p as NSString).deletingLastPathComponent
        ctx.outLine(d.isEmpty ? "." : d)
        return 0
    }

    static let trueCmd = ClosureCommand("true", synopsis: "true", class: .readOnly) { _ in 0 }
    static let falseCmd = ClosureCommand("false", synopsis: "false", class: .readOnly) { _ in 1 }

    static let diff = ClosureCommand("diff", synopsis: "diff [-u] fileA fileB", class: .readOnly) { ctx in
        let o = try options(ctx.args, allowed: "u", command: "diff")
        guard o.operands.count == 2 else { ctx.err("diff: needs two files"); return 2 }
        let a = try ctx.fileSystem.readText(try ctx.resolve(o.operands[0]))
        let b = try ctx.fileSystem.readText(try ctx.resolve(o.operands[1]))
        if a == b { return 0 }
        ctx.out(LineDiff.unified(old: a, new: b, oldName: o.operands[0], newName: o.operands[1]))
        return 1
    }

    static let help = ClosureCommand("help", synopsis: "help", class: .readOnly) { ctx in
        for c in BuiltinCommands.all.map(\.info).sorted(by: { $0.name < $1.name }) {
            ctx.outLine(c.synopsis)
        }
        return 0
    }
}

/// A grep-style line matcher shared by the shell and the grep tool.
public struct LineMatcher: Sendable {
    private let regex: NSRegularExpression

    public init(pattern: String, literal: Bool = false, ignoreCase: Bool = false, wholeWord: Bool = false) throws {
        var p = literal ? NSRegularExpression.escapedPattern(for: pattern) : pattern
        if wholeWord { p = "\\b(?:" + p + ")\\b" }
        do {
            regex = try NSRegularExpression(pattern: p, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw BuiltinCommands.UsageError(message: "invalid regular expression: \(pattern)")
        }
    }

    public func matches(_ line: some StringProtocol) -> Bool {
        let s = String(line)
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
