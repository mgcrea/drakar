# Driving Codex over app-server

Findings from probes run on 2026-10-06 and 2026-10-07 against `codex-cli 0.160.1` (Homebrew cask,
`/opt/homebrew/bin/codex`), signed in with a ChatGPT Plus account, the user's
`config.toml` choosing `gpt-6-astra` at `low` effort. The Codex counterpart of
[claude-stream-json.md](claude-stream-json.md): written so another agent can pick the
protocol up cold, and so future fixtures have a record of where they came from.

Every claim carries one of two marks:

- **verified**: seen on the wire on 2026-10-06 (or the date given) with 0.160.1, by the probes listed under
  "Raw captures";
- **types**: read from the bindings the same binary generates
  (`codex app-server generate-ts --out <dir>`; `--experimental` adds the experimental
  methods and fields) or its JSON Schema (`generate-json-schema`), not seen live.

A section heading carries the mark that applies to all of it; a line that differs says so.

## Verdict

- **The protocol ships its own schema.** The binary generates TypeScript bindings and a
  JSON Schema for exactly the version installed, stable and experimental halves apart.
  Claude Code's stream-json has nothing like it. Regenerate on every Codex release and
  diff: that is the changelog. `codex app-server --help` still calls the whole command
  "[experimental]", so decode leniently all the same.
- **The whole loop works from outside** (verified): initialize, start a thread, send a
  prompt, stream the answer, answer a file-change and a command approval (accept, decline
  and cancel), steer a running turn, interrupt one, compact, resume in a fresh process,
  read history, rename, fork.
- **The model is thread → turn → item, each with an explicit lifecycle.** `turn/started`
  … `turn/completed` with a status; `item/started` → deltas keyed by `itemId` →
  `item/completed` carrying the whole item. Approvals are JSON-RPC requests from the
  server, with ids. One process hosts many threads and every notification names its
  `threadId`. This is a cleaner shape than stream-json's, and the obvious skeleton for a
  neutral event type.
- **Traps found on the wire, each detailed below:** an interrupted turn leaves its command
  running and reports it finished later, under the old turn; `turn/start` during a turn
  silently becomes a steer; resuming without `sandbox` drops the thread to the config's
  sandbox; declined commands vanish from history; one writer per thread, enforced; plan
  mode and the question tool are experimental API; there are no server-side slash commands.

## Spawning (verified)

```sh
codex app-server [-c key=value]… [--enable <feature>] [--disable <feature>]
```

- stdio is the default transport (`--listen stdio://`); `unix://` and `ws://IP:PORT` exist
  too. Drakar wants stdio.
- `sandboxPolicy` on `turn/start` takes the full object: `{type: "workspaceWrite",
  writableRoots: [], networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp:
  false}` was accepted (verified 2026-10-07); `{type: "dangerFullAccess"}` and `{type:
  "readOnly", networkAccess}` are the other forms (types).
- `-c` overrides `config.toml` for the process, the value parsed as TOML
  (`-c model="gpt-6-sol"`). `thread/start` also takes a `config` map per thread (types).
- **`CODEX_HOME`** selects the account. With it pointing at an empty directory,
  `initialize` reported that directory as `codexHome`, `account/read` answered
  `{"account": null, "requiresOpenaiAuth": true, …}`, `account/rateLimits/read` failed
  ("codex account authentication required to read rate limits"), `model/list` still
  answered, and the process created `state_5.sqlite`, `logs_2.sqlite`, `goals_1.sqlite`,
  `memories_1.sqlite`, `queue_1.sqlite` and `installation_id` there at once.
- **stderr is tracing output**, ANSI-coloured, not protocol. On this Mac every thread start
  writes 80 to 200 `ERROR rmcp::transport::worker` lines, one per MCP server failing auth.
- **Closing stdin ends the process with status 0** and releases its thread locks (checked
  idle; mid-turn not checked).
- The `clientInfo.name` we send becomes the thread's `originator`, and every thread this
  process creates is `source: "vscode"`; the user agent reads
  `drakar-probe/0.160.1 (Mac OS 27.0.1; arm64) vscode/1.140.0 (drakar-probe; 0)`. Armada and
  the ChatGPT app will list Drakar's threads as VS Code sessions.

## Framing (verified)

One JSON object per line, both directions. JSON-RPC 2.0 shapes **without the `jsonrpc`
member**: the server never writes it, and a client line carrying `"jsonrpc": "2.0"` is
accepted all the same.

```jsonc
>> {"id":3,"method":"turn/start","params":{…}}          // request
<< {"id":3,"result":{…}}                                // response
<< {"id":4,"error":{"code":-32600,"message":"…"}}       // error
<< {"method":"turn/started","params":{…},"emittedAtMs":1791299288041}   // notification
<< {"method":"item/fileChange/requestApproval","id":0,"params":{…}}     // server request
>> {"id":0,"result":{"decision":"accept"}}              // our answer to it
```

- **Ids are numbers or strings** and come back as sent (`"init-1"` was echoed).
- **Server requests have their own id space**, numbers from 0 per process, which collide
  with ours: keep the two tables apart.
- Notifications carry `emittedAtMs` beside `params`.
- **Every error seen was `-32600`**, the text being the only distinction: `Not initialized`,
  `Already initialized`, ``Invalid request: unknown variant `x`, expected one of …`` (which
  lists every method, experimental ones included), ``Invalid request: missing field
  `threadId` ``, `no active turn to steer`, `expected active turn id <a> but found <b>`,
  `thread <id> already has an active writer`, `ephemeral threads do not support
  thread/turns/list`, ``ephemeral paginated thread/fork requires `excludeTurns: true` ``,
  `codex account authentication required to read rate limits`.
- **A malformed line gets no answer.** stderr logs `Failed to deserialize JSONRPCMessage`
  and the process carries on.
- A response and the notifications it causes are not ordered: `thread/started` came after
  the `thread/start` response, `thread/status/changed` before the `thread/resume` one.

## Handshake (verified)

```jsonc
>> {"id":1,"method":"initialize","params":{
     "clientInfo":{"name":"drakar","title":"Drakar","version":"…"},
     "capabilities":{"experimentalApi":false,"requestAttestation":false,
                     "optOutNotificationMethods":["mcpServer/startupStatus/updated"]}}}
<< {"id":1,"result":{"userAgent":"…","codexHome":"/Users/…/.codex",
     "platformFamily":"unix","platformOs":"macos"}}
>> {"method":"initialized"}
```

- Anything before `initialize` fails `Not initialized`; a second one, `Already initialized`.
- `initialized` is the protocol's only client notification. The first probe never sent it
  and nothing changed; send it anyway.
- **`optOutNotificationMethods` works**: by exact method name, the 222
  `mcpServer/startupStatus/updated` lines of a thread start became 0.
- **`experimentalApi: true`** opens the experimental half: `collaborationMode` on
  `turn/start` (plan mode), `collaborationMode/list`, `thread/queue/*`,
  `thread/settings/update`, `turn/settings/update`, `thread/backgroundTerminals/*` and
  more (types; plan mode and `collaborationMode/list` verified). Whether the server
  refuses those without the flag was not tested.
- Unlike Claude's `initialize`, **the reply says nothing** about models, commands or the
  account. Each is its own call, all answered without a model request: `model/list`,
  `account/read`, `account/rateLimits/read`, `skills/list`, `mcpServerStatus/list` (types),
  `collaborationMode/list` (experimental).
- Unprompted at start: `remoteControl/status/changed` (`status: "disabled"`, the host name,
  an installation id) and `account/updated` (`{authMode: "chatgpt", planType: "plus"}`).

## Threads (verified)

### Starting

`thread/start` takes `model`, `modelProvider`, `serviceTier`, `cwd`, `approvalPolicy`,
`approvalsReviewer`, `sandbox`, `config`, `baseInstructions`, `developerInstructions`,
`ephemeral`, `sessionStartSource` (`startup` | `clear`), `threadSource` (types). No name, and
no effort: effort goes on `turn/start`, or in config as `model_reasoning_effort`.

The response, then a `thread/started` notification with the same `thread`:

```jsonc
{"thread":{"id":"01a111c1-…","sessionId":"01a111c1-…","forkedFromId":null,"parentThreadId":null,
  "preview":"","ephemeral":true,"historyMode":"paginated","modelProvider":"openai",
  "model":"gpt-6-astra","reasoningEffort":"low","createdAt":1791299288,"updatedAt":1791299288,
  "status":{"type":"idle"},"path":null,"cwd":"/p","cliVersion":"0.160.1",
  "originator":"drakar-probe","source":"vscode","name":null,"turns":[], …},
 "model":"gpt-6-astra","cwd":"/p","approvalPolicy":"never","approvalsReviewer":"user",
 "sandbox":{"type":"readOnly","networkAccess":false},"activePermissionProfile":null,
 "reasoningEffort":"low","multiAgentMode":"explicitRequestOnly","instructionSources":[], …}
```

- Ids are UUIDv7 (types), so they sort by creation time.
- `path` is the rollout file, given outright for a persistent thread; `null` when ephemeral.
- **`sandbox` goes in as a mode string** (`"read-only"`) **and comes back as a policy
  object** (`{type: "readOnly", networkAccess: false}`); `turn/start` takes the object form,
  as `sandboxPolicy`.
- The model comes from `config.toml` (`gpt-6-astra`), not from `model/list`'s `isDefault`
  (`gpt-6.1-sol`).
- **Ephemeral threads** write no rollout (none appeared under `sessions/`), refuse
  `thread/turns/list`, and cannot be forked without `excludeTurns`.
- MCP servers start per thread: the `mcpServer/startupStatus/updated` burst follows
  `thread/start`, not `initialize`, and stderr shows the same servers failing on
  `thread/resume`.

### Resuming

`thread/resume {threadId}` from a fresh process, the thread on disk:

- **Nothing is replayed as notifications.** After the response come only
  `thread/status/changed` (`idle`), one `thread/tokenUsage/updated` (the last turn's usage,
  which feeds a context meter straight away) and `thread/goal/cleared`.
- **The response holds the full history in `thread.turns`**, items and all, but asking for
  it is deprecated: it emits `deprecationNotice` ("Full-history hydration is deprecated for
  paginated threads; use `excludeTurns: true`, then page with `thread/turns/list` and
  `thread/items/list`."). Pass `excludeTurns: true` and page instead. The response also
  carries `collaborationMode` (even without `experimentalApi`), `turnsBackwardsCursor`
  and `itemsBackwardsCursor`.
- **Settings left out are not the thread's own.** The thread was started `workspace-write`;
  resumed without `sandbox`, it came back `readOnly`, and the rollout recorded the change
  (`thread_settings_applied`). `approvalPolicy` stayed `untrusted`. Pass `approvalPolicy`,
  `sandbox`, `model` and effort on every resume; with them the response matched.
- **One writer per thread.** A second process resuming a thread the first holds gets
  `thread <id> already has an active writer`. Forking is the way round, as with Claude's
  `--fork-session`.
- `~/.codex/thread-writer-locks/<id>.lock` appeared on resume, **stayed after
  `thread/unsubscribe`** (answered `{"status": "unsubscribed"}`), and went when the process
  exited. `thread/loaded/list` lists what this process holds.

### History

- `thread/items/list {threadId, limit, cursor?, turnId?, sortDirection?}` →
  `{data: [{turnId, item, startedAtMs, completedAtMs}], nextCursor, backwardsCursor}`,
  ascending by default, every item. **It works on a thread no process has loaded**: no
  resume, no lock.
- `thread/turns/list {threadId, limit, itemsView?}` → turns, newest first; the default
  `summary` view keeps only the prompt and the final answer of each.
- Cursors are opaque strings (JSON inside; do not parse).
- `thread/read {threadId}` gives the metadata, `thread.name` included; `includeTurns: true` is
  deprecated like the resume hydration. It also works on a thread no process has loaded
  (Drakar's history restore read a renamed thread's name this way, 2026-10-08).
- **Each entry is `{turnId, item, startedAtMs, completedAtMs}`**, both times numbers; a
  short thread fits one page (`nextCursor: null`). A `userMessage` keeps its `clientId`
  (verified 2026-10-07; `Fixtures/codex-items-page.json`).
- `thread/delete {threadId}` → `{}` removes a thread (verified 2026-10-07: probes clean up
  after themselves with it).
- **Declined commands are not in history.** The live stream showed the declined `touch` as
  a `commandExecution` with `status: "declined"`; neither the resume response nor
  `thread/items/list` has it, though the rollout keeps the tool call and its output.
  Accepted commands and file changes, and declined file changes, are there.
- `thread/list {limit, cwd?, searchTerm?, archived?, sourceKinds?, …}` lists threads from
  the state database, newest first, `cwd` filtering exactly (verified with `cwd`), each with
  `name`, `preview`, `cwd`, `source`, and a `status` that is `notLoaded` for anything this
  process does not hold, live elsewhere or not.

### Forking

`thread/fork {threadId, lastTurnId?, ephemeral?, excludeTurns?, …settings}`. An ephemeral
fork needs `excludeTurns: true`. The source need not be loaded. The fork came back with a
new id, `forkedFromId` set, **the source's name and preview copied**, `path: null`, and the
settings passed honoured. `lastTurnId` forks through a given turn (types).

### Titles and names

- `thread/name/set {threadId, name}` → `{}`, then `thread/name/updated {threadId,
  threadName}`, and a line `{"id", "thread_name", "updated_at"}` appended to
  `~/.codex/session_index.jsonl`. `thread.name` carries it in later reads; a fork copies it.
- **The app-server named nothing on its own.** A persistent thread that completed a turn
  had no index entry and `name: null` minutes later. `thread.preview` is the first prompt.
  Who writes the generated titles the ChatGPT app shows is open.

## Turns (verified)

`turn/start` takes `threadId`, `input[]`, `clientUserMessageId`, and overrides that
**persist for later turns**: `cwd`, `approvalPolicy`, `approvalsReviewer`, `sandboxPolicy`,
`model`, `serviceTier`, `effort`, `summary` (`auto` | `concise` | `detailed` | `none`),
`outputSchema`; `serviceTierForTurn` is the one-turn exception; `collaborationMode`
is experimental (types).

A running turn keeps the approval policy and sandbox it started with: no request changes
them mid-turn (0.160.1 schema; `thread/settings/updated` is a notification only). A switch
to a mode that lets more through is honoured by Drakar answering the approvals it covers
(`CodexPolicy.letsThrough`); the sandbox follows on the next `turn/start`.

```jsonc
>> {"id":3,"method":"turn/start","params":{"threadId":"…","effort":"low",
     "input":[{"type":"text","text":"Run `cat note.txt` …","text_elements":[]}]}}
<< {"id":3,"result":{"turn":{"id":"01a111c1-fbe2-…","items":[],"itemsView":"notLoaded",
     "status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}
<< thread/status/changed {status: {type: "active", activeFlags: []}}
<< turn/started {turn}
   … items …
<< thread/status/changed {status: {type: "idle"}}
<< turn/completed {turn: {status: "completed", items: [<final agentMessage>],
     itemsView: "summary", error: null, durationMs: 8955}}
```

`turn.status` is `completed`, `interrupted`, `failed` or `inProgress`; `turn.error` is
`{message, codexErrorInfo, additionalDetails}`, `codexErrorInfo` naming
`contextWindowExceeded`, `usageLimitExceeded`, `rateLimitExceeded`, `serverOverloaded`,
`unauthorized`, … (types). A failed turn was not seen.

### Input

`UserInput` is one of (types; marked where verified):

| `type` | Fields | |
| --- | --- | --- |
| `text` | `text`, `text_elements: [{byteRange, placeholder}]` | verified, sent with `[]` |
| `localImage` | `path`, `detail?` | verified: a red 32 px PNG was read as red |
| `image` | `url` (or `fileId`), `detail?` | verified with a `data:image/png;base64,…` URL |
| `skill` | `name`, `path` | verified: runs the skill (see Skills) |
| `mention` | `name`, `path` | a file reference |
| `audio`, `localAudio` | `url` / `path` | |

There is **no document type**: a PDF or text file goes as a path (`mention`, or named in the
text) for the agent to read, or inlined as text. The `userMessage` item echoes the input,
data URL included.

### Skills (verified 2026-10-08, 0.160.1)

```jsonc
>> {"id":5,"method":"skills/list","params":{"cwds":["/Users/me/project"],"forceReload":true}}
<< {"id":5,"result":{"data":[{"cwd":"/Users/me/project","errors":[],"skills":[
     {"name":"deploy","description":"…","shortDescription":null,
      "interface":{"displayName":"Deploy","shortDescription":"Deploy to staging","defaultPrompt":"…"},
      "path":"/Users/me/project/.agents/skills/deploy/SKILL.md",
      "scope":"repo","enabled":true,"pluginId":null}, …]}]}}
```

- No model request. `forceReload` (optional) has Codex read the files again. The answer is
  large: about 140 KB for 197 skills on one Mac, every description in full.
- A skill: `name`, `description`, `shortDescription?` (legacy), `interface?`
  (`displayName?`, `shortDescription?`, `defaultPrompt?`, …), `path` (its SKILL.md),
  `scope` (`repo`, `user`, `system`, `admin`), `enabled`, `pluginId` (null outside a
  plugin). A plugin's skills are named `plugin:name` (`data:analyze`).
- A repo's skills come from both `<folder>/.agents/skills/` and `<folder>/.codex/skills/`.
  One name can be listed twice, from two scopes (a user `skill-creator` and the system's).
- A prompt runs a skill with a `skill` input item beside its text:
  `[{"type":"text","text":"/probe-secret beta","text_elements":[]}, {"type":"skill",
  "name":"probe-secret","path":"…/SKILL.md"}]` ran the skill's body, not only its
  description, and `thread/items/list` returns the `userMessage` content exactly as sent.
  The text alone (`/name args` or `$name args`) also worked; the item is the explicit form.
- `skills/changed` (no params; types) is a notification: re-run `skills/list` when fresh metadata
  is wanted.

Drakar lists the enabled skills, one per name (repo over user over admin over system), in a
Codex session's `/` menu and the inspector, and sends a prompt starting `/name` with its
`skill` item (`CodexSkillList`, `CodexInput`).

### Prompts sent mid-turn

- **`turn/steer {threadId, expectedTurnId, input}`** → `{turnId}` at once. The prompt is
  taken at the next boundary (here, once the running `sleep 6` finished), appears as a
  second `userMessage` item **inside the same turn**, and the answer covered both prompts
  ("ALPHA BETA"). Idle, it fails `no active turn to steer`.
- **`clientUserMessageId` comes back** as the `userMessage` item's `clientId`, for
  `turn/start` and `turn/steer` alike (verified 2026-10-07): it is how a client knows which
  of its prompts a turn took.
- **A steer is never lost to a turn ending**, only to an interrupt (verified 2026-10-07): sent
  after the final answer had already streamed, it still joined the turn, which made another
  model request and answered both ("ONE TWO"). Sent before a `turn/interrupt`, it was dropped
  with no `userMessage`, no new turn and no notice.
- **0.162 takes a steer at once** (verified 2026-10-12, 0.162.1): sent while a command ran,
  its `userMessage` item started and completed right away, before the model's next step. An
  interrupt then leaves it in the thread unanswered, where 0.160.1 dropped it. A `turn/start`
  with `input: []` after the interrupt has the model answer it ("QUEUED"), with no second
  copy of the message; on 0.160.1 the same empty turn is accepted, and the model only
  remarks on the interruption. Drakar's Esc sends a steer Codex never echoed again as a turn,
  and follows one it took but nobody answered with that empty turn.
- **`turn/start` while a turn runs is a steer.** Its response carried the *running* turn's
  id, its prompt joined that turn, and the model answered only the newer prompt (asked for
  GAMMA, then DELTA: it said "DELTA"). Compare the returned turn id with the one running
  before assuming a new turn began.
- **No queue in the stable API**: no lifecycle lines, no cancel. The experimental
  `thread/queue/add | list | update | delete | reorder | start` with
  `thread/queue/changed` holds `QueuedSubmission {id, input, clientUserMessageId}` (types).

### Interrupting

```jsonc
>> {"id":6,"method":"turn/interrupt","params":{"threadId":"…","turnId":"…"}}
<< {"id":6,"result":{}}
<< thread/status/changed {status: {type: "idle"}}
<< turn/completed {turn: {status: "interrupted", error: null, items: [], …}}
```

- Answered at once; a wrong `turnId` fails `expected active turn id … but found …`.
- **The running command is not killed.** The `sleep 20` the turn was in had no
  `item/completed` before `turn/completed`. It arrived about 19 s later, during a later
  turn, with `status: "completed"`, `exitCode: 0`, `durationMs: 19898`, and the **old
  `turnId`**. Route every item event by its own `turnId` and `itemId`, never by "the
  current turn", and accept items completing after their turn ended. The experimental
  `thread/backgroundTerminals/list | terminate | clean` is presumably how to stop them
  (types).
- Answering an approval with `cancel` ends the turn the same way (below).

## Items

One item per tool call or message; `item/started` carries what is known up front (the
whole command, the whole patch), `item/completed` the final state. Every delta is keyed by
`itemId`, not by a content-block index.

| `type` | Fields that matter | Streamed by | |
| --- | --- | --- | --- |
| `userMessage` | `content: [UserInput]`, `clientId` | started and completed together | verified |
| `agentMessage` | `text`, `phase: commentary \| final_answer \| null`, `questions`, `delivery` | `item/agentMessage/delta {delta}` | verified |
| `reasoning` | `summary: [String]`, `content: [String]` | `item/reasoning/summaryPartAdded {summaryIndex}`, `…/summaryTextDelta {delta, summaryIndex}`, `…/textDelta {delta, contentIndex}` | verified (summary) |
| `commandExecution` | `command`, `cwd`, `processId`, `source`, `status: inProgress \| completed \| failed \| declined`, `commandActions`, `aggregatedOutput`, `exitCode`, `durationMs` | `item/commandExecution/outputDelta {delta}`, `…/terminalInteraction {processId, stdin}` | verified |
| `fileChange` | `changes: [{path, kind, diff}]`, `status: inProgress \| completed \| failed \| declined` | `item/fileChange/patchUpdated {changes}` (types; not seen) | verified |
| `plan` | `text` | `item/plan/delta {delta}` | verified, plan mode |
| `contextCompaction` | none | | verified |
| `mcpToolCall` | `server`, `tool`, `arguments`, `status`, `result`, `error`, `durationMs`, `readOnlyHint` | `item/mcpToolCall/progress {message}` | types |
| `dynamicToolCall` | `namespace`, `tool`, `arguments`, `contentItems`, `success` | answered through the `item/tool/call` server request | types |
| `collabAgentToolCall` | `tool: spawnAgent \| sendInput \| wait \| closeAgent \| …`, `senderThreadId`, `receiverThreadIds`, `prompt`, `model`, `reasoningEffort`, `agentsStates` | | types |
| `subAgentActivity` | `kind: started \| interacted \| interrupted \| completed`, `agentThreadId`, `agentPath` | | types |
| `webSearch`, `imageView {path}`, `imageGeneration`, `sleep` | | | types |
| `enteredReviewMode`, `exitedReviewMode` | `review` | from `review/start` | types |
| `hookPrompt` | `fragments` | | types |

- **`agentMessage` comes several times a turn**: `commentary` ones between tool calls ("I'll
  read `note.txt`."), the `final_answer` last, each streamed. Types warn that `phase` may be
  null on older models.
- **Reasoning is a summary only.** At `medium` effort with `summary: "detailed"` one
  summary part streamed (`**Computing 17×23**`); `content` stayed `[]`. At `low` effort
  reasoning items arrive with both arrays empty: skip them.
- **`commandExecution`.** `command` is the wrapped form (`/bin/zsh -lc 'cat note.txt'`);
  `commandActions` is the parsed one, each `{type: read, command, name, path}`,
  `{type: listFiles, command, path}`, `{type: search, command, query, path}` or
  `{type: unknown, command}`. There is no Read or Grep tool: reads and searches are shell
  commands that `commandActions` classifies. `outputDelta` appeared for some commands and
  not others; `aggregatedOutput` on completion is the dependable copy (and was `null` for a
  command with no output). `source` is `agent`, `userShell`, `unifiedExecStartup` or
  `unifiedExecInteraction`.
- **`fileChange` diffs are not uniform.** `path` is absolute. For `kind: {type: "add"}` the
  `diff` is the new file's content (`"hi\n"`); for `{type: "update", move_path: null}` it is
  hunks without file headers (`"@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"`). For
  `{type: "delete"}` it is the removed file's content (`"bye\n"`); for a pure rename,
  `{type: "update", move_path: "<new absolute path>"}`, it is `"\n\nMoved to: <new path>"`
  and no hunks (verified 2026-10-07, one `apply_patch` doing all three). Separately, **`turn/diff/updated {diff}`** carries the turn's whole change as a
  real `git diff` (headers, index lines), re-sent after each model request.
- `item/fileChange/outputDelta` is declared but "no longer emitted" (types).

## Approvals and user input

The server's requests (types): `item/commandExecution/requestApproval`,
`item/fileChange/requestApproval`, `item/permissions/requestApproval`,
`item/tool/requestUserInput`, `mcpServer/elicitation/request`, `item/tool/call` (client
tools), `account/chatgptAuthTokens/refresh`, `attestation/generate` (only when
`requestAttestation`), and the v1 `applyPatchApproval` / `execCommandApproval`. Answer
anything unknown with a JSON-RPC error so nothing waits.

### Commands and file changes (verified)

`approvalPolicy: "untrusted"`, `sandbox: "workspace-write"`, a prompt asking for an
`apply_patch` and a `touch`. The order, for the file change:

1. `item/started` for the `fileChange`, `status: "inProgress"`, the diff included: the sheet
   can show the patch from the item.
2. `thread/status/changed`, `activeFlags: ["waitingOnApproval"]` (for the command this came
   before `item/started`).
3. The request:

   ```jsonc
   {"method":"item/fileChange/requestApproval","id":0,"params":{"threadId":"…","turnId":"…",
     "itemId":"exec-5cf6…","startedAtMs":1791299639342,"reason":null,"grantRoot":null}}
   {"method":"item/commandExecution/requestApproval","id":1,"params":{"kind":"command",
     "threadId":"…","turnId":"…","itemId":"exec-d481…","startedAtMs":1791299644347,
     "environmentId":"local","command":"/bin/zsh -lc 'touch from-shell.txt'","cwd":"/p",
     "commandActions":[{"type":"unknown","command":"touch from-shell.txt"}],
     "proposedExecpolicyAmendment":["touch","from-shell.txt"],
     "availableDecisions":["accept",
       {"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["touch","from-shell.txt"]}},
       "cancel"]}}
   ```

4. Our answer, `{"id":0,"result":{"decision":"accept"}}`.
5. `serverRequest/resolved {threadId, requestId}`, in the same millisecond or the next.
6. `thread/status/changed`, `activeFlags: []`.
7. `item/completed` with the item's final `status`.

Decisions: commands take `accept`, `acceptForSession`,
`{acceptWithExecpolicyAmendment: {execpolicy_amendment}}`,
`{applyNetworkPolicyAmendment: {network_policy_amendment}}`, `decline`, `cancel`; file changes
`accept`, `acceptForSession`, `decline`, `cancel` (types). What each did:

| Answer | Result |
| --- | --- |
| `accept` (file) | written; item `completed`; `turn/diff/updated` follows |
| `decline` (file) | nothing written; item `declined`; the turn goes on |
| `accept` (command) | ran; item `completed`, `exitCode: 0` |
| `decline` (command) | item `declined`; the model was told `exec_command failed: CreateProcess { message: "Rejected(\"rejected by user\")" }` (from the rollout) and the turn went on: "the shell command was rejected" |
| `cancel` (command) | item `declined`, then at once `turn/completed` with `status: "interrupted"`, `error: null` |

- **A file-change request carries no `availableDecisions`**; a command request's listed
  `accept`, `acceptWithExecpolicyAmendment` and `cancel` in every probe, never
  `acceptForSession` (rechecked 2026-10-07).
  Codex's own TUI labels `acceptForSession` "Yes, and don't ask again for these files" (file
  change) and "Yes, and don't ask again for this command in this session" (command), seen in
  the 0.160.1 binary's strings (2026-10-08). **On a file change it covers later changes to the
  same files only** (checked in Drakar, 2026-10-08): after `acceptForSession` on an edit of
  `a.txt`, a second patch to `a.txt` applied without a request; a patch to `b.txt` in the
  same session still asked. The command side is unexercised (never offered).
- **`availableDecisions` arrived without `experimentalApi`**, though the types put it in the
  experimental half. It listed neither `decline` nor `acceptForSession`, and `decline` was
  honoured anyway. Offer the listed ones plus `decline`.
- **What asks** depends on policy and sandbox, not on tools: `untrusted` × `workspace-write`
  asked for both the `apply_patch` inside the workspace and the `touch`; `on-request` ×
  `workspace-write` asked for neither; `never` × `read-only` ran `cat` without a word.
- `item/permissions/requestApproval {cwd, reason, permissions}` →
  `{permissions, scope, strictAutoReview?}` asks for wider sandbox access (types).

### Questions: `item/tool/requestUserInput` (verified, plan mode only)

Seen in experimental plan mode, asked to put a question first:

```jsonc
{"method":"item/tool/requestUserInput","id":0,"params":{"threadId":"…","turnId":"…",
  "itemId":"call_lo67…","isBlocking":true,"autoResolutionMs":null,
  "questions":[{"id":"language","header":"Language",
    "question":"Should the hello script use Python or shell?","isOther":true,"isSecret":false,
    "options":[{"label":"Python (Recommended)","description":"Create hello.py that prints hello."},
               {"label":"Shell","description":"Create hello.sh that prints hello."}]}]}}
>> {"id":0,"result":{"answers":{"language":{"answers":["Python (Recommended)"]}}}}
```

`thread/status/changed` flags `waitingOnUserInput` meanwhile, and `serverRequest/resolved`
follows the answer. Against Claude's AskUserQuestion: a request of its own, not a
permission; answers keyed by question `id`, not by question text; each answer an array, so
multi-select needs nothing special; `isOther` allows free text; `isSecret` asks for a
masked field; no `preview`. The model put "(Recommended)" in the label itself. Whether the
tool is offered outside plan mode was not seen; the types call it EXPERIMENTAL. A skipped
question's answer is unknown.

### MCP elicitation (types)

`mcpServer/elicitation/request {threadId, turnId | null, serverName, mode, message, …}`,
`mode` being `form` (`requestedSchema`), `url` (`url`, `elicitationId`) or `openai/form`.
Answer `{action: "accept" | "decline" | "cancel", content, _meta}`. Drakar declines, as it
does for Claude. `approvalPolicy: {granular: {mcp_elicitations: false, …}}` turns them off.

## Mode, model, effort

### Approval policy × sandbox

`approvalPolicy`: `untrusted` | `on-request` | `never` |
`{granular: {sandbox_approval, rules, skill_approval, request_permissions, mcp_elicitations}}`.
`sandbox`: `read-only` | `workspace-write` | `danger-full-access`. `approvalsReviewer`: `user`
(default) | `auto_review` (a reviewing subagent decides) | `guardian_subagent` (types).

Against Claude's permission modes, as a starting point (behaviour verified only where the
probes went):

| Claude mode | Codex | Note |
| --- | --- | --- |
| `default` | `untrusted` × `workspace-write` | asks for edits and for any command not known safe (verified) |
| `acceptEdits` | `on-request` × `workspace-write` | edits **and** sandboxed commands in the workspace run unasked (verified); asks only to leave the sandbox |
| `plan` | `collaborationMode: {mode: "plan"}` (experimental) | below |
| `auto` | `approvalsReviewer: "auto_review"` | types |
| `bypassPermissions` | `never` × `danger-full-access` | never run here |

There is no `set_permission_mode`: send `approvalPolicy` and `sandboxPolicy` with the next
`turn/start` (they persist), or the experimental `thread/settings/update`.
`thread/settings/updated {threadId, threadSettings}` reports the result (verified when
`turn/start` switched to plan mode).

### Plan mode (verified, experimental)

With `experimentalApi`, `collaborationMode/list` answered
`[{name: "Plan", mode: "plan", reasoning_effort: "medium"}, {name: "Default", mode: "default"}]`,
and a turn started with
`"collaborationMode": {"mode": "plan", "settings": {"model": "gpt-6-astra",
"reasoning_effort": "low", "developer_instructions": null}}` asked its question, ran a
read-only command, streamed a `plan` item (53 `item/plan/delta` lines, a numbered Markdown
list) and ended the turn. **No request asks to approve the plan**, unlike ExitPlanMode:
going ahead is presumably the next `turn/start` with `mode: "default"` and a prompt. The
wording Codex's own clients send is not known.

### Models and effort

`model/list {cursor?, limit?, includeHidden?}` → `{data: [Model], nextCursor}`, no model
call (verified):

```jsonc
{"id":"gpt-6.1-sol","model":"gpt-6.1-sol","displayName":"GPT-6.1-Sol",
 "description":"Latest workhorse model for coding and everyday work.","hidden":false,
 "isDefault":true,"defaultReasoningEffort":"low",
 "supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast responses with lighter reasoning"},
   …,{"reasoningEffort":"ultra","description":"Maximum reasoning with automatic task delegation"}],
 "inputModalities":["text","image"],
 "serviceTiers":[{"id":"priority","name":"Fast","description":"2x speed, increased usage"}],
 "defaultServiceTier":null,"multiAgentVersion":"v2","upgrade":null,"availabilityNux":{…}}
```

Seven models on this account. Efforts `low`, `medium`, `high`, `xhigh`, `max`, plus
`ultra` on all but the two Luna models. `ReasoningEffort` is typed as a free string: take
the list from the model. Set both per turn (`model`, `effort` on `turn/start`, persisting);
the thread reports them as `model` and `reasoningEffort`. Claude's fast mode has a
counterpart in `serviceTier: "priority"`. A model can be swapped by the server
mid-turn: `model/rerouted {fromModel, toModel, reason}` (types).

## Usage and limits (verified)

**`thread/tokenUsage/updated`** follows every model request:

```jsonc
{"threadId":"…","turnId":"…","tokenUsage":{
  "total":{"totalTokens":42676,"inputTokens":42628,"cachedInputTokens":28288,
           "cacheWriteInputTokens":0,"outputTokens":48,"reasoningOutputTokens":0},
  "last": {"totalTokens":21369,"inputTokens":21364,"cachedInputTokens":21120,
           "cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},
  "modelContextWindow":258400}}
```

- `total` adds up every request of the thread and outgrows the window; **`last` is the
  context now**, `last.totalTokens / modelContextWindow` the meter. `inputTokens` includes
  `cachedInputTokens`, the opposite of Claude's `usage` (Armada's notes; every line here is
  consistent with it: `totalTokens` is `inputTokens + outputTokens`).
- After a compaction, `last` read `{totalTokens: 5598, every other field 0}`: the size of
  the compacted context.
- No breakdown by category, nothing like `get_context_usage`. No cost in money: a ChatGPT
  plan has none to report.

**`account/rateLimits/updated`** follows each usage line:

```jsonc
{"rateLimits":{"limitId":"codex","planType":"plus",
  "primary":{"usedPercent":2,"windowDurationMins":300,"resetsAt":1791317294},
  "secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1791792475},
  "credits":{"hasCredits":false,"unlimited":false,"balance":"0"},
  "rateLimitReachedType":null,"spendControlReached":null, …}}
```

`usedPercent` is 0–100 (Claude's `utilization`, 0–1), `resetsAt` epoch seconds, the windows
named by length rather than by key. **`account/rateLimits/read` answers at any time without
a model call**, adding `ordinaryUsageAllowed`, `rateLimitsByLimitId`,
`rateLimitResetCredits {availableCount, credits: [{title, expiresAt, …}]}` and `accountId`.
That closes the gap Armada's notes describe ("Codex states its limits only as a side effect
of a turn"): a process can ask. `account/read` gives `{account: {type, email, planType},
requiresOpenaiAuth, workspaceRouting}`. **`requiresOpenaiAuth` is `true` when signed in
too**: not signed in is `account: null` (verified 2026-10-07 with an empty `CODEX_HOME`).

## Compaction (verified)

`thread/compact/start {threadId}` → `{}`, then a turn of its own: `turn/started`, a
`contextCompaction` item (started, then completed eight seconds later), a usage line,
`turn/completed`. The deprecated `thread/compacted` notification was not sent. Automatic
compaction mid-turn is presumably the same item; not seen.

## Noise to tolerate (verified)

- **`mcpServer/startupStatus/updated`**: one line per configured MCP server per state, per
  thread start: 222 in the first capture (111 `starting`, 80 `failed`, 31 `ready`). Opt out
  in `initialize`; `mcpServerStatus/list` answers when the state is wanted.
- **stderr**: the same servers' failures again, as `ERROR` lines.
- `remoteControl/status/changed` and `account/updated` at start; `thread/goal/cleared` on
  resume; `deprecationNotice` on full-history reads; `thread/settings/updated` on a mode
  change.
- `turn/diff/updated` re-sent with an unchanged diff after every model request;
  `account/rateLimits/updated` after every `thread/tokenUsage/updated`.
- `thread/started` after the `thread/start` response it repeats.
- Large answers: `skills/list` carries every skill with its full description (plugins'
  included), `model/list` marketing copy (`availabilityNux`).

## Files on disk

Armada's [codex-sessions.md](../../armada/docs/codex-sessions.md) (measured on this Mac
against 0.152–0.153) has the detail; what Drakar needs from it, rechecked where marked:

- **Rollouts** are `~/.codex/sessions/YYYY/MM/DD/rollout-<local time>-<id>.jsonl`, the day
  and time local, not UTC (verified: `rollout-2026-10-06T17-13-49-01a111c7-….jsonl` for a
  thread created 15:13Z). The app-server hands the path over as `thread.path`. Ephemeral
  threads write none (verified).
- **Session to folder**: `session_meta.cwd` in the rollout's first line, or `thread.cwd`,
  and `thread/list {cwd}` filters by it (verified).
- **Titles**: `session_index.jsonl`, last line per id wins (verified written by
  `thread/name/set`).
- **Live**: `thread-writer-locks/<id>.lock`, a zero-byte flock held while a process has the
  thread loaded, idle or not (verified for app-server). No pid inside; a crash may leave one.
  `thread/list`'s `status` only knows about its own process.
- **Accounts**: `CODEX_HOME` per account (verified above); profiles as
  `$CODEX_HOME/<profile>.config.toml`.
- **Subagents** have their own rollouts, with `parent_thread_id`, and a `session_id` that is
  the parent's: key on the filename id (Armada; not rechecked).
- Armada's "no compaction record" predates this: the protocol has the `contextCompaction`
  item; whether rollouts now record it was not checked.

## Open questions

- **`turn/plan/updated` never came.** Three tries asked for a 3-step plan through the plan
  tool, ephemeral and persistent, on `gpt-6-astra` and `gpt-5.6-luna`; each time the model
  said it had no plan tool ("unavailable in this non-persistent thread", then simply "No plan
  tool is available"). The notification's shape, `{explanation, plan: [{step, status:
  pending | inProgress | completed}]}`, is from the types. Possibly gated by a feature flag
  or by the code-mode `exec` tool the rollout shows wrapping `apply_patch` and
  `exec_command`.
- How a plan-mode plan is approved and what Codex's own clients send to go ahead.
- `item/tool/requestUserInput` outside plan mode; what an empty or skipped answer does.
- `acceptForSession` on a command, `acceptWithExecpolicyAmendment` (where the rule is saved),
  `item/permissions/requestApproval`, network approvals, `mcpServer/elicitation/request`:
  none exercised.
- Whether `serverRequest/resolved` also withdraws a request nobody answered (Claude's
  `control_cancel_request`), for instance on interrupt.
- Subagents: do a child thread's notifications arrive on the same connection, and does
  `collabAgentToolCall` stream?
- `error {error, willRetry}` (the retry notice), a `failed` turn, and the `model/rerouted`
  case: not seen.
- Whether experimental methods are refused without `experimentalApi`.
- Size limits on `localImage` and data URLs.
- Whether closing stdin mid-turn leaves a clean rollout, as SIGTERM does for Claude.

## Against Claude Code

What each stream-json concept Drakar uses becomes. **V**: verified 2026-10-06 with 0.160.1;
**T**: from the generated types; **E**: experimental API.

| Claude Code (stream-json) | Codex app-server | | Note |
| --- | --- | --- | --- |
| `initialize` reply: `commands`, `models`, account | `model/list`, `account/read`, `account/rateLimits/read`, `skills/list` | V | Separate calls, none costs a model request. |
| `system/init` (session id, cwd, model, permission mode, tools, MCP servers) | `thread/start` / `thread/resume` response, then `thread/started` | V | Once per thread, not per turn. No tool list; MCP state from `mcpServerStatus/list` (T) or startup notifications. |
| Session id | `thread.id` (UUIDv7) | V | `sessionId` differs only for subagents. |
| `user` prompt line | `turn/start {threadId, input}` | V | Returns the turn id. |
| `assistant` text block | `agentMessage` item | V | One item per message, complete on `item/completed`; nothing to merge by message id. `phase` tells commentary from the final answer. |
| `assistant` thinking block | `reasoning` item, `summary[]` | V | Summary only; `content` stays empty. Empty items at low effort. |
| `tool_use` Bash | `commandExecution` item | V | `command` wrapped in `zsh -lc`; `commandActions` parsed. |
| `tool_use` Read, Grep, Glob | `commandExecution` with `commandActions` `read`, `search`, `listFiles` | V | No separate tools: the shell does it. |
| `tool_use` Edit, Write | `fileChange` item, `changes[].diff` | V | Add: the content. Update: header-less hunks. `turn/diff/updated` has a real git diff. |
| `tool_use` MCP tool | `mcpToolCall` item | T | |
| `tool_use` WebSearch / WebFetch | `webSearch` item | T | No fetch counterpart seen. |
| `stream_event` `text_delta` | `item/agentMessage/delta {itemId, delta}` | V | Keyed by item, no block index. |
| `stream_event` `thinking_delta` | `item/reasoning/summaryTextDelta {summaryIndex}` (+ `summaryPartAdded`) | V | `textDelta` for raw reasoning is declared, not seen. |
| `stream_event` `input_json_delta` | none | V | `item/started` carries the whole command or patch. |
| `stream_event` `message_start` / `content_block_start` / `_stop` | `item/started` / `item/completed` | V | |
| `user` `tool_result` + `tool_use_result` | the same item's `item/completed`: `aggregatedOutput`, `exitCode`, `status` | V | Live output via `item/commandExecution/outputDelta`. |
| `control_request` `can_use_tool` | server requests `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval` | V (first two) | Answer `{decision}`. The item is already started, diff included. |
| `allow` / `deny` | `accept` / `decline` | V | `decline` lets the turn continue, the model told "rejected by user". |
| `deny` with `interrupt: true` | `cancel` | V | Item declined, turn `interrupted`. |
| `permission_suggestions` ("don't ask again") | `acceptForSession`, `acceptWithExecpolicyAmendment`, `proposedNetworkPolicyAmendments`; `availableDecisions` lists the offer | V (offered) / T (effect) | |
| `control_cancel_request` | `serverRequest/resolved {requestId}` | V (after an answer) | Sent for every resolved request; as a withdrawal, unverified. |
| AskUserQuestion | `item/tool/requestUserInput` | V, E (plan mode) | A request of its own; answers keyed by question id, arrays of labels or text; `isOther`, `isSecret`; no `preview`. |
| `elicitation` | `mcpServer/elicitation/request` | T | Decline. |
| ExitPlanMode | `plan` item (`item/plan/delta`), then the turn ends | V, E | No approval request; going ahead is a new turn in default mode (unverified). |
| `set_permission_mode` `plan` | `collaborationMode: {mode: "plan"}` on `turn/start` | V, E | |
| `set_permission_mode` other modes | `approvalPolicy` + `sandboxPolicy` on the next `turn/start`; `thread/settings/update` | V / E | Persist for later turns. Mapping table under "Mode, model, effort". |
| TodoWrite | `turn/plan/updated {explanation, plan: [{step, status}]}` | T | Whole list each time. Never emitted in three tries. |
| Agent / Task subagents, `parent_tool_use_id` | `collabAgentToolCall` and `subAgentActivity` items; child threads with `parentThreadId` | T | Keyed by thread id, not by a parent tool-use id. |
| `task_started` / `task_progress` / `task_notification` | `collabAgentToolCall.agentsStates`, `subAgentActivity.kind` | T | |
| `result` | `turn/completed {turn: {status, error, durationMs}}` | V | No cost. Usage arrives separately. |
| `result` error subtypes, `is_error` | `turn.status: "failed"`, `turn.error.codexErrorInfo`; `error` notification | T | |
| `interrupt` | `turn/interrupt {threadId, turnId}` → `{}`; `turn/completed` `interrupted` | V | The running command keeps running and completes later under the old turn id. |
| `interrupt` with `cancel_queued` | none | | No stable queue. |
| `set_model` | `model` on `turn/start` | T | Persists. `turn/settings/update` (E) changes a running turn. |
| Effort (`apply_flag_settings` `effortLevel`) | `effort` on `turn/start` | V | Levels from `model/list` `supportedReasoningEfforts`; `ultra` adds delegation. |
| `get_context_usage` | `thread/tokenUsage/updated`: `last.totalTokens`, `modelContextWindow` | V | Pushed after each request and on resume; no categories. |
| `rate_limit_event` | `account/rateLimits/updated`; `account/rateLimits/read` | V | `usedPercent` 0–100, `resetsAt` epoch seconds, windows by `windowDurationMins`. |
| `compact_boundary` | `contextCompaction` item | V (manual) | Its own turn when started by `thread/compact/start`. No `pre_tokens`: compare usage before and after. |
| `system/status` `compacting` | `item/started` `contextCompaction` | V | |
| `api_retry` | `error {error, willRetry: true}` | T | |
| `system/notification` | `warning {threadId, message}`, `configWarning`, `deprecationNotice`, `guardianWarning` | V (`deprecationNotice`) / T | |
| `rename_session`, `custom-title` | `thread/name/set` → `thread/name/updated`; `session_index.jsonl` | V | |
| `ai-title` | none seen | V | `thread.preview` is the first prompt. |
| `--resume` | `thread/resume {threadId, …settings}` | V | Pass the settings again. No replay: history from `thread/items/list`, which needs no resume. |
| Transcript as history source | `thread/items/list` | V | Declined commands are missing. |
| `--fork-session` | `thread/fork {threadId, lastTurnId?}` | V | `forkedFromId` recorded; name copied. |
| `sessions/<pid>.json` registry | `thread-writer-locks/<id>.lock`; `thread/loaded/list` per process | V | One writer per thread, enforced. |
| Image blocks | `localImage {path}`, `image {url}` (data URL) | V | |
| Document blocks (PDF, text) | none | T | A path in the text or a `mention`, or inline text. |
| Editor context text blocks | `text` input, or `mention {name, path}` | T | |
| Prompt sent mid-turn (held to the next tool boundary) | `turn/steer {expectedTurnId}`; `turn/start` while busy does the same | V | Joins the running turn, a second `userMessage` item. |
| `command_lifecycle`, `cancel_async_message` | none; `thread/queue/*`, `thread/queue/changed` | E | |
| Slash commands (`commands`, `commands_changed`) | none server-side; `skills/list` and `skill` input; `skills/changed` | V (`skills/list`, `skill`, 2026-10-08) / T | A `skill` item beside the text runs the skill (Skills). Built-ins become methods: `/compact` `thread/compact/start`, `/review` `review/start`, `/model` `model/list`, `/new` `thread/start`. |
| `mcp_status` | `mcpServerStatus/list`, `mcpServer/startupStatus/updated` | T / V | |
| `hook_callback` | `hook/started`, `hook/completed` (observe only) | T | |
| `--permission-prompt-tool stdio` | always on | V | Approvals reach the client whenever the policy asks and `approvalsReviewer` is `user`. |
| `--include-partial-messages` | always on | V | Deltas cannot be turned off, only opted out by method name. |

What this suggests for a shared event type: an item model with `started` / `delta` /
`completed` keyed by item id fits both (Claude's per-block `assistant` lines and
`stream_event` indexes map onto it); turns start and end explicitly in both; approvals and
questions are requests with an id in both, answered once, each with its own answer shape;
usage and limits are side channels, not part of a turn's result.

## 0.162.1 (checked 2026-10-12)

The bindings `generate-ts` writes for 0.160.1 and 0.162.1 differ in nothing Drakar reads or
sends: `thread/prediction/updated` (notification) and `thread/attachmentOwner/list` (request)
are new; `MessagePhase` adds `partial_answer`; `Turn` and `TurnStartParams` add
`rootTurnId` (and `parentTurnId` on the start); a collab agent item adds `model` and
`reasoningEffort`; skill paths are typed `LegacyAppPathString`, still a plain string;
`CodexErrorInfo` may be any string or object. The same approval and steer scenario, run on
both with Drakar's request shapes, differs only in when a steer is taken (above, "Prompts
sent mid-turn"). Tested with the npm package `@openai/codex@0.162.1-darwin-arm64`, signed
by the same team (`2DC432GLL2`) as the Homebrew cask.

## Raw captures

The claims marked verified come from eleven probes run on 2026-10-06 against codex-cli
0.160.1, each a small Python driver speaking JSON-RPC to `codex app-server` over stdio: one
read-only turn; the handshake (errors before and after `initialize`, string ids, opt-out);
file and command approvals (accept, decline, cancel, under `untrusted` and `on-request`);
interrupt during `sleep 20` and the late completion, steer; resume, fork and a second writer;
reasoning; the plan tool (missing); experimental plan mode; images; an update diff and
`thread/compact/start`; an empty `CODEX_HOME`. Three more on 2026-10-07: an update, a delete and a
rename in one patch; steers (mid-turn, after the answer, before an interrupt); a persistent
thread's `thread/items/list` from a fresh process, then `thread/delete`; `account/read` with
an empty `CODEX_HOME`. The logs were not kept: they hold the account's
ids and email. Scrubbed, hand-trimmed excerpts are in
`apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/`: `codex-turn.jsonl`
(reasoning, a file change after an approval, a declined command, usage, the end),
`codex-file-changes.jsonl` (update, delete, rename), `codex-steer.jsonl` (a steered prompt's
`clientId`) and `codex-items-page.json` (one history page), which `CodexTranslator`'s tests
fold. To capture more, drive `codex app-server` the same way in a scratch folder, with
`ephemeral: true` threads so nothing lands in the account's history, and scrub ids, emails,
the installation id and paths before anything reaches a fixture.
