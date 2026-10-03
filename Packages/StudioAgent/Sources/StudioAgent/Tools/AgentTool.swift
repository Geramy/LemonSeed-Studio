import Foundation

/// What a call would do, decided before it runs. Permission tiers key on it.
public enum ToolEffect: Sendable, Hashable {
    case read
    case write(paths: [String])
    case shell(command: String, commandClass: ShellCommandClass)
}

/// What a tool sees while it runs.
public struct ToolContext: Sendable {
    public var fileSystem: WorkspaceFileSystem
    public var shell: any ShellProviding
    /// Live output for the tool card (bash streams here).
    public var progress: @Sendable (String) -> Void

    public init(fileSystem: WorkspaceFileSystem, shell: any ShellProviding,
                progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileSystem = fileSystem
        self.shell = shell
        self.progress = progress
    }
}

/// A tool's result: text for the model, optional structured details for the
/// UI and the session (`details` is never sent to the model).
public struct ToolOutput: Sendable, Hashable {
    public var text: String
    public var isError: Bool
    public var details: JSONValue?

    public init(text: String, isError: Bool = false, details: JSONValue? = nil) {
        self.text = text
        self.isError = isError
        self.details = details
    }
}

/// Errors a tool reports back to the model (as an error result it can act
/// on, never as a crash).
public struct ToolError: Error, Hashable, Sendable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A tool the agent can call.
public protocol AgentTool: Sendable {
    var name: String { get }
    /// The description in the tool schema.
    var description: String { get }
    /// One line for the system prompt's tool section.
    var promptSnippet: String { get }
    /// JSON Schema for the arguments. `strict` is never used: LSE does not do
    /// grammar-constrained decoding, so arguments are validated here instead.
    var parameters: JSONValue { get }
    /// Classifies a call for the permission gate without running it.
    func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput
}

extension AgentTool {
    public var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: parameters)
    }
}

/// Typed access to call arguments with model-friendly errors.
public struct ToolArguments: Sendable {
    public let raw: JSONValue
    let tool: String

    public init(_ raw: JSONValue, tool: String) {
        self.raw = raw
        self.tool = tool
    }

    public func string(_ key: String) throws -> String {
        guard let v = raw[key], !v.isNull else { throw ToolError("\(tool): missing required argument \"\(key)\".") }
        if let s = v.stringValue { return s }
        if let n = v.doubleValue { return n.rounded() == n ? String(Int(n)) : String(n) }
        throw ToolError("\(tool): \"\(key)\" must be a string.")
    }

    public func optionalString(_ key: String) throws -> String? {
        guard let v = raw[key], !v.isNull else { return nil }
        return try string(key)
    }

    /// Accepts numbers and numeric strings (models often quote numbers).
    public func optionalInt(_ key: String) throws -> Int? {
        guard let v = raw[key], !v.isNull else { return nil }
        if let i = v.intValue { return i }
        if let s = v.stringValue, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        throw ToolError("\(tool): \"\(key)\" must be an integer.")
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        guard let v = raw[key], !v.isNull else { return nil }
        if let b = v.boolValue { return b }
        if let s = v.stringValue?.lowercased() { if s == "true" { return true }; if s == "false" { return false } }
        throw ToolError("\(tool): \"\(key)\" must be true or false.")
    }
}

/// Output limits shared by the tools (the window is 32K tokens).
public enum OutputLimits {
    public static let readLines = 400
    public static let readBytes = 16 * 1024
    public static let maxLineLength = 2000
    public static let shellTailBytes = 8 * 1024
    public static let searchResults = 200

    /// Keeps the last `bytes` of `text`, cut at a line boundary, with a marker.
    public static func tail(_ text: String, bytes: Int = shellTailBytes) -> (text: String, truncated: Bool) {
        let utf8 = Array(text.utf8)
        guard utf8.count > bytes else { return (text, false) }
        var start = utf8.count - bytes
        while start < utf8.count, utf8[start] != 0x0A { start += 1 }
        let kept = String(decoding: utf8[min(start + 1, utf8.count)...], as: UTF8.self)
        let dropped = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } - kept.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return ("[… \(dropped) earlier lines omitted]\n" + kept, true)
    }

    public static func clipLine(_ line: some StringProtocol) -> String {
        line.count > maxLineLength ? String(line.prefix(maxLineLength)) + " [… line truncated]" : String(line)
    }
}
