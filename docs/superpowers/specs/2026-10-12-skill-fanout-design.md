# Run a skill in each subfolder

Status: approved in conversation on 2026-10-12 (whole design presented at once; the person
chose an unlimited, configurable concurrency; the other two open points took the
recommendation).

## Why

The person keeps many repos side by side (`~/Projects/apps/*`) and runs the same chore in
each: a dependency bump, an audit, a market-intel pass. Today that means opening a session
per repo and typing the skill N times. They want to open the parent folder in Drakar, pick
one skill, and get one session per subfolder, each running that skill in its own folder.

## Decisions

| Question | Decision |
| --- | --- |
| Where it starts | A "Run in Each Subfolder…" item in the inspector's skill context menu, and Session › Run Skill in Subfolders… (same sheet, with a skill picker). |
| Which folders | The immediate subfolders of a parent folder, default the window's project folder. Hidden folders skipped; "Git repositories only" on by default. No deeper walk. |
| Which agent | The skill's: the inspector lists `Project.skillsAgent`'s skills, and that agent runs them. No agent picker. |
| How many at once | All, by default. A "Run at most [  ] at a time" field, empty meaning unlimited; with a number, the rest wait their turn. |
| Where the sessions live | All in the window the batch was started from. |
| Same prompt | Every session gets `/<skill>` plus the same arguments, if the skill takes any. |

## §1 Finding the subfolders

A DrakarKit type, `SubfolderScan`, lists a parent folder's immediate children:

- directories only, symbolic links to directories followed (a linked repo is a repo);
- names starting with `.` skipped;
- each child marked `isGitRepository` when it holds a `.git` entry (folder or file, so a
  linked worktree counts);
- sorted by name, the way Finder sorts (`localizedStandardCompare`).

It reads only the directory listing and one `fileExists` per child, so the sheet runs it
when shown and again when the parent changes.

## §2 Whether the skill is there

A skill reaches a session from the account (user), a plugin, or the session folder's own
`.claude/skills` / `.claude/commands`. A skill from the parent's project folder is not read
by a session started in a child, so it would fail there.

- **Claude:** `ClaudeSkillScan` with no project gives the user and plugin skills. If the
  skill's name is among them it is available everywhere. Otherwise each subfolder is scanned
  as a project, and the skill is available where its name turns up.
- **Codex:** one `skills/list` with every ticked subfolder in `cwds` (the call takes a list),
  read through a one-shot reader like `CodexSkills`'. A subfolder is available when the
  reply lists the skill for it. If the one call cannot be split by cwd, fall back to one
  call per subfolder; the plan checks this first.

A folder without the skill is shown dimmed with "Not available here" and starts unticked. It
can still be ticked: the session then gets the prompt and says so itself.

## §3 The sheet

`SkillFanOutSheet`, presented on the project window.

- Title: "Run /<skill> in Each Subfolder".
- Parent folder: its path, with Change… (an `NSOpenPanel` for folders).
- The list: a checkbox, the folder name, a dimmed note ("Not a git repository", "Not
  available here"). Select All / Select None. "Git repositories only" filters the list; the
  ticks of hidden rows are kept but not counted.
- Arguments: a text field with the skill's `argumentHint` as placeholder, shown only when
  `takesArguments`.
- Mode: the permission-mode picker the composer offers, defaulting to Settings'. Bypass only
  when allowed (`allowsBypass`), as today.
- Account (Claude Code, when there is more than one): every account, defaulting to the
  window's. Each session starts under it, over its subfolder's own pick and Settings', and
  §2's check reads that account's skills. Without it a session would take its subfolder's
  pick, not the window's.
- Run at most: a number field, empty by default, placeholder "Unlimited".
- Buttons: Cancel, and "Start N Sessions" (default), disabled at zero.

From the Session menu the sheet first shows a skill picker over `slashCommands` for the
shown session's agent (the inspector's list), then the same content.

## §4 Starting the sessions

`Project.runInSubfolders(_ skill: SkillEntry, folders: [URL], arguments: String, mode:
PermissionMode?, limit: Int?, account: ClaudeAccount?)` (a nil mode leaves Settings'
default; a nil account, Codex's, the folder's):

1. For each folder, a new session (`agent: skillsAgent, folder:`), named
   `"/<skill> · <folder name>"` with `rename(to:)` (a session with no process takes the
   name at start, via `--name`), with the mode set. They are inserted in folder order at the
   top of the list without being selected one after the other; the first is selected at the
   end. `newSession` gains a `select: Bool = true` parameter for this.
2. A `FanOut` (below) is kept on the project with the sessions' ids, in folder order.
3. The prompt `/<skill>` (plus `" " + arguments` when not empty) is sent to as many as the
   limit allows, all when unlimited. `takeOver` is skipped: these are new sessions.

**`FanOut`, in DrakarKit, pure.** It holds the ids and a state per id: `waiting`,
`running`, `finished`, `cancelled`. `start(limit:) -> [ID]` returns the ids to send now.
`finished(_ id) -> [ID]` marks one finished and returns the next one to send, if any.
`cancel() -> [ID]` marks the waiting ones cancelled and returns them. It is done when
nothing waits or runs.

**What frees a slot.** In `Project.make`, the existing `onTurnEnded` and `onStopped`
closures also tell the project's fan-outs that the session finished. A session that fails to
start stops, so it frees its slot too. A session waiting for a permission or a question
keeps its slot: it is still working.

With no limit, `FanOut` still records the batch, for the banner (§5).

## §5 Seeing them

- **Session rows** show the subfolder for a session whose folder is below the project
  folder but is not the project folder: its first path component under the project, in the
  row's detail line, before the worktree name when both apply. This helps outside
  batches too.
- **A banner** above "This Window" while a fan-out is not done: "/<skill> · 4 running ·
  8 waiting · 3 done", with Cancel (cancels the waiting ones; running sessions are left to
  the person, who has Stop). It goes away when the batch is done. With several batches, one
  banner each.
- Permission prompts, questions and turn ends reach the attention pane and notifications
  the way any session's do. Nothing new there.

The fan-out is not saved with the window: after a relaunch the sessions come back as
ordinary sessions and the waiting ones, never prompted, as empty ones.

## Errors and edge cases

- The parent has no subfolders, or none left after filtering: the list says so and the
  button stays disabled.
- A folder vanishes between the sheet and the start: its session fails to start and stops,
  which frees its slot.
- A subfolder already open in its own window: the session still lives in this window (it is
  held here); the other window lists it under Elsewhere.
- A limit of 0 or less is treated as unlimited.
- Codex skill read fails: every folder shows as available, with a note under the list that
  availability could not be checked.

## Testing

DrakarKit:
- `SubfolderScanTests`: hidden folders skipped, files skipped, links to folders followed,
  `.git` as a folder and as a file, sort order.
- `FanOutTests`: unlimited sends all; a limit sends that many, then one per `finished`;
  `finished` on an unknown or already finished id does nothing; `cancel` returns only the
  waiting ones; done-ness.

App:
- `ProjectFanOutTests`: N folders make N sessions named `/<skill> · <name>` in folder order,
  the first selected; with a limit of 2 only two are prompted, and a turn end prompts the
  next; cancel leaves the waiting ones unprompted.
- Availability: a user skill is available everywhere; a project-only skill only in the
  subfolders that hold it.

Live, with cupertino-desktop (screenshots are black): a scratch parent with three git repos
and one plain folder, a user skill with no arguments, limit 2. Check the sheet's ticks, the
three session names, the banner counts moving, and the third session starting after the
first turn ends.

## Not in this version

- Going deeper than the immediate subfolders.
- A different prompt per folder.
- A git worktree per session.
- Saved batches or presets, and resuming a batch after relaunch.
- Starting from the Skills window (its `SkillRecord` carries no argument hint, and it may
  not belong to a project window). A follow-up can add a context menu there that hands off to
  the chosen project's window.
- Starting from a folder (Home's project rows).
