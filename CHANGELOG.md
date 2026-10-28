# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged `app-v<version>` the way the sibling repos are; none is tagged yet. The GitHub
release notes, the Sparkle update dialog and the app's What's New pane are all rendered from this
file, which is the curated summary. `### Internal` sections are left out of all three.

## [1.0.0] - Unreleased

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
