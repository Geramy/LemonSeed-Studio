import Foundation
import SwiftUI

// The contracts between the Studio shell and the packages that plug into
// it. Each subsystem (LemonText, StudioGit, StudioAgent, StudioTelemetry,
// the terminal) implements one protocol and registers an instance with
// `StudioServices` at launch; the shell asks the registry for views and
// state and never imports those packages directly.
//
// All providers are main-actor objects: they hand SwiftUI views to the
// shell and expose observable state. Heavy work belongs on their own
// queues or actors. Implementations should be `@Observable` classes so the
// status bar and panels update when their state changes.

// MARK: - Workspace context

/// What a provider can see and do in the window it is shown in.
@MainActor
public protocol WorkspaceContext: AnyObject {
    var rootURL: URL { get }
    var displayName: String { get }
    var workspace: Workspace { get }
    /// The document in the focused editor pane, if any.
    var activeDocument: EditorDocument? { get }
    /// Opens a file in the focused pane, optionally revealing a position.
    func open(_ url: URL, at position: TextPosition?)
    /// Selects and reveals a file in the explorer.
    func reveal(_ url: URL)
    /// Appends text to an Output panel channel.
    func log(_ text: String, channel: String)
}

public extension WorkspaceContext {
    var diagnostics: DiagnosticsCenter { workspace.diagnostics }
    var output: OutputCenter { workspace.output }
}

// MARK: - Editor

/// What an editor needs besides its document.
public struct EditorContext {
    /// The workspace the document belongs to (nil for loose files).
    public let workspace: (any WorkspaceContext)?
    public let settings: EditorSettings
    /// Whether this editor's pane has focus (show the caret, take keys).
    public let isFocused: Bool

    public init(workspace: (any WorkspaceContext)?, settings: EditorSettings, isFocused: Bool) {
        self.workspace = workspace
        self.settings = settings
        self.isFocused = isFocused
    }
}

/// Provides the editing surface for documents.
///
/// The editor reads `document.text` once loaded, reports edits with
/// `document.setText(_:)`, keeps `document.cursor` and
/// `document.selectionLength` current, and honors (then clears)
/// `document.pendingReveal`. The theme and code font arrive through the
/// SwiftUI environment (`\.theme`, `\.codeFont`, `\.editorSettings`).
@MainActor
public protocol EditorProviding: AnyObject {
    /// Stable identifier, e.g. "com.lemonseed.lemontext".
    var id: String { get }
    var displayName: String { get }
    /// How well this provider handles `document`: nil if it cannot, higher
    /// wins. The built-in plain editor answers 0 for loaded text.
    func priority(for document: EditorDocument) -> Int?
    func makeEditor(for document: EditorDocument, context: EditorContext) -> AnyView
}

// MARK: - Source control

/// A summary of a repository's state for the status bar and sidebar badge.
public struct GitStatusSummary: Hashable, Sendable {
    public enum ChangeKind: String, Hashable, Sendable {
        case added, modified, deleted, renamed, untracked, conflicted
    }

    public struct Change: Hashable, Sendable, Identifiable {
        public var path: String
        public var kind: ChangeKind
        public var staged: Bool
        public var id: String { (staged ? "S:" : "W:") + path }

        public init(path: String, kind: ChangeKind, staged: Bool) {
            self.path = path
            self.kind = kind
            self.staged = staged
        }
    }

    /// Current branch, or nil when HEAD is detached.
    public var branch: String?
    /// Abbreviated commit when detached.
    public var detachedAt: String?
    public var ahead: Int?
    public var behind: Int?
    /// nil when the provider does not compute changes.
    public var changes: [Change]?

    public init(branch: String?, detachedAt: String? = nil, ahead: Int? = nil, behind: Int? = nil, changes: [Change]? = nil) {
        self.branch = branch
        self.detachedAt = detachedAt
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
    }

    public var headDescription: String {
        branch ?? detachedAt.map { "(\($0))" } ?? "(no branch)"
    }
}

/// Provides Git for a workspace: status for the chrome, and the Source
/// Control sidebar.
@MainActor
public protocol GitProviding: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// Status of the repository containing `root`, or nil when `root` is not
    /// in a repository. Called when a workspace opens and after file changes.
    func status(for root: URL) async -> GitStatusSummary?
    /// The Source Control sidebar.
    func makeSourceControlView(context: any WorkspaceContext) -> AnyView
}

// MARK: - Agent

public struct AgentStatus: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Not usable; the reason is shown to the user.
        case unavailable(String)
        case connecting
        case idle
        case working(String)
    }

    public var state: State
    /// The model in use, for the status bar ("Qwen3.8-27B Q4").
    public var modelName: String?
    /// Where the model runs ("on-device GPU", "remote: 127.0.0.1:8080").
    public var backend: String?

    public init(state: State, modelName: String? = nil, backend: String? = nil) {
        self.state = state
        self.modelName = modelName
        self.backend = backend
    }
}

/// Provides the coding agent: its sidebar panel and status.
@MainActor
public protocol AgentProviding: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var status: AgentStatus { get }
    /// The AI sidebar panel.
    func makePanel(context: any WorkspaceContext) -> AnyView
    /// Re-checks the backend (e.g. after the endpoint setting changes).
    func refresh() async
}

// MARK: - Telemetry and engine

/// The engine layer's state, as the plan's state machine defines it.
public enum EngineState: Hashable, Sendable {
    case unknown
    /// The driver is installed but not enabled in Settings › General › Drivers.
    case driverNotEnabled
    /// The driver is enabled but no GPU is attached.
    case noDevice
    /// A GPU is attached and matched; not started.
    case deviceMatched(String)
    case initializing(String)
    case ready(String)
    case quarantined(String)
    case faulted(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// A snapshot for the status-bar GPU pill. nil fields mean "n/a" (never a
/// fake zero).
public struct GPUSummary: Hashable, Sendable {
    public var loadPercent: Double?
    public var vramUsedBytes: UInt64?
    public var vramTotalBytes: UInt64?
    public var junctionTemperatureC: Double?
    public var powerWatts: Double?
    /// Where the numbers come from ("gpu_metrics", "fixture").
    public var source: String

    public init(loadPercent: Double? = nil, vramUsedBytes: UInt64? = nil, vramTotalBytes: UInt64? = nil,
                junctionTemperatureC: Double? = nil, powerWatts: Double? = nil, source: String) {
        self.loadPercent = loadPercent
        self.vramUsedBytes = vramUsedBytes
        self.vramTotalBytes = vramTotalBytes
        self.junctionTemperatureC = junctionTemperatureC
        self.powerWatts = powerWatts
        self.source = source
    }
}

/// Provides GPU telemetry and engine state: the GPU sidebar screen and the
/// status-bar pill.
@MainActor
public protocol TelemetryProviding: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var engineState: EngineState { get }
    var summary: GPUSummary? { get }
    /// Re-reads driver and device state.
    func refresh()
    /// The GPU screen.
    func makeGPUView(context: (any WorkspaceContext)?) -> AnyView
}

// MARK: - Terminal

/// One terminal session (one tab in the Terminal panel).
@MainActor
public protocol TerminalSession: AnyObject {
    var id: UUID { get }
    var title: String { get }
    var workingDirectory: URL { get }
    func terminate()
}

/// Provides terminal sessions and their views.
@MainActor
public protocol TerminalProviding: AnyObject {
    var id: String { get }
    var displayName: String { get }
    func makeSession(workingDirectory: URL, context: (any WorkspaceContext)?) -> any TerminalSession
    func makeTerminalView(for session: any TerminalSession) -> AnyView
}
