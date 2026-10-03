import Foundation

/// A parsed command line: pipelines joined by `;`, `&&` and `||`.
public struct ShellScript: Equatable, Sendable {
    public enum Connector: Equatable, Sendable { case always, ifSuccess, ifFailure }

    public struct Word: Equatable, Sendable {
        public var text: String
        /// Some part was quoted or escaped, so it is never glob-expanded.
        public var quoted: Bool

        public init(_ text: String, quoted: Bool = false) {
            self.text = text
            self.quoted = quoted
        }
    }

    public struct Command: Equatable, Sendable {
        public var words: [Word]
        /// `> file` or `>> file` for stdout.
        public var redirect: Redirect?
    }

    public struct Redirect: Equatable, Sendable {
        public var target: Word
        public var append: Bool
    }

    public struct Pipeline: Equatable, Sendable {
        /// How this pipeline depends on the previous one's exit status.
        public var connector: Connector
        public var commands: [Command]
    }

    public var pipelines: [Pipeline]
}

public enum ShellParseError: LocalizedError, Equatable {
    case unterminatedQuote
    case missingRedirectTarget
    case emptyCommand(String)

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote: "unterminated quote"
        case .missingRedirectTarget: "syntax error: expected a file name after '>'"
        case .emptyCommand(let near): "syntax error near '\(near)'"
        }
    }
}

/// Tokenizes and parses a POSIX-flavored subset: words with single and
/// double quotes and backslash escapes, `$VAR` / `${VAR}` expansion, a
/// leading `~`, `|`, `>`, `>>`, `;`, `&&` and `||`, and `#` comments.
public enum ShellParser {
    enum Token: Equatable {
        case word(ShellScript.Word)
        case pipe, and, or, semicolon, redirect, append
    }

    public static func parse(_ line: String, environment: [String: String] = [:]) throws -> ShellScript {
        let tokens = try tokenize(line, environment: environment)
        var pipelines: [ShellScript.Pipeline] = []
        var commands: [ShellScript.Command] = []
        var words: [ShellScript.Word] = []
        var redirect: ShellScript.Redirect?
        var connector = ShellScript.Connector.always
        var index = 0

        func finishCommand(near: String) throws {
            guard !words.isEmpty else {
                if redirect != nil || !commands.isEmpty { throw ShellParseError.emptyCommand(near) }
                return
            }
            commands.append(ShellScript.Command(words: words, redirect: redirect))
            words = []
            redirect = nil
        }

        func finishPipeline(near: String, next: ShellScript.Connector) throws {
            try finishCommand(near: near)
            if !commands.isEmpty {
                pipelines.append(ShellScript.Pipeline(connector: connector, commands: commands))
            }
            commands = []
            connector = next
        }

        while index < tokens.count {
            let token = tokens[index]
            index += 1
            switch token {
            case .word(let word):
                words.append(word)
            case .redirect, .append:
                guard index < tokens.count, case .word(let target) = tokens[index] else {
                    throw ShellParseError.missingRedirectTarget
                }
                index += 1
                redirect = ShellScript.Redirect(target: target, append: token == .append)
            case .pipe:
                guard !words.isEmpty else { throw ShellParseError.emptyCommand("|") }
                try finishCommand(near: "|")
            case .semicolon:
                try finishPipeline(near: ";", next: .always)
            case .and:
                guard !words.isEmpty else { throw ShellParseError.emptyCommand("&&") }
                try finishPipeline(near: "&&", next: .ifSuccess)
            case .or:
                guard !words.isEmpty else { throw ShellParseError.emptyCommand("||") }
                try finishPipeline(near: "||", next: .ifFailure)
            }
        }
        if !words.isEmpty || !commands.isEmpty {
            if words.isEmpty { throw ShellParseError.emptyCommand("|") }
            try finishCommand(near: "end")
            pipelines.append(ShellScript.Pipeline(connector: connector, commands: commands))
        } else if connector != .always {
            throw ShellParseError.emptyCommand(connector == .ifSuccess ? "&&" : "||")
        }
        return ShellScript(pipelines: pipelines)
    }

    static func tokenize(_ line: String, environment: [String: String]) throws -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var quoted = false
        var inWord = false
        var chars = Array(line)
        chars.append("\0")
        var i = 0

        func flush() {
            if inWord { tokens.append(.word(ShellScript.Word(current, quoted: quoted))) }
            current = ""
            quoted = false
            inWord = false
        }

        func expandVariable() -> String {
            // At chars[i] == "$".
            var j = i + 1
            var name = ""
            if j < chars.count, chars[j] == "{" {
                j += 1
                while j < chars.count, chars[j] != "}", chars[j] != "\0" { name.append(chars[j]); j += 1 }
                i = j + 1
            } else if j < chars.count, chars[j] == "?" {
                name = "?"
                i = j + 1
            } else {
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    name.append(chars[j])
                    j += 1
                }
                if name.isEmpty {
                    i += 1
                    return "$"
                }
                i = j
            }
            return environment[name] ?? ""
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\0":
                flush()
                i += 1
            case " ", "\t", "\n":
                flush()
                i += 1
            case "#" where !inWord:
                flush()
                i = chars.count
            case "'":
                inWord = true
                quoted = true
                i += 1
                while i < chars.count, chars[i] != "'" {
                    if chars[i] == "\0" { throw ShellParseError.unterminatedQuote }
                    current.append(chars[i])
                    i += 1
                }
                i += 1
            case "\"":
                inWord = true
                quoted = true
                i += 1
                while true {
                    guard i < chars.count, chars[i] != "\0" else { throw ShellParseError.unterminatedQuote }
                    let d = chars[i]
                    if d == "\"" { i += 1; break }
                    if d == "\\", i + 1 < chars.count, ["\"", "\\", "$", "`"].contains(chars[i + 1]) {
                        current.append(chars[i + 1])
                        i += 2
                    } else if d == "$" {
                        current += expandVariable()
                    } else {
                        current.append(d)
                        i += 1
                    }
                }
            case "\\":
                inWord = true
                quoted = true
                if i + 1 < chars.count, chars[i + 1] != "\0" {
                    current.append(chars[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            case "$":
                inWord = true
                current += expandVariable()
            case "~" where !inWord:
                inWord = true
                let next = chars[i + 1]
                if next == "/" || next == " " || next == "\0" || next == "\t" {
                    current += environment["HOME"] ?? "~"
                } else {
                    current.append("~")
                }
                i += 1
            case "|":
                flush()
                if chars[i + 1] == "|" { tokens.append(.or); i += 2 } else { tokens.append(.pipe); i += 1 }
            case "&":
                flush()
                if chars[i + 1] == "&" { tokens.append(.and); i += 2 } else {
                    // Background jobs are not supported; treat '&' as ';'.
                    tokens.append(.semicolon)
                    i += 1
                }
            case ";":
                flush()
                tokens.append(.semicolon)
                i += 1
            case ">":
                flush()
                if chars[i + 1] == ">" { tokens.append(.append); i += 2 } else { tokens.append(.redirect); i += 1 }
            default:
                inWord = true
                current.append(c)
                i += 1
            }
        }
        return tokens
    }
}
