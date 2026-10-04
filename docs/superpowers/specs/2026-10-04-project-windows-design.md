# Project windows

A Drakar window becomes one project: a folder, its files and editor, and every session in
it, listed in the sidebar with what each is doing and how full its context is. Clicking a
session switches the window to it. Today a window is one session; after this, a window holds
as many as the person starts, and the ones they are not looking at keep working.

## Why

The person runs two or three sessions in one project at a time and wants to see at a glance
which is working, which needs them, and how close each is to the end of its context, without
a window per session and without a second editor per session. Phase 4 put the editor beside
the session, so a window per session now means a file tree, tabs, unsaved state and a folder
watcher per session for one folder. One window per project removes that duplication.

Nothing that works today is lost: the IDE bridge, resume, forks of sessions live elsewhere,
the editor's selection going with the prompt, and windows restored at launch.

## Decisions

Settled with the person on 2026-10-03 and 2026-10-04.

| Question | Decision |
| --- | --- |
| What a click on a session does | Switches this window to it (not: brings a per-session window forward) |
| When a session has a process | On demand: the history shows at once, `claude` spawns on the first prompt, and a started session keeps running in the background until it is ended or its window closes |
| Which sessions a project holds | Its folder and below, worktrees included, on whole path components; the deepest open project wins |
| Where the list goes | Above the file tree, in the one sidebar, with a split between them |
| Who owns a session | The window. Not the app with windows as views, and not native window tabs, which would keep a `Workspace` per session |

## Where the data comes from

Armada reads every session on the Mac from outside, through files, because it never owns a
session's stdin or stdout (`armada/docs/claude-code-sessions.md`). Drakar owns them for its
own sessions, so each kind of row takes the most direct source there is:

| Row | Status | Context used | Context window |
| --- | --- | --- | --- |
| Attached, process running | `ClaudeSession`: working, waiting for you (it holds the permission request), ready, stopped. Exact | `usage` on each streamed `assistant` message, live | `get_context_usage` → `maxTokens` after each `result`; before the first, `system/init.model`, which carries `[1m]` |
| Attached, not spawned | Not started; last activity from the file | Transcript tail, read once | `ContextWindow.resolve` |
| Elsewhere | Registry `status` and `waitingFor`; "running a tool" is a guess and says so | Transcript tail, on each write | `ContextWindow.resolve` |
| Ended | None, only the time | Transcript tail, read once | `ContextWindow.resolve` |

Context used is `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, all
three. `input_tokens` alone is near zero on a warm turn.

### Ported from Armada

Armada's readers live in its app target, not a package, so they are copied into DrakarKit,
moved onto `JSONValue` from `JSONSerialization`, and come with tests.

| Armada | What it settles |
| --- | --- |
| `TranscriptTitle.tail(of:)`, `TranscriptContext.reading(fromLine:)`, `newestModelID` | One 64KB tail read per write answers the title, the context reading and the model attachment |
| `ContextWindow.resolve` | Nothing on disk records the window size, and `message.model` never carries `[1m]`. Session `attachment/model` first, then the account's `settings.json` model, then `message.model`; usage above the size found means the window is at least that big (`.observed`). Each answer keeps its source for the tooltip |
| `SessionRegistry`, `SessionState` | The registry reports `busy`, `waiting` and `idle`; `waitingFor` is display text, never branched on; `updatedAt` is the honest last activity. Probes are skipped by parent pid, plugin summarizers by their temporary-folder cwd |
| `ProjectPath.contains`, `deepest` | Containment on whole components, so `drakar-old` is not in `drakar` |
| `SessionWatcher` | FSEvents with file events on `sessions/` and `projects/`, exact filename matching so a subagent's writes do not mark its parent, a 1s sweep for dead pids |

Not taken: `ContextProbe`, which spawns a `claude` per breakdown (about 200MB each), and
asking Armada over MCP, which would break Drakar's claim that it reaches nothing and would
fail when Armada is not running.

Not done: a `statusLine` command or hooks for terminal sessions. Both would give exact
figures, and both mean writing into the person's `settings.json`, against "your Claude
Code, unchanged". A possible opt-in later.

## Windows and ownership

- **The window's value** is `ProjectRoute { folder }`, replacing `SessionRoute` in
  `WindowGroup(for:)`. `openWindow(value:)` on a folder already open brings that window
  forward, which keeps one writer per transcript at the level of the project.
- **`Project`** (`@Observable`, one per window): the folder, the `Workspace`, `sessions:
  [ProjectSession]` and `selectedID`. A session is attached by being started here or clicked
  in the sidebar; live and ended sessions that are not attached are listed without being
  held.
- **`ProjectSession`** wraps `ClaudeSession`, whose `start()` splits into `loadHistory()`,
  run when the row is first selected, and `spawn()`, run on the first prompt. The composer is
  enabled before the spawn; the prompt is sent once `initialize` has answered. A new session
  is a `ProjectSession` without a target and takes its id from `system/init`, as today.
- **Persistence**: `@SceneStorage` keeps the attached sessions as JSON `[ResumeTarget]` and
  the selected id, outside the window's value so that its identity stays the folder. A
  relaunch restores the rows and their transcripts and spawns nothing.
- **Ending**: processes stop when the window closes, as today. A row's menu has End Session
  (stops the process, keeps the row) and Remove from Window; either asks first mid-turn.
- **`OpenSessions`** becomes the app's index of `sessionID → (window, ProjectSession)`, so
  another window and the global list know a session is open in Drakar and read its live
  state from memory rather than from the registry.
- **Overlap**: with `drakar/` and `drakar/apps/apple` both open, a session in
  `apps/apple` belongs to the second.
- **An empty window** still shows the global `SessionsView`. Picking a session there opens
  the open window whose folder contains its `cwd`, or a new window on the `cwd`.
- **Migration**: windows restored from `SessionRoute` do not decode and open empty. Nothing
  has shipped, so there is no migration.

## The sidebar

A split: sessions on top, the file tree below, the divider kept per window.

### Groups

1. **This window**: attached sessions in the order they were attached, newest on top. Rows
   do not move when their status changes. A **+** in the header starts a new session; ⌘N
   does the same in a project window, ⇧⌘N opens a new window.
2. **Elsewhere**: this project's sessions live in a terminal, VS Code or another Drakar
   window, newest activity first.
3. **Ended**: collapsed with a count; the 20 most recent, then Show All.

### A row

A status dot, the title, a context gauge (`62%`), and the time since the last activity. A
second line only when it says something: `waitingFor` ("permission prompt"), what a waiting
Drakar session wants ("Bash: make test", from the cards' tool summary), the host ("terminal",
"VS Code", "connected" for a terminal on the IDE bridge), or the worktree's name when the
`cwd` is not the project root. The gauge's tooltip is `142k of 200k` and where the window
size came from; it turns amber at 75% and red at 90%.

Colours follow Armada's `SessionState.tint`: green working, orange running a tool (a guess),
blue waiting for you, grey idle.

### A click

- **Attached**: selects it. Each session keeps its transcript's scroll position, its
  composer draft and its permission queue.
- **Ended**: attaches it and shows its history from disk; the first prompt resumes it under
  the account that wrote it.
- **Elsewhere, outside Drakar**: attaches it read-only. The transcript follows the file;
  the composer is replaced by "Live in a terminal" and Fork a Copy. When the other process
  exits, the row becomes resumable where it is.
- **Elsewhere, in another Drakar window**: brings that window forward with the session
  selected.

### `SessionMonitor`

One for the app, not one per window: an FSEvents stream per account on `sessions/` and
`projects/`, as Armada's `SessionWatcher`. Windows read it filtered by `ProjectPath`. It
replaces the global list's refresh-on-demand, which phase 2 left open.

## Attention

- **Nothing switches for the person.** A background session never takes the selection,
  which would move the composer under their typing.
- **A permission request in the background** turns the row blue with what it wants, and
  counts in the group's header. Selecting the row presents `PermissionSheet`, which moves
  from `SessionView` to each session.
- **A turn ending in the background** marks the row unread until it is selected. A session
  that stopped on an error is red ("Stopped, exit 1") and unread; selecting it shows the
  problem banner with the end of stderr.
- **⌥⌘↓ Next Session Needing You** goes to waiting rows first, then unread ones, in a new
  Session menu with New Session.
- **With Drakar in the background**, the Dock badge counts permission requests waiting in
  every window, and a local notification (`UserNotifications`, no connection) names the
  session and what it wants; clicking it brings the window forward with the row selected.
  Permission is asked when the first notification is due. Notifications for ended turns are
  a setting, off by default.
- **Only Drakar's own sessions notify.** Armada already notifies for every session on the
  Mac; two apps chiming for one prompt is noise.
- **Closing or quitting mid-turn asks first**: "2 sessions are still working. Closing stops
  them." One alert with the unsaved tabs question, through `WindowCloseGuard` and
  `applicationShouldTerminate`.

## The IDE bridge and the editor

- The lock file's `workspaceFolders` are the project windows' folders. A terminal `claude`
  in a subfolder or worktree already matches. `openDiff` still opens Review Changes, and
  `selection_changed` still comes from the frontmost window's `Workspace`.
- The `pid` in `ide_connected` ties a connection to its registry file: the terminal
  session's row says "connected", and ⌘⌥K can name the session the mention went to.
- One `Workspace` per window: tabs, tree and folder search are shared by the project's
  sessions. Pinned selections are per window too, and go with the prompt of whichever
  session sends next.
- `sessionFolder`, which tool cards and diffs resolve paths against, is the session's own
  `cwd`, not the project's.
- A session in a worktree sent a selection from the main checkout is reading another copy
  of that file. The selection's chip says "from the main checkout". Paths are absolute, so
  it still resolves.

## Kit changes

- `Transcript`: `usage` from streamed `assistant` messages; incremental append from a byte
  offset over `LineBuffer`, for following a file read-only.
- `ContextReading`, `ContextWindow` and the tail readers, ported.
- `LiveSession` reads `cwd`, `waitingFor` and `updatedAt`, and skips Drakar's own children
  and temporary-folder spawns.
- `ProjectPath`, ported.
- `ClientMessage.contextUsage(requestID:)` and decoding its `control_response`.

## Spike first

Before the plan: a Drakar session against the real CLI, sent `get_context_usage` with
`detail: "summary"` mid-turn and between turns. Record whether it is answered mid-turn,
whether it stays local (no `count_tokens` call), and capture the reply as a fixture. If it
is only answered between turns, the gauge takes streamed `usage` during a turn and corrects
`maxTokens` at each `result`; the design holds either way.

## Testing

Everything that can be argued about in a unit test is in the kit and tested against
captured output.

- **Kit**: registry files with `status`, `waitingFor`, `updatedAt` and the two filters; tail
  readings and the model attachment; `ContextWindow.resolve` with `.observed`; `ProjectPath`
  containment and deepest-wins; incremental append equal to a whole replay of the same
  file; the captured `get_context_usage` reply.
- **App, hosted**: the attached list's `@SceneStorage` round trip; the first prompt spawning
  and arriving after `initialize`; attention counts for the badge; the combined close and
  quit alert.
- **Live, before it is done**: two sessions working at once in one window against the real
  CLI; a background permission request, its notification and the answer; a terminal
  `claude --ide` shown as connected; resume, fork and relaunch; `make audit`.

## Out of scope

- A context breakdown by category in the sidebar. The `get_context_usage` reply carries it
  and a later panel can show it.
- Sessions of other projects in a project window's sidebar.
- Following a rewound branch of a transcript (history is still read in file order).
- Choosing the account for a new session (PLAN.md §7.2).
