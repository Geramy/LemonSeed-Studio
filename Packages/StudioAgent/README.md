# StudioAgent

The LemonSeed agent: a native Swift re-implementation of the
[pi](https://github.com/badlogic/pi-mono) coding agent's design for LemonSeed
Studio, talking to LemonSeed Engine (LSE) or any OpenAI-compatible endpoint.

| Product | Contents |
|---|---|
| `StudioAgent` | Model client, agent loop, tools, shell, permissions, checkpoints, review, pi v3 sessions. Foundation only. |
| `StudioAgentUI` | SwiftUI: chat panel, tool cards, permission prompts, diff review, session list, inline selection actions. Styled through `AgentTheme`. |

## Architecture

```
AgentPanel / DiffReviewSheet / SessionListView / SelectionActionBar   (StudioAgentUI)
        │  AgentViewModel (@MainActor): folds AgentEvents into a transcript,
        │  bridges permission prompts and reviews
        ▼
Agent (actor) ── pi loop: turn → stream → tools → turn …, steer / followUp / abort
  ├─ LLMClient ── OpenAICompatibleClient (protocol: encode, decode chunks, text tools)
  │                 └─ ChatTransport: HTTPChatTransport (SSE) │ ClosureChatTransport (in-process LSE)
  ├─ tools ────── read, write, edit, list, glob, grep, bash   (AgentTool)
  │                 ├─ WorkspaceFileSystem: path jail over an AgentWorkspace (security scope)
  │                 └─ ShellProviding: InProcessShell (no process spawning on iPad)
  ├─ PermissionPolicy + PermissionApprover: readOnly / ask / review / autopilot
  ├─ CheckpointStore (clonefile) → ChangeSet (Myers diff, per-hunk accept/reject)
  ├─ SystemPromptBuilder + ContextFiles (AGENTS.md), CompactionPolicy
  └─ SessionDocument / SessionStore: pi v3 JSONL in .lemonseed/sessions/
```

**Transport seam.** `OpenAICompatibleClient` owns the chat.completions protocol;
a `ChatTransport` only moves JSON. `HTTPChatTransport` strips SSE framing;
`ClosureChatTransport` wraps a blocking callback API of the shape
`lse_request(engine, method, path, json_body, cb, …)`, where `cb` receives the
same chunk objects the SSE stream carries, without `data:` framing, and returns
false to cancel. Both share every line of encoding and decoding.

**Prefix stability.** LSE keeps one resident KV session and reuses it only when
the whole cached sequence is a token-exact prefix of the next prompt. So the
system prompt and tool schemas are built once per session and persisted as
pi's leading system message, every request replays them byte-for-byte (JSON
with sorted keys, no timestamps), history is append-only, reasoning is replayed
in `reasoning_content` (LSE renders it back), and the thinking level is fixed
per session (it is part of LSE's system prompt). Compaction, which necessarily
rewrites the prefix, runs only above 75% of the window.

## Tool protocol with LSE

LSE implements OpenAI function calling natively (`src/server/chat_protocol.cpp`):
it renders `tools` into Qwen3.x's trained XML format in the system prompt,
parses `<tool_call><function=…><parameter=…>` (or JSON) from the output, and
returns standard `tool_calls` with ids; `role: "tool"` results are rendered back
as `<tool_response>` blocks in call order. The agent therefore uses **native
tool calling** (`ToolProtocol.native`), with `strict` never sent (LSE answers
400 to `strict: true` because it does no constrained decoding) and arguments
validated in Swift. A malformed call surfaces as a stream `{"error":
{"type":"model_output_error"}}`, which the agent retries once.

For servers without function calling, `ToolProtocol.text` does the same on the
client: declarations and the format go into the system prompt, assistant calls
are replayed as XML text, results as a user turn of `<tool_response>` blocks,
and `TextToolCallExtractor` pulls calls (and `<think>` reasoning) out of the
streamed text, holding back partial markers so none reach the screen. Parameter
values are JSON-decoded unless the schema says string; a call cut off by the
token limit stays text and is never executed.

## Sessions

pi's v3 format verbatim: a `session` header (`version: 3`) and tree entries
(`id`/`parentId`) of every documented type; unknown types and fields round-trip
untouched. The agent adds `custom` entries of type `lemonseed.checkpoint`
(files checkpointed by a run) and `lemonseed.review` (rejected hunks).

## Tests

```sh
swift test                                   # preferred: runs on the Mac
# On the iPad simulator, reuse one existing device by id and do not let
# xcodebuild clone extra simulators for parallel testing:
xcodebuild test -scheme StudioAgent-Package -parallel-testing-enabled NO \
  -destination 'platform=iOS Simulator,id=<device id>'
```

`LiveLSETests` run against `http://127.0.0.1:8080/v1` (override with
`LSE_BASE_URL`, `LSE_MODEL`) and are skipped, with a message, when the server
does not answer `/health`. They never start or stop the server.

## Demo

`Demo/AgentDemo` is an iPad app running the agent on a sample C project:

```sh
cd Demo/AgentDemo && xcodegen generate && open AgentDemo.xcodeproj
```

Launch arguments are listed in `project.yml` (`-scripted YES` replays a
built-in run without an engine and is labeled "Scripted demo"). Screenshots are
in `docs/screenshots/agent/`.
