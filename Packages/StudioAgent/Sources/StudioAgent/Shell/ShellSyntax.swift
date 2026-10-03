import Foundation

/// The subset of POSIX shell syntax the in-process shell understands:
/// words with single quotes, double quotes and backslash escapes; pipelines
/// (`|`); lists (`;`, `&&`, `||`); and redirections (`>`, `>>`, `<`, `2>&1`,
/// `2>/dev/null`). There is no variable expansion, command substitution,
/// background job or subshell; those are rejected with a clear error.
public enum ShellSyntax {
    public struct Word: Sendable, Hashable {
        public var text: String
        /// False when any part was quoted: quoted words never glob-expand.
        public var globbable: Bool
    }

    public enum Redirect: Sendable, Hashable {
        case stdoutTo(String, append: Bool)
        case stdinFrom(String)
        case stderrToStdout
        case stderrDiscard
    }

    public struct SimpleCommand: Sendable, Hashable {
        public var words: [Word]
        public var redirects: [Redirect]
        public var name: String? { words.first?.text }
    }

    public enum Connector: Sendable, Hashable { case sequence, and, or }

    public struct Pipeline: Sendable, Hashable {
        public var commands: [SimpleCommand]
    }

    /// A parsed command line: pipelines joined by connectors. The connector at
    /// index i joins pipelines i and i+1.
    public struct CommandList: Sendable, Hashable {
        public var pipelines: [Pipeline]
        public var connectors: [Connector]
    }

    public enum ParseError: Error, Hashable, Sendable, LocalizedError {
        case unterminatedQuote
        case unsupported(String)
        case missingRedirectTarget
        case emptyCommand

        public var errorDescription: String? {
            switch self {
            case .unterminatedQuote: "syntax error: unterminated quote"
            case .unsupported(let s): "syntax error: \(s) is not supported by this shell"
            case .missingRedirectTarget: "syntax error: redirection without a target"
            case .emptyCommand: "syntax error: empty command"
            }
        }
    }

    enum Token: Hashable {
        case word(Word)
        case pipe, and, or, semicolon
        case redirOut, redirAppend, redirIn, stderrToStdout, stderrDiscard
    }

    static func tokenize(_ line: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(line)
        var i = 0
        var current = ""
        var inWord = false
        var globbable = true

        func flush() {
            if inWord { tokens.append(.word(Word(text: current, globbable: globbable))) }
            current = ""
            inWord = false
            globbable = true
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t", "\n":
                flush()
                i += 1
            case "'":
                inWord = true
                globbable = false
                i += 1
                while i < chars.count, chars[i] != "'" { current.append(chars[i]); i += 1 }
                guard i < chars.count else { throw ParseError.unterminatedQuote }
                i += 1
            case "\"":
                inWord = true
                globbable = false
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                        current.append(chars[i + 1]); i += 2
                    } else if chars[i] == "$" || chars[i] == "`" {
                        throw ParseError.unsupported("expansion (\(chars[i]))")
                    } else {
                        current.append(chars[i]); i += 1
                    }
                }
                guard i < chars.count else { throw ParseError.unterminatedQuote }
                i += 1
            case "\\":
                inWord = true
                if i + 1 < chars.count { current.append(chars[i + 1]) }
                i += 2
            case "|":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "|" { tokens.append(.or); i += 2 }
                else { tokens.append(.pipe); i += 1 }
            case "&":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "&" { tokens.append(.and); i += 2 }
                else { throw ParseError.unsupported("background jobs (&)") }
            case ";":
                flush()
                tokens.append(.semicolon)
                i += 1
            case ">":
                // "2>" is handled below when the word so far is exactly "2".
                if inWord, current == "2", globbable {
                    current = ""; inWord = false
                    let rest = String(chars[(i + 1)...]).drop(while: { $0 == " " })
                    if rest.hasPrefix("&1") {
                        tokens.append(.stderrToStdout)
                        i = chars.count - rest.count + 2
                    } else if rest.hasPrefix("/dev/null") {
                        tokens.append(.stderrDiscard)
                        i = chars.count - rest.count + 9
                    } else {
                        throw ParseError.unsupported("redirecting stderr to a file")
                    }
                    continue
                }
                flush()
                if i + 1 < chars.count, chars[i + 1] == ">" { tokens.append(.redirAppend); i += 2 }
                else { tokens.append(.redirOut); i += 1 }
            case "<":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "<" { throw ParseError.unsupported("here-documents") }
                tokens.append(.redirIn)
                i += 1
            case "$", "`":
                throw ParseError.unsupported("expansion (\(c))")
            case "(", ")":
                throw ParseError.unsupported("subshells")
            default:
                inWord = true
                current.append(c)
                i += 1
            }
        }
        flush()
        return tokens
    }

    public static func parse(_ line: String) throws -> CommandList {
        let tokens = try tokenize(line)
        var pipelines: [Pipeline] = []
        var connectors: [Connector] = []
        var commands: [SimpleCommand] = []
        var cmd = SimpleCommand(words: [], redirects: [])
        var i = 0

        func endCommand() throws {
            guard !cmd.words.isEmpty else { throw ParseError.emptyCommand }
            commands.append(cmd)
            cmd = SimpleCommand(words: [], redirects: [])
        }
        func endPipeline() throws {
            try endCommand()
            pipelines.append(Pipeline(commands: commands))
            commands = []
        }
        func target() throws -> String {
            i += 1
            guard i < tokens.count, case .word(let w) = tokens[i] else { throw ParseError.missingRedirectTarget }
            return w.text
        }

        while i < tokens.count {
            switch tokens[i] {
            case .word(let w): cmd.words.append(w)
            case .pipe: try endCommand()
            case .and: try endPipeline(); connectors.append(.and)
            case .or: try endPipeline(); connectors.append(.or)
            case .semicolon:
                if cmd.words.isEmpty && commands.isEmpty { break }  // tolerate "a; ;" and trailing ";"
                try endPipeline(); connectors.append(.sequence)
            case .redirOut: cmd.redirects.append(.stdoutTo(try target(), append: false))
            case .redirAppend: cmd.redirects.append(.stdoutTo(try target(), append: true))
            case .redirIn: cmd.redirects.append(.stdinFrom(try target()))
            case .stderrToStdout: cmd.redirects.append(.stderrToStdout)
            case .stderrDiscard: cmd.redirects.append(.stderrDiscard)
            }
            i += 1
        }
        if cmd.words.isEmpty && commands.isEmpty {
            if connectors.last == .sequence { connectors.removeLast() }
        } else {
            try endPipeline()
        }
        guard !pipelines.isEmpty, connectors.count == pipelines.count - 1 else { throw ParseError.emptyCommand }
        return CommandList(pipelines: pipelines, connectors: connectors)
    }
}
