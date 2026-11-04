# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged `app-v<version>` the way the sibling repos are, `app-v1.3.0` being the newest.
The GitHub release notes, the Sparkle update dialog and the app's What's New pane are all rendered
from this file, which is the curated summary. `### Internal` sections are left out of all three.

## [1.3.0] - 2026-11-04

**Sessions in tabs.** A project window's sessions are tabs that switch at once, and closing one
while its agent works lets the turn finish first. A long idle session also compacts before its
prompt cache runs out, and streaming costs your Mac far less.

### Added

- **Session tabs.** A window's sessions are tabs above the conversation, in the order you put
  them: a new one opens right of the tab shown, a drag moves one, and ⌘-click or ⇧-click marks
  tabs for one prompt to all. A session opened from Elsewhere or Ended shows in a single preview
  tab that the next one replaces; a double click keeps it. ⌘W closes the tab shown (the editor's
  file first, while the editor has the keys), ⌘1–⌘9 pick a tab, and ⌃Tab or ⇧⌘] moves to the next.
  A session shown recently comes back at once, its scroll position and draft kept.
- **Closing a tab at work lets the turn finish.** The agent goes on in the background, listed
  under Elsewhere, and ends with its turn unless you open it again. Closing asks first only when
  something would be lost: a draft, or a turn Drakar cannot hand over.
- **Idle compaction.** A session with 200k tokens of context, left idle, compacts six minutes
  before its hour of prompt cache runs out, as Claude Code does in a terminal, so the next prompt
  starts from a summary rather than reading the whole conversation again uncached. Settings ›
  General › Compaction turns it off, or sends a command of yours first, such as `/distill`. The
  Session inspector's Compact does the same on demand.
- **Send a queued message now.** An ↑ beside the first queued message stops the turn, as Esc does,
  and the queue goes at once.

### Changed

- A streaming reply is drawn 20 times a second rather than on every token, and no longer redraws
  the other windows, Home or the sidebar, so several agents at work no longer keep Drakar busy.
- The sidebar keeps Elsewhere and Ended; the sessions it listed under This Window are the tabs.
- A session with a very long log reopens in seconds rather than minutes.

### Fixed

- Scrolling up while an agent writes stays where you scrolled.
- Settings › Runner and a runner window's toolbar draw their icon.

## [1.2.0] - 2026-11-02

**Sessions on another Mac.** A second Mac kept on can run your Claude Code sessions, its screen
and all, while you follow and answer them from yours. And permission rules get a tab, `drakar .`
opens a folder, and the Mac stays awake while an agent works.

### Added

- **Sessions on another Mac.** Name a second Mac in Settings › Runner, reached through your own
  ssh, and a session's `claude` runs there, in a folder there, with that Mac's MCP servers and
  screen, while you follow it, answer its prompts and send yours from your Mac. Home lists the
  runner's sessions and starts new ones there, and closing the window or quitting leaves them
  running. The runner takes nothing until "Let my other Macs start sessions here" is on in its
  own Settings. Setting one up is in
  [docs/runner.md](https://github.com/mgcrea/drakar/blob/main/docs/runner.md).
- **Permission rules.** The inspector's Rules tab lists the rules a session runs under and where
  each comes from, and adds or removes yours, with or without a session running.
- **Open Plan.** Session › Open Plan (⌥⌘P) opens the session's plan file in a tab.
- **The `drakar` command.** `drakar .` opens a folder in Drakar, as `code .` does in VS Code, and
  so do `open -a Drakar` and a folder dropped on the Dock icon. Drakar links the command into
  `~/.local/bin` when your shell's PATH has it; Settings › General installs it elsewhere.
- **The Mac stays awake while an agent works,** even through a quit, and may sleep again once the
  agent finishes or waits for you. Settings › General turns it off.
- **Reconnect a failed MCP server.** While a session runs, the inspector's MCP pane lists that
  session's own servers, and a failed one reconnects without restarting the session: its tools
  are there at the next prompt.

### Changed

- Home and a project's sidebar list sessions without waiting for your login shell, so a slow
  `.zshrc` no longer holds the spinner, and a project window opens faster on a long history.
- Settings groups its panes in three sections: how sessions behave, this build, and the licence.
- The prompt cache timer sits left of the model in the composer, as in the VS Code extension.

## [1.1.0] - 2026-10-30

**Drakar is on sale, and a prompt can rewind.** A licence is $14.99 (€14.99 with VAT), once, for
every 1.x release on every Mac you own, with a 30-minute trial and a 30-day refund. And any prompt
in a Claude Code session can now fork the conversation from there, rewind your files to that
point, or both.

### Added

- **A licence, sold once.** Settings › Licence takes a key, starts a 30-minute trial, and links to
  the store. Without a key or a trial Drakar sends nothing to an agent, and everything else stays:
  your projects, sessions, transcripts and diffs, and a turn already running keeps going. The key
  is checked on your Mac, never by a server. The terms are at drakar.mgcrea.io/terms.
- **Rewind and fork from a prompt.** Hover a prompt, or right-click beside it: fork the
  conversation from there, rewind the files Claude changed since, or both. The rewind shows which
  files it would restore, and how much, before anything changes.
- **Mark All Sessions.** Session › Mark All Sessions (⌥⌘A) marks every session in the window, from
  anywhere, for one prompt to all of them.

### Fixed

- A fork you have not sent yet comes back after a relaunch, with its draft.
- A question's card takes the keyboard when its session is opened from the sidebar.
- A subagent sent to the background says so on its card.
- A rewind overtaken by a turn that starts under it says so, rather than reporting a failure.

## [1.0.0] - 2026-10-30

**Claude Code, in a native Mac window.** The conversation, the tool calls, the permission prompts
and the diffs, in a window as light as Zed, driving the `claude` you already installed.

### Added

- **Claude Code's conversation, natively.** Drakar runs the `claude` you installed over its
  stream-json protocol, the way the VS Code extension does, and shows the conversation, the tool
  calls, the permission prompts and the diffs in a native window.
- **Codex as a second agent.** A session can run Codex instead, through its `app-server`.
- **Which `claude`, and which account.** Settings › General picks the `claude` that runs when more
  than one is installed, and the account (`CLAUDE_CONFIG_DIR`) a new session starts under. The
  footer warns when the CLI is outside the versions Drakar was tested with, since the protocol it
  speaks is undocumented.
- **The editor for `claude` in a terminal.** While Drakar runs, a `claude --ide` started in a
  folder Drakar has open (or connected with `/ide`) sends every edit to Drakar's Review Changes
  window, and the file is written only if you accept it there. Settings › General picks the
  folders.
- **An editor beside the conversation.** A session window shows its folder's files in the sidebar
  and opens them as tabs, with line numbers and colours, saved with ⌘S, found by name with ⌘P and
  searched with ⇧⌘F. A tab the agent changes reloads; if you edited it too, Drakar asks which
  version to keep, and it asks before a window with unsaved tabs closes.
- **Your selection goes with the prompt.** What you select, or the file you have open, goes with
  your next prompt, as in the VS Code extension, and with a terminal `claude --ide`'s too. ⌥K pins
  a selection so the next one can be added beside it.
- **Sessions that outlive the app.** A small helper holds the `claude` and `codex` processes, so a
  quit, a crash or an update leaves them working, and the next launch attaches again and replays
  what they did meanwhile.
- **Many sessions, one window.** The sidebar sorts what needs you first; ⌥⌘↑ and ⌥⌘↓ move between
  sessions, and Next After Replying shows the next one waiting. Mark several with ⌘-click and send
  them one prompt, or run a skill in a session per subfolder, a few at a time.
- **Answered where they are asked.** Permission prompts, the agent's questions and an MCP server's
  questions are answered in their card in the transcript; a yes-or-no question also from the
  toolbar, with ⌥⌘Y or ⌥⌘N.
- **Tasks and subagents.** A subagent's card shows its whole conversation. A running task can be
  stopped, sent to the background, and its output read.
- **Sessions run elsewhere.** A session a terminal or VS Code runs shows its state in the sidebar,
  and can be moved into the window. A folder's sessions can move to another account.
- **A Skills window.** Both agents' skills, commands and plugins in one list, installed from a git
  address or a folder, shared between projects, and deleted without leaving dangling links.
- **Updates, when you ask for them.** Drakar checks for updates only once you said yes. Settings ›
  What's New keeps each release's notes, with a count on its row while some are unread.
