import Foundation

/// How much a command line can change, used by the permission tiers. Ordered:
/// a pipeline is classified by its most consequential stage.
public enum ShellCommandClass: Int, Sendable, Hashable, Comparable, Codable {
    /// Reads the workspace only (ls, cat, grep, find…).
    case readOnly = 0
    /// Builds or tests; writes only build outputs (registered by Toolchain).
    case build = 1
    /// Creates, changes or deletes workspace files (rm, mv, redirections…).
    case mutating = 2
    /// Reaches the network or credentials.
    case network = 3
    /// Not a known command; always treated as needing approval.
    case unknown = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .readOnly: "read-only"
        case .build: "build"
        case .mutating: "modifies files"
        case .network: "network"
        case .unknown: "unknown command"
        }
    }
}

public struct ShellResult: Sendable, Hashable {
    public var exitCode: Int32
    public var output: String
    public var timedOut: Bool

    public init(exitCode: Int32, output: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.output = output
        self.timedOut = timedOut
    }
}

public struct ShellCommandInfo: Sendable, Hashable {
    public var name: String
    public var synopsis: String
    public var commandClass: ShellCommandClass

    public init(name: String, synopsis: String, commandClass: ShellCommandClass) {
        self.name = name
        self.synopsis = synopsis
        self.commandClass = commandClass
    }
}

/// The agent's `bash` tool routes here. iPadOS cannot spawn processes, so a
/// "shell" is an in-process interpreter over registered library commands.
/// The Terminal module provides the full `lsh` with the Toolchain's commands
/// (clang, cmake, ninja, ctest…); `InProcessShell` is the minimal built-in
/// set the agent ships with.
public protocol ShellProviding: Sendable {
    /// Listed in the tool description so the model knows what exists.
    var commands: [ShellCommandInfo] { get }
    /// Classifies a full command line without running it. Must be exact:
    /// unknown commands are `.unknown`, never guessed.
    func classify(_ commandLine: String) -> ShellCommandClass
    /// Runs a command line with the working directory at the workspace root.
    /// `output` receives text as it is produced, for live tool cards.
    func run(_ commandLine: String, fileSystem: WorkspaceFileSystem, timeout: Duration,
             output: @escaping @Sendable (String) -> Void) async -> ShellResult
}
