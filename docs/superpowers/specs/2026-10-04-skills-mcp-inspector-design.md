# Skills and MCP servers inspector

A project window gets a right-hand column, the inspector, listing what Claude Code would
load in that project: its skills and its MCP servers. A click on a skill runs it in a new
session; a right click runs it in the current one. The servers show their status, so a
failed or unauthenticated one is visible before a session trips over it.

## Why

What a project's `claude` can do is invisible until a session is running and the person
types `/` or `/mcp`. Skills are many (about 100 on this Mac, most from plugins) and their
names are hard to remember; MCP servers fail or lose their auth silently, and the first
sign is a tool call that never comes. The person wants both lists in view while they work,
and a skill one click away.

## Decisions

Settled with the person on 2026-10-04.

| Question | Decision |
| --- | --- |
| Where | A right-hand inspector column in the project window, two folding panes like the left sidebar's |
| A click on a skill | Runs it in a new session. With no arguments it is sent at once; with an `argumentHint` the new session opens with `/name ` in the composer and the hint as placeholder |
| A right click | Run in Current Session (same rule), Run in New Session, Copy Name |
| What the MCP pane does | Status at a glance in v1. Fixing (authenticate, reconnect) and per-session toggling come later |
| Where the lists come from | A short probe process per project, refreshed by the project's own sessions (approach A below) |
| Shared per | Project folder, not window |
| Refresh on file changes | Yes, from the project's `.claude/` and `.mcp.json` |
| Telling the person something changed | Marked rows, and a dot on the inspector's toolbar button while it is hidden. No system notification |

## What the CLI tells us (verified 2026-10-04, 2.1.288)

A `claude` started with Drakar's arguments answers two control requests before any prompt,
in about 1.2 to 1.8 s, without writing a transcript:

- **`initialize`** (already sent by every session): its reply's `commands` lists 161
  entries, each `{name, description, argumentHint}`, plus `builtin: true` on the 58 that
  are the CLI's own (`compact`, `init`, `loop`, …) and `aliases` on some. `argumentHint` is
  always present; `""` means the command takes no arguments. Plugin skills are namespaced
  (`superpowers:brainstorming`).
- **`mcp_status`** (`{"subtype":"mcp_status"}`, new to Drakar): its reply's `mcpServers`
  lists every server, each `{name, status, source, scope, config}`, plus `serverInfo`
  (`name`, `title`, `version`) and `tools` (`[{name, annotations: {readOnly, destructive}}]`)
  when connected, and `error` when failed. Seen: `status` `connected`, `needs-auth`,
  `failed`, `pending`; `source` and `scope` `user`, `plugin`/`dynamic`, `claudeai`.

**`config` carries secrets.** A user server's `config.headers` came back with its
`Authorization: Bearer …` in clear. Drakar never decodes `config`.

**A probe registers as a live session.** While it runs, `<config>/sessions/<pid>.json`
exists (`status: idle`, `entrypoint: claude-vscode`, a derived name), and it is removed
when the process exits after its stdin closes. Drakar's own lists already skip its
children (`LiveSession.read` drops entries whose parent is Drakar); Armada shows it as an
idle session for a second or two.

These findings go into `docs/claude-stream-json.md` as a "Skills and MCP status" section.

## Approach

Three were weighed:

- **A. A probe per project, refreshed by live sessions** (chosen). The CLI's own view,
  including claude.ai connectors and live status, with none of its resolution rules copied
  into Drakar. Costs a process per probe, which starts every stdio MCP server it connects.
- **B. Read the files** (`~/.claude/skills`, `.claude/skills`, enabled plugins, `.mcp.json`,
  `~/.claude.json`). Instant, but copies precedence and plugin rules that will drift, cannot
  see claude.ai connectors, and has no status at all.
- **C. Live sessions only.** No extra process, but empty in a fresh window, exactly when a
  one-click session is wanted.

## Layout

The inspector is `.inspector(isPresented:)` on the project window's `NavigationSplitView`,
shown and hidden by:

- a toolbar toggle (`sidebar.right`) in the `primaryAction` group, beside Projects and Keep
  on Top;
- View › Show Inspector / Hide Inspector, **⌥⌘0**, a `@FocusedBinding` command built as
  `FilesCommand` is.

Whether it is shown, its width, the split between its panes and each pane's folding are
kept per window in `@SceneStorage` (`drakar.inspectorShown`, `drakar.skillsFraction`,
`drakar.skillsCollapsed`, `drakar.mcpCollapsed`). It starts hidden.

Inside, top to bottom:

1. **A filter field**, filtering both panes by name and description, case- and
   diacritic-insensitive. It takes the `isFirst` top padding.
2. **A `VerticalSplit`** of two panes, each under a `PaneHeader`:
   - **Skills** (`sparkles`), trailing: the count, and a refresh button that is a spinner
     while a probe runs.
   - **MCP Servers** (`server.rack`), trailing: the count, and the same refresh button.
   Each pane's rows are a `.sidebar` `List`.

### A skill row

- The name; a plugin skill's namespace in secondary colour (`superpowers:` then
  `brainstorming`).
- One line of description, secondary, truncated; the whole of it in the tooltip.
- Built-in commands are not listed. Order: alphabetical by the name without its namespace.
- **Click**: a new session in the project (`newSession()`), selected, then
  - `argumentHint == ""`: `/name` is sent;
  - otherwise: the draft is `/name `, the composer shows the hint as its placeholder, and
    takes focus.
- **Context menu**: Run in Current Session (the same rule, in the selected session;
  disabled with no selection, a read-only session, or one mid-turn), Run in New Session,
  Copy Name.

### A server row

- A status dot in the sidebar's colours: green connected, blue needs auth, red failed, grey
  pending or anything else.
- The name; below it, secondary: the source (User, Project, Plugin, claude.ai) and the
  tool count, or for a failed server its error.
- A disclosure lists its tools, read-only and destructive ones marked.
- Order: failed, needs auth, then the rest; alphabetical within each.
- No click action in v1.

## Data

### DrakarKit

- **`ClientMessage.mcpStatus(requestID:)`**: `{"type":"control_request","request_id":…,
  "request":{"subtype":"mcp_status"}}`.
- **`ProjectCapabilities`**: `skills: [SkillEntry]?` and `mcpServers: [MCPServerEntry]?`,
  each nil when its reply did not come or did not hold the list.
  - `SkillEntry(name, description, argumentHint)`, from `commands`, built-ins dropped.
  - `MCPServerEntry(name, status, source, version?, tools: [MCPTool], error?)`, with
    `MCPServerStatus` `connected`, `needsAuth`, `failed`, `pending`, `other(String)`, and
    `MCPTool(name, isReadOnly, isDestructive)`. **`config` is not read.**
  - Decoded leniently from the two replies' `JSONValue`s: a missing field is nil or empty,
    an unknown status is `other`, nothing throws.
- **`CapabilityChanges.diff(from:to:)`**: the skills added, and the servers that are new
  and failed or needing auth, or whose status went from connected to anything else. A
  removed row and a status that got better mark nothing.

### App

- **`CapabilityProbe`**: starts `claude` through `AgentProcess` with `ClaudeCommand`'s
  arguments, in the project's folder, with the environment and executable a new session
  would get. That part of `ClaudeSession.start` (shell environment, `ClaudeChoice`'s
  account and executable, `executableOverride`) moves into one helper both use. It sends
  `initialize` and `mcpStatus`, waits for both replies up to 20 s, then closes stdin, and
  terminates the process if it is still there 2 s later. Never a hard kill first: that
  leaves the registry entry behind.
- **`Capabilities`** (`@Observable`), one per project, in a store keyed by
  `ProjectPath.normalize(folder)`, the key `ProjectList` and `OpenSessions` use:
  `state` is loading, loaded (with the time), or failed (with the message and stderr tail),
  and the last loaded `ProjectCapabilities` is kept through a reload. It lives for the
  launch, never on disk: a tab closed and reopened shows the last lists while it probes.
- **What refreshes it**:
  1. The first window or tab for the folder appearing.
  2. A refresh button.
  3. A session in the project receiving its `initialize` reply: `ClaudeSession` stops
     ignoring it and hands `commands` to the store, which replaces the skills only. Only a
     session whose folder is the project's own counts: a worktree session (inside or
     outside the repo) is another checkout, and must not replace the project's list.
  4. A change under the project's `.claude/skills/`, `.claude/commands/`,
     `.claude/settings*.json` or `.mcp.json`, from the paths `Workspace`'s `FolderWatcher`
     already delivers, two seconds after the last one. Changes under `~/.claude` are not
     watched; the refresh button covers them.
  One probe per folder at a time; a refresh asked during one runs once after it, however
  many were asked.
- **Nested projects** (`drakar/` and `drakar/apps/apple`) are two keys and two probes, each
  in its own folder, as their sessions run.
- **Home never probes.** Only projects open in a window or tab do: a probe per tracked
  project would start every stdio server once per project.
- **Accounts.** The probe runs under the account a new session would
  (`ClaudeChoice.newSessionAccount`). If accounts become per window (`feat/window-account`),
  the probe takes the window's, and the store's key becomes folder and account.

### Running a skill

`Project.run(_ skill: SkillEntry, in target: .newSession | .current)`: picks or makes the
session, then sends `/name` or sets the draft and asks the composer for focus.
`ComposerView` gains an optional placeholder, cleared once the draft no longer starts with
the prefilled text, and a focus request it honours on appear.

## Change marks

- **`Project.capabilityMarks`**, per window, not in the shared store: one tab having seen a
  change does not clear it in another.
- Each new result is diffed against the one before it (`CapabilityChanges`); its additions
  and worsened servers are marked. The first result of a launch marks nothing.
- A row's mark is a blue dot, as on an unread session row. It clears when the row is run or
  its disclosure opened; all clear when the inspector is hidden after being on screen.
- While the inspector is hidden and anything is marked, its toolbar button has a dot, and
  its tooltip says what: "2 new skills · github: failed".
- No notification, Dock badge or sound: those are for sessions waiting on the person, and a
  changed list is almost always their own or their agent's doing.

## Errors

| Case | What the panes show |
| --- | --- |
| `claude` not found, or the folder gone | The message a session would show, and Retry |
| Timeout, or one reply only | What arrived; the other pane says "Couldn't read skills" / "Couldn't read MCP status", and Retry |
| The process exits early | "Claude Code exited with status N", the stderr tail in a disclosure as `ProblemBanner` shows it |
| A CLI whose reply lacks `commands` or `mcpServers` | "This Claude Code version didn't list them" |
| A reload failing | The last lists stay, the header's refresh button turns into a warning with the message |

A probe never blocks the window, the sessions or the editor.

## Testing

- **Kit**, against two fixtures captured from 2.1.288 and trimmed, the `mcp_status` one
  with every header and URL token replaced by a dummy before it is committed:
  built-ins dropped; empty and non-empty `argumentHint`; every status and an unknown one; a
  server without `tools` or `serverInfo`; **a fixture server with a bearer header decoding
  to no string that contains it**; `CapabilityChanges` for an added skill, a worsened
  status, an improved one (no mark), a removed row, and a first result; `mcpStatus`
  encoding.
- **App, hosted**: `CapabilityProbe` against a fake `claude` script replaying the fixtures
  (`executableOverride`): both replies; `initialize` then silence (the timeout keeps the
  skills); exit 1 with stderr. The store coalescing three refreshes into one rerun. A
  worktree session's `initialize` reply leaving the project's skills alone. `Project.run`
  in a new and in the current session, sending and prefilling. The watcher's path filter.
- **Live, before it is done**, in this repo with the real CLI: `/check` sends on a click;
  `/simplify` opens with its hint; the needs-auth plugin servers sort first; adding
  `.claude/skills/x/SKILL.md` brings `x` with a dot, and a dot on the toolbar button with
  the inspector hidden; Run in Current Session on an idle session; closing the tab mid-probe
  leaves no `sessions/<pid>.json` behind.

## Out of scope, next

- **Fixing servers**: Authenticate… for needs-auth (likely a session or terminal running
  `/mcp`, the OAuth flow being a browser's) and Reconnect for failed.
- **Toggling a server per session** (`mcp_toggle`, unverified), to save context.
- **Counts on home's project rows** ("12 skills · 2 servers need auth"), which the store
  allows without change.
- **Pinned or favourite skills**, and the CLI's own `/` commands.
- **Per-worktree lists** for sessions in a worktree whose skills differ from the project's.
