# Rewind

When the agent took a wrong turn, the VS Code extension lets you go back: put the files back
as they were before one of your prompts, start a new conversation from that prompt, or both.
Drakar can only fork a whole session today (`Project.fork`). After this, each of your prompts
in a Drakar session offers the same three choices. This is the second batch adopted in
`docs/extension-parity.md`: `rewind_code`, and `fork_conversation` from a chosen message.

## Why

The parity ledger marked both `adopt` on 2026-10-27 ("adopt: `rewind_files`, dry run first";
"adopt: from a chosen message, with rewind"). Undoing the agent's edits is the extension's
safety net. Without it, a bad edit in Drakar is undone by hand or with git.

## What the CLI and the extension do

Read from extension 2.1.312 and the 2.1.312 binary on 2026-10-28; the CLI's side captured
live by slice 1 on 2026-10-29 ("Rewind (verified 2026-10-29, 2.1.312)" in
`docs/claude-stream-json.md`).

- **Checkpoints must be on.** The extension starts the CLI with
  `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` in its environment, as Drakar now does
  (Goal 1). Without it the CLI answers "File rewinding is not enabled.".
  `CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING` and the `fileCheckpointingEnabled` setting turn it
  off.
- **Code.** `control_request` `{subtype: "rewind_files", user_message_id, dry_run}`. The reply
  is `{canRewind: Bool, error?, filesChanged?: [path], insertions?, deletions?, skippedLinks?}`.
  `dry_run: true` reports what would change without writing anything. The CLI refuses with
  "No file checkpoint found for this message." for a prompt it has no checkpoint for. A
  refused dry run is a `success` with `canRewind: false` and `error`; a refused real rewind
  is a control `error` with the same string, no `canRewind`. "rewindFiles: no turn received
  yet" is in the binary but not on the stream-json path: a resumed process can rewind before
  its first prompt, to prompts of earlier processes too (stream-json "Rewind", answers 1, 3
  and 4).
- **Conversation.** The extension forks: its host writes a new session that ends at the
  chosen prompt (`forkSession(fromSession, resumeSessionAt)`), with no control request. The
  CLI takes `--resume-session-at <message uuid>`, which beside `--fork-session` does the same.
  It keeps the message it is given, so a fork ending before a prompt passes that prompt's
  `parentUuid`; the first prompt's is null (stream-json "Rewind", answer 5). The prompt's own
  text goes back into the composer, as the extension does (`promptText`).
- **Extension UI.** An undo arrow on each of your prompts opens a menu: "Fork conversation
  from here", and when the code can be rewound, "Rewind code to here" and "Fork conversation
  and rewind code". A sheet then confirms. Its title is "Rewind code" or "Fork and rewind";
  a fork adds "A new forked conversation will be created after rewinding."; it shows "Restored
  files go back whole, losing later changes by anyone. Bash changes to other files are not
  undone."; the buttons are "Rewind" (or "Continue") and "Never mind". Outcomes: "Code rewind
  successful", "Failed to rewind code", "Failed to rewind: no checkpoint for this message".

## Goals

1. **Checkpoints on.** Every Claude Code process Drakar starts gets
   `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true`, unless the person's own environment sets
   `CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING`, which then wins.
2. **The menu.** Each prompt bubble Drakar shows gets an undo arrow (on hover, and in its
   context menu). It offers "Fork conversation from here" on any session that can be forked,
   and "Rewind code to here" and "Fork conversation and rewind code" while Drakar drives the
   session's process and that process has not said rewinding is not enabled.
3. **The sheet.** Choosing a code rewind first sends a dry run, then shows the files it would
   change (paths relative to the session's folder), "+N −M", the warning, and Rewind / Never
   mind. A dry run that says no checkpoint shows the extension's failure line and no Rewind
   button. Rewind sends the real request and reports the outcome in the extension's words.
4. **The fork.** "Fork conversation from here" starts a new session in the same window from
   the chosen prompt, as Drakar's fork does today but cut at that prompt, and puts the
   prompt's text in the new session's composer. "Fork conversation and rewind code" rewinds
   the code in the current session first, then forks.
5. **Files on screen.** After a rewind, editor tabs reload the restored files through the
   folder watcher, and a tab with unsaved edits asks which version to keep, as it does today.

## Non-goals

- Rewinding the conversation in place. The extension forks, and so does Drakar.
- The extension's "Rewind to…" list (Esc Esc). The arrow on each prompt is Drakar's way in.
- Rewinding a session another process drives, or one with no process: a fork is offered
  there, code is not. A session reopened from the list has no process until its first new
  prompt starts one, so until then it offers only the fork.
- Codex.

## Anti-goals

- A file changes without the person seeing the dry run's list and pressing Rewind.
- A rewind while a turn runs. The agent may be writing the same files: during a turn the
  menu's items are shown disabled and nothing is queued, and a turn starting while the sheet
  is open fails the sheet.
- A rewind offered where it is known to fail: a process that said rewinding is not enabled,
  a session Drakar does not drive. (A prompt with no checkpoint is only known by asking: the
  dry run asks.)
- The fork drops the person's text: the prompt they forked from is in the composer, unsent.

## Decided

- The extension's words for every outcome and label it names. Drakar's own copy is limited to
  what the extension has no words for.
- Checkpoints on for every session Drakar starts, as the extension does: the feature does not
  exist without them.

## Calls made without asking

Each came out of the builder check. Each is the writer's call, not something the person said.

- **Which prompts offer a code rewind.** Every prompt in the transcript. The code items are
  offered while Drakar drives a live process that has not said "File rewinding is not
  enabled.", and enabled while no turn runs. There is no "has run a turn" rule: a resumed
  process answers before its first prompt, for prompts of earlier processes too, from the
  transcript's `file-history-snapshot` lines (stream-json "Rewind", answer 3). That holds
  for a process that is live, such as one the session host kept running; a session reopened
  from the list starts its process only when a prompt is sent, and offers only the fork
  before then (Non-goals). The dry run,
  sent when the person picks "Rewind code to here" (never on hover), is the authority: "No
  file checkpoint found" shows the extension's failure line and no Rewind button. Once a
  process answers "File rewinding is not enabled." (a setting turned it off, or a process the
  session host started before this shipped), that process offers no code rewind again.
- **During a turn.** The menu's items are shown disabled while a turn runs, the fork
  included, not hidden. Nothing is queued: a queued rewind would write files the person
  approved before the agent changed them again.
- **A turn while the sheet waits.** A turn starting while the sheet checks or shows the dry
  run's list fails the sheet: the list may no longer hold. A rewind already sent is left to
  its reply.
- **The sheet's buttons.** Return never presses Rewind; Esc is Never mind. Never mind is
  disabled while the real rewind runs, since it may already be writing.
- **Nothing to rewind.** A plain "Rewind code" whose dry run lists no files shows "No files
  to rewind." with only Never mind.
- **The first prompt.** "Fork conversation from here" on the first prompt starts a plain new
  session in the same folder, under the source session's account, with its mode and model
  picks and the prompt's text in the composer. Nothing else is copied: there is no history
  before it to resume.
- **Fork and rewind.** The rewind runs first. If it fails, nothing is forked and the failure
  shows. If the dry run lists no files, the sheet says so and Continue forks without a rewind.
- **Versions.** No version gate. `--resume-session-at`, `rewind_files` and
  `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING` are in the 2.1.308 and 2.1.312 binaries; an older
  CLI's refusal shows as the extension's failure line, as with the task controls.
- **Checkpoints on for everyone** (Goal 1) costs disk under the account's config folder; the
  extension pays the same.

## Left to the builder

- How a prompt entry carries the CLI's message uuid. Today it is `prompt#N`. In history the
  user line has `uuid`. Live, Drakar sends each prompt with a `uuid` of its own (the queue
  uses it), and the CLI writes that uuid on its transcript line (stream-json "Rewind",
  answer 2).
- How the menu learns that a process said rewinding is not enabled.
- The sheet's layout, within the extension's words.

## Slices

1. **Capture.** On 2.1.312 with checkpointing on: two prompts that edit a file, then
   `rewind_files` dry run and real for the first prompt, for an unknown uuid, in a freshly
   resumed process, and in a resumed process after one new turn, to a prompt from before
   it. Also without the environment variable. Also whether a live prompt's transcript uuid is the one Drakar sent, and
   what `--resume-session-at <uuid> --fork-session` writes. Record the shapes in
   `docs/claude-stream-json.md`. A shape that differs from the above changes the plan first.
2. **Kit.** The prompt entry's message uuid, the request and its reply, and the fork's
   arguments, tested against slice 1's fixtures.
3. **App.** The environment variable, the menu, the sheet, the fork with the prompt in the
   composer.
4. **Docs.** The ledger rows move to `has`.

## Live checks

In the running app, relaunched by the person (never `make run`):

1. Two prompts that edit a file; rewind to the first: the dry run lists the file, Rewind
   restores it, its open tab reloads.
2. Fork from the second prompt: a new session whose history ends before that prompt, the
   prompt's text in its composer. Fork from the first prompt: a plain new session, the text
   in its composer.
3. Fork and rewind: both.
4. A session whose process is live but has not prompted since it resumed (for example one
   the session host kept running): the fork and the code items are all offered, and a dry
   run for an earlier prompt answers rather than refusing (stream-json "Rewind", answer 3).
   A session reopened from the list, with no process yet: only the fork is offered.
5. During a running turn: the menu's items show disabled, and nothing is queued. With the
   sheet open on a dry run's list, a turn that starts fails the sheet.
