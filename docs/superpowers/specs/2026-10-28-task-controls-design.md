# Subagent and task controls

A running subagent or a long Bash command can only be watched in Drakar today. The VS Code
extension can stop it, move it to the background, show a background command's output as it
grows, and open a subagent's whole conversation, including after a reload. After this, Drakar
does the same, on the cards where those calls already show. This is the first batch adopted in
`docs/extension-parity.md`: `stop_subagent`, `run_in_background`, `get_task_output` and
`get_subagent_transcript`.

## Why

PLAN.md's second promise is that nothing is lost against the extension, subagents named among
the things it covers. On 2026-10-27 the parity ledger marked these four `adopt`. Three are one
control request each, which `claude` already answers, so the work is UI. The fourth reads a
file the CLI already writes.

## What the CLI and the extension do

Read from extension 2.1.312's `extension.js` (the Agent SDK it bundles) and `webview/index.js`
on 2026-10-28. None of it has been captured live yet: slice 1 captures it. All three requests
are in the 2.1.308, 2.1.311 and 2.1.312 binaries (`strings`); `ClaudeVersion.tested` starts at
2.1.284, where they were not checked.

| Feature | Control request | Reply | Extension UI |
| --- | --- | --- | --- |
| Stop | `{subtype: "stop_task", task_id}` | empty success, or an error | "Stop agent" in its agent map, "Stopping…" while it waits, "The agent could not be stopped. It may have finished already." on an error. A successful stop shows as the task's status (`task_updated` / `task_notification`). |
| Run in background | `{subtype: "background_tasks", tool_use_id}` | `{backgrounded: Bool}` (the SDK reads a missing value as true) | A "Run in background" line on the card of a call that has **no result yet** and a **foreground task** (`task_started` with `is_backgrounded: false`), for the tools `Bash`, `PowerShell`, `Agent` and `Task`. `backgrounded: false` → "Could not move this to the background. It may have just finished or already be running in the background." An error containing "Background tasks are disabled in this session." → "Moving to the background is turned off for this session." and the line is hidden for the rest of the session. Any other error → "Could not move this to the background. Try again." |
| Task output | `{subtype: "get_task_output", task_id}` | `{output, total_bytes, truncated}` | Polled every **1 s** while the view is open, the window visible and the task running. "No output yet." when empty, "Showing the end of …" when truncated. |
| Subagent transcript | none: the host reads a file | | "Open transcript", from the agent map. It follows the file while the agent runs. |

The subagent's file is `<session transcript without .jsonl>/subagents/agent-<agentId>.jsonl`.
Every line in it has `isSidechain: true`. Its `agentId` is the stream's `task_id` (both
fixtures, `subagent-and-todos` and `fork-subagent`). In history it is the `Agent` call's
`toolUseResult.agentId`. The `agent-<id>.meta.json` beside it names the call (`toolUseId`).
All checked on disk on 2026-10-28.

## Goals

1. **Stop.** A card with a task that is running gets a Stop button. That covers an `Agent`
   call, and a `Bash` or `PowerShell` call the CLI tracks as a task (a long foreground command,
   or one in the background). While the request waits, the button reads "Stopping…" and is
   disabled. An error shows under the card's header in the extension's words. Success changes
   nothing at once: the card turns stopped when the CLI says so. A stopped task gets its own
   state, a neutral stop icon and "Stopped", instead of today's red failure mark.
2. **Run in background.** A card that meets the extension's conditions (above) gets a "Run in
   background" button, with the extension's three outcomes and the per-session hiding. Once
   the CLI moves the call, the card reads as a background one, as it already does for a call
   the model sent to the background.
3. **Output.** A background `Bash` or `PowerShell` task's card gets an Output section, closed
   by default. Open, it shows the output's tail in a monospaced, selectable block, polled
   every second while the task runs and the window is key or visible, plus one last fetch
   when the task ends. "No output yet." and "Showing the end of 12 KB" follow the extension.
4. **Subagent transcript.** An expanded `Agent` card shows the subagent's whole conversation
   from its file: its text and thinking, and its tool calls with their results. While the
   subagent runs, the file is followed. This works for a resumed session, for one read-only
   because another process holds it, and for one that ended. When there is no file (an older
   CLI, a moved account, a deleted folder), the card shows what it shows today: the calls
   streamed while it ran.

## Non-goals

- The extension's agent map, a panel listing every agent and task. The cards are Drakar's
  view of them. A list in the inspector can follow if a session's cards get too many to scan.
- Codex. None of this applies to its sessions, and `AgentFeatures` hides it there.
- Stopping, or moving to the background, from a session's sidebar row, or several calls at
  once.
- Writing a subagent's transcript anywhere, or editing it.

## Anti-goals

- A control on a session Drakar does not drive: read-only (held elsewhere), ended, moving,
  reconnecting. Sending a control request there writes to a process that isn't ours, or to
  none. Reading the transcript file is fine anywhere.
- Polling that runs while nobody can see it: a closed Output section, a hidden window, an
  ended task.
- A click that does nothing visible. Every request ends either in the state the CLI then
  reports or in one of the extension's messages, never in silence. A reply that never comes
  leaves the button usable again after 10 s.
- Reading a whole large transcript to draw a card that is closed. The file is read only when
  the card is expanded.

## Decided

- The controls live on the cards, where the calls already show, rather than in a panel.
- The extension's words, unchanged, for every outcome it names. Drakar's own text is only
  "Stop", "Stopping…", "Stopped", "Run in background" and "Output".
- The file wins over the stream for a subagent's inner conversation whenever the file exists,
  live or not. The file carries text and thinking that a foreground subagent never streams.

## Calls made without asking

Each of these came out of the builder check. Each is the writer's call, not something the
person said.

- **Versions.** No version gate. Drakar gates nothing else by CLI version: the footer already
  warns outside `ClaudeVersion.tested`. Slice 1 raises `tested` to 2.1.312 with the usual
  full pass over the earlier scenarios, which is due anyway (the installed CLI is 2.1.312 and
  the range ends at 2.1.308). A CLI that refuses a subtype it doesn't know gets the same
  outcome as any other error: "Try again." for Run in background, and the extension's Stop
  sentence for Stop. The CLI's own error text goes in that message's tooltip, because nothing
  tells an unknown subtype apart from a task that already ended.
- **A background Bash or PowerShell card.** `ToolCallView` gets the call's task, as
  `AgentCallView` does. While that task runs in the background, the card shows a spinner and
  "Running in the background" instead of the green check its immediate result would give it.
  It shows its end state when the task ends. After a reload there are no `task_*` lines, and
  the card shows what history knows, as today.
- **Stopped, everywhere it is reported.** Every task the CLI reports `stopped` or `killed`
  shows "Stopped", whoever stopped it. That includes Esc, which today shows red. Live only:
  history isn't parsed for it.
- **Output is live only.** It shows while the session is driven and the task ran in this
  process. The last tail stays on the card until the window closes. Output is not read from
  the task's output file, which is temporary.
- **Forks.** The subagent file is looked up under the session's own folder, then under the
  other session folders beside it in the same project folder. Agent IDs are random and
  unique, so a match there is the original's. `Transcript` does not keep the `sessionId` of
  each call's line, so the sibling scan replaces the lookup by `sessionId` first written
  here.

## Left to the builder

- How replies reach the card. Today `ClaudeBackend` routes control responses by request-ID
  prefix to `BackendSignal`s. New signals per reply are the obvious route.
- Where the task's ID and type live. `TaskEvent` decodes `task_id`, but `AgentTaskUpdate` and
  `AgentTask` drop it. `task_type` (`local_agent`, `local_bash`) isn't decoded at all.
- Decoding the subagent file. `History.history` drops sidechain lines (`ClaudeTranslator`,
  `historyLines`), and every line of this file is one. A variant that keeps them, or a
  translator flag, both work. `TranscriptFollower` already follows a file from an offset.
- The 10 s timeout and the exact layout of the buttons on the card.

## Slices

1. **Capture.** Run `stop_task`, `background_tasks` (foreground Bash and foreground Agent,
   plus a session started with `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`) and `get_task_output`
   (a background Bash) against 2.1.312, following the procedure at the end of
   `docs/claude-stream-json.md`. Run the earlier scenarios on 2.1.308 and 2.1.312 in the same
   pass, and raise `ClaudeVersion.tested` to 2.1.312. Trim the captures into fixtures and
   record the shapes in that doc. A shape that differs from the table above changes the plan
   before any UI is built.
2. **Kit.** The three `ClientMessage`s, their replies, the task ID and type on `AgentTask`, a
   stopped status, and the subagent file read into entries. Tested against slice 1's
   fixtures.
3. **App.** The buttons, messages and Output section on the cards, gated by `AgentFeatures`
   and by whether the session is driven. The subagent card reads its file when expanded.
4. **Docs.** The ledger's four rows move to `has` with their evidence, and the protocol doc
   gets the captured section.

## Live checks

Things no kit test can show, done in the running app (never `make run`, which quits the
person's Drakar):

1. Stop a foreground subagent: "Stopping…", then "Stopped" on the card, and the turn goes on.
2. Stop a long foreground Bash command: the same.
3. Run a foreground Bash command in the background. The turn ends and the card reads as
   background. Open Output: the tail grows every second, and stops growing when the window is
   hidden.
4. Run a foreground subagent in the background, then reload the session. The card shows its
   whole conversation from the file.
5. A session started with `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`: the first attempt says
   it's turned off, and no card offers it again.
