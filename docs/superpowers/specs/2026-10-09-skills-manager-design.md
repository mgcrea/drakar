# Skills manager window (part 1 of 2: skills; part 2 is plugins)

Status: approved in conversation on 2026-10-09 (§1 presented; the person waived per-section
approval for the rest and will review the implementation).

## Why

Skills reach Drakar's two agents from many places: the account's own folder, the project,
plugins, Codex's built-in set, folders linked in by hand. The person shares skills between
Claude Code and Codex with symbolic links today, by hand. They want one window that shows
every skill, where it comes from and which agent sees it, and that can install, share and
delete skills.

Part 2 (a later spec) manages plugins: installed plugins per agent, enable and disable,
uninstall, marketplaces. In this part plugin skills are listed, read-only.

## Decisions

| Question | Decision |
| --- | --- |
| Where | A window of its own, `Window("Skills", id: "skills")`: Window menu "Skills", and a "Manage…" button in the inspector's Skills pane. |
| Which project | The window shows one project at a time: the project of the window it was opened from, changeable with a picker listing the open projects, or none (user-level skills only). |
| Sharing | Symbolic links: one real folder, a link in the other agent's folder. Never copies, except when installing with "Copy" chosen. |
| Delete | A link is removed; the folder it points to is never touched. A real folder goes to the Trash. Plugin, Codex system and admin skills cannot be deleted here. |
| Install | From a folder on disk (link it in, or copy it in), or from a git URL (a shallow clone in a folder Drakar manages, then links). |

## §1 Finding skills and where they come from

**Codex: ask Codex.** `skills/list {cwds: [project]}` lists every skill with `path` (its
SKILL.md), `scope` (`repo`, `user`, `system`, `admin`), `pluginId` and `enabled`. A new
DrakarKit parse, `CodexSkillList.records(_:)`, keeps all of it, shadowed duplicates
included (today's `entries(_:)` keeps one per name for the `/` menu and stays as it is).
The read goes through the existing per-folder `CodexSkills` store (its one-shot reader),
extended to keep the records next to its entries, so one `skills/list` serves both. With no
project chosen, the read uses the home folder as its cwd (user-level skills only, no repo
scope).

**Claude: read the places Claude reads, then cross-check.** Claude's `initialize` reports
names only, so a DrakarKit scanner, `ClaudeSkillScan`, reads:

- the account's own skills: `<account directory>/skills/<name>/SKILL.md` (the account is
  the chosen project window's account, `AccountStore.windowAccount(for:)`; with no project,
  the Settings default account);
- the project's `.claude/skills/<name>/SKILL.md` and `.claude/commands/**/*.md` (commands
  are named by their path below `commands/`, `a/b.md` → `a:b`, as Claude does);
- plugin skills: `<account directory>/plugins/installed_plugins.json` (version 2:
  `plugins["name@marketplace"] = [{scope, projectPath?, installPath, version}]`) gives each
  plugin's install path; an install is in effect for a `user` scope, or a `project` or
  `local` scope whose `projectPath` is the chosen project. `<account
  directory>/settings.json` `enabledPlugins["name@marketplace"]` says on or off (absent
  means on). Skills are `<installPath>/skills/<name>/SKILL.md`, named `plugin:name`.

A skill's name and description come from its SKILL.md frontmatter (`name`, `description`),
else the folder name; a command's description from its frontmatter `description`, else
empty. A folder without a SKILL.md is not a skill and is skipped.

The scan is checked against the names Claude itself reports (the existing `Capabilities`
lists, loaded if needed): a scanned skill Claude does not list reads "Not loaded by Claude
Code" (broken frontmatter, a disabled plugin); a reported name the scan cannot place is
listed with origin "Unknown". Before Claude's list has loaded, nothing is marked.

**One row per real skill.** Each location is resolved through its links
(`URL.resolvingSymlinksInPath`). Locations whose real folder is the same become one row:
`~/.claude/skills/find-skills` (a link) and `~/.agents/skills/find-skills` (the folder) are
one row seen by Claude and Codex. A DrakarKit `SkillInventory.merge` builds the rows from
the Claude scan, Claude's reported names and Codex's records. A row (`SkillRecord`) has:

- `name`, `description`;
- `kind`: skill or command (Claude's `.claude/commands`);
- `origin`: `.user` (an account's or `~/.agents`'s own folder), `.project`, `.plugin(id)`,
  `.codexSystem`, `.codexAdmin`, `.unknown`;
- `sightings`: per agent, the path the agent sees it at (the link, if it is one), and
  for Codex whether it is enabled or shadowed by a nearer skill of the same name;
- `realPath`: the resolved folder (or file, for a command);
- `isLink`: true when any sighting's path differs from `realPath`;
- `notLoadedByClaude`;
- `canDelete`, `canShare`: true only for `.user` and `.project` origins.

**Live.** The window's model refreshes when a skill folder changes: `FolderWatcher` on each
existing user root (`<account>/skills`, `~/.agents/skills`, `~/.codex/skills`; the plugins
folder is not watched, plugins change in part 2), the chosen project's `.claude/skills`, `.claude/commands`, `.agents/skills`, `.codex/skills`
(through the project's existing `Workspace` callbacks when the project is open, which it
always is when chosen), and when a Codex session reports `skills/changed` (already wired to
the `CodexSkills` store). After an action of its own the window refreshes at once.

## §2 The window

Three columns (`NavigationSplitView`):

- **Sidebar, places:** All; Yours (the account's name in a caption, e.g. "personal"); This
  project (the project's folder name); Plugins; Codex built-in (system and admin). Each with
  a count. Above, the project picker.
- **List:** a `Table` of the place's skills, sortable by name: Name (with a link badge when
  `isLink`), Agents (a "Claude" and a "Codex" tag, dimmed when that agent's sighting is
  disabled or shadowed), Origin (Yours, Project, the plugin's id, Codex system, Codex admin,
  Unknown), Location (the path of the first sighting, abbreviated with `~`; for a link,
  "→ target"). A filter field matches name and description (`SkillEntry.matches` semantics).
  "Not loaded by Claude Code" and "Shadowed" show as a secondary caption in the Name cell.
- **Detail:** the selected skill: name, description, origin, each agent's sighting path
  and the real path (selectable text), notes (not loaded, shadowed, disabled), and the
  first 4 KB of the SKILL.md (or command file) as plain monospaced text. Buttons: Open
  (in the chosen project window's editor via `Workspace.open`; with no project,
  `NSWorkspace.open`), Reveal in Finder, Share with Codex / Share with Claude (only when
  `canShare` and the other agent has no sighting), Delete… (only when `canDelete`).

Toolbar: Install from Folder…, Install from Git…, Refresh. Loading shows a spinner in the
list; a failed read (Codex's `skills/list`, a scan error) shows the problem above the list
with Retry, and whatever did load stays listed.

Entry points: Window menu "Skills" (no shortcut); inspector Skills pane header "Manage…"
(`inspector.skills.manage`), which opens the window on that window's project. The window
remembers its size; it is not restored at launch.

Accessibility identifiers: `skills.window`, `skills.sidebar`, `skills.table`,
`skills.detail`, `skills.install.folder`, `skills.install.git`, `skills.refresh`,
`skills.share`, `skills.delete`, `skills.open`, `skills.reveal`, `skills.project`.

## §3 Actions

All file operations live in one app-side `SkillActions` type over a `FileSystem` seam
(link, copy, move to Trash, remove link, exists, read) so tests run on temp folders and a
fake trash. Each action returns what it did, or throws an error with a sentence the window
shows in an alert. Nothing overwrites: an existing file or folder at a destination is a
refusal ("A skill named x is already in …").

**Folders per place and agent** (where installs and shares write):

| | Claude | Codex |
| --- | --- | --- |
| Yours | `<account>/skills/` | `~/.agents/skills/` |
| This project | `<project>/.claude/skills/` | `<project>/.agents/skills/` |

Missing folders are created.

**Share** (a `.user` or `.project` skill seen by one agent): create, in the other agent's
folder of the same place, a link named after the skill's folder pointing to `realPath`.
Commands cannot be shared (Codex has no commands).

**Delete…** (a `.user` or `.project` row): a confirmation sheet says exactly what happens,
per sighting:

- a sighting that is a link: "Remove the link at `<path>` (the folder it points to stays)";
- the real folder or command file: "Move `<path>` to the Trash", and every link found
  pointing at it from the four folders above (for the account and the chosen project) is
  removed too, so no dangling link is left;
- if the real folder lies outside those folders (a link to `~/Projects/claude-skills/…`),
  only the links are removed and the sheet says the folder itself stays.

**Install from Folder…**: an `NSOpenPanel` (folders, or a SKILL.md file → its folder). If
the chosen folder has a SKILL.md it is one skill; otherwise its subfolders with a SKILL.md
(depth ≤ 3) are offered as a checklist. A sheet then asks: Place (Yours / This project),
Agents (Claude, Codex, both; default both), Method (Link to it where it is, default; or
Copy into the place's folder). Link: a link per agent pointing at the chosen folder. Copy:
the folder is copied once into the first selected agent's folder and the other agent gets a
link to the copy.

**Install from Git…**: a sheet with a URL field (https or `git@`), then the same Place and
Agents choices. Drakar runs `git clone --depth 1 <url> <dest>` with the login-shell
environment (`AgentSession.environment`), 120 s timeout, where `<dest>` is
`~/.agents/skill-sources/<host>/<owner>/<repo>` (from the URL; an existing clone there is
reused after `git -C <dest> pull --ff-only`). The clone's SKILL.md folders (depth ≤ 4) are
offered as a checklist; each picked skill is linked into the chosen agents' folders. Errors
show git's stderr. `git` not found: "Git was not found. Install the Xcode command line
tools." A skill whose `realPath` is inside `skill-sources` shows "Update" in the detail
(runs the pull) and its Delete removes the links, then moves the clone to the Trash when no
link in the four folders points into it any more.

## Errors and edge cases

| Case | Behaviour |
| --- | --- |
| `codex` not installed | Codex sightings are absent; a caption "Codex was not found" under the list; Claude's still listed. |
| Claude's capabilities fail to load | No "not loaded" marks; scan results still listed. |
| A link whose target is gone | Listed as a row with origin from its place, description "Missing: `<target>`", Delete removes the link. |
| Name clash on share or install | Refused with a sentence; nothing written. |
| Unreadable SKILL.md | Row with the folder name and an empty description. |
| Skill folder changed by hand while open | Watchers refresh the list; a vanished selection clears the detail. |
| No project chosen | "This project" place hidden; installs offer Yours only. |

## Testing

- DrakarKit: `ClaudeSkillScan` on temp folders (account skills, a link, a dangling link,
  project skills, commands with subfolders, plugins from an `installed_plugins.json` and
  `settings.json` fixture: user scope, project scope for this and another project,
  disabled); `CodexSkillList.records` on the existing fixture (shadowed and disabled kept);
  `SkillInventory.merge` (one row for a skill linked into both agents, not-loaded marking,
  unknown origin, plugin and system origins non-deletable).
- App: `SkillActions` on temp folders with a fake trash (share; delete a link, delete a real
  folder and its links, delete a link to an outside folder; install link and copy; refusals
  on clashes); git install against a local repository created in the test (`git init`,
  commit, clone from a `file://` URL), including reuse with pull and the clone trashed when
  its last link goes; the window model choosing project and account, filtering, and
  refreshing after an action; the inspector's Manage button opening the window on its
  project.
- A check in the running app after the person's go-ahead for `make run`.

## Not in this part

Plugins (part 2). Creating a new skill from scratch. Editing SKILL.md in this window
(Open uses the editor). Enabling or disabling Codex skills (`skills/config/write`). Claude
accounts other than the chosen window's. Codex accounts (`CODEX_HOME`).
