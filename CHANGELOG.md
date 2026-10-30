# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged `app-v<version>` the way the sibling repos are, `app-v1.0.0` being the newest.
The GitHub release notes, the Sparkle update dialog and the app's What's New pane are all rendered
from this file, which is the curated summary. `### Internal` sections are left out of all three.

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
