# Move sessions between accounts

A project's sessions can move from one Claude account to another and carry on there under
the same id. Picking another account in the toolbar offers to move the folder's sessions
with it; a session row's context menu moves one. The files are relocated, never copied or
deleted, and a session something else is running stays where it is.

## Why

The person has two accounts, `~/.claude` (Personal, Max 20x) and `~/.claude-skitrust`
(Skitrust, Team). When one runs low (Personal's week was at 92 % on 2026-10-04), they want
the project's conversations to go on under the other, not to start them again. The window
account spec (`2026-10-04-window-account-design.md`) made new sessions follow a per-folder
pick; existing ones still resume under the account that wrote them, because a session lives
where its transcript is.

## Decisions

Settled with the person on 2026-10-04.

| Question | Decision |
| --- | --- |
| What a move does to the original | A real move: the files leave the old account, the id stays. Not a copy that continues (Armada's handover), not a fork |
| What a move covers | The folder's sessions (worktrees included), offered when the picker changes account; and one session from its row's context menu. Not a whole account |
| A session this window runs | Idle at Ready: its process is stopped, it moves, its next prompt resumes it on the new account. Mid-turn or waiting on a permission: skipped |
| How files travel | Rename, transcript last; copy, check, delete only when a rename crosses volumes |

## What a session is on disk

Claude Code 2.1.288 keeps, per session `<id>`, under an account's directory:

| Path | What | Moved |
| --- | --- | --- |
| `projects/<folder name>/<id>.jsonl` | The transcript. Where it is decides the account: `claude --resume <id>` looks for it under `CLAUDE_CONFIG_DIR` | Yes, last |
| `projects/<folder name>/<id>/` | Subagent transcripts, `tool-results` | Yes |
| `file-history/<id>/` | What `/rewind` restores files from | Yes |
| `session-env/<id>` | The session's environment snapshot | Yes |
| `history.jsonl` | The account's prompt history (up-arrow), one file for every session | No |
| `sessions/<pid>.json` | The registry of running processes | No: a running session is never moved |

No line of a transcript names its account, so a moved transcript needs no rewriting.
`<folder name>` is reused exactly as the source has it, never encoded again from the path:
Armada's handover learned that a re-encoded name can differ from the CLI's.

## Moving one session: `SessionMover` (DrakarKit, file operations only)

```swift
public enum MoveOutcome: Sendable, Equatable {
  case moved
  case skipped(SkipReason)
  case failed(String)
}

public enum SkipReason: Sendable, Equatable {
  case alreadyThere      // the target already holds a transcript with this id
  case busy              // a Drakar window is running a turn or waiting on a permission
  case runningElsewhere(String)  // "VS Code", "a terminal", "the Claude app", "another app"
}

public enum SessionMover {
  /// Moves `transcript` (`<source>/projects/<folder name>/<id>.jsonl`) and its sidecars to
  /// `target`. Nothing is overwritten; the transcript goes last.
  public static func move(
    transcript: URL, from source: ClaudeAccount, to target: ClaudeAccount,
    fileManager: FileManager = .default
  ) -> MoveOutcome
}
```

1. The target directory must exist; otherwise `.failed("Skitrust's folder ~/.claude-skitrust is gone")` before anything moves.
2. The target transcript path exists: `.skipped(.alreadyThere)`, nothing touched.
3. Each sidecar that exists at the source moves: the subagent folder, then `file-history/<id>`, then `session-env/<id>`. A sidecar already at the target is left in place and the source's copy stays too (never merged, never overwritten).
4. The transcript moves.
5. Each move is `moveItem` (a rename on one volume). On `EXDEV` (another volume) that one item is copied, its size checked against the source, and the source removed.

A failure at 3 leaves the transcript on the source: the session still works where it was,
and moving it again moves what is left. A failure at 4 is reported as `.failed`, with the
sidecars already at the target; moving again finishes it.

## Deciding what moves (app)

**Candidates** for a folder and a target account: every session `SessionMonitor` lists under
the folder whose account `key` differs from the target's, plus the window's held sessions that
have a transcript. A new session never prompted has no files and is not a candidate; it starts
on the window's account.

Each candidate is classified immediately before its own move, not once for the batch, since a
terminal may resume one meanwhile:

| Session | Outcome |
| --- | --- |
| No process anywhere | Moved |
| Held by a Drakar window (any), process idle (`phase == .ready`, not running, no pending permission) | Process stopped, moved, then `relocate(to:)` |
| Held by a Drakar window, no process | Moved, then `relocate(to:)` |
| Held by a Drakar window, mid-turn or waiting on a permission | `.skipped(.busy)` |
| Live in another process (`SessionMonitor.liveIDs`, not held by Drakar) | `.skipped(.runningElsewhere(host))`, `host` from `SessionMonitor.host(of:)` |

`OpenSessions.shared.locate(_:)` finds a held session in any window. File work runs off the
main actor, one session at a time; the session's state is read and changed on the main actor.

### `ClaudeSession.relocate(to:)`

Replaces `resuming` and `savedTarget` with a `ResumeTarget` for the new transcript path and
account (`forks` cleared), so the next spawn resumes the moved file under the target's
`CLAUDE_CONFIG_DIR`. Called only after `.moved`; the window's stored project follows through
`Project.stored`, so a relaunch after a move opens the session on its new account and one
after a failed move on its old.

## Interface

### From the picker

After a pick that changes the window's account (the window account spec, `AccountStore.pick`),
when the folder has candidates on another account:

> **Move this folder's 14 sessions from Personal to Skitrust too?**
> 2 are running in VS Code and will stay on Personal.
> [Move 14 Sessions] [Not Now]

The count excludes sessions running elsewhere; the second line appears only when there are
some. "Not Now" leaves the pick in place and moves nothing.

### From a row

The context menu of a held row, an ended row and an elsewhere row gains **Move to ▸** with every
other discovered account by profile name. On a row running in another process the items are
disabled, with the host as the reason (`Running in VS Code`).

### Afterwards

One alert summarises the batch:

- all moved: `Moved 12 sessions to Skitrust.`
- some not: `Moved 12 sessions to Skitrust. Not moved: 2 running in VS Code, 1 already on Skitrust.`
- a failure: listed by session title with its reason.

A single move from a row that succeeds shows nothing; the row's account badge changes. One that
does not move says why in an alert.

The rows update through the `projects` folder watching `SessionMonitor` already does on every
account.

## Consequences

- A moved transcript takes its past token usage with it: Armada's per-account totals, and
  anything else that sums transcripts per account, count those turns under the new account
  from then on. Plan limits are unaffected; they come from Anthropic.
- The old account's prompt history (`history.jsonl`) keeps the moved session's prompts; the
  new account's does not gain them.

## Testing

DrakarKit, `SessionMoverTests`, on temporary account directories:

- a full move: transcript, subagent folder, `file-history/<id>`, `session-env/<id>` arrive, the
  source holds none of them;
- only some sidecars exist;
- the target holds the id already: `.skipped(.alreadyThere)`, both transcripts unchanged;
- the folder name is reused exactly, including one that encoding the cwd would not produce;
- a missing target directory: `.failed`, nothing moved;
- a failure after the sidecars moved leaves the transcript at the source; a second move
  finishes;
- the cross-volume fallback, through an injected `FileManager` whose `moveItem` throws `EXDEV`.

App tests:

- the classification table, with injected live ids and held sessions;
- `relocate(to:)`: the next spawn of the stand-in `claude` sees the target's
  `CLAUDE_CONFIG_DIR` and `--resume <id>`, and the stored project names the new file;
- an idle held session with a running stand-in process is stopped, moved, relocated;
- a busy one (a pending permission) is skipped.

In the running app, once nothing else is relaunching Drakar from `main`: move a scratch
session from Personal to Skitrust and back; its badge, footer and the files on disk follow.

## Not in this spec

- Moving a whole account's sessions across folders.
- Copying or forking to another account (Armada's "Continue on").
- Moving sessions of another tool (Codex, Grok).
- Undo: moving back is the same operation the other way.
