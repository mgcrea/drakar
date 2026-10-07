# Live Codex sessions (Codex support, slice 2)

Slice 1 put the agent behind a protocol: `AgentSession` runs an `AgentBackend`, `Transcript`
changes only through `AgentEvent`, tool calls say what they do (`ToolKind`), and a
`CodexTranslator` folded a recorded Codex turn as a fit check, connected to nothing. This
slice connects it: a project window can run Codex sessions beside Claude Code ones, over
`codex app-server`, streaming into the same transcript and answering approvals in the same
sheet. Claude sessions do not change.

## Why

Supporting Codex beside Claude Code was sized on 2026-10-06 as four slices: (1) the protocol,
landed on main at `a658443` and checked in the running app on 2026-10-07; (2) **this one**,
live sessions; (3) Codex history in the sidebar (Elsewhere, Ended), fork, following a thread
another process runs; (4) Codex accounts and limits (`CODEX_HOME` as a second kind of
account).

The protocol is recorded in `docs/codex-app-server.md` (verified 2026-10-06 against
`codex-cli 0.160.1`); its closing table maps each stream-json concept Drakar uses to Codex.
Field names in this spec were rechecked on 2026-10-07 against the bindings the same binary
generates (`codex app-server generate-ts`).

## Decisions

Settled with the person on 2026-10-07.

| Question | Decision |
| --- | --- |
| How a session picks its agent | Per session. New Session starts the default agent (Settings), ⌥-click or its menu starts the other; one window mixes both |
| The mode pill for Codex | Drakar's modes, mapped onto approval policy × sandbox: Ask before edits, Edit automatically, Bypass permissions (when Settings allows bypass). Plan and Auto are not offered for Codex |
| A window's Codex sessions after a relaunch | Restored with history, from `thread/items/list`; the next prompt resumes the thread |
| Process layout | One `codex app-server` per session, as one `claude` per session today (approach A). A shared server per window or account (B) was rejected: it breaks the session's ownership of its process for no measured saving, MCP servers starting per thread anyway. `codex exec --json` per turn (C) was rejected: no approvals over the wire |

## What changes, in one picture

```text
Project.newSession(agent:)        StoredProject.sessions: [ResumeTarget(agent:)]
          │                                    │ restore
          ▼                                    ▼
AgentSession(folder:, resuming:, agent:) ── backend: ClaudeBackend | CodexBackend
          │ history (restored Codex)             │ launch / started / receive / send
          ▼                                      ▼
CodexHistory ─ app-server ─ thread/items/list   AgentProcess ─ codex app-server (stdio)
          │                                      │ lines
          └──────────► CodexTranslator ◄─────────┘
                            │ [AgentEvent]
                            ▼
                        Transcript ──► views (gated by AgentFeatures)
```

## DrakarKit

All new code sits under `Sources/DrakarKit/Codex/`, tested with Swift Testing, zero
dependencies as today.

### `CodexRPC`

The JSON-RPC layer, no knowledge of methods' meaning.

- `CodexRPC.Line`: what one line is. `response(id: RPCID, result: JSONValue)`,
  `failure(id: RPCID, message: String)`, `notification(method: String, params: JSONValue)`,
  `request(id: RPCID, method: String, params: JSONValue)` (the server asking). Anything else
  is `nil`. Lines carry no `jsonrpc` member and none is written.
- `RPCID`: a number or a string, echoed as it came. Our ids and the server's live in separate
  tables: the server counts from 0 per process and collides with ours.
- `CodexRPC.Client` (a value type the backend owns): numbers our requests, remembers what
  each was for (`Pending`: `.initialize`, `.account`, `.models`, `.threadStart`,
  `.threadResume`, `.turnStart(uuid)`, `.turnSteer(uuid)`, `.interrupt`, `.rename`), and
  returns that purpose with each response. It writes requests, the `initialized`
  notification, answers (`{"id", "result"}`) and refusals (`{"id", "error": {code: -32601,
  message}}`).

### `CodexPolicy`

- `PermissionMode` → `(approvalPolicy, sandbox)`:

  | Drakar mode | `approvalPolicy` | `sandbox` (thread) / `sandboxPolicy` (turn) | Verified |
  | --- | --- | --- | --- |
  | `.ask` | `untrusted` | `workspace-write` / `{type: workspaceWrite}` | asks for edits and unknown commands |
  | `.acceptEdits` | `on-request` | `workspace-write` / `{type: workspaceWrite}` | edits and sandboxed commands run unasked |
  | `.bypass` | `never` | `danger-full-access` / `{type: dangerFullAccess}` | not run in a probe |

  The modes offered for Codex are these three, `.bypass` only when Settings allows bypass.
  The exact `sandboxPolicy` object shapes are taken from the generated `SandboxPolicy` type
  when the plan is written, and checked by the probe.
- `PermissionDecision` → Codex decision, for a command or a file change:

  | `PermissionDecision` | Codex |
  | --- | --- |
  | `.allow(updatedInput:, updatedPermissions: [])` | `"accept"` |
  | `.allow(…, updatedPermissions: [s])`, `s` a Codex decision suggestion | `s`'s decision (`"acceptForSession"`) |
  | `.deny(message:, interrupt: false)` | `"decline"` |
  | `.deny(message:, interrupt: true)` | `"cancel"` |

  The sheet's Reject sends `deny` without `interrupt`, so Reject declines and the turn goes
  on, as with Claude. `acceptWithExecpolicyAmendment` and network amendments are not offered
  (where the rule is saved is unverified).

### `CodexModels`

`model/list`'s `data` → `[ModelOption]`: `value` and `resolvedModel` the model id, the
display name, `effortLevels` from `supportedReasoningEfforts[].reasoningEffort`, hidden
models dropped. Default model and effort stay Codex's own (its `config.toml`): Drakar sends
neither until a pill is picked. `EffortLevel`'s titles gain a fallback (the level,
capitalised) for levels Claude lacks (`ultra`).

### `CodexTranslator`, completed

Kept from slice 1: agent messages, streamed reasoning (empty ones skipped), commands with
`commandActions`, file changes, approvals, `serverRequest/resolved`, usage, compaction, turn
end. Added:

- `turn/started` → no event; the backend reads the turn id from it.
- `userMessage` items: live, one carrying a `clientId` that names a queued prompt →
  `.queue(id: clientId, .started)`; one without (the session's own first prompt) → nothing.
  In history → `.prompt(Prompt(text:), running: false)`, text inputs joined, image inputs as
  attachment previews.
- File changes: `kind.type` `add` and `update` stay `FileEdit.Change.patch(diff)` (a new
  file's content, or header-less hunks, which `PatchText` already draws); `update` with a
  `move_path` shows the new path, the old one in the card's subtitle; `delete` becomes a new
  `FileEdit.Change.delete`, drawn as the file removed (its diff shape is what the probe
  finds: if Codex sends the old content, it draws as all-removed lines).
- `error {error, willRetry: true}` → `.retrying(APIRetry(attempt: nil, maxRetries: nil,
  delayMS: nil))`; `willRetry: false` → a failure note with `error.message`. Neither was
  seen live (types only).
- A refused server request → `.note(Note(text:, isFailure: false))` naming it.
- `history(_ entries: [JSONValue]) -> [AgentEvent]`: `thread/items/list` entries
  (`{turnId, item, startedAtMs, completedAtMs}`) folded as completed items, a prompt opening
  each turn, `.turnOutcome(.completed)` closing each, and once per thread a note that Codex
  keeps no record of declined commands.
- Approval suggestions: a file-change request, and a command request whose
  `availableDecisions` lists `acceptForSession`, carry one `PermissionRequest.suggestions`
  entry `{"type": "codexDecision", "decision": "acceptForSession"}`.
  `PermissionSuggestion.Kind` gains `.codexDecision(String)`, titled "Accept for this
  session" / "Allow for this session".

## App

### `AgentKind` and `AgentFeatures`

- `enum AgentKind: String, Codable { case claude, codex }`.
- `ResumeTarget.agent: AgentKind?`, nil decoding as Claude, so every stored window loads
  unchanged. A Codex target: `sessionID` the thread id, `cwd`, `file` the rollout path
  (`thread.path`, empty until known), `accountDirectory` the `codexHome` the handshake
  reported, `accountIsDefault` true.
- `AgentSession.init(folder:resuming:agent:)` builds its backend from the agent (the
  `backend:` parameter stays for tests). `Project.newSession(agent:)`; `attach` and
  restore read the target's agent.
- `struct AgentFeatures`, from `AgentBackend.features`: `agentName`, `offeredModes(allowsBypass:)`,
  `cancelsQueued`, `slashCommands`, `showsCost`, `showsPromptCache`, `showsAccountUsage`,
  `forks`, `movesHere`, `acceptsPDF`. Claude's are all on and its name "Claude Code"; the
  views read these instead of asking which agent runs. `SessionPills.offeredModes` and
  `cycle` take the offered modes from here.

### `CodexLaunch`

Finds `codex` on the login shell's `PATH` (`AgentSession.environment`), then
`/opt/homebrew/bin/codex`, then `/usr/local/bin/codex`. Arguments: `app-server`. The
environment passes through unchanged, so a `CODEX_HOME` set in the shell still selects the
account until slice 4. Not found: "Codex was not found. Install it with `brew install
--cask codex`."

### `CodexBackend`

An `AgentBackend`. State: the RPC client, the translator (new per process), the thread id,
its rollout path, the current turn id, the prompts waiting for a thread, the picks to send
with the next turn, the pending approvals' kinds (command or file change) by request id.

- `launch`: `CodexLaunch`, `account: nil`.
- `started(process, then:)`: `initialize {clientInfo: {name: "drakar", title: "Drakar",
  version}, capabilities: {experimentalApi: false, optOutNotificationMethods:
  ["mcpServer/startupStatus/updated"]}}`, `initialized`, `account/read`, `model/list`.
  `first` is held until a thread exists.
- First prompt: no thread → `thread/start {cwd, model?, approvalPolicy, sandbox}`; a
  restored target → `thread/resume {threadId, excludeTurns: true, model?, approvalPolicy,
  sandbox}` (settings left out fall back to `config.toml`'s, verified). On the response, the
  held prompt goes as `turn/start {threadId, input, clientUserMessageId: uuid, effort?,
  model?, approvalPolicy, sandboxPolicy}`.
- `.prompt` while a turn runs → `turn/steer {threadId, expectedTurnId, input,
  clientUserMessageId}`. A `no active turn to steer` failure resends it as `turn/start`.
  Prompts still queued when their turn ends without echoing them → `.queue(id, .dropped(agent:
  "Codex"))`, unless the probe shows Codex carries them into a new turn, in which case that
  is followed instead.
- `.interrupt` → `turn/interrupt {threadId, turnId}`; a waiting approval is answered
  `cancel` first. `.cancelQueued` is never sent (`cancelsQueued` off).
- `.answer(requestID, decision)` → the result `{decision}` per `CodexPolicy`.
- `.setMode`, `.setModel`, `.setEffort` → stored for the next `turn/start` (Codex keeps them
  for later turns) and answered at once with `.changeAnswered(refusal: nil)`; while a turn
  runs, `AgentSession.pillNote` reads "From the next turn" until it ends. The experimental
  `thread/settings/update` is not used.
- `.rename` → `thread/name/set {threadId, name}`.
- `receive`: responses by purpose (`account/read` with `account: null` and
  `requiresOpenaiAuth` → the session fails "Codex isn't signed in. Run `codex login` in a
  terminal."; `model/list` → `.models`; thread responses → thread id, path,
  `.sessionStarted`; a failed `thread/start`, `thread/resume` or `turn/start` → a failure
  note, the session back to ready; `already has an active writer` → the session read-only,
  saying the thread is open in another Codex process). Server requests other than command
  and file-change approvals are refused with an error and noted. Everything else goes
  through the translator.
- `locateTarget` → the Codex `ResumeTarget` from the thread id and path, no disk search.
- `features`: name "Codex", modes per `CodexPolicy`, every other flag off. The context
  meter needs no flag: it shows whenever `.usage` arrives.

### `CodexHistory`

For a restored Codex session, in `AgentSession.loadHistory` (which branches on the agent in
this slice; slice 3 moves history behind the protocol): a short-lived `codex app-server`,
`initialize`, `initialized`, `thread/items/list {threadId, limit: 200, cursor}` until
`nextCursor` is null, closed input, exit. The entries go through
`CodexTranslator.history`. No resume and no lock (verified: listing needs neither). A
failure leaves the transcript empty with a note; the session still resumes on the next
prompt.

### Views

- New Session: click starts `Settings > New sessions run` (Claude Code by default); ⌥-click
  and the button's menu start the other. File > New Claude Code Session ⌘N, New Codex
  Session ⌥⌘N.
- Sidebar: Codex rows carry a small "Codex" tag; Claude rows unchanged.
- Agent name in place of "Claude" where it names the agent: the permission sheet's question,
  "… exited with status", the footer's version (`thread.cliVersion` for Codex), the question
  and plan panels. Claude sessions keep their exact text.
- Composer for Codex: mode pill per `AgentFeatures`, ⇧Tab cycling those; model and effort
  pills from the catalog; no `/` menu.
- Footer for Codex: no cost, no prompt cache timer, no account usage; the context meter from
  `.usage` (`last`, `modelContextWindow`).
- Toolbar Fork and the read-only bar's Fork / Move Here hidden for Codex.
- Attachments for Codex: images as `image` input with a `data:` URL (verified), text files
  inline as `text` input, PDFs refused at intake ("Codex can't read PDFs here"). Editor
  context goes as a `text` input ahead of the prompt.
- `ModelCatalog` keys by agent and account: Codex sessions share one key until slice 4.
- Settings: the default agent picker; a Codex section showing the `codex` found, or "Not
  found" with the install line.

## Failures

| What | What the person sees |
| --- | --- |
| `codex` not found | The session fails with the install line, as a missing `claude` does |
| Not signed in | Fails before the prompt: "Codex isn't signed in. Run `codex login` in a terminal." |
| `thread/start`, `thread/resume`, `turn/start` error | A failure note with Codex's text; the session ready to retry |
| Thread held by another process | Read-only: "Open in another Codex process." No following (slice 3) |
| `turn/completed` `failed` | `turn.error.message` as the failure, as Claude's failed turn |
| `error {willRetry: true}` | The retry notice on the working indicator |
| Unknown server request | Refused with an error, a note says what was refused, nothing waits |
| Process exits | `processExited()`, pending approvals cleared, as for Claude |
| Malformed line, unknown method | Ignored; stderr kept in diagnostics |

## Order of work

On `feat/codex-live` in `../drakar-codex-live`, landed on main by fast-forward.

1. **Probe** (scratch folder, ephemeral threads where they suffice, a persistent one deleted
   after): update, delete and rename `fileChange`; a steer with `clientUserMessageId` (is it
   echoed as `clientId`?; what a steer sent just before the turn ends becomes); one
   `thread/items/list` page; `account/read` under an empty `CODEX_HOME`; the
   `SandboxPolicy` objects `turn/start` accepts. Scrubbed fixtures; `docs/codex-app-server.md`
   updated. Uses a little of the ChatGPT plan's usage.
2. `AgentKind`, `ResumeTarget.agent`, `AgentFeatures`, `AgentSession(agent:)`: no visible
   change, Claude's features all on.
3. `CodexRPC`.
4. `CodexPolicy`, `CodexModels`, `PermissionSuggestion.codexDecision`.
5. `CodexTranslator` completed, its history fold, a Codex golden.
6. `CodexLaunch`, `CodexBackend`.
7. `CodexHistory`, restore.
8. Views: New Session, Settings, sidebar tag, wording, gating, attachments.
9. Check in the running app (with the person's go-ahead for `make run`).

## Testing

- DrakarKit: `CodexRPC` (line kinds, number and string ids, server ids apart from ours,
  purpose matching); `CodexPolicy` (both tables); `CodexModels`; `CodexTranslator` on the
  existing fixture and the probe's (steer echo, delete, rename, history fold); a Codex golden
  snapshot beside the Claude ones. The Claude goldens stay byte-identical.
- App: `CodexBackendTests` with the `cat` stand-in `ClaudeBackendTests` uses, lines fed to
  `receive` and writes asserted: handshake; first prompt held for `thread/start`; resume with
  settings; steer and its fallback; interrupt with the turn id and a waiting approval
  cancelled; each decision; unknown server requests refused; picks on the next
  `turn/start`; not signed in. `ResumeTarget` decoding without `agent`;
  `Project.newSession(agent:)`.
- In the app: a Codex session in a scratch folder (accept, decline, steer, Stop), relaunch
  and restore, a Claude session beside it unchanged.

## Not in this spec

- Codex threads Drakar did not start (sidebar Elsewhere and Ended), fork, Move Here,
  following a thread another process holds: slice 3.
- Accounts, `CODEX_HOME` choice, rate limits, the toolbar's usage: slice 4.
- Plan mode and `item/tool/requestUserInput` (experimental API), Auto mode
  (`approvalsReviewer: auto_review`, unverified), `acceptWithExecpolicyAmendment`, network
  approvals, MCP elicitation answers, `thread/queue/*`, `thread/settings/update`,
  `turn/plan/updated` (never seen), subagents (`collabAgentToolCall`).
- A Settings picker to override the `codex` path.
