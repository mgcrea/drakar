# Amiral: product and technical plan

Name: **Amiral**, chosen 2026-10-03. An admiral commands a fleet: the agents are the ships,
you give the orders. It pairs with **Armada**, which watches every session on the Mac;
Amiral drives one. A native macOS app to work with a coding agent: as light and fast as
Zed, with the conversation, the tool calls, the permission prompts and the diffs as first
class UI. An editor later, but never the centre.

Status: written 2026-10-03, the day the repo was bootstrapped; phases 1 and 2 landed the
same day. **What exists**: AmiralKit decodes and encodes the stream-json protocol against
captured fixtures and supervises the process; the app opens a folder, runs your `claude`
in it, streams the transcript with tool cards, asks permission in a sheet with the CLI's
"always allow" suggestions, and stops a turn. All three were checked against the real CLI
(2.1.288) in the running app. Phase 2 added the session list across accounts, resume
with history, one window per session, and diffs for Edit and Write in the cards and the
permission sheet. Everything from phase 3 on is a proposal, and §7 lists what has to be
decided before it stops being one.

---

## 1. Positioning

| | Claude Code in VS Code | `claude` in a terminal | Zed's agent panel | This app |
| --- | --- | --- | --- | --- |
| Shell | Electron + webview | your terminal | native (gpui) | native (SwiftUI + AppKit) |
| Agent | bundled `claude` | `claude` | any agent over ACP | your installed `claude` |
| Weight | an editor you may not want | none | an editor you must want | the agent first, an editor later |
| Protocol fidelity | full | full | ACP's common denominator | full (stream-json) |

The wedge: **the agent is the primary object, not a panel in something else.** People who
live in Claude Code open VS Code to get its UI, not to edit. Amiral gives them that UI
without the editor, in a window that opens in a blink and stays smooth at a thousand-turn
transcript.

Core promises, in priority order:

1. Never slower than the terminal. Streaming text paints as fast as it arrives; a long
   session scrolls without a hitch.
2. Nothing is lost against the extension: thinking, tool inputs and results, subagents,
   permission prompts with their "always allow" suggestions, plan mode, todos.
3. Your Claude Code, not ours. The `claude` you installed, your settings, hooks, skills,
   MCP servers and accounts, unchanged. Sessions resume from either side (§2.3).
4. Amiral itself talks to nothing (§5, the checkable claim).

## 2. How it drives Claude

`docs/claude-stream-json.md` is the spike, with the exact arguments and every message type
observed. The decisions it supports:

### 2.1 stream-json, not ACP

Amiral spawns `claude --input-format stream-json --output-format stream-json --verbose
--permission-prompt-tool stdio --include-partial-messages`, the same arguments the VS Code
extension passes to its bundled binary. That is full fidelity: every block the model
writes, every structured tool result, every control message.

ACP (the Agent Client Protocol Zed defined) would let one UI drive Claude, Gemini and
Codex, through an adapter that maps Claude Code onto a common set of concepts. Amiral is
Claude-first, so the adapter only loses information. The decoder sits behind AmiralKit's
own `AgentEvent` vocabulary, so an ACP backend can be added later without the UI knowing.

### 2.2 Not the extension's webview

The extension's UI is a 5.8 MB React bundle talking to VS Code through
`acquireVsCodeApi()`. Hosting it in a WKWebView with a shim would reproduce its look
exactly, and is ruled out: the package is "© Anthropic PBC. All rights reserved", its
internal message format changes every release, and a webview plus six megabytes of
JavaScript is the weight Amiral exists to drop. Its layout is the design reference; none of
its code is used.

### 2.3 Sessions are shared on disk

Transcripts live at `<config-dir>/projects/<encoded-cwd>/<session-id>.jsonl` whichever UI
wrote them, and `--resume=<id>` continues any of them. Amiral lists and resumes the same
sessions the extension and the terminal do; it does not keep a store of its own. Armada's
`docs/claude-code-sessions.md` mapped that layout and its traps on 2026-09-10.

### 2.4 Later: Amiral as "the IDE"

A running `claude` looks for `~/.claude/ide/<port>.lock` (`workspaceFolders`, `ideName`,
`transport: ws`, `authToken`) and connects to that WebSocket as an MCP client, calling the
editor's tools: open a diff, read diagnostics, read the selection. An Amiral that writes
the lock file becomes the editor of every `claude` on the Mac, including one started in a
terminal. That is phase 3 and the bridge to the editor.

## 3. Architecture

```
AmiralKit      Foundation only, zero dependencies, offline tests in under a second. The
               stream-json codec (both directions), the AgentEvent vocabulary, and the
               reducer that folds events into a transcript: merging per-block `assistant`
               lines by message id, applying deltas, pairing tool_use with tool_result.
App target     Process supervision (spawn, stdin/stdout pipes, interrupt, exit), binary
               resolution, the session window, the permission prompt, settings.
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

0. **Protocol core.** AmiralKit decodes every message type in the spike's captures and
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
   session already in an Amiral window brings that window forward. Not yet: following a
   rewound branch of a transcript (history is read in file order), and watching the list
   for changes (it refreshes on demand).
3. **The IDE bridge.** The lock file and the MCP-over-WebSocket server (§2.4).
4. **The editor.** A file tree and a text view, grown out of the diff view.

## 5. Distribution

The fourth Developer ID app in the fleet, after armada, bastion and cupertino. It follows
`fleet-direct-conventions`, with one difference recorded up front:

- **Not an `LSUIElement` app.** The other three are menu bar agents; Amiral is a
  windowed app with a Dock icon, menus and a real `Settings` scene. So the agent-app
  shape (`HostedWindow`, `DockPresence`, the popover) does not apply, and
  `survey.sh amiral` will say so; that is a difference, not drift.
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

**The checkable claim (proposed):** *Amiral makes no network connection of its own;
everything that reaches the network is the `claude` you installed, or Sparkle.* That is
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
   app launched from the Finder does not inherit the shell's PATH at all. Proposal: probe
   the known install locations, show the one found with its `--version` in Settings, let
   the user pick, and run it through a login shell only if nothing is found.
2. **Which account.** `CLAUDE_CONFIG_DIR` selects one; this Mac has more than one config
   directory. A session window needs to know which it runs under, and the session list
   should read all of them, as Armada does.
3. **Protocol drift.** Record the Claude Code version each fixture came from, fail
   loudly in the UI (not silently) on a `system/init` from a version outside the tested
   range, and re-capture on every minor.
4. **The Sparkle key.** The trio share one EdDSA key, and one leak updates all three. A
   new app has no installed base, so its own key (`generate_keys --account amiral`) costs
   nothing today and a rotation later. Recommended; the owner decides.
5. **Price and trial.** The trio sell a one-time licence with a 30-minute in-memory trial.
   Whether Amiral is sold, and when, is open; `LicenceLinks.isSelling` stays false until
   it is.
6. **The site.** `amiral.mgcrea.io` and the `mgcrea/support/amiral` tracker are wired into
   `Support.swift` ahead of existing, as calque's were. Dead until the website lands;
   `survey.sh amiral --net` before the first release.
7. **The name.** Not on the store, so the store-title check does not apply, but check the
   domain and GitHub `mgcrea/amiral` before the first public release.
