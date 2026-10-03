import Foundation

/// `read(path, offset?, limit?)`: a file with line numbers.
public struct ReadTool: AgentTool {
    public init() {}
    public let name = "read"
    public let description = """
    Read a text file in the workspace. Output has 1-based line numbers. By default returns up to \
    \(OutputLimits.readLines) lines or \(OutputLimits.readBytes / 1024) KB; use offset and limit to read \
    other ranges of large files. Read a file before editing it.
    """
    public let promptSnippet = "read a file, or a range of lines (offset, limit) of a large one"
    public var parameters: JSONValue {
        ["type": "object",
         "properties": [
            "path": ["type": "string", "description": "File path relative to the workspace root"],
            "offset": ["type": "integer", "description": "1-based line to start at (default 1)"],
            "limit": ["type": "integer", "description": "Maximum number of lines to return"],
         ],
         "required": ["path"]]
    }

    public func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect { .read }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico"]

    public func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let args = ToolArguments(arguments, tool: name)
        let path = try args.string("path")
        let url = try context.fileSystem.resolve(path)
        if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            return ToolOutput(text: "\(path) is an image. This model reads text only, so images are not supported.")
        }
        if context.fileSystem.isDirectory(url) {
            throw ToolError("\(path) is a directory. Use the list tool to see its contents.")
        }
        let text = try context.fileSystem.readText(url)
        let lines = LineDiff.lines(text)
        if lines.isEmpty { return ToolOutput(text: "(\(path) is empty)") }
        let offset = max(1, try args.optionalInt("offset") ?? 1)
        guard offset <= lines.count else {
            throw ToolError("offset \(offset) is past the end of \(path) (\(lines.count) lines).")
        }
        let limit = max(1, try args.optionalInt("limit") ?? OutputLimits.readLines)
        var out = ""
        var bytes = 0
        var last = offset - 1
        let width = String(min(lines.count, offset + limit - 1)).count
        for i in (offset - 1)..<min(lines.count, offset - 1 + limit) {
            let line = String(repeating: " ", count: max(0, width - String(i + 1).count)) + "\(i + 1)\t"
                + OutputLimits.clipLine(lines[i]) + "\n"
            if bytes + line.utf8.count > OutputLimits.readBytes, i > offset - 1 { break }
            out += line
            bytes += line.utf8.count
            last = i + 1
        }
        if last < lines.count {
            out += "\n[Showing lines \(offset)-\(last) of \(lines.count). Use offset=\(last + 1) to continue.]"
        }
        return ToolOutput(text: out, details: ["path": .string(context.fileSystem.relativePath(of: url)),
                                               "startLine": .int(offset), "endLine": .int(last),
                                               "totalLines": .int(lines.count)])
    }
}

/// `write(path, content)`: creates or replaces a file.
public struct WriteTool: AgentTool {
    public init() {}
    public let name = "write"
    public let description = """
    Create a new file or replace an existing file's entire content. Parent directories are created. \
    Prefer edit for changing part of an existing file.
    """
    public let promptSnippet = "create a file or replace one completely"
    public var parameters: JSONValue {
        ["type": "object",
         "properties": [
            "path": ["type": "string", "description": "File path relative to the workspace root"],
            "content": ["type": "string", "description": "The complete new file content"],
         ],
         "required": ["path", "content"]]
    }

    public func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect {
        .write(paths: [arguments["path"]?.stringValue ?? "?"])
    }

    public func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let args = ToolArguments(arguments, tool: name)
        let path = try args.string("path")
        let content = try args.string("content")
        let url = try context.fileSystem.resolve(path)
        if context.fileSystem.isDirectory(url) { throw ToolError("\(path) is a directory.") }
        let existed = context.fileSystem.exists(url)
        let before = existed ? ((try? context.fileSystem.readText(url)) ?? "") : ""
        try context.fileSystem.writeText(content, to: url)
        let rel = context.fileSystem.relativePath(of: url)
        let lineCount = LineDiff.lines(content).count
        return ToolOutput(
            text: "\(existed ? "Replaced" : "Created") \(rel) (\(lineCount) lines, \(content.utf8.count) bytes).",
            details: ["path": .string(rel), "created": .bool(!existed),
                      "diff": .string(LineDiff.unified(old: before, new: content, oldName: "a/\(rel)", newName: "b/\(rel)"))])
    }
}

/// `edit(path, edits[{oldText, newText}])`: exact-text replacement, atomic per call.
public struct EditTool: AgentTool {
    public init() {}
    public let name = "edit"
    public let description = """
    Edit one file by exact text replacement. Every edits[].oldText must match a unique, non-overlapping \
    region of the original file exactly, including whitespace. All edits are matched against the original \
    file, not after earlier edits. If two changes touch the same or nearby lines, merge them into one edit. \
    Keep oldText as small as possible while still unique.
    """
    public let promptSnippet = "change part of a file by exact text replacement (several disjoint edits per call)"
    public var parameters: JSONValue {
        ["type": "object",
         "properties": [
            "path": ["type": "string", "description": "File path relative to the workspace root"],
            "edits": [
                "type": "array",
                "description": "One or more targeted replacements, matched against the original file",
                "items": [
                    "type": "object",
                    "properties": [
                        "oldText": ["type": "string", "description": "Exact text to replace; unique in the file"],
                        "newText": ["type": "string", "description": "Replacement text"],
                    ],
                    "required": ["oldText", "newText"],
                ],
            ],
         ],
         "required": ["path", "edits"]]
    }

    public func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect {
        .write(paths: [arguments["path"]?.stringValue ?? "?"])
    }

    /// Accepts pi's shapes: an `edits` array, `edits` as a JSON string or a
    /// single object, and the legacy top-level `oldText`/`newText`.
    public static func replacements(from arguments: JSONValue) throws -> [EditEngine.Replacement] {
        var items: [JSONValue] = []
        var edits = arguments["edits"]
        if let s = edits?.stringValue, let parsed = try? JSONValue.parse(s) { edits = parsed }
        if let a = edits?.arrayValue { items = a } else if let o = edits, o.objectValue != nil { items = [o] }
        if let old = arguments["oldText"]?.stringValue, let new = arguments["newText"]?.stringValue {
            items.append(["oldText": .string(old), "newText": .string(new)])
        }
        guard !items.isEmpty else { throw ToolError("edit: edits must contain at least one {oldText, newText}.") }
        return try items.enumerated().map { i, item in
            guard let old = (item["oldText"] ?? item["old_text"])?.stringValue,
                  let new = (item["newText"] ?? item["new_text"])?.stringValue else {
                throw ToolError("edit: edits[\(i)] needs string oldText and newText.")
            }
            return EditEngine.Replacement(oldText: old, newText: new)
        }
    }

    public func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let path = try ToolArguments(arguments, tool: name).string("path")
        let reps = try Self.replacements(from: arguments)
        let url = try context.fileSystem.resolve(path)
        guard context.fileSystem.exists(url) else {
            throw ToolError("Could not edit \(path): the file does not exist. Use write to create it.")
        }
        let original = try context.fileSystem.readText(url)
        let result: EditEngine.Result
        do { result = try EditEngine.apply(reps, to: original) } catch let f as EditEngine.Failure {
            throw ToolError("Could not edit \(path). " + (f.errorDescription ?? ""))
        }
        try context.fileSystem.writeText(result.content, to: url)
        let rel = context.fileSystem.relativePath(of: url)
        let diff = LineDiff.unified(old: original, new: result.content, oldName: "a/\(rel)", newName: "b/\(rel)")
        var text = "Applied \(reps.count) edit\(reps.count == 1 ? "" : "s") to \(rel)."
        if result.usedFuzzyMatch { text += " (Matched after normalizing whitespace and punctuation.)" }
        var details: [String: JSONValue] = ["path": .string(rel), "diff": .string(diff)]
        if let line = result.firstChangedLine { details["firstChangedLine"] = .int(line) }
        return ToolOutput(text: text, details: .object(details))
    }
}

/// `list(path?, depth?)`: a directory tree.
public struct ListTool: AgentTool {
    public init() {}
    public let name = "list"
    public let description = """
    List a directory of the workspace as an indented tree (directories end with "/"). \
    depth controls how many levels are shown (default 2). Build outputs and .git are skipped.
    """
    public let promptSnippet = "show a directory tree"
    public var parameters: JSONValue {
        ["type": "object",
         "properties": [
            "path": ["type": "string", "description": "Directory relative to the workspace root (default: the root)"],
            "depth": ["type": "integer", "description": "Levels to show, 1-6 (default 2)"],
         ]]
    }

    public func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect { .read }

    public func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let args = ToolArguments(arguments, tool: name)
        let path = try args.optionalString("path") ?? "."
        let depth = min(6, max(1, try args.optionalInt("depth") ?? 2))
        let url = try context.fileSystem.resolve(path)
        guard context.fileSystem.isDirectory(url) else { throw ToolError("\(path) is not a directory.") }
        var lines: [String] = []
        var truncated = false
        func walk(_ dir: URL, level: Int) throws {
            for name in try context.fileSystem.list(dir) {
                if lines.count >= 500 { truncated = true; return }
                let bare = name.hasSuffix("/") ? String(name.dropLast()) : name
                if name.hasSuffix("/"), WorkspaceFileSystem.ignoredDirectories.contains(bare) { continue }
                lines.append(String(repeating: "  ", count: level) + name)
                if name.hasSuffix("/"), level + 1 < depth { try walk(dir.appending(path: bare), level: level + 1) }
            }
        }
        try walk(url, level: 0)
        let rel = context.fileSystem.relativePath(of: url)
        var text = (rel.isEmpty ? "/" : rel + "/") + "\n" + lines.map { "  " + $0 }.joined(separator: "\n")
        if lines.isEmpty { text += "  (empty)" }
        if truncated { text += "\n[Listing truncated at 500 entries; list a subdirectory for more.]" }
        return ToolOutput(text: text)
    }
}
