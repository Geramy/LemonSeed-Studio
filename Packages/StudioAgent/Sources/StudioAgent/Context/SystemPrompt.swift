import Foundation

/// An `AGENTS.md` found for the workspace.
public struct ContextFile: Sendable, Hashable {
    /// Display path: workspace-relative inside the workspace, absolute above it.
    public var path: String
    public var content: String
}

/// Finds context files: `AGENTS.md` (or `AGENTS.override.md`, which wins in
/// its directory) in the workspace root and each parent directory, ordered
/// outermost first so the most specific instructions come last. Parents
/// outside the sandbox are simply unreadable on iPad and are skipped.
public enum ContextFiles {
    public static let names = ["AGENTS.override.md", "AGENTS.md"]
    /// Each file is capped so one large file cannot crowd out the window.
    public static let maxBytesPerFile = 12_000

    public static func discover(workspace: any AgentWorkspace, includeParents: Bool = true) -> [ContextFile] {
        var dirs: [URL] = [workspace.rootURL]
        if includeParents {
            var d = workspace.rootURL.deletingLastPathComponent()
            while d.path != "/" && dirs.count < 16 {
                dirs.append(d)
                d = d.deletingLastPathComponent()
            }
        }
        var out: [ContextFile] = []
        for dir in dirs {
            for name in names {
                let url = dir.appending(path: name)
                let text = workspace.withSecurityScope { try? String(contentsOf: url, encoding: .utf8) }
                guard let text else { continue }
                let rel = dir == workspace.rootURL ? name : url.path
                var body = text
                if body.utf8.count > maxBytesPerFile {
                    body = String(decoding: Data(body.utf8).prefix(maxBytesPerFile), as: UTF8.self)
                        + "\n[… truncated at \(maxBytesPerFile) bytes]"
                }
                out.append(ContextFile(path: rel, content: body))
                break
            }
        }
        return out.reversed()
    }
}

/// Builds the session's leading system message.
///
/// The prompt is built once, when a session starts, and persisted as pi's
/// leading system message (named sections plus the tool declarations). Every
/// later request replays it unchanged, so the engine sees a byte-identical
/// prefix: no timestamps, no volatile state, a fixed section order and tool
/// schemas serialized with sorted keys. LSE reuses its KV cache only when the
/// whole cached sequence is a prefix of the next prompt.
public enum SystemPromptBuilder {
    public static func build(workspace: any AgentWorkspace, tools: [any AgentTool],
                             contextFiles: [ContextFile], globalContext: String? = nil) -> AgentMessage.SystemMessage {
        var sections: [String: String?] = [:]
        sections["preamble"] = preamble
        sections["tools"] = toolGuidelines(tools)
        sections["workspace"] = """
        # Workspace

        The workspace is the folder "\(workspace.displayName)". Its root is "/" and every path you use is \
        relative to it; nothing outside it can be read or changed.
        """
        var context = ""
        if let globalContext, !globalContext.isEmpty {
            context += "## Global instructions\n\n\(globalContext)\n\n"
        }
        for f in contextFiles {
            context += "## \(f.path)\n\n\(f.content.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        if !context.isEmpty {
            sections["context"] = "# Project context\n\nInstructions from the project's AGENTS.md files. " +
                "Follow them; the more specific (later) ones win.\n\n" +
                context.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return AgentMessage.SystemMessage(content: "", sections: sections,
                                          toolsAdded: tools.map(\.definition))
    }

    public static let preamble = """
    You are the LemonSeed agent, the coding assistant built into LemonSeed Studio, an IDE for iPad. \
    You help the user with their code by reading, searching and editing files in their workspace \
    and by running commands in the Studio's built-in shell.

    # How to work

    - Look before you change: read the relevant files (or the relevant ranges) first.
    - Prefer `edit` for changes to existing files; use `write` for new files or complete rewrites.
    - Keep changes focused on the request. Do not reformat or rewrite unrelated code.
    - The shell runs a fixed set of in-process commands. There is no network, package manager, \
    interpreter or process spawning; only the commands listed in the bash tool exist.
    - When something fails, read the error, adjust, and try again rather than repeating the same call.
    - Every change you make is checkpointed and the user reviews it, so explain briefly what you \
    changed and why when you finish.
    - Answer concisely. Use Markdown, and fenced code blocks with a language for code.
    """

    static func toolGuidelines(_ tools: [any AgentTool]) -> String {
        var s = "# Tools\n"
        for t in tools {
            s += "\n- \(t.name): \(t.promptSnippet)"
        }
        return s
    }
}
