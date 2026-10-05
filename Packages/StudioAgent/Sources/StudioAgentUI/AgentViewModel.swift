import Foundation
import Observation
import StudioAgent

/// One row of the chat transcript.
public struct TranscriptItem: Identifiable, Sendable {
    public enum Kind: Sendable {
        case user(text: String, entryID: String?)
        case assistant(AssistantBlock)
        case tool(ToolCard)
        case notice(String, isError: Bool)
        case compaction(summary: String)
        case changes(ChangeSet)
    }

    public var id: String
    public var kind: Kind
}

/// A streaming or finished assistant message.
public struct AssistantBlock: Sendable {
    /// The answer and the reasoning as they stream (views draw these).
    public var answer = ChunkedText(.markdownBlocks)
    public var thinking = ChunkedText(.lines)
    public var isStreaming = true
    public var reasoningStarted: Date?
    public var reasoningEnded: Date?
    public var stopReason: StopReason?
    /// Why the reply was cut off, when the agent said (this run only).
    public var replyStop: ReplyStop?
    public var errorMessage: String?
    /// When the first streamed token (reasoning or answer) arrived.
    public var firstTokenAt: Date?
    /// Streamed deltas so far: about one token each.
    public var streamedTokens = 0
    /// The engine's timings for the turn, once it has finished.
    public var finalTimings: GenerationTimings?

    /// Live decode speed while streaming, from the deltas' arrival times.
    public func liveTokensPerSecond(now: Date = Date()) -> Double? {
        guard let first = firstTokenAt, streamedTokens > 1 else { return nil }
        let seconds = now.timeIntervalSince(first)
        return seconds > 0.2 ? Double(streamedTokens - 1) / seconds : nil
    }

    public init(text: String = "", reasoning: String = "", isStreaming: Bool = true) {
        answer = ChunkedText(.markdownBlocks, text)
        thinking = ChunkedText(.lines, reasoning)
        self.isStreaming = isStreaming
    }

    /// The whole answer: O(n), for tests and tools, not for views.
    public var text: String {
        get { answer.string }
        set { answer = ChunkedText(.markdownBlocks, newValue) }
    }

    /// The whole reasoning: O(n), for tests and tools, not for views.
    public var reasoning: String {
        get { thinking.string }
        set { thinking = ChunkedText(.lines, newValue) }
    }

    public var reasoningSeconds: Int? {
        guard let s = reasoningStarted, let e = reasoningEnded else { return nil }
        return max(1, Int(e.timeIntervalSince(s).rounded()))
    }
}

/// A tool call with its live output and result.
public struct ToolCard: Sendable {
    public enum Status: Sendable, Equatable { case running, awaitingApproval, done, failed }
    public var callID: String
    public var name: String
    public var arguments: JSONValue
    public var effect: ToolEffect?
    public var status: Status
    /// A running command's output as it streams; only its end is kept.
    public var live = ChunkedText(.lines)
    public var result: ToolOutput?

    /// The live output kept so far: O(n), for tools, not for views.
    public var liveOutput: String { live.string }

    public init(callID: String, name: String, arguments: JSONValue, effect: ToolEffect?, status: Status,
                result: ToolOutput? = nil) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.effect = effect
        self.status = status
        self.result = result
    }
}

/// Where the model is and how it is doing, shown in the panel header.
public enum EngineStatus: Sendable, Equatable {
    case unknown
    case online(model: String, detail: String?)
    case offline(String)
    /// A scripted client (previews, offline demo). Never labeled as the engine.
    case scripted
}

/// What the user decided about one file an agent run changed.
public enum FileReviewState: String, Sendable, Hashable {
    /// On disk, waiting for Accept or Deny (review and ask modes).
    case pending
    /// Kept.
    case accepted
    /// Reverted to the checkpoint.
    case denied
    /// Some blocks kept, some reverted (from the diff).
    case partial
    /// Applied directly (autopilot); can still be undone.
    case applied
    /// A later run changed the file again; decide on that run's card.
    case superseded

    public var isOpen: Bool { self == .pending || self == .applied }
}

/// Generation statistics from LSE's timings. Nil fields render as "n/a".
public struct AgentStats: Sendable, Equatable {
    public var lastTimings: GenerationTimings?
    public var contextTokens = 0
    public var contextWindow = 32768
    public var turns = 0
}

/// Drives the agent views: owns the `Agent`, folds its events into a
/// transcript, and bridges permission prompts and reviews to the UI.
@MainActor @Observable
public final class AgentViewModel {
    public private(set) var items: [TranscriptItem] = []
    public var composer = ""
    public private(set) var isRunning = false
    public private(set) var stats = AgentStats()
    public private(set) var engine: EngineStatus = .unknown
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var sessionTitle = "New session"
    public private(set) var pendingApproval: PermissionRequest?
    /// Set to present the review sheet (a whole run, or one file of it).
    public var review: ChangeSet?
    /// Per run (change set id) and file: the user's decision.
    public private(set) var fileReview: [String: [String: FileReviewState]] = [:]
    /// Files the agent changed that still wait for a decision (workspace
    /// relative): the explorer marks them.
    public var pendingPaths: Set<String> {
        var paths = Set<String>()
        for (_, files) in fileReview { for (path, state) in files where state == .pending { paths.insert(path) } }
        return paths
    }
    /// Files changed by the agent in this chat that are still in place
    /// (pending, accepted, partial or applied).
    public var changedPaths: Set<String> {
        var paths = Set<String>()
        for (_, files) in fileReview {
            for (path, state) in files where state != .denied && state != .superseded { paths.insert(path) }
        }
        return paths
    }
    /// Asks the host to open a workspace-relative file in the editor.
    public var onOpenFile: ((String) -> Void)?
    /// Tells the host which files changed on disk (reverted, kept), so the
    /// editor, explorer and source control refresh.
    public var onFilesChanged: (([String]) -> Void)?
    /// Set to present the session list.
    public var isShowingSessions = false
    public var mode: PermissionMode {
        didSet { if let agent { Task { await agent.setPermissionMode(mode) } } }
    }
    /// The session's thinking level (`reasoning_effort`). Fixed per session
    /// so the engine's prompt cache stays valid; see `setThinking`.
    public private(set) var thinking: ThinkingLevel

    public let workspace: any AgentWorkspace
    public private(set) var configuration: AgentConfiguration
    private let client: any LLMClient
    private let shell: any ShellProviding
    private let isScripted: Bool
    private var agent: Agent?
    private var runTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<PermissionResponse, Never>?
    private var index: [String: Int] = [:]
    private var currentAssistant: String?
    private var lastAssistant: String?
    // Streamed deltas are applied to the transcript at most ~30 times a
    // second, never held back until the end.
    private var pendingText = ""
    private var pendingReasoning = ""
    private var pendingTokens = 0
    private var flushTask: Task<Void, Never>?
    private static let flushInterval: Duration = .milliseconds(33)

    public init(workspace: any AgentWorkspace, client: any LLMClient, configuration: AgentConfiguration = .init(),
                shell: any ShellProviding = InProcessShell()) {
        self.workspace = workspace
        self.client = client
        self.configuration = configuration
        self.shell = shell
        self.mode = configuration.permissionMode
        self.thinking = configuration.thinking
        self.isScripted = client is ScriptedLLMClient
        stats.contextWindow = configuration.endpoint.contextWindow
        if isScripted { engine = .scripted }
    }

    // MARK: Engine and sessions

    public func checkEngine() async {
        guard !isScripted else { engine = .scripted; return }
        guard let http = client as? OpenAICompatibleClient else { engine = .online(model: configuration.endpoint.model, detail: nil); return }
        if let health = await http.health(), health.ok {
            let models = (try? await http.models()) ?? []
            let model = models.contains(configuration.endpoint.model) ? configuration.endpoint.model : (models.first ?? configuration.endpoint.model)
            engine = .online(model: model, detail: health.speculation)
        } else {
            engine = .offline("No engine at \(configuration.endpoint.baseURL.host() ?? "?"):\(configuration.endpoint.baseURL.port.map(String.init) ?? "")")
        }
    }

    public func refreshSessions() {
        sessions = SessionStore(workspace: workspace).list()
    }

    private func approver() -> any PermissionApprover {
        ApprovalBridge { [weak self] request in
            guard let self else { return .deny(reason: nil) }
            return await self.ask(request)
        }
    }

    /// Starts a fresh session (the next message creates it).
    public func newSession() {
        stop()
        agent = nil
        currentSessionIDCache = nil
        items = []
        index = [:]
        fileReview = [:]
        // Every new chat starts in the default mode (review); read-only is
        // an explicit choice per chat.
        mode = configuration.permissionMode
        sessionTitle = "New session"
        stats = AgentStats(contextWindow: configuration.endpoint.contextWindow)
    }

    public func open(_ summary: SessionSummary) {
        stop()
        do {
            let a = try Agent.resume(url: summary.url, workspace: workspace, client: client, shell: shell,
                                     approver: approver(), configuration: configuration)
            agent = a
            sessionTitle = summary.title
            currentSessionIDCache = summary.id
            Task {
                await a.setPermissionMode(mode)
                self.thinking = await a.configuration.thinking
                let doc = await a.document
                self.items = Self.transcript(from: doc)
                self.reindex()
            }
        } catch {
            append(.notice("Could not open the session: \(error.localizedDescription)", isError: true))
        }
    }

    /// Called with a session's id once it is deleted, so the host can tell
    /// the engine to drop that session's KV cache.
    public var onSessionDeleted: ((String) -> Void)?

    /// The current session's id (the `session_id` every request carries).
    public var currentSessionID: String? { currentSessionIDCache }
    private var currentSessionIDCache: String?

    public func deleteSession(_ summary: SessionSummary) {
        if summary.id == currentSessionIDCache { newSession() }
        try? SessionStore(workspace: workspace).delete(summary.url)
        onSessionDeleted?(summary.id)
        refreshSessions()
    }

    public func renameSession(_ summary: SessionSummary, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? SessionStore(workspace: workspace).rename(summary.url, to: trimmed)
        if summary.id == currentSessionIDCache { sessionTitle = trimmed }
        refreshSessions()
    }

    public func setPinned(_ summary: SessionSummary, _ pinned: Bool) {
        try? SessionStore(workspace: workspace).setPinned(pinned, id: summary.id)
        refreshSessions()
    }

    // MARK: Sending

    /// Whether the session already talked to the engine (a thinking change
    /// then costs one full re-read of the conversation).
    public var hasHistory: Bool { agent != nil && !items.isEmpty }

    /// Sets the thinking level. Before the first message it simply applies.
    /// In a session with history it applies from the next request (the
    /// engine's prompt cache resets once), or starts a new session with it.
    public func setThinking(_ level: ThinkingLevel, startNewSession: Bool = false) {
        guard level != thinking else { return }
        thinking = level
        configuration.thinking = level
        guard hasHistory, let agent else { return }
        if startNewSession {
            newSession()
            append(.notice("New session with thinking \(level.title).", isError: false))
            return
        }
        Task {
            do {
                try await agent.setThinking(level)
                append(.notice("Thinking is \(level.title) from the next message. The engine re-reads this conversation once, because the thinking level is part of its cached prompt.", isError: false))
            } catch {
                append(.notice("Could not record the thinking change: \(error.localizedDescription)", isError: true))
            }
        }
    }

    public var canSend: Bool { !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func send() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer = ""
        send(text)
    }

    public func send(_ text: String) {
        if isRunning, let agent {
            Task { await agent.steer(text) }
            append(.notice("Steering: the agent will read this after its current step.", isError: false))
            return
        }
        do {
            let a = try agent ?? makeAgent(firstMessage: text)
            agent = a
            if currentSessionIDCache == nil { Task { self.currentSessionIDCache = await a.document.header.id } }
            isRunning = true
            runTask = Task {
                for await event in a.prompt(text) { self.apply(event) }
                self.isRunning = false
                self.runTask = nil
                self.refreshSessions()
            }
        } catch {
            append(.notice("Could not start a session: \(error.localizedDescription)", isError: true))
        }
    }

    private func makeAgent(firstMessage: String) throws -> Agent {
        var config = configuration
        config.permissionMode = mode
        let title = String(firstMessage.split(separator: "\n").first ?? "").prefix(60)
        sessionTitle = String(title)
        return try Agent.start(workspace: workspace, client: client, shell: shell, approver: approver(),
                               configuration: config, name: String(title))
    }

    /// Stops the run at the next token.
    public func stop() {
        if let c = approvalContinuation {
            approvalContinuation = nil
            pendingApproval = nil
            c.resume(returning: .deny(reason: "The user stopped the agent."))
        }
        if let agent { Task { await agent.abort() } }
    }

    // MARK: Permission prompts

    private func ask(_ request: PermissionRequest) async -> PermissionResponse {
        await withCheckedContinuation { c in
            approvalContinuation?.resume(returning: .deny(reason: nil))
            approvalContinuation = c
            pendingApproval = request
            updateTool(request.callID) { $0.status = .awaitingApproval }
        }
    }

    public func respond(_ response: PermissionResponse) {
        guard let c = approvalContinuation, let request = pendingApproval else { return }
        approvalContinuation = nil
        pendingApproval = nil
        updateTool(request.callID) { $0.status = .running }
        c.resume(returning: response)
    }

    // MARK: Review

    public func openLatestReview() {
        guard let agent else { return }
        Task { self.review = await agent.latestChangeSet() }
    }

    // MARK: Per-file review

    public func reviewState(_ changes: ChangeSet, path: String) -> FileReviewState {
        fileReview[changes.id]?[path] ?? .accepted
    }

    /// Keeps a file as the agent left it, and opens it in the editor.
    public func acceptFile(_ changes: ChangeSet, path: String) {
        guard reviewState(changes, path: path).isOpen else { return }
        fileReview[changes.id]?[path] = .accepted
        if changes.files.first(where: { $0.path == path })?.kind != .deleted { onOpenFile?(path) }
        onFilesChanged?([path])
    }

    /// Reverts a file to its checkpoint; the model hears about it next turn.
    public func denyFile(_ changes: ChangeSet, path: String) {
        guard reviewState(changes, path: path).isOpen, let file = changes.files.first(where: { $0.path == path }) else { return }
        var decisions = ChangeSet.Decisions()
        decisions.setAll(file, accepted: false)
        if file.isBinary || file.hunks.isEmpty { decisions.rejected[path] = [-1] }
        revert(changes, decisions: decisions, paths: [path], state: .denied)
    }

    public func acceptAll(_ changes: ChangeSet) {
        let open = changes.files.filter { reviewState(changes, path: $0.path).isOpen }
        guard !open.isEmpty else { return }
        for f in open { fileReview[changes.id]?[f.path] = .accepted }
        if let first = open.first(where: { $0.kind != .deleted }) { onOpenFile?(first.path) }
        onFilesChanged?(open.map(\.path))
    }

    public func denyAll(_ changes: ChangeSet) {
        let open = changes.files.filter { reviewState(changes, path: $0.path).isOpen }
        guard !open.isEmpty else { return }
        var decisions = ChangeSet.Decisions()
        for f in open {
            decisions.setAll(f, accepted: false)
            if f.isBinary || f.hunks.isEmpty { decisions.rejected[f.path] = [-1] }
        }
        revert(changes, decisions: decisions, paths: open.map(\.path), state: .denied)
    }

    /// Opens the diff of one file (per-block accept and deny).
    public func showDiff(_ changes: ChangeSet, path: String) {
        guard let file = changes.files.first(where: { $0.path == path }) else { return }
        review = ChangeSet(checkpoint: changes.checkpoint, files: [file])
    }

    private func revert(_ changes: ChangeSet, decisions: ChangeSet.Decisions, paths: [String], state: FileReviewState) {
        guard let agent else { return }
        Task {
            do {
                try await agent.applyReview(changes, decisions: decisions)
                for p in paths { fileReview[changes.id]?[p] = state }
                onFilesChanged?(paths)
            } catch {
                append(.notice("Could not revert \(paths.joined(separator: ", ")): \(error.localizedDescription)", isError: true))
            }
        }
    }

    /// The result of the diff review: hunk decisions for the files shown.
    /// Files are looked up in the whole run, so a one-file review applies to
    /// that file only.
    public func applyReview(_ changes: ChangeSet, decisions: ChangeSet.Decisions) {
        guard let run = items.lazy.compactMap({ item -> ChangeSet? in
            if case .changes(let c) = item.kind, c.id == changes.id { return c }
            return nil
        }).first ?? Optional(changes) else { return }
        guard let agent else { return }
        let paths = changes.files.map(\.path)
        Task {
            do {
                try await agent.applyReview(run, decisions: decisions)
                for file in changes.files {
                    let rejected = decisions.rejected[file.path] ?? []
                    let state: FileReviewState = rejected.isEmpty ? .accepted
                        : (file.isBinary || rejected.isSuperset(of: file.hunks.map(\.id))) ? .denied : .partial
                    fileReview[run.id]?[file.path] = state
                    if state != .denied, file.kind != .deleted, paths.count == 1 { onOpenFile?(file.path) }
                }
                onFilesChanged?(paths)
            } catch {
                append(.notice("Could not apply the review: \(error.localizedDescription)", isError: true))
            }
            review = nil
        }
    }

    /// Rewinds to before a user message, restoring files; returns its text
    /// to the composer.
    public func rewind(to item: TranscriptItem) {
        guard !isRunning, let agent, case .user(_, let entryID?) = item.kind else { return }
        Task {
            do {
                if let text = try await agent.rewind(toUserEntry: entryID) {
                    let doc = await agent.document
                    items = Self.transcript(from: doc)
                    reindex()
                    composer = text
                }
            } catch {
                append(.notice("Could not rewind: \(error.localizedDescription)", isError: true))
            }
        }
    }

    // MARK: Events

    func apply(_ event: AgentEvent) {
        switch event {
        case .reasoningDelta(let s):
            pendingReasoning += s
            pendingTokens += 1
            scheduleFlush()
            return
        case .textDelta(let s):
            pendingText += s
            pendingTokens += 1
            scheduleFlush()
            return
        default:
            flushDeltas()
        }
        switch event {
        case .agentStart:
            break
        case .userMessage(let text, let entryID):
            append(.user(text: text, entryID: entryID))
        case .turnStart:
            break
        case .assistantStart:
            let id = "a-\(UUID().uuidString)"
            currentAssistant = id
            lastAssistant = id
            items.append(TranscriptItem(id: id, kind: .assistant(AssistantBlock())))
            index[id] = items.count - 1
        case .reasoningDelta, .textDelta:
            break
        case .toolCallStreamed:
            break
        case .assistantEnd(let m, _):
            updateAssistant {
                if $0.reasoningStarted != nil, $0.reasoningEnded == nil { $0.reasoningEnded = Date() }
                $0.isStreaming = false
                $0.stopReason = m.stopReason
                $0.errorMessage = m.errorMessage
                $0.text = m.text
            }
            if let id = currentAssistant, let i = index[id], case .assistant(let b) = items[i].kind,
               b.answer.isEmpty, b.thinking.isEmpty, b.errorMessage == nil {
                items.remove(at: i)
                reindex()
            }
            currentAssistant = nil
        case .permissionRequested:
            break
        case .toolExecutionStart(let callID, let name, let arguments, let effect):
            if index[callID] == nil {
                // The approver can be asked before this event is delivered.
                let status: ToolCard.Status = pendingApproval?.callID == callID ? .awaitingApproval : .running
                items.append(TranscriptItem(id: callID, kind: .tool(ToolCard(callID: callID, name: name, arguments: arguments,
                                                                              effect: effect, status: status))))
                index[callID] = items.count - 1
            }
        case .toolExecutionUpdate(let callID, let output):
            updateTool(callID) {
                $0.live.append(output)
                $0.live.dropFront(keepingUTF8: 48_000)
            }
        case .toolExecutionEnd(let callID, let name, let output, _):
            if index[callID] == nil {
                items.append(TranscriptItem(id: callID, kind: .tool(ToolCard(callID: callID, name: name, arguments: [:],
                                                                              effect: nil, status: .running))))
                index[callID] = items.count - 1
            }
            updateTool(callID) {
                $0.result = output
                $0.status = output.isError ? .failed : .done
            }
        case .turnEnd(_, let timings, _, let contextTokens):
            stats.turns += 1
            if let timings {
                stats.lastTimings = timings
                if let id = lastAssistant, let i = index[id], case .assistant(var b) = items[i].kind {
                    b.finalTimings = timings
                    items[i].kind = .assistant(b)
                }
            }
            stats.contextTokens = contextTokens
        case .compactionStart:
            append(.notice("Compacting the conversation to fit the context window…", isError: false))
        case .compactionEnd(let summary):
            append(.compaction(summary: summary))
        case .changesReady(let changes):
            // An earlier run's undecided change to the same file is
            // superseded: this run's checkpoint holds the newer original.
            let paths = Set(changes.files.map(\.path))
            for (id, files) in fileReview {
                for (path, state) in files where paths.contains(path) && state.isOpen {
                    fileReview[id]?[path] = .superseded
                }
            }
            let initial: FileReviewState = mode == .autopilot ? .applied : .pending
            fileReview[changes.id] = Dictionary(uniqueKeysWithValues: changes.files.map { ($0.path, initial) })
            append(.changes(changes))
            onFilesChanged?(changes.files.map(\.path))
        case .notice(let text):
            append(.notice(text, isError: false))
        case .replyStopped(let stop):
            if let id = lastAssistant, let i = index[id], case .assistant(var b) = items[i].kind {
                b.replyStop = stop
                items[i].kind = .assistant(b)
            }
            append(.notice(stop.detail, isError: false))
        case .agentEnd(let reason):
            switch reason {
            case .completed: break
            case .aborted: append(.notice("Stopped.", isError: false))
            case .maxTurns(let n): append(.notice("Stopped after \(n) turns.", isError: true))
            case .error(let message): append(.notice(message, isError: true))
            }
            updateAllRunningTools()
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard let self else { return }
            self.flushTask = nil
            self.flushDeltas()
        }
    }

    /// Applies the streamed deltas gathered since the last flush.
    private func flushDeltas() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingText.isEmpty || !pendingReasoning.isEmpty else { return }
        let text = pendingText, reasoning = pendingReasoning, tokens = pendingTokens
        pendingText = ""
        pendingReasoning = ""
        pendingTokens = 0
        updateAssistant {
            let now = Date()
            if $0.firstTokenAt == nil { $0.firstTokenAt = now }
            $0.streamedTokens += tokens
            if !reasoning.isEmpty {
                if $0.reasoningStarted == nil { $0.reasoningStarted = now }
                $0.thinking.append(reasoning)
            }
            if !text.isEmpty {
                if $0.reasoningStarted != nil, $0.reasoningEnded == nil { $0.reasoningEnded = now }
                $0.answer.append(text)
            }
        }
    }

    private func append(_ kind: TranscriptItem.Kind) {
        let id = UUID().uuidString
        items.append(TranscriptItem(id: id, kind: kind))
        index[id] = items.count - 1
    }

    private func reindex() {
        index = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func updateAssistant(_ body: (inout AssistantBlock) -> Void) {
        guard let id = currentAssistant, let i = index[id], case .assistant(var b) = items[i].kind else { return }
        body(&b)
        items[i].kind = .assistant(b)
    }

    private func updateTool(_ callID: String, _ body: (inout ToolCard) -> Void) {
        guard let i = index[callID], case .tool(var card) = items[i].kind else { return }
        body(&card)
        items[i].kind = .tool(card)
    }

    private func updateAllRunningTools() {
        for i in items.indices {
            if case .tool(var card) = items[i].kind, card.status == .running || card.status == .awaitingApproval {
                card.status = .failed
                items[i].kind = .tool(card)
            }
        }
    }

    /// Rebuilds a transcript from a stored session.
    static func transcript(from doc: SessionDocument) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var cards: [String: Int] = [:]
        for (entryID, message) in doc.contextEntries() {
            switch message {
            case .user(let u):
                if u.text.hasPrefix(Agent.reviewNotePrefix) {
                    out.append(TranscriptItem(id: entryID, kind: .notice(String(u.text.dropFirst(Agent.reviewNotePrefix.count)), isError: false)))
                } else {
                    out.append(TranscriptItem(id: entryID, kind: .user(text: u.text, entryID: entryID)))
                }
            case .assistant(let a):
                if !a.text.isEmpty || !a.thinking.isEmpty || a.errorMessage != nil {
                    var b = AssistantBlock(text: a.text, reasoning: a.thinking, isStreaming: false)
                    b.stopReason = a.stopReason
                    b.errorMessage = a.errorMessage
                    out.append(TranscriptItem(id: entryID, kind: .assistant(b)))
                }
                for call in a.toolCalls {
                    cards[call.id] = out.count
                    out.append(TranscriptItem(id: call.id, kind: .tool(ToolCard(
                        callID: call.id, name: call.name, arguments: call.parsedArguments ?? [:], effect: nil, status: .failed))))
                }
            case .toolResult(let r):
                if let i = cards[r.toolCallId], case .tool(var card) = out[i].kind {
                    card.result = ToolOutput(text: r.text, isError: r.isError, details: r.details)
                    card.status = r.isError ? .failed : .done
                    out[i].kind = .tool(card)
                }
            case .compactionSummary(let s, _, _):
                out.append(TranscriptItem(id: entryID, kind: .compaction(summary: s)))
            default:
                continue
            }
        }
        return out
    }
}

/// Forwards permission requests to the main actor.
final class ApprovalBridge: PermissionApprover {
    private let handler: @MainActor @Sendable (PermissionRequest) async -> PermissionResponse

    init(_ handler: @escaping @MainActor @Sendable (PermissionRequest) async -> PermissionResponse) {
        self.handler = handler
    }

    func requestPermission(_ request: PermissionRequest) async -> PermissionResponse {
        await handler(request)
    }
}
