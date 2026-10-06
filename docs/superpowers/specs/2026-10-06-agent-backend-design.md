# An agent behind a protocol (Codex support, slice 1)

Drakar drives one agent, Claude Code, and its wire format runs through the session, the
transcript and the views. This slice puts it behind a protocol without changing anything a
person sees: `ClaudeSession` becomes a generic `AgentSession` over an `AgentBackend`,
`Transcript` changes only through a neutral `AgentEvent`, and tool calls say what they do
(`ToolKind`) instead of what Claude Code calls them. Codex then arrives as a second backend
(slice 2) without the views or the transcript learning a second wire format.

## Why

Supporting Codex beside Claude Code was sized on 2026-10-06 as four slices:

1. **This one:** the protocol, with Claude Code as its only implementation. No visible change.
2. Live Codex sessions: `codex app-server`, a turn, streaming, approvals, interrupt, model and
   effort, in a project window.
3. Codex history: the sidebar, resume and fork, following a session another process runs.
4. Codex accounts and limits: `CODEX_HOME` as a second kind of account.

Today the coupling sits in three places: `ClaudeSession` (714 lines, half lifecycle, half
stream-json), `Transcript.apply(StreamMessage)` and `applyHistory(json)` (Claude's per-block
`assistant` lines, `<message>#<index>` keys, `UserText.classify`), and ten comparisons with
tool names (`"Bash"`, `"Edit"`, `"Write"`, `"MultiEdit"`, `"Agent"`/`"Task"`,
`AskUserQuestion`, `ExitPlanMode`, `TodoWrite`).

Codex's protocol is recorded in `docs/codex-app-server.md` (verified 2026-10-06 against
`codex-cli 0.160.1`), which ends with a table mapping each stream-json concept Drakar uses to
its Codex counterpart. This spec's vocabulary is checked against that table.

## Decisions

Settled with the person on 2026-10-06.

| Question | Decision |
| --- | --- |
| Scope | The live session only: session/backend split, the transcript seam, `ToolKind`. The disk side (`SessionIndex`, `TranscriptFollower`'s file discovery, accounts, `AccountStore`, `SessionMonitor`, `SessionMover`) stays Claude-only until slice 3 |
| The generic session's name | `AgentSession`, renamed in this slice, in a commit of its own so merges with concurrent work stay mechanical |
| The transcript seam | A neutral `AgentEvent` enum: each backend translates its wire format into events, and `Transcript` applies only events. Chosen over mutation primitives (less churn, no shared vocabulary) and over Codex emitting fake `StreamMessage`s (keeps the coupling) |
| When | After the VS Code extension parity work (A–D, landed 2026-10-06) and after `feat/cache-timer`, which changes `Transcript`, `History`, `ContextUsage` and `ClaudeSession` |
| A Codex fit check | In: a minimal `CodexTranslator` for the verified items, tested on scrubbed captures, connected to nothing |

## What Codex taught the design

From `docs/codex-app-server.md`, the findings that shape a shared vocabulary:

- **Codex is item-based.** `item/started` → `item/agentMessage/delta` (and reasoning,
  command output deltas) → `item/completed`, each with a stable id. Claude's content block at
  `<message>#<index>`, and its tool-use ids, map onto the same model.
- **Items outlive their turn.** After `turn/interrupt` the turn ends `interrupted` at once,
  but the running command's `item/completed` arrives seconds later, during a later turn,
  carrying the old turn id. Events therefore address items by their own id, never "the
  current turn".
- **A prompt sent mid-turn steers the running turn** (`turn/steer`, or `turn/start` while
  busy), where Claude queues it for the next one. The queue's states need "joined the running
  turn".
- **Usage and limits are side channels:** `thread/tokenUsage/updated` (with
  `modelContextWindow`) and `account/rateLimits/updated`, not part of a turn's result.
- **Not yet from Codex:** `turn/plan/updated` (TodoWrite's counterpart) never fired in three
  tries; plan mode and `item/tool/requestUserInput` are experimental API. Todos, plan approval
  and questions stay Claude-only for now; the design leaves room for them and no more.

## Layers

```text
AgentProcess          JSON lines over pipes; parses each line off the main thread
      │ [Line]        .json(JSONValue) | .invalid(String)
AgentBackend          ClaudeBackend now, CodexBackend in slice 2
      │               launch · handshake · translate · encode · replies it owes its CLI
      │ BackendOutput { events: [AgentEvent], signals: [SessionSignal] }
AgentSession          @Observable, generic lifecycle
      │ [AgentEvent]
Transcript.apply(_:)  the only way a transcript changes
      │
Views                 unchanged, apart from reading ToolKind
```

History goes the same way: `TranscriptFollower` reads lines, the backend's translator turns
them into events, `Transcript.apply` takes them. Today's `applyHistory` logic moves into
`ClaudeTranslator`.

## `AgentEvent`

An event says what changed in the conversation, never how a CLI wrote it. Items are addressed
by their own id.

```swift
public enum AgentEvent: Sendable, Equatable {
  // The session and its turns
  case sessionStarted(SessionInfo)
  case prompt(Prompt, running: Bool)
  case turnEnded(TurnSummary)

  // Items: a text, a thinking block or a tool call
  case itemStarted(Item)
  case itemDelta(id: String, Delta)
  case itemCompleted(Item)
  case toolResult(callID: String, Transcript.ToolResult)
  case note(Note)

  // Requests waiting for the person
  case permissionRequested(Transcript.PendingPermission)
  case permissionWithdrawn(requestID: String)

  // State shown beside the items
  case usage(ContextSample)
  case retrying(APIRetry?)
  case compaction(CompactionState)
  case todos([Todo])
  case agentTask(callID: String, AgentTaskUpdate)
  case queue(id: String, QueueState)
  case title(custom: String?, ai: String?)
  case historyMeta(HistoryMeta)
}

public struct Item: Sendable, Equatable {
  public var id: String
  /// The subagent call it runs under; nil on the main thread.
  public var parent: String?
  /// `.text`, `.thinking` or `.tool`.
  public var kind: Transcript.Kind
}
```

| Event | Claude Code (`ClaudeTranslator`) | Codex (slice 2, `CodexTranslator`) |
| --- | --- | --- |
| `sessionStarted` | `system/init` | `thread/start` / `thread/resume` response, `thread/started` |
| `prompt` | a live send; a history `user` line with prompt text | a `userMessage` item that is not our own echo |
| `turnEnded` | `result` (outcome, failure text, cost, duration); history `stop_reason: end_turn` | `turn/completed` (status, error, duration; no cost) |
| `itemStarted` | `content_block_start` | `item/started` |
| `itemDelta` | `text_delta`, `thinking_delta` | `item/agentMessage/delta`, `item/reasoning/summaryTextDelta` |
| `itemCompleted` | an `assistant` line's block | `item/completed` |
| `toolResult` | a `user` line's `tool_result` (+ `tool_use_result`) | the tool item's completion: output, exit code, status |
| `note` | `system/notification`, CLI user-turn text (`[Request interrupted by user]`), declined elicitation | `warning`, `deprecationNotice`, `configWarning` |
| `permissionRequested` | `can_use_tool` | `item/commandExecution/requestApproval`, `item/fileChange/requestApproval` |
| `permissionWithdrawn` | `control_cancel_request` | `serverRequest/resolved` |
| `usage` | an `assistant` line's main-thread usage and model | `thread/tokenUsage/updated` (with the window) |
| `retrying` | `api_retry`; cleared by anything else | `error` with `willRetry` |
| `compaction` | `status: compacting`, `compact_boundary`, history `isCompactSummary` | `contextCompaction` item started / completed |
| `todos` | the main thread's `TodoWrite` | `turn/plan/updated` (not yet seen) |
| `agentTask` | `task_started`, `task_progress`, `task_updated`, `task_notification` | collab agent items (unverified) |
| `queue` | `command_lifecycle` | a steer: `joinedTurn` |
| `title` | `custom-title`, `ai-title` | `thread/name/updated` |
| `historyMeta` | a history line's `version`, `permissionMode`, effort | from the rollout (slice 3) |

### What moves where

- **Into `ClaudeTranslator`, Claude's quirks:** per-block `assistant` lines merged by
  `message.id` and the block count per message; the `<message>#<index>` keys and their alias to
  the tool-use id; the stream cursor per subagent; `UserText.classify`; `isMeta` and
  `isSidechain` filtering; the `<synthetic>` model whose usage is all zeros; the answers in
  `tool_use_result`.
- **Kept in `Transcript`, neutral behaviour:** thinking timing (an item started as thinking
  and completed gets its duration); "a completed item never blanks streamed text"; the end of a
  turn (pending permissions cleared, thinking stopped, `isRunning` false); `closingText`;
  `unansweredQuestion` and `earlierAnswers`; grouping by `parent`; `revision`.
- **Claude-shaped state made neutral:** `lastResult: TurnResult` becomes
  `lastTurn: TurnSummary` (outcome, failure text, cost, duration: what the views read).
  `SessionInfo.claudeCodeVersion` becomes `agentVersion`. `customTitle`, `aiTitle`,
  `writerVersion`, `historyPermissionMode` and `historyEffort` are set only through `.title`
  and `.historyMeta`.
- **Not events:** rate limits, `initialize`'s models and commands, the applied effort and
  model, context-usage replies and confirmed mode changes concern the session, not the
  conversation. The backend reports them as `SessionSignal`s.

## `ToolKind`

The translator classifies each call once; nothing downstream compares tool names again.

```swift
public enum ToolKind: Sendable, Equatable {
  case shell(command: String)          // Bash                   | commandExecution
  case read(path: String)              // Read                   | commandExecution action "read"
  case search(pattern: String)         // Grep, Glob             | actions "search", "listFiles"
  case fileChange([FileEdit])          // Edit, MultiEdit, Write | fileChange
  case web(String)                     // WebFetch url, WebSearch query | webSearch
  case subagent(description: String?)  // Agent, Task            | collabAgentToolCall
  case question                        // AskUserQuestion
  case planApproval                    // ExitPlanMode
  case todos                           // TodoWrite
  case mcp(server: String, tool: String)
  case other
}

public enum FileEdit: Sendable, Equatable {
  case replace(old: String, new: String)   // an Edit; each MultiEdit edit
  case write(content: String)              // diffed against the file on disk when drawn
  case patch(String)                       // Codex: a new file's content, or header-less hunks
}
```

- `Transcript.ToolCall` gains `kind`, and keeps `name` (the card's header: "Bash", an MCP
  tool's name) and `input` (the raw arguments, for the input disclosure).
  `PermissionRequest` gains the same `kind`; `isChoice`, `isPlan` and the permission sheet's
  Write check read it.
- `ClaudeTools.kind(name:input:)` is the one place that knows Claude Code's tool names and
  their input keys, including today's summary keys (`command`, `file_path`, `pattern`, `url`,
  `query`, `description`). MCP tools are recognised by the `mcp__<server>__<tool>` name.
- `summary` derives from `kind`; `.mcp` and `.other` fall back, as now, to the first string
  argument by key order, so every summary stays as it is.
- `FileChange.init(edits:existing:)` replaces `init(toolName:input:existing:)`. Parsing
  `.patch` is written in this slice (the Codex fit check needs it) but no Claude call produces
  one.
- The question card (`UserQuestion.list`), the plan panel (`PlanApproval`) and the todo strip
  (`TodoList`) still read Claude-shaped `input`; they are chosen by `kind`, so the dispatch is
  neutral while the parsing is not. Codex's question, a request rather than a tool call, gets
  its own source in slice 2.

## `AgentSession` and `AgentBackend`

The test for each line of today's `ClaudeSession`: would a Codex session need it verbatim?

**`AgentSession` keeps:** the phase; spawning, `stop()`, `stopAndWait`, and the
`stopCount` guards against a stop during a spawn; read-only and moving; loading history off
the main thread and the prompts typed meanwhile; the pending first prompt; the queue
(`canQueue`, `cancelQueued`); `earlierQuestion`; the name and the unsent name; the attention
callbacks; `diagnostics`; `transcript`; applying events and noticing permission changes.

**`ClaudeBackend` takes:** `ClaudeCommand` and `ClaudeLaunch`; the `initialize` handshake;
request ids, their prefixes and the revert table; `get_settings` after a start and after a
model or effort change; `get_context_usage` after each turn; the replies to elicitations and
to requests it does not handle; `ClientMessage`; `findTarget`; `ClaudeTranslator`.

```swift
/// One agent's wire format, behind which `AgentSession` runs it: how to start its CLI, what
/// its lines mean, how a command is written. Claude Code's is `ClaudeBackend`.
///
/// Stateless about the process, which the session owns and passes in; stateful about the
/// stream (its translator, its request ids).
protocol AgentBackend: AnyObject {
  /// Shown when the agent's CLI was not found.
  var notFoundMessage: String { get }
  /// What to run for `start`; no executable when the CLI was not found.
  func launch(_ start: AgentStart) -> AgentLaunch
  /// Everything owed right after the process started, then `first`, the prompt typed before
  /// it existed.
  func started(_ process: AgentProcess, then first: AgentCommand?) throws
  /// One line the process wrote. A reply the agent waits for is written here.
  func receive(_ line: AgentProcess.Line, from process: AgentProcess, at time: Date)
    -> BackendOutput
  /// Writes `command`; the request id, where an answer can come back (mode, model, effort).
  @discardableResult func send(_ command: AgentCommand, to process: AgentProcess) throws
    -> String?
  /// Where a session's own transcript is, once it has an id. Disk-side, Claude-typed until
  /// Codex history (slice 3).
  func locateTarget(sessionID: String, cwd: String, in accounts: [ClaudeAccount]) -> ResumeTarget?
}

/// What a session asks to start with: its folder, what it resumes, and its pills' picks,
/// frozen for this process.
struct AgentStart {
  var folder: URL
  var resuming: ResumeTarget?
  /// The login shell's.
  var environment: [String: String]
  var executableOverride: URL?
  /// Nil or `default`: the agent's own.
  var model: String?
  var mode: PermissionMode?
  var effort: String?
  var allowsBypass: Bool
  /// A name not yet recorded.
  var name: String?
}

struct AgentLaunch {
  /// Nil when the CLI was not found.
  var configuration: AgentProcess.Configuration?
  var executable: URL?
  var account: ClaudeAccount?
}

/// What the person does, in no agent's words.
enum AgentCommand {
  case prompt(text: String, context: [EditorSelection], uuid: String, attachments: [Attachment])
  case answer(requestID: String, decision: PermissionDecision)
  case interrupt(cancelQueued: Bool)
  case cancelQueued(uuid: String)
  case setMode(String)
  case setModel(String)
  case setEffort(String)
  case rename(title: String, sessionID: String)
}

struct BackendOutput {
  /// What the conversation shows.
  var events: [AgentEvent] = []
  /// What the session learns, never shown as conversation.
  var signals: [SessionSignal] = []
}

enum SessionSignal: Equatable {
  /// The handshake's answer, which lists the skills.
  case initialized(JSONValue?)
  case commandsChanged(JSONValue)
  case models([ModelOption])
  case modeAdopted(String)
  case settingsApplied(effort: String?, model: String?)
  case contextReported(ContextUsageReply)
  case rateLimit(JSONValue)
  /// A mode, model or effort change was answered: `refusal` nil when it took.
  case changeAnswered(requestID: String, refusal: String?)
  /// A queued prompt moved: taken, cancelled, dropped, or only acknowledged.
  case queueChanged
}
```

This is the protocol as built; how it departs from the first sketch, and why, is in the
plan's "Refinements of the spec" (docs/superpowers/plans/2026-10-06-agent-backend.md).

- `send` returns the request id it used where a refusal can come back (mode, model, effort),
  so the session keeps its own revert closures and the backend stays free of pill state.
- `AgentProcess` parses lines to `JSONValue` off the main thread, as it decodes them now, and
  emits `.lines([Line])`; a line that is not JSON is `.invalid(text)`, kept as today's
  `invalid-line`. `send` takes a `JSONValue`. The stderr and exit handling do not change.
- **Not neutral yet, and named so:** `ResumeTarget`, `ClaudeAccount`, `isLiveElsewhere` and
  `SessionTitle.write` are disk-side and stay Claude-typed on `AgentSession` until slice 3. The
  pills stay typed as Claude's `PermissionMode` and `ClaudeChoice` until slice 2, where Codex's
  approval policy × sandbox needs its own design.

## The Codex fit check

A `CodexTranslator` covering only what `docs/codex-app-server.md` verified:

- `thread/started` → `sessionStarted`; `turn/completed` → `turnEnded`;
- `agentMessage` and `reasoning` items with their deltas → `itemStarted` / `itemDelta` /
  `itemCompleted`;
- `commandExecution` → a `.shell` (or `.read` / `.search`, from `commandActions`) tool item
  and its `toolResult`; `fileChange` → `.fileChange([.patch])`;
- `thread/tokenUsage/updated` → `usage`;
- the two approval requests → `permissionRequested`; `serverRequest/resolved` →
  `permissionWithdrawn`.

It is tested by feeding scrubbed excerpts of the 2026-10-06 captures (account ids, email,
installation id and local paths replaced) through `CodexTranslator` and `Transcript`, and
asserting the entries. Nothing in the app uses it. It exists to find holes in `AgentEvent`
while they are cheap, and becomes slice 2's starting point.

## Order of work

Branch `feat/agent-backend` in `../drakar-agent-backend`, rebuilt on `main` once
`feat/cache-timer` has landed. Each commit passes `make -C apps/apple test test-app`.

1. **Docs:** `docs/codex-app-server.md` and this spec.
2. **Characterization goldens, before anything moves.** Every fixture in
   `DrakarKit/Tests/DrakarKitTests/Fixtures`, as history and as live lines, through today's
   `Transcript`; entries, pending permissions, turn end, last result, title, todos, agent
   tasks, usage, queue and closing text recorded as JSON goldens. Every later commit reproduces
   them unchanged.
3. **Rename** `ClaudeSession` → `AgentSession`, test files included. Nothing else.
4. **`ToolKind` and `FileEdit`.** `ClaudeTools.kind` sets `kind` where calls and permission
   requests are made; every name comparison switches to it. Classifier tests; the goldens hold.
5. **`AgentEvent`.** `Transcript.apply(AgentEvent)`, `ClaudeTranslator` (live, then history),
   and `ClaudeFeed` for tests: a `Transcript` and a `ClaudeTranslator`, with
   `apply(StreamMessage)` and `applyHistory(json)`, reading the transcript through
   `@dynamicMemberLookup`. `Transcript.apply(StreamMessage)` and `applyHistory` go. Tests
   change `Transcript()` to `ClaudeFeed()` and nothing else. May split into live and history.
6. **`AgentProcess`** emits lines and sends `JSONValue`.
7. **`AgentBackend` and `ClaudeBackend`,** extracted from `AgentSession`. The app's session
   tests run unchanged through the Claude backend.
8. **The Codex fit check.**

Landing: merge `main` into the branch, run both suites, fast-forward `main`. Commits 3 and 4
can land early if `main` keeps moving under the rest.

## Testing

- The goldens from step 2 are the refactor's contract: identical transcripts for every
  fixture, live and from history, at every commit.
- The existing tests stay as written, apart from the mechanical rename (step 3) and
  `Transcript()` → `ClaudeFeed()` (step 5).
- New: `ToolKind` classification for every Claude tool name and an MCP name; `FileEdit.patch`
  parsing (a new file's content, header-less hunks); `Transcript.apply(AgentEvent)` directly,
  for the neutral rules (an item completed after its turn ended, a completion that would blank
  streamed text, thinking timing); `ClaudeBackend.receive` for the signals; the Codex fit check.
- In the running app, once landed (asking first, since `make run` quits the Drakar in use): a
  long history opens as before; a live turn with a tool call and a permission; plan mode;
  a queued prompt; an attachment.

## Not in this spec

- Anything Codex a person can see: slice 2.
- The disk side: `SessionIndex`, `TranscriptFollower`'s file discovery, `ClaudeAccount`,
  `AccountStore`, `SessionMonitor`, `SessionMover`, `ProjectStats`: slice 3 and 4.
- The pills' types and Settings' defaults (`PermissionMode`, `ClaudeChoice`): slice 2.
- The IDE bridge, which Codex has no counterpart for.
- Codex's todos, plan mode, questions and subagents, until their protocol is verified.
