# Driving Claude Code over stream-json

Findings from a spike run on 2026-10-03 against Claude Code 2.1.284 (CLI) and the VS Code
extension 2.1.287. Written so another agent can pick the protocol up cold, and so the
fixtures in `DrakarKit`'s tests have a record of where they came from.

## Verdict

- **The extension is a UI over the same binary.** It bundles `resources/native-binary`
  and spawns it with exactly the arguments below. Nothing it does over this channel is
  out of reach of another app.
- **The whole loop works from outside:** initialize, send a prompt, stream the answer,
  answer a permission request, receive the result. Verified end to end: a `touch` the CLI
  asked permission for ran after Drakar's `allow`, and the file existed afterwards.
- **None of this is documented as a protocol.** The Agent SDK (TypeScript, Python) wraps
  it, and the extension uses it, so it is stable in practice, but any release can add a
  field or a message type. Decode leniently, keep unknown messages, never crash on one.

## Spawning

```sh
claude --output-format stream-json --verbose --input-format stream-json \
       --permission-prompt-tool stdio [--include-partial-messages] \
       [--resume=<session-id>] [--model <id>]
```

- `--verbose` is required with `--output-format stream-json`; the extension always passes it.
- `--permission-prompt-tool stdio` turns permission prompts into `can_use_tool` control
  requests on stdout, answered on stdin. Without it a non-interactive session can only
  run what its settings already allow.
- `--include-partial-messages` adds `stream_event` lines (the raw Messages API stream:
  `message_start`, `content_block_start`, `content_block_delta`, …). Without it the UI
  gets each content block whole, after it finished.
- One JSON object per line in both directions. stderr is diagnostics, not protocol.

## Messages the CLI writes (stdout)

Every line has `type`. Observed in the spike, in order of a turn:

| `type` | `subtype` / shape | Notes |
| --- | --- | --- |
| `control_response` | `response.subtype = success`, `response.request_id` | The answer to our `initialize`; carries `commands` (slash commands, skills), models, account. |
| `system` | `init` | `session_id`, `cwd`, `model`, `permissionMode`, `tools`, `mcp_servers`, `slash_commands`, `claude_code_version`, … |
| `system` | `status` (`status: requesting`) | Emitted before each API request. |
| `rate_limit_event` | `rate_limit_info` | `status` (`allowed` / `rejected`), `rateLimitType`, `unifiedWindows.five_hour` / `seven_day`: `utilization` 0–1, `resetsAt` epoch seconds. The account's `.claude.json` caches the same windows as `cachedUsageUtilization` (0–100, ISO-8601 `resets_at`). |
| `stream_event` | `event: {type: message_start \| content_block_start \| content_block_delta \| content_block_stop \| message_delta \| message_stop}` | Only with `--include-partial-messages`. Deltas seen: `text_delta`, `thinking_delta`, `signature_delta`, `input_json_delta`. |
| `assistant` | `message` (an API message) | **Emitted once per content block, not once per message.** A thinking block and a tool_use block of the same turn arrive as two `assistant` lines sharing one `message.id`, each holding only its own block. Merge by `message.id`. |
| `user` | `message.content[]` of `tool_result` | Plus `tool_use_result` with the tool's structured output (Bash: `stdout`, `stderr`, `interrupted`). |
| `control_request` | `request.subtype = can_use_tool` | `tool_name`, `display_name`, `input`, `description`, `permission_suggestions[]`, `blocked_path`. Must be answered or the turn waits forever. Other subtypes: "Lines beside the conversation" below. |
| `result` | `success` (also error subtypes) | `session_id`, `total_cost_usd`, `usage`, `duration_api_ms`, `stop_reason`. Ends a turn, not the process. |

Every line after init carries `session_id` and a `uuid`; model output carries
`parent_tool_use_id`, non-null inside a subagent.

## Messages we write (stdin)

```jsonc
// once, first
{"type":"control_request","request_id":"req_init","request":{"subtype":"initialize","hooks":null}}
// a prompt; content may also be an array of content blocks (images)
{"type":"user","session_id":"","parent_tool_use_id":null,
 "message":{"role":"user","content":"…"}}
// answering can_use_tool
{"type":"control_response","response":{"subtype":"success","request_id":"<theirs>",
 "response":{"behavior":"allow","updatedInput":{…}}}}
//   or {"behavior":"deny","message":"why"}
```

The process stays alive between turns; closing stdin after a `result` ends it cleanly
(exit 0).

**Editor context.** The extension's chat sends what the editor shows as a text block ahead
of the prompt, in the same `content` array (webview 2.1.288, `LC1`): the selection with its
lines counted from 1, or only the open file when nothing is selected.

```text
<ide_selection>The user selected the lines 3 to 5 from /p/main.swift:
<the selected text>

This may or may not be related to the current task.</ide_selection>

<ide_opened_file>The user opened the file /p/main.swift in the IDE. This may or may not be related to the current task.</ide_opened_file>
```

Drakar sends the same (`EditorSelection.promptContext`). Verified on 2026-10-03 with
2.1.288: with `src/main.swift` open and nothing else said, "Which file do I have open in my
editor?" got `main.swift`; without the block the model says it cannot know. The transcript
keeps both blocks, and history shows them as a label on the prompt.

## AskUserQuestion (verified 2026-10-04, 2.1.288)

The tool asks for permission like any other, as a `can_use_tool` request, with one field
more:

```jsonc
{"type":"control_request","request_id":"…","request":{"subtype":"can_use_tool",
 "tool_name":"AskUserQuestion","display_name":"AskUserQuestion",
 "input":{"questions":[{"question":"Which filename would you prefer?","header":"Filename",
   "options":[{"label":"a.txt","description":"Name the file a.txt"},
              {"label":"b.txt","description":"Name the file b.txt"}],
   "multiSelect":false}]},
 "tool_use_id":"toolu_…","requires_user_interaction":true}}
```

- **The answer rides in `updatedInput`**: `allow` with the request's `input` plus
  `"answers": {"<question text>": "<chosen label>"}`. The tool result the model gets is
  `Your questions have been answered: "Which filename would you prefer?"="a.txt". You can
  now continue with these answers in mind.`, and it went on with `a.txt`.
- **A plain `allow`** (the input unchanged) gives the model `The user did not answer the
  questions.`, and it gives up. So a sheet that only offers Allow and Deny cannot answer one:
  the options have to be shown and the picked label sent back.
- **Closing stdin while the request is pending** fails the call with
  `Tool permission request failed: AbortError: Stream closed`.

What the VS Code extension (2.1.289) does with it, read from its webview bundle on
2026-10-05, and what Drakar copies:

- **An option may carry `preview`**, text shown beside the options while it is pointed at:
  Markdown when it holds a fence, monospaced otherwise. 4 of 10 calls in real transcripts
  had one.
- **The result says what was answered twice.** The `tool_result` text is
  `Your questions have been answered: "<q>"="<a>", "<q2>"="<a2>". You can now continue…`
  (newer CLIs: `The user answered: … . Read the answers carefully…`), and the user line
  beside it carries `tool_use_result` (stream) or `toolUseResult` (transcript) as
  `{questions, answers}`. The structured one is read first, the text as a fallback. A
  multi-select answer reads back as its labels by the longest that start it, each followed
  by a comma and a space, the rest typed.
- **Skip is the standard rejection** (`The user doesn't want to proceed with this tool use.
  … STOP what you are doing and wait for the user to tell you how to proceed.`), not a
  bespoke message, so the model waits instead of guessing. Other endings: `The user did not
  answer the questions.` (a plain `allow`), `[Request interrupted by user for tool use]`,
  and, for a process that went away, `Tool permission request failed…` or `[Tool call
  interrupted…`.
- **A question whose process ended before an answer is offered again** when the session is
  reopened (not while another process has it), and the answer goes as a prompt:
  `Answering your earlier question "<q>": <a>`, or for several,
  `Answering your earlier questions:` then a `- "<q>": <a>` line each. The extension reads
  such a prompt back to mark the question answered, and so does Drakar.

## Interrupting (verified 2026-10-03)

```jsonc
{"type":"control_request","request_id":"req_int","request":{"subtype":"interrupt"}}
```

The CLI answers within milliseconds with `control_response` success
(`{"still_queued":[]}`), flushes the block it was writing as an `assistant` line, writes
a user turn whose content is the text `[Request interrupted by user]`, and ends the turn
with a `result` whose `subtype` is `error_during_execution` and `is_error` true. Only
`terminal_reason: "aborted_streaming"` says it was an interrupt, not a failure. The
process stays up and takes the next prompt normally (`terminal_reason: "completed"`).
Captured as the `interrupt-then-turn` fixture.

Other control subtypes the extension sends, unverified here:
`set_max_thinking_tokens`, `rewind_files`,
`mcp_toggle`, `get_usage`, and the CLI may send
`control_cancel_request` to withdraw a pending `can_use_tool`.

## Skills and MCP status (verified 2026-10-04, 2.1.288)

A process started with Drakar's arguments answers two control requests before any prompt,
in 1.2 to 1.8 s, and writes no transcript:

- **`initialize`**: the reply's `response.commands` lists every command, each
  `{name, description, argumentHint}`, with `builtin: true` on the CLI's own (58 of 161 on
  the spike's Mac) and `aliases` on some. `argumentHint` is always there; `""` means the
  command takes no arguments. `builtin` covers the skills the CLI bundles too (`simplify`,
  `code-review`, `loop`): nothing tells them from `compact`. Plugin skills are namespaced
  (`superpowers:brainstorming`), and their description starts `(superpowers) `.
- **`mcp_status`**, sent as `{"type":"control_request","request_id":"…","request":
  {"subtype":"mcp_status"}}`: the reply's `response.mcpServers` lists every server, each
  `{name, status, source, scope, config}`, plus `serverInfo` (`name`, `title`, `version`)
  and `tools` (`[{name, annotations: {readOnly, destructive}}]`) once connected, and `error`
  when failed. Statuses seen: `connected`, `needs-auth`, `failed`, `pending`. Sources:
  `user`, `plugin` (scope `dynamic`), `claudeai`.

**`config` is the server's configuration as written, secrets included**: a user server's
`headers.Authorization` came back as `Bearer …` in clear. Drakar never decodes it.

**The process registers as a live session** while it runs: `<config>/sessions/<pid>.json`
appears (`status: idle`, `entrypoint: claude-vscode`, a derived name) and is removed when it
exits after its stdin closes. A process killed outright leaves it behind. Drakar's own lists
skip its children (`LiveSession.read`); Armada shows it as an idle session for a second or two.

Captured as the `capabilities` fixture, trimmed, every secret replaced.

## Mode and model (verified 2026-10-06, 2.1.288)

Before any prompt, no API call:

- `initialize`'s reply has `models`, each `{value, resolvedModel, displayName, description,
  supportsEffort, supportedEffortLevels, supportsAdaptiveThinking, supportsFastMode,
  supportsAutoMode}`, first `default`, then the aliases, then pinned ids; and
  `current_permission_mode`.
- `{"subtype":"set_model","model":"sonnet"}` → empty success.
- `{"subtype":"set_permission_mode","mode":"acceptEdits"}` → success `{"mode":"acceptEdits"}`,
  then `{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}`.
  `auto` and `plan` likewise.
- `bypassPermissions` without `--allow-dangerously-skip-permissions` (or
  `--dangerously-skip-permissions`) → error `bypass_not_launched`.
- Transcript prompt lines carry `permissionMode`.

Captured as the `mode-and-model` fixture.

## Effort (verified 2026-10-06, 2.1.288)

Before any prompt, no API call:

- Each of `initialize`'s `models` says `supportsEffort` and `supportedEffortLevels`
  (`low`, `medium`, `high`, `xhigh`, `max` on every model that takes effort); `haiku` has
  neither.
- `{"subtype":"get_settings"}` → `{effective, sources, applied}`; `applied` is
  `{model, effort, advisor, ultracode, …}`, the resolved model id and the effort it runs
  with: `settings.json`'s `effortLevel`, else `--effort`'s, else the model's own. `effort`
  is null on a model without effort.
- `{"subtype":"apply_flag_settings","settings":{"effortLevel":"low"}}` → empty success,
  and `applied.effort` follows. The flag layer is the process's alone: `settings.json` is
  not touched. An unknown level (`bogus`) is a success too, and changes nothing.
- Switching to `haiku` makes `applied.effort` null; back to `opus`, it is the level last
  applied, not the model's default.
- `--effort medium` at launch → `applied.effort` `medium`.

The VS Code extension writes a picked effort into the user's `settings.json`
(`updateSettings("userSettings", {effortLevel})`). Drakar sends it as a flag setting, so a
pick lasts for its session as the model's does.

## Lines beside the conversation (read from the 2.1.288 source, 2026-10-06; not yet captured)

What the CLI says that is not a block of the conversation, and what Drakar does with it.
Read out of the CLI's bundled JavaScript and the extension's (2.1.289), not seen on a live
stream yet:

| Line | Shape | Drakar |
| --- | --- | --- |
| `control_request` `elicitation` | `mcp_server_name`, `message`, `mode`, `url`, `requested_schema` | An MCP server asking the person. Sent whatever the client registered, and **waited on with no deadline**. Declined with `{"action":"decline"}`, as the extension declines it (its host passes no handler), and noted in the transcript. |
| `control_request` `hook_callback`, `mcp_message`, `request_user_dialog` | | Sent only to a client that registered hooks, SDK MCP servers or `supportedDialogKinds` in `initialize`; Drakar registers none. Any subtype Drakar does not serve is answered `{"subtype":"error","error":"Unsupported control request subtype: <x>"}`, the SDK's own answer, so that nothing waits. |
| `result` with an `error_*` subtype | `errors: [String]` (`error_max_turns`, `error_max_budget_usd`, `error_during_execution`) | The reason is in `errors`, not `result`. A failed `success` (an API error) says it in `result`, after an `assistant` line of model `<synthetic>` saying the same. Shown in red unless the last text already says it; an interrupt is not a failure. |
| `system` `api_retry` | `attempt`, `max_retries`, `retry_delay_ms`, `error_status`, `error` | The working indicator reads "Retrying (2/10)" until the next line. |
| `system` `status` `compacting` | `status: "compacting"`, then `compact_result` / `compact_error` | The working indicator reads "Compacting". |
| `system` `compact_boundary` | `compact_metadata: {trigger: auto \| manual, pre_tokens, post_tokens?}` | A note: "Conversation compacted (auto, 617K tokens before)". The transcript file writes the same line camelCased (`compactMetadata.preTokens`), which history does not read: it notes the `isCompactSummary` prompt instead. |
| `system` `notification` | `key`, `text`, `priority`, `color?`, `timeout_ms?` | A note, red when `color` is `error`. |

## Observed details worth knowing

- **Read-only commands never ask.** `echo amiral` ran with no `can_use_tool`; `touch`
  asked. What asks is the CLI's permission engine plus the user's settings, not ours.
- `permission_suggestions` are ready-made "always allow" choices (`addRules` to
  `localSettings`, `addDirectories` for the session, `setMode acceptEdits`). Offering them
  is how the extension's "don't ask again" buttons work.
- `--setting-sources project` keeps user-level hooks and plugins out of a spike run. A
  real session must not pass it: the user's settings are the point.

## Resuming (verified 2026-10-03, 2.1.288)

`--resume=<id>`, run from the session's own folder (the id is resolved against that
folder's project directory), keeps the **same** session id under stream-json and appends
to the same transcript; the model has the earlier turns. It does **not** replay the
history on stdout: no `user` or `assistant` lines for past turns. A UI draws the past from
the transcript file, `<config>/projects/<encoded cwd>/<id>.jsonl`, whose `user` and
`assistant` entries have the stream's shapes (assistant entries one block per line, as
live), plus `ai-title` entries for the title. One id can have a transcript under two
config directories, when a session was resumed after switching `CLAUDE_CONFIG_DIR`.

`--fork-session` with `--resume` continues a copy under a new id, which is how Drakar
opens a session another process has open (the registry at `<config>/sessions/<pid>.json`
says which; Armada's `docs/claude-code-sessions.md` describes it).

## Session titles (verified 2026-10-06, 2.1.288; extension 2.1.289)

A transcript carries two kinds of title line. `ai-title` (`aiTitle`) is the CLI's own
summary, written again as it refines it. `custom-title` (`customTitle`) is a name given
with `/rename`, `--name` or `rename_session`; every writer of one also writes an
`agent-name` line with the same text. The newest `custom-title` wins, and an `ai-title`
never replaces it, even a newer one: the extension's session list reads them that way,
and so does Drakar (`Transcript.title`, `SessionIndex`).

- **A fork copies the original's title.** `--fork-session` starts the new transcript with
  the original's `ai-title` line, verbatim, and keeps it after the fork's own turns, so a
  fork and its original list under the same title unless the fork is named.
- **`--name=<name>`** (one argument, so a name starting with a dash is not read as a flag)
  names a new session or a fork: a `custom-title` line at the head of the transcript,
  written again later. A session started with a name gets no `ai-title` at all.
- **`rename_session`** names a running session, as the extension sends it:

  ```jsonc
  {"type":"control_request","request_id":"…","request":{"subtype":"rename_session",
    "title":"Plum","source":"host","session_id":"<id>"}}
  ```

  The CLI answers `control_response` success at once and appends `custom-title` and
  `agent-name` lines. The process keeps the name for its own later writes.
- **A sidecar, `<projects>/<encoded cwd>/<id>/custom-title.json`** (`{"customTitle":…}`,
  mode 0600 in a 0700 folder), is written beside the transcript by a rename. The CLI's
  `/resume` list takes a `custom-title` from the transcript's tail first, then the
  sidecar, then one from its head. Renaming a session no process has open therefore takes
  both: the line appended to the transcript, and the sidecar rewritten (Drakar's
  `SessionTitle.write`), or the sidecar's old name returns once the line is no longer
  near the end.

## Ending another process's session (verified 2026-10-06, 2.1.288; extension 2.1.289)

How "Move to This Window" takes a session from the app running it. A headless
stream-json `claude` signalled while idle exits in about a second: SIGINT with status 0,
SIGTERM 143, SIGHUP 129. Each time its `sessions/<pid>.json` and the `.key` beside it are
removed and the transcript ends whole (`cost-state` last). SIGTERM mid-turn is clean too:
during thinking, nothing is left half-written; during a Bash call, the CLI kills the
tool's child (exit 137) and writes a `tool_result` with its partial output before
exiting, and a resume reads that turn as cut short. The CLI's own debug log shows the
shutdown is graceful: MCP servers exit cleanly and SessionEnd hooks run.

The VS Code panel whose process got **SIGINT shows nothing**. After **SIGTERM** it shows
"Claude Code process exited with code 143" and the stderr tail. Either way **the next
message typed there resumes the same id** (`--resume=<id>`, a new pid, the same
transcript) without a word. The registry entry can appear already `busy`. So the app a
session moved from can take it back at any time. Drakar sends SIGTERM, which leaves that
panel saying the process ended, and a window running a session gives way the moment
another process registers it (`OpenSessions.liveChanged`).

A `claude` started from a VS Code session's shell registers as `claude-vscode`: the
entrypoint comes from the environment it inherits.

## What the extension passes as of 2.1.288

Read off its running processes on 2026-10-03, beyond the arguments above:
`--setting-sources=user,project,local`, `--thinking-display summarized`,
`--max-thinking-tokens 31999`, `--replay-user-messages` (the CLI echoes prompts back),
`--enable-auth-status`, `--no-chrome`, `--debug --debug-to-stderr`, and the user's
permission mode. Drakar passes `--thinking-display summarized`: without it thinking
blocks arrive with their text withheld; with it they stream as `thinking_delta` text
(checked on 2.1.288). It passes none of the others yet.

Unsettled: whether `result.total_cost_usd` is the turn's cost or the process's running
total. Two consecutive turns read 0.00096 then 0.0063, consistent with either.

## Context usage (measured 2026-10-04, Claude Code 2.1.288)

`{"type":"control_request","request_id":…,"request":{"subtype":"get_context_usage","detail":"summary"}}`
is answered by the process that owns stdin, with `totalTokens`, `maxTokens` (the window:
200000 for the haiku session measured; a `[1m]` variant was not measured) and `categories`
(`name`, `tokens`, `color`, `kind`). `kind` is `used`, `deferred` or `free`; `isDeferred:
true` appears only on deferred categories, never as `false`. The deferred ones (MCP and
system tools, together larger than the whole prompt in the capture) and "Free space" are
listed but are not part of `totalTokens`, so a breakdown has to drop them by `kind`.
Mid-turn: answered in 35 ms (before the turn's
`result`). Between turns: 19 ms. `summary` made no `count_tokens` calls (`--debug` wrote
nothing to stderr in this build, so this rests on the timing: 35 and 19 ms in one run, not
a network round trip). Drakar asks after every `result`. Capture: `Fixtures/context-usage.jsonl`.

## Raw captures

The captures this was written from are trimmed into
`apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/`. Signatures, the init
payload's tool and server lists, and local paths were cut; the shapes were not.
