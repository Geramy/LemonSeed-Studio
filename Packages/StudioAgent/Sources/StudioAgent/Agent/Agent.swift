import Foundation

/// Settings for one agent session.
public struct AgentConfiguration: Sendable, Hashable {
    public var endpoint: EndpointConfiguration
    /// Fixed per session: the level is part of the engine's prompt prefix.
    public var thinking: ThinkingLevel
    public var permissionMode: PermissionMode
    public var maxTurns: Int
    public var temperature: Double?
    public var compaction: CompactionPolicy
    public var checkpointStorage: Checkpoint.Storage
    /// Global instructions from app settings, placed before AGENTS.md files.
    public var globalContext: String?
    /// Retries when the engine rejects a malformed tool call.
    public var modelOutputRetries: Int

    public init(endpoint: EndpointConfiguration = .lseDefault, thinking: ThinkingLevel = .low,
                permissionMode: PermissionMode = .review, maxTurns: Int = 40, temperature: Double? = nil,
                compaction: CompactionPolicy? = nil, checkpointStorage: Checkpoint.Storage = .clone,
                globalContext: String? = nil, modelOutputRetries: Int = 1) {
        self.endpoint = endpoint
        self.thinking = thinking
        self.permissionMode = permissionMode
        self.maxTurns = maxTurns
        self.temperature = temperature
        self.compaction = compaction ?? CompactionPolicy(contextWindow: endpoint.contextWindow,
                                                         maxOutputTokens: endpoint.maxOutputTokens)
        self.checkpointStorage = checkpointStorage
        self.globalContext = globalContext
        self.modelOutputRetries = modelOutputRetries
    }
}

/// The LemonSeed agent: pi's loop over a workspace, a model and a session.
///
/// One `prompt` runs at a time. While it runs, `steer` injects a message at
/// the next safe boundary (after the current tool batch) and `followUp`
/// queues one for when the run would otherwise end. `abort` cancels the
/// model stream at the next token (closing the connection stops LSE's
/// generation) and any running tool.
public actor Agent {
    public nonisolated let workspace: any AgentWorkspace
    public nonisolated let fileSystem: WorkspaceFileSystem
    public nonisolated let checkpoints: CheckpointStore
    public nonisolated let sessionStore: SessionStore
    public nonisolated let sessionURL: URL

    public private(set) var configuration: AgentConfiguration
    public private(set) var document: SessionDocument
    private let client: any LLMClient
    private let shell: any ShellProviding
    private let tools: [String: any AgentTool]
    private let approver: any PermissionApprover
    private var policy: PermissionPolicy
    private var estimator = TokenEstimator()
    /// The output budget of the request streaming now (or last streamed).
    private var lastBudget = OutputBudget(contextWindow: 0, promptTokens: 0, limit: nil)
    private var steering: [String] = []
    private var followUps: [String] = []
    private var runTask: Task<Void, Never>?
    public private(set) var lastContextTokens = 0
    /// What the user decided about the agent's changes since its last turn,
    /// told to the model at the start of the next one.
    private var reviewNotes: [String] = []

    /// User messages that carry review outcomes start with this, so a
    /// transcript can show them as notices rather than as the user's words.
    public static let reviewNotePrefix = "[Review of your changes] "

    // MARK: Lifecycle

    private init(workspace: any AgentWorkspace, client: any LLMClient, shell: any ShellProviding,
                 tools: [any AgentTool], approver: any PermissionApprover, configuration: AgentConfiguration,
                 store: SessionStore, url: URL, document: SessionDocument, checkpoints: CheckpointStore) {
        self.workspace = workspace
        self.client = client
        self.shell = shell
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.approver = approver
        self.configuration = configuration
        self.sessionStore = store
        self.sessionURL = url
        self.document = document
        self.checkpoints = checkpoints
        self.fileSystem = WorkspaceFileSystem(workspace: workspace, observer: checkpoints)
        self.policy = PermissionPolicy(mode: configuration.permissionMode)
    }

    /// Starts a new session: discovers AGENTS.md files and persists the
    /// prefix-stable system prompt with the tool declarations.
    public static func start(workspace: any AgentWorkspace, client: any LLMClient,
                             shell: any ShellProviding = InProcessShell(), tools: [any AgentTool]? = nil,
                             approver: any PermissionApprover, configuration: AgentConfiguration = .init(),
                             name: String? = nil) throws -> Agent {
        let tools = tools ?? DefaultTools.all(shell: shell)
        let store = SessionStore(workspace: workspace)
        var (url, doc) = try store.create(cwd: workspace.rootURL.path)
        let system = SystemPromptBuilder.build(workspace: workspace, tools: tools,
                                               contextFiles: ContextFiles.discover(workspace: workspace),
                                               globalContext: configuration.globalContext)
        var entries = [
            doc.append(.modelChange(provider: configuration.endpoint.isRemote ? "remote" : "lse",
                                    modelId: configuration.endpoint.model)),
            doc.append(.thinkingLevelChange(configuration.thinking.rawValue)),
            doc.append(.message(.system(system))),
        ]
        if let name { entries.append(doc.append(.sessionInfo(name: name))) }
        try store.append(entries, to: url)
        let checkpoints = CheckpointStore(workspace: workspace, storage: configuration.checkpointStorage)
        return Agent(workspace: workspace, client: client, shell: shell, tools: tools, approver: approver,
                     configuration: configuration, store: store, url: url, document: doc, checkpoints: checkpoints)
    }

    /// Reopens a session file. Its persisted system prompt and tools are
    /// reused as they are, so the engine's cached prefix stays valid.
    public static func resume(url: URL, workspace: any AgentWorkspace, client: any LLMClient,
                              shell: any ShellProviding = InProcessShell(), tools: [any AgentTool]? = nil,
                              approver: any PermissionApprover,
                              configuration: AgentConfiguration = .init()) throws -> Agent {
        let tools = tools ?? DefaultTools.all(shell: shell)
        let store = SessionStore(workspace: workspace)
        let doc = try store.load(url)
        var config = configuration
        if let level = doc.thinkingLevel.flatMap(ThinkingLevel.init(rawValue:)) { config.thinking = level }
        let checkpoints = CheckpointStore(workspace: workspace, storage: config.checkpointStorage)
        for e in doc.entries {
            if case .custom(Checkpoint.sessionCustomType, let data?) = e.payload, let cp = Checkpoint(sessionData: data) {
                checkpoints.register(cp)
            }
        }
        return Agent(workspace: workspace, client: client, shell: shell, tools: tools, approver: approver,
                     configuration: config, store: store, url: url, document: doc, checkpoints: checkpoints)
    }

    // MARK: Controls

    public var isRunning: Bool { runTask != nil }

    public func setPermissionMode(_ mode: PermissionMode) {
        configuration.permissionMode = mode
        policy.mode = mode
    }

    public var permissionMode: PermissionMode { policy.mode }

    /// Changes the thinking level from the next request on, recorded in the
    /// session. The level is part of the engine's prompt prefix, so the next
    /// request re-reads the conversation once instead of reusing the cache.
    public func setThinking(_ level: ThinkingLevel) throws {
        guard level != configuration.thinking else { return }
        configuration.thinking = level
        let e = document.append(.thinkingLevelChange(level.rawValue))
        try sessionStore.append([e], to: sessionURL)
    }

    /// Injects a message after the current tool batch.
    public func steer(_ text: String) { steering.append(text) }

    /// Queues a message for when the current run would end.
    public func followUp(_ text: String) { followUps.append(text) }

    public func abort() { runTask?.cancel() }

    public func rename(_ name: String) throws {
        let e = document.append(.sessionInfo(name: name))
        try sessionStore.append([e], to: sessionURL)
    }

    /// Runs one prompt to completion, streaming events.
    public nonisolated func prompt(_ text: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            Task { await self.launch(text, continuation) }
        }
    }

    private func launch(_ text: String, _ continuation: AsyncStream<AgentEvent>.Continuation) {
        guard runTask == nil else {
            // Already running: treat it as steering, as pi does while streaming.
            steering.append(text)
            continuation.yield(.notice("Queued; the agent will read it after the current step."))
            continuation.finish()
            return
        }
        let task = Task { await self.run(text, continuation) }
        runTask = task
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
    }

    // MARK: The loop

    private func run(_ prompt: String, _ out: AsyncStream<AgentEvent>.Continuation) async {
        defer {
            runTask = nil
            out.finish()
        }
        out.yield(.agentStart)
        checkpoints.begin()
        var reason: AgentEndReason = .completed
        do {
            if !reviewNotes.isEmpty {
                let note = Self.reviewNotePrefix + reviewNotes.joined(separator: " ")
                reviewNotes.removeAll()
                try record(.message(.user(.init(text: note))))
            }
            try record(.message(.user(.init(text: prompt))), out: out, announce: prompt)
            reason = try await loop(out)
        } catch is CancellationError {
            reason = .aborted
        } catch {
            reason = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        if Task.isCancelled { reason = .aborted }
        finishCheckpoint(out)
        out.yield(.agentEnd(reason))
    }

    private func loop(_ out: AsyncStream<AgentEvent>.Continuation) async throws -> AgentEndReason {
        var turn = 0
        while true {
            try Task.checkCancellation()
            if turn >= configuration.maxTurns { return .maxTurns(turn) }
            try await compactIfNeeded(out)
            if currentRequest().budget.contextIsFull {
                // Nothing is left for a reply: say so rather than send a request.
                out.yield(.replyStopped(.contextFull(contextWindow: configuration.endpoint.contextWindow)))
                return .completed
            }
            turn += 1
            out.yield(.turnStart(index: turn))

            let (assistant, finish, timings, usage) = try await streamAssistant(out)
            let calls = assistant.toolCalls
            if calls.isEmpty {
                if finish == .length {
                    out.yield(.replyStopped(lastBudget.boundByContext
                        ? .contextFull(contextWindow: configuration.endpoint.contextWindow)
                        : .replyLimit(lastBudget.maxTokens)))
                }
                out.yield(.turnEnd(index: turn, timings: timings, usage: usage, contextTokens: lastContextTokens))
                if !followUps.isEmpty {
                    try flushQueue(&followUps, out: out)
                    continue
                }
                return .completed
            }
            try await executeTools(calls, out)
            out.yield(.turnEnd(index: turn, timings: timings, usage: usage, contextTokens: lastContextTokens))
            if !steering.isEmpty { try flushQueue(&steering, out: out) }
        }
    }

    private func flushQueue(_ queue: inout [String], out: AsyncStream<AgentEvent>.Continuation) throws {
        let items = queue
        queue.removeAll()
        for text in items { try record(.message(.user(.init(text: text))), out: out, announce: text) }
    }

    /// Persists an entry (and announces user messages).
    @discardableResult
    private func record(_ payload: SessionEntry.Payload, out: AsyncStream<AgentEvent>.Continuation? = nil,
                        announce: String? = nil) throws -> SessionEntry {
        let e = document.append(payload)
        try sessionStore.append([e], to: sessionURL)
        if let announce { out?.yield(.userMessage(text: announce, entryID: e.id)) }
        return e
    }

    /// The current request: replayed system prompt, tools, and context, and
    /// a reply budget of what the context window has left after them (or the
    /// user's limit when smaller). Reasoning counts toward it like the answer.
    private func currentRequest() -> (ChatRequest, estimated: Int, budget: OutputBudget) {
        let state = document.systemState()
        let messages = WireConverter.messages(systemPrompt: state.prompt, context: document.contextMessages())
        let budget = OutputBudget(contextWindow: configuration.endpoint.contextWindow,
                                  promptTokens: estimator.estimate(messages, tools: state.tools),
                                  limit: configuration.endpoint.maxOutputTokens)
        let request = ChatRequest(model: configuration.endpoint.model, messages: messages, tools: state.tools,
                                  maxTokens: budget.maxTokens,
                                  temperature: configuration.temperature, thinking: configuration.thinking,
                                  sessionID: document.header.id)
        return (request, TokenEstimator.rawEstimate(messages, tools: state.tools), budget)
    }

    private func streamAssistant(_ out: AsyncStream<AgentEvent>.Continuation) async throws
        -> (AgentMessage.AssistantMessage, FinishReason?, GenerationTimings?, TokenUsage?)
    {
        var attempt = 0
        while true {
            let (request, rawEstimate, budget) = currentRequest()
            lastBudget = budget
            lastContextTokens = estimator.estimate(request.messages, tools: request.tools)
            out.yield(.assistantStart)
            var acc = ChatCompletionAccumulator()
            var streamedCalls = 0
            do {
                for try await event in client.stream(request) {
                    acc.apply(event)
                    switch event {
                    case .contentDelta(let s): out.yield(.textDelta(s))
                    case .reasoningDelta(let s): out.yield(.reasoningDelta(s))
                    case .toolCallDelta:
                        let calls = acc.toolCalls
                        if calls.count > streamedCalls, let c = calls.last, c.parsedArguments != nil {
                            streamedCalls = calls.count
                            out.yield(.toolCallStreamed(c))
                        }
                    default: break
                    }
                }
                // A cancelled consumer sees the stream end quietly; make it an abort.
                try Task.checkCancellation()
            } catch let error as LLMError where error.isContextFull {
                // The engine reached the end of its KV cache before the
                // budget (an estimate) ran out: the reply so far stands, cut
                // off because the context is full.
                lastBudget.boundByContext = true
                let message = assistantMessage(from: acc, keepCalls: false, stop: .length, error: nil)
                let e = try record(.message(.assistant(message)))
                out.yield(.assistantEnd(message, entryID: e.id))
                return (message, .length, acc.timings, acc.usage)
            } catch let error as LLMError where error.isModelOutputError && attempt < configuration.modelOutputRetries {
                attempt += 1
                out.yield(.notice("The model produced a malformed tool call; retrying."))
                continue
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                let partial = assistantMessage(from: acc, keepCalls: false,
                                               stop: cancelled ? .aborted : .error,
                                               error: cancelled ? nil : ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                if !partial.content.isEmpty || !cancelled {
                    let e = try record(.message(.assistant(partial)))
                    out.yield(.assistantEnd(partial, entryID: e.id))
                }
                if cancelled { throw CancellationError() }
                throw error
            }
            if let usage = acc.usage {
                estimator.calibrate(actualPromptTokens: usage.promptTokens, estimated: rawEstimate)
                lastContextTokens = usage.promptTokens + usage.completionTokens
            }
            let message = assistantMessage(from: acc, keepCalls: acc.finishReason != .length,
                                           stop: acc.finishReason == .length ? .length : nil, error: nil)
            let e = try record(.message(.assistant(message)))
            out.yield(.assistantEnd(message, entryID: e.id))
            return (message, acc.finishReason, acc.timings, acc.usage)
        }
    }

    private func assistantMessage(from acc: ChatCompletionAccumulator, keepCalls: Bool, stop: StopReason?,
                                  error: String?) -> AgentMessage.AssistantMessage {
        var blocks: [ContentBlock] = []
        if !acc.reasoning.isEmpty { blocks.append(.thinking(acc.reasoning)) }
        if !acc.content.isEmpty { blocks.append(.text(acc.content)) }
        let calls = keepCalls ? acc.toolCalls : []
        for c in calls {
            // Unparseable arguments are kept as a string so the error result
            // can show the model what it sent.
            let args = c.parsedArguments ?? ["_unparsed": .string(c.arguments)]
            blocks.append(.toolCall(id: c.id, name: c.name, arguments: args))
        }
        let reason = stop ?? (calls.isEmpty ? .stop : .toolUse)
        return AgentMessage.AssistantMessage(
            content: blocks, provider: configuration.endpoint.isRemote ? "remote" : "lse",
            model: configuration.endpoint.model, usage: acc.usage.map(MessageUsage.init) ?? .init(),
            stopReason: reason, errorMessage: error)
    }

    // MARK: Tools

    private func toolContext(callID: String, _ out: AsyncStream<AgentEvent>.Continuation) -> ToolContext {
        ToolContext(fileSystem: fileSystem, shell: shell) { chunk in
            out.yield(.toolExecutionUpdate(callID: callID, output: chunk))
        }
    }

    /// Runs a batch of calls. Consecutive read-only calls run concurrently;
    /// results are recorded in call order. Calls not reached because of
    /// cancellation get an error result so the history stays well-formed.
    private func executeTools(_ calls: [ToolCall], _ out: AsyncStream<AgentEvent>.Continuation) async throws {
        var results: [String: ToolOutput] = [:]
        var i = 0
        while i < calls.count {
            if Task.isCancelled { break }
            // Gather a run of read-only calls.
            var group: [(ToolCall, any AgentTool, JSONValue)] = []
            while i < calls.count, case let (tool, args)? = resolve(calls[i]),
                  case .read = tool.effect(of: args, context: toolContext(callID: calls[i].id, out)) {
                group.append((calls[i], tool, args))
                i += 1
            }
            if !group.isEmpty {
                for (call, _, args) in group {
                    out.yield(.toolExecutionStart(callID: call.id, name: call.name, arguments: args, effect: .read))
                }
                let fs = fileSystem, sh = shell
                let outputs = await withTaskGroup(of: (String, ToolOutput).self) { tg in
                    for (call, tool, args) in group {
                        let ctx = ToolContext(fileSystem: fs, shell: sh) { chunk in
                            out.yield(.toolExecutionUpdate(callID: call.id, output: chunk))
                        }
                        tg.addTask { (call.id, await Self.invoke(tool, args, ctx)) }
                    }
                    var r: [String: ToolOutput] = [:]
                    for await (id, o) in tg { r[id] = o }
                    return r
                }
                results.merge(outputs) { a, _ in a }
                continue
            }
            let call = calls[i]
            i += 1
            results[call.id] = await executeOne(call, out)
        }

        for call in calls {
            let output = results[call.id] ?? ToolOutput(text: "Not run: the user stopped the agent.", isError: true)
            let message = AgentMessage.ToolResultMessage(toolCallId: call.id, toolName: call.name, text: output.text,
                                                         details: output.details, isError: output.isError)
            let e = try record(.message(.toolResult(message)))
            out.yield(.toolExecutionEnd(callID: call.id, name: call.name, output: output, entryID: e.id))
        }
        try Task.checkCancellation()
    }

    private func resolve(_ call: ToolCall) -> (any AgentTool, JSONValue)? {
        guard let tool = tools[call.name], let args = call.parsedArguments else { return nil }
        return (tool, args)
    }

    private func executeOne(_ call: ToolCall, _ out: AsyncStream<AgentEvent>.Continuation) async -> ToolOutput {
        guard let tool = tools[call.name] else {
            out.yield(.toolExecutionStart(callID: call.id, name: call.name, arguments: [:], effect: .read))
            return ToolOutput(text: "Unknown tool \"\(call.name)\". Available tools: \(tools.keys.sorted().joined(separator: ", ")).",
                              isError: true)
        }
        guard let args = call.parsedArguments else {
            out.yield(.toolExecutionStart(callID: call.id, name: call.name, arguments: [:], effect: .read))
            return ToolOutput(text: "The arguments were not a valid JSON object: \(call.arguments.prefix(500))",
                              isError: true)
        }
        let ctx = toolContext(callID: call.id, out)
        let effect = tool.effect(of: args, context: ctx)
        out.yield(.toolExecutionStart(callID: call.id, name: call.name, arguments: args, effect: effect))
        switch policy.decide(effect) {
        case .allow:
            break
        case .deny(let reason):
            return ToolOutput(text: "Permission denied. \(reason)", isError: true)
        case .ask:
            let request = PermissionRequest(callID: call.id, toolName: call.name, effect: effect, arguments: args)
            out.yield(.permissionRequested(request))
            switch await approver.requestPermission(request) {
            case .allowOnce: break
            case .allowForSession: policy.grant(effect)
            case .deny(let reason):
                return ToolOutput(text: "The user declined this \(call.name) call." + (reason.map { " They said: \($0)" } ?? ""),
                                  isError: true)
            }
            if Task.isCancelled { return ToolOutput(text: "Cancelled.", isError: true) }
        }
        return await Self.invoke(tool, args, ctx)
    }

    private static func invoke(_ tool: any AgentTool, _ args: JSONValue, _ ctx: ToolContext) async -> ToolOutput {
        do {
            return try await tool.execute(args, context: ctx)
        } catch is CancellationError {
            return ToolOutput(text: "Cancelled.", isError: true)
        } catch {
            return ToolOutput(text: (error as? LocalizedError)?.errorDescription ?? "\(error)", isError: true)
        }
    }

    // MARK: Checkpoints and review

    private func finishCheckpoint(_ out: AsyncStream<AgentEvent>.Continuation) {
        guard let cp = checkpoints.end() else { return }
        _ = try? record(.custom(customType: Checkpoint.sessionCustomType, data: cp.sessionData))
        let changes = ChangeSet.build(checkpoint: cp, store: checkpoints, fileSystem: fileSystem)
        if !changes.isEmpty { out.yield(.changesReady(changes)) }
    }

    /// The changes of the most recent run that changed files.
    public func latestChangeSet() -> ChangeSet? {
        for e in document.path().reversed() {
            if case .custom(Checkpoint.sessionCustomType, let data?) = e.payload,
               let cp = Checkpoint(sessionData: data).flatMap({ checkpoints.checkpoint(id: $0.id) ?? $0 }) {
                return ChangeSet.build(checkpoint: cp, store: checkpoints, fileSystem: fileSystem)
            }
        }
        return nil
    }

    /// Applies a review: rejected hunks go back to the checkpointed original.
    /// The model hears which changes were reverted at the start of its next
    /// turn.
    public func applyReview(_ changes: ChangeSet, decisions: ChangeSet.Decisions) throws {
        try changes.apply(decisions, store: checkpoints, fileSystem: fileSystem)
        let rejected = decisions.rejected.values.reduce(0) { $0 + $1.count }
        var reverted: [String] = []
        for file in changes.files {
            guard let hunks = decisions.rejected[file.path], !hunks.isEmpty else { continue }
            let all = file.isBinary || hunks.isSuperset(of: file.hunks.map(\.id))
            switch (all, file.kind) {
            case (true, .added): reverted.append("\(file.path) was not created (the user denied it)")
            case (true, .deleted): reverted.append("\(file.path) was restored (the user denied deleting it)")
            case (true, _): reverted.append("your changes to \(file.path) were reverted (the user denied them)")
            case (false, _): reverted.append("\(hunks.count) of \(file.hunks.count) changed blocks in \(file.path) were reverted")
            }
        }
        if !reverted.isEmpty {
            reviewNotes.append(reverted.joined(separator: "; ") + ". Do not redo denied changes unless the user asks.")
        }
        if rejected > 0 {
            try record(.custom(customType: "lemonseed.review",
                               data: ["checkpoint": .string(changes.checkpoint.id),
                                      "rejected": .object(decisions.rejected.mapValues { .array($0.sorted().map(JSONValue.int)) })]))
        }
    }

    /// Rewinds to just before a user message: restores the files of every run
    /// after it and moves the leaf to its parent. Returns the message text so
    /// the UI can put it back in the composer; the next prompt branches.
    public func rewind(toUserEntry id: String) throws -> String? {
        guard !isRunning, let target = document.entry(id), case .message(.user(let u)) = target.payload else { return nil }
        let path = document.path()
        guard let start = path.firstIndex(where: { $0.id == id }) else { return nil }
        for e in path[start...].reversed() {
            if case .custom(Checkpoint.sessionCustomType, let data?) = e.payload, let cp = Checkpoint(sessionData: data) {
                try checkpoints.restore(checkpoints.checkpoint(id: cp.id) ?? cp)
            }
        }
        document.moveLeaf(to: target.parentId)
        // Persist the branch point so the leaf survives a reload.
        try record(.label(targetId: target.parentId ?? id, label: "rewind"))
        return u.text
    }

    // MARK: Compaction

    private func compactIfNeeded(_ out: AsyncStream<AgentEvent>.Continuation) async throws {
        let (request, _, _) = currentRequest()
        let estimate = estimator.estimate(request.messages, tools: request.tools)
        guard configuration.compaction.shouldCompact(estimatedTokens: estimate) else { return }
        try await compact(out, estimate: estimate)
    }

    /// Summarizes older context now (pi's `/compact`).
    public func compactNow() async throws {
        let (request, _, _) = currentRequest()
        let (stream, cont) = AsyncStream<AgentEvent>.makeStream()
        _ = stream
        try await compact(cont, estimate: estimator.estimate(request.messages, tools: request.tools))
        cont.finish()
    }

    private func compact(_ out: AsyncStream<AgentEvent>.Continuation, estimate: Int) async throws {
        let context = document.contextEntries()
        guard context.count > 2 else { return }
        out.yield(.compactionStart(tokensBefore: estimate))
        let firstKept = configuration.compaction.cutPoint(context)
        let cutIndex = firstKept.flatMap { id in context.firstIndex(where: { $0.entryId == id }) } ?? context.count
        let older = Array(context[..<cutIndex].map(\.message))
        let wire = WireConverter.messages(systemPrompt: "", context: older)
        let summaryRequest = configuration.compaction.summaryRequest(model: configuration.endpoint.model,
                                                                     conversation: wire)
        guard summaryRequest.maxTokens > 0 else {
            out.yield(.notice("Compaction skipped: the part of the conversation to summarize leaves no room for a summary in the \(configuration.endpoint.contextWindow)-token context window."))
            return
        }
        let result = try await client.complete(summaryRequest)
        let summary = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            out.yield(.notice("Compaction produced no summary; continuing with the full context."))
            return
        }
        let state = document.systemState()
        var sections: [String: String?] = [:]
        for s in state.sections { sections[s.name] = s.text }
        let checkpointMessage = AgentMessage.system(.init(content: state.appended.joined(separator: "\n\n"),
                                                          sections: sections, toolsAdded: state.tools, replace: true))
        let files = CompactionPolicy.fileActivity(older)
        let id = document.newEntryID()
        let payload = SessionEntry.Payload.compaction(
            // A retain-none compaction stores its own id.
            summary: summary, firstKeptEntryId: firstKept ?? id, tokensBefore: estimate,
            systemMessage: checkpointMessage,
            details: ["readFiles": .array(files.read.map(JSONValue.string)),
                      "modifiedFiles": .array(files.modified.map(JSONValue.string))])
        let e = document.append(payload, id: id)
        try sessionStore.append([e], to: sessionURL)
        estimator.calibration = 1.0
        out.yield(.compactionEnd(summary: summary))
    }
}
