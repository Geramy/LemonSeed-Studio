import SwiftUI

/// A fenced code block: language label, copy button, light syntax tinting,
/// horizontal scrolling for long lines.
public struct CodeBlockView: View {
    let code: String
    let language: String?
    @Environment(\.agentTheme) private var theme
    @State private var copied = false

    public init(code: String, language: String?) {
        self.code = code
        self.language = language
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.tertiaryText)
                Spacer()
                Button {
                    copy(code)
                    withAnimation(.snappy) { copied = true }
                    Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(theme.captionFont)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? theme.success : theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Rectangle().fill(theme.hairline).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxTint.highlight(code, language: language, theme: theme))
                    .font(theme.codeFont)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).strokeBorder(theme.hairline))
    }
}

func copy(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

/// A small lexical tinter for code blocks in chat (comments, strings,
/// numbers, keywords). The editor's tree-sitter highlighting is the real
/// thing; this only keeps chat code readable.
enum SyntaxTint {
    static let keywords: Set<String> = [
        // C family
        "int", "char", "void", "float", "double", "long", "short", "unsigned", "signed", "const", "static",
        "struct", "enum", "union", "typedef", "return", "if", "else", "for", "while", "do", "switch", "case",
        "default", "break", "continue", "sizeof", "include", "define", "auto", "class", "public", "private",
        "protected", "template", "typename", "namespace", "using", "new", "delete", "true", "false", "nullptr",
        "bool", "virtual", "override", "constexpr", "inline", "extern", "volatile", "goto",
        // Swift, Python, JS, Rust
        "func", "let", "var", "import", "self", "Self", "nil", "guard", "in", "throws", "try", "await", "async",
        "def", "None", "True", "False", "from", "as", "with", "lambda", "pass", "yield", "fn", "mut", "pub",
        "impl", "match", "function", "const", "export", "interface", "type", "extension", "protocol", "some", "any",
    ]

    static func highlight(_ code: String, language: String?, theme: AgentTheme) -> AttributedString {
        var out = AttributedString()
        let hashComments = ["python", "py", "sh", "bash", "shell", "zsh", "ruby", "yaml", "toml", "cmake"]
            .contains(language?.lowercased() ?? "")
        let chars = Array(code)
        var i = 0
        func emit(_ s: String, _ color: Color?) {
            var a = AttributedString(s)
            if let color { a.foregroundColor = color } else { a.foregroundColor = theme.primaryText }
            out += a
        }
        while i < chars.count {
            let c = chars[i]
            // Comments
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" || (hashComments && c == "#") {
                var j = i
                while j < chars.count && chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), theme.syntaxComment); i = j; continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count && !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                j = min(chars.count, j + 2)
                emit(String(chars[i..<j]), theme.syntaxComment); i = j; continue
            }
            // Strings
            if c == "\"" || c == "'" {
                var j = i + 1
                while j < chars.count && chars[j] != c && chars[j] != "\n" { j += chars[j] == "\\" ? 2 : 1 }
                j = min(chars.count, j + 1)
                emit(String(chars[i..<j]), theme.syntaxString); i = j; continue
            }
            // Numbers
            if c.isNumber {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j].isLetter || chars[j] == "." || chars[j] == "_") { j += 1 }
                emit(String(chars[i..<j]), theme.syntaxNumber); i = j; continue
            }
            // Identifiers and keywords
            if c.isLetter || c == "_" || c == "#" {
                var j = i + 1
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let word = String(chars[i..<j])
                let bare = word.hasPrefix("#") ? String(word.dropFirst()) : word
                emit(word, keywords.contains(bare) ? theme.syntaxKeyword : nil); i = j; continue
            }
            var j = i + 1
            while j < chars.count && !(chars[j].isLetter || chars[j].isNumber || "\"'/_#".contains(chars[j])) { j += 1 }
            emit(String(chars[i..<j]), nil); i = j
        }
        return out
    }
}
