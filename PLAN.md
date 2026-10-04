# Drakar: product and technical plan

Name: **Drakar**, chosen 2026-10-03 (bootstrapped as Amiral and renamed the same day,
before anything had shipped). The longship: light, fast, shallow in draft, built to go
anywhere with a small crew. It sails with **Armada**, which watches every session on the
Mac; Drakar is the one ship you steer. A native macOS app to work with a coding agent: as light and fast as
Zed, with the conversation, the tool calls, the permission prompts and the diffs as first
class UI. An editor later, but never the centre.

Status: written 2026-10-03, the day the repo was bootstrapped; phases 1 to 4 landed the
same day. **What exists**: DrakarKit decodes and encodes the stream-json protocol against
captured fixtures and supervises the process; the app opens a folder, runs your `claude`
in it, streams the transcript with tool cards, asks permission in a sheet with the CLI's
"always allow" suggestions, and stops a turn. All three were checked against the real CLI
(2.1.288) in the running app. Phase 2 added the session list across accounts, resume
with history, one window per session, and diffs for Edit and Write in the cards and the
permission sheet. Phase 3 made Drakar the editor of `claude` run in a terminal: its edits
arrive as diffs to accept or reject. Phase 4 added a plain-text editor beside the session,
whose selection goes with the next prompt, Drakar's or a terminal `claude`'s. What comes
after is a proposal, and §7 lists what has to be decided before it stops being one.

---

## 1. Positioning

| | Claude Code in VS Code | `claude` in a terminal | Zed's agent panel | This app |
| --- | --- | --- | --- | --- |
| Shell | Electron + webview | your terminal | native (gpui) | native (SwiftUI + AppKit) |
| Agent | bundled `claude` | `claude` | any agent over ACP | your installed `claude` |
| Weight | an editor you may not want | none | an editor you must want | the agent first, an editor later |
| Protocol fidelity | full | full | ACP's common denominator | full (stream-json) |

The wedge: **the agent is the primary object, not a panel in something else.** People who
live in Claude Code open VS Code to get its UI, not to edit. Drakar gives them that UI
without the editor, in a window that opens in a blink and stays smooth at a thousand-turn
transcript.

Core promises, in priority order:

1. Never slower than the terminal. Streaming text paints as fast as it arrives; a long
   session scrolls without a hitch.
2. Nothing is lost against the extension: thinking, tool inputs and results, subagents,
   permission prompts with their "always allow" suggestions, plan mode, todos.
3. Your Claude Code, not ours. The `claude` you installed, your settings, hooks, skills,
   MCP servers and accounts, unchanged. Sessions resume from either side (§2.3).
4. Drakar itself reaches nothing: its one socket listens on 127.0.0.1 for terminal
   sessions holding its token, and it opens no connection (§5, the checkable claim).

## 2. How it drives Claude

`docs/claude-stream-json.md` is the spike, with the exact arguments and every message type
observed. The decisions it supports:

### 2.1 stream-json, not ACP

Drakar spawns `claude --input-format stream-json --output-format stream-json --verbose
--permission-prompt-tool stdio --include-partial-messages`, the same arguments the VS Code
extension passes to its bundled binary. That is full fidelity: every block the model
writes, every structured tool result, every control message.

ACP (the Agent Client Protocol Zed defined) would let one UI drive Claude, Gemini and
Codex, through an adapter that maps Claude Code onto a common set of concepts. Drakar is
Claude-first, so the adapter only loses information. The UI consumes DrakarKit's
`StreamMessage` and `Transcript`, which are stream-json shaped; an ACP backend would have
to map onto them, or a neutral event type would have to be introduced first. None exists
today.

### 2.2 Not the extension's webview

The extension's UI is a 5.8 MB React bundle talking to VS Code through
`acquireVsCodeApi()`. Hosting it in a WKWebView with a shim would reproduce its look
exactly, and is ruled out: the package is "© Anthropic PBC. All rights reserved", its
internal message format changes every release, and a webview plus six megabytes of
JavaScript is the weight Drakar exists to drop. Its layout is the design reference; none of
its code is used.

### 2.3 Sessions are shared on disk

Transcripts live at `<config-dir>/projects/<encoded-cwd>/<session-id>.jsonl` whichever UI
wrote them, and `--resume=<id>` continues any of them. Drakar lists and resumes the same
sessions the extension and the terminal do; it does not keep a store of its own. Armada's
`docs/claude-code-sessions.md` mapped that layout and its traps on 2026-09-10.

### 2.4 Drakar as "the IDE"

An **interactive** `claude` looks for `<config>/ide/<port>.lock` and connects to that
WebSocket as an MCP client, sending every edit as an `openDiff` for the editor to accept
or reject. Drakar writes the lock file, so a `claude --ide` in a terminal, in a folder
Drakar has open, uses it as its editor (phase 3), and hears what is selected in Drakar's
editor (phase 4). Headless sessions, Drakar's own among them, never connect; they get the
selection the way the extension's chat gives it, as a block ahead of the prompt.
`docs/claude-ide-bridge.md` has the contract and its traps.

## 3. Architecture

```text
DrakarKit      Foundation only, zero dependencies, offline tests in under a second. The
               stream-json codec (both directions) and the reducer that folds it into a
               transcript; process supervision over pipes (AgentProcess, tested against
               /bin/cat); finding `claude` and the login shell's environment; the
               session index and history replay; line diffs; the IDE bridge's protocol
               and lock files; the file tree, what a text file is and how it is folded
               back after a change on disk, and selections as `claude` counts them.
App target     The session model and windows, the permission sheet, the review window,
               the editor (an NSTextView over each document's own text storage, FSEvents
               for the folder), settings, and the bridge's WebSocket server (Network
               framework).
```

The rule is calque's: everything that can be argued about in a unit test lives in the
kit. The protocol is undocumented and moves with every Claude Code release, so it is the
part that most needs tests, and those tests run against **captured** output, never output
written by hand from a reading of the SDK.

**The transcript view is the performance risk.** A SwiftUI `List` that re-lays out the
history on every delta will not stay smooth at a thousand turns. Phase 1 builds it in
SwiftUI with an append-only model and measures; if it stutters, the transcript moves to an
`NSTableView` (or TextKit 2) host while the chrome stays SwiftUI. Decided by measurement,
not in advance.

## 4. Phases

0. **Protocol core.** DrakarKit decodes every message type in the spike's captures and
   encodes `initialize`, a prompt and a permission answer. *Done 2026-10-03.*
1. **One session, one window.** Pick a folder, spawn `claude`, stream text and thinking,
   tool calls as collapsible cards with their results, the permission prompt as a sheet
   with its suggestions, interrupt, cost and context in a footer. *Done 2026-10-03*,
   except context usage. Block Markdown (headings, lists, fences, quotes, tables) and
   summarized thinking followed the same day.
2. **Sessions.** The list from disk, resume, several windows, Edit and Write calls shown
   as diffs to accept or reject. *Done 2026-10-03.* The list reads every account
   (`~/.claude`, `~/.claude-*`) and marks sessions live in another process from the CLI's
   own registry; those open as a fork (`--fork-session`), never as a second writer, and a
   session already in an Drakar window brings that window forward. Not yet: following a
   rewound branch of a transcript (history is read in file order), and watching the list
   for changes (it refreshes on demand).
3. **The IDE bridge.** The lock file and the MCP-over-WebSocket server (§2.4). *Done
   2026-10-03*, spiked first against a fake editor (`docs/claude-ide-bridge.md`): a
   terminal `claude --ide` in a folder Drakar has open sends its edits to a Review Changes
   window, Accept writes and Reject does not (both verified), several terminals at once.
   Lock files per account, swept after a crash; `scripts/audit-network.sh` landed with the
   socket. Headless sessions never connect, so Drakar's own windows keep their sheet. Not
   yet: editing the proposal before accepting it, diagnostics, selections.
4. **The editor.** *Done 2026-10-03.* A session window is the folder's files in the
   sidebar, open files as tabs over a plain-text editor, and the session beside them. The
   folder is watched (FSEvents): a file the agent edits reloads in its tab, and one the user
   has edited too asks which version to keep. Save writes in place, through links, keeping
   the file's permissions. The active tab's selection (or only its file) goes with the next
   prompt as the extension's chat sends it, and a chip above the composer leaves it out;
   terminal sessions get it as `selection_changed`, and `openFile`, `getOpenEditors`,
   `getCurrentSelection`, `checkDocumentDirty` and `saveDocument` answer from the open
   tabs. Verified against 2.1.288 in the running app and through a terminal `claude --ide`;
   the document's disk handling by hosted tests, since nothing can type into the text view
   without synthetic input. ⌘P finds a file by a few letters of its name (dependencies and
   build output skipped). Closing a window or quitting with unsaved tabs asks first; the
   window's guard stands in front of SwiftUI's delegate and forwards the rest (a clean
   close checked live, the question by hosted tests: it needs typing to provoke). ⌘W
   closes the active tab, then the window. Line numbers, and colours from a lexer per
   language family (comments, strings, numbers, keywords, types, attributes; no grammar,
   no dependency), applied as layout attributes so they never touch the text or its undo.
   ⇧⌘F searches the folder's text (smart case), each hit opening its file with the match
   selected. ⌥K pins the selection to the next prompt, so one prompt can carry several;
   ⌘⌥K sends `at_mentioned` to a terminal `claude`. A proposal can be edited before it is
   accepted. Not yet: diagnostics, find-and-replace across files.

## 5. Distribution

The fourth Developer ID app in the fleet, after armada, bastion and cupertino. It follows
`fleet-direct-conventions`, with one difference recorded up front:

- **Not an `LSUIElement` app.** The other three are menu bar agents; Drakar is a
  windowed app with a Dock icon, menus and a real `Settings` scene. So the agent-app
  shape (`HostedWindow`, `DockPresence`, the popover) does not apply, and
  `survey.sh drakar` will say so; that is a difference, not drift.
- **Not sandboxed, no entitlements file.** It spawns your `claude`, which runs your tools
  over your files and reads your `~/.claude`; under App Sandbox every child inherits the
  container and none of that works. Bastion's precedent: no `CODE_SIGN_ENTITLEMENTS` at
  all, asserted by the audit, rather than an empty file. Hardened runtime on.
- **Out of the store for good.** Guideline 2.5.2 (executing code the app does not ship)
  and the sandbox both rule the Mac App Store out, which is why Zed, Cursor, VS Code and
  Nova are all distributed directly.

Still to land, in the order `fleet-direct-conventions` gives: Sparkle (vendored 2.9.6),
the release job, the appcast and the site redirects, the licence and trial, the Stripe
Worker (copied from **armada's**, whose price guard fails closed, not bastion's), and the
audit script.

**The checkable claim:** *Drakar opens one socket, a listener on 127.0.0.1 that answers
only a client holding this launch's token, and makes no connection of its own; everything
that reaches the network is the `claude` you installed, or Sparkle.* `make audit` asserts
the sources half and `make audit-running` the live half since phase 3; the binary sweep
below arrives with Sparkle. That is
cupertino's `audit-network.sh` model: an `nm -u`/`otool -L` sweep over every Mach-O in
the bundle, with Sparkle the one named allowance. Phase 3's WebSocket is a listening
socket on loopback, and lands with its own Loopback check in the same commit, as
armada's did.

## 6. What comes from the fleet

- The scaffold from `fleet-apple-conventions/scripts/bootstrap_apple.py`, cut to Mac only.
- swift-support-kit: the Help menu, the settings sidebar, the About pane.
- From armada: the knowledge of Claude Code's on-disk layout and of several config
  directories per Mac (it watches every account), and the licence stack and Worker.
- From cupertino: the audit script's shape.

## 7. Open questions

1. **Which `claude`.** Two are on this Mac's PATH (`~/.local/bin` and Homebrew), and an
   app launched from the Finder does not inherit the shell's PATH at all. The login
   shell's environment is read once per launch (`$SHELL -l -i`, so `.zshrc` additions
   count), and Automatic runs the first executable on that PATH, then in the installers'
   locations (`ClaudeLocator`). Settings lists every install with its version and can pin
   one; a pinned one that disappears falls back to Automatic.
2. **Which account.** `CLAUDE_CONFIG_DIR` selects one; this Mac has more than one config
   directory. A resume runs under the account that wrote the session. A new session runs
   under the one picked in Settings, or the login shell's; the footer names it when it is
   not the default. Still open: picking per session rather than app-wide, which belongs to
   the project window's new-session control.
3. **Protocol drift.** Each fixture's version is in its own lines (2.1.284 for the
   stream captures, 2.1.288 for history and the IDE bridge), and `ClaudeVersion.tested`
   holds that range: the footer's version turns orange outside it, and Settings says why
   beside the install it would run. Still open: the habit of re-capturing on every minor,
   and raising the range only after.
4. **The Sparkle key.** The trio share one EdDSA key, and one leak updates all three. A
   new app has no installed base, so its own key (`generate_keys --account drakar`) costs
   nothing today and a rotation later. Recommended; the owner decides.
5. **Price and trial.** The trio sell a one-time licence with a 30-minute in-memory trial.
   Whether Drakar is sold, and when, is open; `LicenceLinks.isSelling` stays false until
   it is.
6. **The site.** `drakar.mgcrea.io` and the `mgcrea/support/drakar` tracker are wired into
   `Support.swift` ahead of existing, as calque's were. Dead until the website lands;
   `survey.sh drakar --net` before the first release.
7. **The name.** Not on the store, so the store-title check does not apply, but check the
   domain and GitHub `mgcrea/drakar` before the first public release.
