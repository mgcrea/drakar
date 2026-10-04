# Projects home

Drakar's home becomes a list of projects instead of a list of sessions. A project is a
folder the person tracks, whether or not it has sessions yet; each row says how busy it is
and how recently it was worked in. A click enters it: the window becomes that project, as
it does today when a session is picked. Several projects are several tabs or several
windows, which macOS gives a `WindowGroup` for free.

## Why

Phase 5 made a window a project, but the window opened without one still shows every
session on the Mac, newest first, across every folder. The person thinks in projects: they
open Drakar to work on one, and want to see which of theirs has something running or
waiting before choosing. A flat session list makes them find the project through one of its
sessions, and a project with no session yet cannot be reached at all except through Open
Folder.

The UI is meant to be project-scoped from here on; what spans projects (attention across
them, later more) belongs in the toolbar, not in a session list.

## Decisions

Settled with the person on 2026-10-04.

| Question | Decision |
| --- | --- |
| What home lists | Tracked projects. Folders with sessions that are not tracked are suggested below them, never mixed in |
| Which stats | Ones that mean something per project: sessions, how many are running and waiting, last activity, the newest session's gauge. Not a sum of context gauges |
| Worktrees | Count under the main repo |
| Tabs or windows | Both, as native window tabs: one window (or tab) per project, as phase 5 has it |
| Going home from a project | The Projects button (⇧⌘H) closes the project in place: the close questions, its sessions stop, and the window shows home. Only ⌘T opens another home |

Phase 5's spec ruled out native window tabs because they would have kept a `Workspace` per
*session*. A tab per *project* keeps one `Workspace` per project, which is what phase 5
wants.

## Tracked projects

- **`ProjectList`** (`@Observable`, one for the app) holds the tracked folders as
  `ProjectPath.normalize` writes them, with the date each was added. Stored in
  `UserDefaults` under `drakar.projects` as JSON; app-wide, not scene storage, so every
  window sees the same list.
- **A folder is tracked** when it is added from home (Add Project…, or a drop of a folder
  on the list, which track without opening), when it is opened with Open Project… (⌘O), when it is opened in a project window by any route, and when a
  suggestion is accepted. Every project window open at the first launch with this code is
  tracked then, so nothing the person had open disappears from home.
- **Removing** a project untracks it and nothing else: its files, transcripts and any open
  window stay. A removed project that is opened again is tracked again.
- **A folder that no longer exists** keeps its row, greyed, with "Folder not found" and
  Remove. It is not dropped silently: a disconnected volume comes back.
- **Nested projects** (`drakar/` and `drakar/apps/apple` both tracked) follow phase 5's
  rule: a session belongs to the deepest one, on whole path components.

## Worktrees

A session's folder is first mapped to its main checkout, then to the deepest tracked
project containing that.

- **Inside the repo** (Claude Code's `<repo>/.claude/worktrees/<name>`, every worktree on
  this Mac today): already contained by the repo's path. Nothing to do.
- **Outside it** (`git worktree add ../repo-feature`): the worktree's `.git` is a file,
  `gitdir: <repo>/.git/worktrees/<name>`. The main checkout is the folder holding that
  `.git` directory. Found by walking up from the `cwd` to the first `.git`, read once per
  folder and cached.
- **A worktree since removed** has no `.git` left to read; its sessions fall back to their
  own path, and show under a suggestion if no tracked project contains it. Accepted: the
  transcript does not record the main checkout.

Project windows' sidebars use the same mapping, so a session in an outside worktree lists
under its repo's window too. The IDE bridge's `workspaceFolders` are unchanged: a terminal
`claude` in an outside worktree still does not match its repo's window.

## Home

The window opened without a project (`WindowRoute.picker`) shows home, titled "Projects".

### A project row

The folder's name, its path abbreviated below (`~/Projects/apps/drakar`), and on the right:

| Stat | Source | Shown as |
| --- | --- | --- |
| Waiting for you | Drakar's own sessions waiting on a permission (`Project.waitingCount`), plus registry `waiting` for the rest | A blue count, first, only when not zero |
| Running | Drakar sessions mid-turn, plus registry `busy` | A green count, only when not zero |
| Sessions | Every transcript the project owns, after the worktree mapping | `24 sessions`; "No sessions" for a new project |
| Last activity | The newest transcript's modification time | `2h ago` |
| Context | The gauge of the most recently active session, as its sidebar row shows it | The same gauge and tooltip as the sidebar's |

A project open in a window or tab says so ("Open"), and a click brings that window forward
instead of turning this one into it.

Rows are ordered by last activity, newest first; a project with no sessions sorts by the
date it was added. Order is recomputed when the list appears and when the person searches,
not on every transcript write, so a row does not move under the pointer.

### Clicking

- **A click** enters the project: this home window becomes its project window, restoring
  the sessions it last held (`@SceneStorage`), or starting a new session when it held none,
  as phase 5 does for Open Folder.
- **The context menu**: Open, Open in New Tab, Open in New Window, New Session, Show in
  Finder, Copy Path, Remove from Projects.

### Suggested folders

Below the projects, a "Recent Folders" section: folders with a session in the last 30 days
that no tracked project owns, each with Add. A folder is suggested as its git top level
(after the worktree mapping), or as the session's `cwd` when it is not in a repo, so a
session in `foo/apps/apple` suggests `foo`. Temporary folders (`/private/tmp`,
`/private/var/folders`, `TMPDIR`) are never suggested. At most 8, then Show All. Hide
removes a suggestion for good (`drakar.hiddenFolders`), until a new session appears in it.

### Searching

The toolbar's search field ("Search projects and sessions") filters the projects by name
and path, and adds a Sessions section below them: the matching sessions, by title and
`cwd`, as the current picker rows draw them. Picking one opens its project window (the
owning tracked project, or the session's folder, which becomes tracked) with it attached,
as phase 5's picker does now.

### Empty

No tracked projects and no suggestions: "Add a project to start", with Add Project….

## Tabs, windows and commands

| Command | Key | In home | In a project |
| --- | --- | --- | --- |
| New Session | ⌘N | Disabled | As today |
| New Tab | ⌘T | Home, in a new tab of this window | Home, in a new tab of this window |
| New Window | ⇧⌘N | A home window | A home window |
| Close Project | ⇧⌘H, and the Projects button in project windows | Disabled | Asks what a close asks, stops the sessions, and shows home in this window |
| Open Project… | ⌘O | Tracks the folder and opens it in a new tab | The same |

A new tab is a new window of the same `WindowGroup`, merged into the key window's tab group.
The tab bar's own **+** does the same, since a window opened with no value already shows
home. Each tab's title is its window's: the project's short path, or "Projects".

Keep on Top stays per window, and so per tab group in practice: AppKit floats the window,
and its tabs move with it.

## Kit changes

- **`TranscriptFolder`** and **`SessionIndex.folders`**: one entry per transcript folder,
  its session ids from the file names, its newest file, and the `cwd`, checkout and
  repository read from that newest file once (reused while it is unchanged). The monitor
  only reads the 500 newest transcripts in full, so counting from its summaries would
  undercount older projects; listing the folders costs a directory listing each.
  Rescanned two seconds after the last transcript write.
- **`ProjectStats`**: given the transcript folders, the registry, the tracked folders and a
  main-checkout mapping, assigns each summary to its project once (not a filter per project per redraw)
  and returns each project's session count, last activity, newest summary, and registry
  waiting and busy counts. The app adds its own sessions' live state on top.
- **`ProjectPath.mainCheckout(of:)`**: the `.git` walk and `gitdir:` parse, over a
  file-reading closure so tests need no repo on disk; `topLevel(of:)` for suggestions.
- **`FolderSuggestions`**: untracked folders from summaries, with the age cut, the
  temporary-folder filter, the hidden list, and the git top level.
- **`ProjectList`'s stored form**: the JSON shape and its decoding of a missing or broken
  value as an empty list.

## Testing

- **Kit**: deepest-wins assignment with nested tracked projects; an outside worktree's
  sessions counted under its repo; a removed worktree falling back to its path;
  `gitdir:` with relative and absolute paths; suggestions skipping temp folders, tracked
  folders, hidden ones, and old sessions, and collapsing subfolders to their repo; stats on
  a project with no sessions.
- **App, hosted**: `ProjectList` round trip through `UserDefaults`; the first launch
  tracking the restored project windows; entering a project from home becoming that
  project window, and a second click on it bringing the window forward.
- **Live, before it is done**: home with this Mac's real transcripts, its counts checked
  against the sidebar of each project opened; ⌘T and the tab bar's **+** opening home as a
  tab; a running and a waiting session in one project showing on its row from another tab;
  an outside worktree created with `git worktree add`, its session listed under its repo.

## Out of scope, next

- **Tokens spent per project.** Needs every transcript read whole, each response counted
  once, not the 64KB tail rows read today. Its own step: an incremental index in DrakarKit,
  each file read from where it was last read, kept on disk, built in the background. Armada
  already counts this and is the reference; Drakar copies the method, not a dependency.
- **Cross-project toolbar.** The waiting count across every project, and a way to jump to
  the next session needing the person in any of them, beside Keep on Top.
- **Reordering or grouping projects by hand.**
- **Per-project settings** (default account or model for new sessions, PLAN.md §7.2).
