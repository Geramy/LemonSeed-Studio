import StudioAgent
import SwiftUI

/// The agent chat panel (⌘L): header, transcript, statistics and composer.
public struct AgentPanel: View {
    @Bindable var model: AgentViewModel
    @FocusState private var composerFocused: Bool
    @Environment(\.agentTheme) private var theme

    public init(model: AgentViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            AgentHeader(model: model, showingSessions: $model.isShowingSessions)
            Rectangle().fill(theme.hairline).frame(height: 1)
            transcript
            StatsBar(stats: model.stats, engine: model.engine, isRunning: model.isRunning)
            Composer(model: model, focused: $composerFocused)
        }
        .background(theme.background)
        .sheet(item: $model.review) { changes in
            DiffReviewSheet(changes: changes) { decisions in
                model.applyReview(changes, decisions: decisions)
            }
            .agentTheme(theme)
        }
        .sheet(isPresented: $model.isShowingSessions) {
            NavigationStack {
                SessionListView(model: model) { model.isShowingSessions = false }
            }
            .agentTheme(theme)
            .presentationDetents([.medium, .large])
        }
        .task { await model.checkEngine() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.items.isEmpty { EmptyAgentView(model: model).padding(.top, 40) }
                    ForEach(model.items) { item in
                        row(item).id(item.id)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: lastItemSize) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// Grows while the last message streams, to keep it in view.
    private var lastItemSize: Int {
        guard let last = model.items.last else { return 0 }
        switch last.kind {
        case .assistant(let b): return b.text.count + b.reasoning.count
        case .tool(let c): return c.liveOutput.count + (c.result == nil ? 0 : 1)
        default: return 0
        }
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item.kind {
        case .user(let text, _):
            UserMessageView(text: text, onRewind: model.isRunning ? nil : { model.rewind(to: item) })
        case .assistant(let block):
            AssistantMessageView(block: block)
        case .tool(let card):
            ToolCallCard(card: card,
                         approval: model.pendingApproval?.callID == card.callID ? model.pendingApproval : nil,
                         onRespond: model.respond)
        case .notice(let text, let isError):
            NoticeView(text: text, isError: isError)
        case .compaction(let summary):
            CompactionView(summary: summary)
        case .changes(let changes):
            PendingChangesCard(model: model, changes: changes)
        }
    }
}

/// Title, engine status, permission mode and session controls.
struct AgentHeader: View {
    @Bindable var model: AgentViewModel
    @Binding var showingSessions: Bool
    @Environment(\.agentTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sessionTitle)
                    .font(theme.titleFont)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                EnginePill(status: model.engine)
            }
            Spacer()
            Button { model.refreshSessions(); showingSessions = true } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel("Chats")
            .accessibilityIdentifier("agent.sessions")
            Button { model.newSession() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("agent.newChat")
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .font(.system(size: 17))
        .foregroundStyle(theme.secondaryText)
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// Names the source of the model honestly: the engine, a remote endpoint,
/// offline, or a scripted demo.
struct EnginePill: View {
    let status: EngineStatus
    @Environment(\.agentTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).lineLimit(1)
        }
        .font(theme.captionFont)
        .foregroundStyle(theme.secondaryText)
    }

    private var label: String {
        switch status {
        case .unknown: "Checking engine…"
        case .online(let model, let detail): ["LSE", model, detail].compactMap { $0 }.joined(separator: " · ")
        case .offline(let why): why
        case .scripted: "Scripted demo (no engine)"
        }
    }

    private var color: Color {
        switch status {
        case .unknown: theme.tertiaryText
        case .online: theme.success
        case .offline: theme.danger
        case .scripted: theme.warning
        }
    }
}

/// Decode and prefill speed, speculative acceptance and context use, from
/// LSE's per-request timings. Missing values read "n/a".
struct StatsBar: View {
    let stats: AgentStats
    let engine: EngineStatus
    let isRunning: Bool
    @Environment(\.agentTheme) private var theme

    var body: some View {
        let t = stats.lastTimings
        ViewThatFits(in: .horizontal) {
            row(t, compact: false)
            row(t, compact: true)
        }
        .font(theme.captionFont.monospacedDigit())
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(theme.background)
        .overlay(alignment: .top) { Rectangle().fill(theme.hairline).frame(height: 1) }
    }

    private func row(_ t: GenerationTimings?, compact: Bool) -> some View {
        HStack(spacing: 12) {
            stat("bolt.fill", t?.decodePerSecond.map { String(format: "%.1f tok/s", $0) }, "decode speed")
            stat("arrow.down.doc", t?.promptPerSecond.map { String(format: compact ? "%.0f" : "%.0f tok/s prefill", $0) },
                 "prefill speed")
            stat("checkmark.seal", t?.acceptanceRate.map { String(format: compact ? "%.0f%%" : "%.0f%% accepted", $0 * 100) },
                 "speculative acceptance (\(t?.speculationMethod ?? "none"))")
            if !compact {
                stat("square.stack.3d.up", t?.promptCachedTokens.map { "\($0) cached" }, "cached prompt tokens")
            }
            Spacer(minLength: 4)
            ContextMeter(used: stats.contextTokens, window: stats.contextWindow)
        }
    }

    private func stat(_ symbol: String, _ value: String?, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(value == nil ? theme.tertiaryText : theme.accent)
            Text(value ?? "n/a").foregroundStyle(value == nil ? theme.tertiaryText : theme.primaryText)
        }
        .lineLimit(1)
        .fixedSize()
        .help(label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value ?? "not available")")
    }
}

struct ContextMeter: View {
    let used: Int
    let window: Int
    @Environment(\.agentTheme) private var theme

    var body: some View {
        let fraction = window > 0 ? min(1, Double(used) / Double(window)) : 0
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(theme.hairline)
                Capsule().fill(fraction > 0.75 ? theme.warning : theme.accent)
                    .frame(width: max(3, 56 * fraction))
            }
            .frame(width: 56, height: 5)
            Text("context \(used.formatted()) / \(window.formatted())")
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityLabel("Context \(Int(fraction * 100)) percent used")
    }
}

/// The message field, with send and stop.
struct Composer: View {
    @Bindable var model: AgentViewModel
    var focused: FocusState<Bool>.Binding
    @Environment(\.agentTheme) private var theme

    @State private var pendingThinking: ThinkingLevel?

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            modeMenu
            thinkingMenu
            TextField(model.isRunning ? "Steer the agent…" : "Ask the LemonSeed agent…", text: $model.composer,
                      axis: .vertical)
                .font(theme.bodyFont)
                .lineLimit(1...8)
                .focused(focused)
                .onSubmit { model.send() }
                .accessibilityIdentifier("agent.composer")
                .padding(.vertical, 10)
                .padding(.leading, 14)

            if model.isRunning {
                Button { model.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(width: 34, height: 34)
                        .background(theme.primaryText, in: Circle())
                }
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("agent.stop")
                .padding(5)
            }
            if !model.isRunning || model.canSend {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(model.canSend ? theme.onAccent : theme.tertiaryText)
                        .frame(width: 34, height: 34)
                        .background(model.canSend ? theme.accent : theme.hairline, in: Circle())
                }
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("agent.send")
                .padding(5)
            }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .animation(.snappy(duration: 0.2), value: model.isRunning)
        .confirmationDialog("Change thinking to \(pendingThinking?.title ?? "")?",
                            isPresented: Binding(get: { pendingThinking != nil }, set: { if !$0 { pendingThinking = nil } }),
                            titleVisibility: .visible) {
            if let level = pendingThinking {
                Button("Apply from the next message") { model.setThinking(level) }
                Button("Start a new session") { model.setThinking(level, startNewSession: true) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text("The thinking level is part of the engine's cached prompt. Changing it in this session makes the engine re-read the conversation once.")
        }
    }

    /// The permission mode, always visible: Review (default), Ask, Autopilot,
    /// Read only (an explicit choice).
    private var modeMenu: some View {
        Menu {
            Picker("Mode", selection: $model.mode) {
                ForEach([PermissionMode.review, .ask, .autopilot, .readOnly]) { m in
                    Label { Text(m.title); Text(m.summary) } icon: { Image(systemName: m.symbol) }.tag(m)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.mode.symbol)
                Text(shortTitle(model.mode))
            }
            .font(theme.captionFont)
            .foregroundStyle(model.mode == .readOnly ? theme.warning : theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(theme.hairline.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("Mode: \(model.mode.title)")
        .accessibilityIdentifier("agent.modeChip")
        .padding(.leading, 6)
        .padding(.bottom, 5)
    }

    private func shortTitle(_ mode: PermissionMode) -> String {
        switch mode {
        case .readOnly: "Read only"
        case .ask: "Ask"
        case .review: "Review"
        case .autopilot: "Autopilot"
        }
    }

    /// Thinking: Default (the model's own level), Off, Low, Medium, High, Max.
    private var thinkingMenu: some View {
        Menu {
            Picker("Thinking", selection: Binding(get: { model.thinking }, set: { choose($0) })) {
                ForEach(ThinkingLevel.pickerLevels, id: \.self) { level in
                    Text(level == .modelDefault ? "Default (model decides)" : level.title).tag(level)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.thinking == .off ? "brain" : "brain.fill")
                Text(model.thinking.title)
            }
            .font(theme.captionFont)
            .foregroundStyle(model.thinking == .off ? theme.tertiaryText : theme.accent)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(theme.hairline.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("Thinking: \(model.thinking.title)")
        .accessibilityIdentifier("agent.thinking")
        .padding(.bottom, 5)
    }

    private func choose(_ level: ThinkingLevel) {
        guard level != model.thinking else { return }
        if model.hasHistory { pendingThinking = level } else { model.setThinking(level) }
    }
}

struct EmptyAgentView: View {
    let model: AgentViewModel
    @Environment(\.agentTheme) private var theme
    let suggestions = [
        ("Explain this project", "Read the README and the main sources, then explain how this project is organized."),
        ("Find and fix a bug", "Run the tests, find the failing one and fix the bug it reveals."),
        ("Add a feature", "Add a function that computes the greatest common divisor, with a test."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 34))
                .foregroundStyle(theme.accent)
                .padding(18)
                .background(theme.accent.opacity(0.12), in: Circle())
            VStack(spacing: 6) {
                Text("LemonSeed agent").font(.system(size: 22, weight: .semibold)).foregroundStyle(theme.primaryText)
                Text("Reads, searches and edits \(model.workspace.displayName). Every change is checkpointed for review.")
                    .font(theme.bodyFont).foregroundStyle(theme.secondaryText).multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.0) { title, prompt in
                    Button { model.send(prompt) } label: {
                        HStack {
                            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.primaryText)
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundStyle(theme.tertiaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).strokeBorder(theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }
}
