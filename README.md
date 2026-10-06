# Drakar

A native macOS app to drive Claude Code: the conversation, the tool calls, the permission
prompts and the diffs, in a window as light as Zed. It runs the `claude` you installed over
its stream-json protocol, the same way the VS Code extension does. The product and technical
plan is [PLAN.md](PLAN.md); the protocol is [docs/claude-stream-json.md](docs/claude-stream-json.md).

Distributed directly (Developer ID, Sparkle), never through the Mac App Store: it spawns
processes that work on your files, which App Sandbox forbids.

Settings › General picks which `claude` runs when more than one is installed, and the
account (`CLAUDE_CONFIG_DIR`) a new session starts under. The footer warns when the CLI is
outside the versions Drakar was tested with, since the protocol it speaks is undocumented.

## Drakar as the editor of `claude` in a terminal

While Drakar runs, a `claude` started with `claude --ide` in a folder Drakar has open (or
connected with `/ide` in a running session) sends every edit to Drakar's Review Changes
window, and writes the file only if you accept it there. Settings › General picks the
folders: those open in Drakar (the default), any folder in your home folder, or none. How
it works, and what was verified: [docs/claude-ide-bridge.md](docs/claude-ide-bridge.md).

## The editor

A session window shows its folder's files in the sidebar and opens them as tabs beside
the conversation, with line numbers and colours, saved with ⌘S, found by name with ⌘P,
and searched with ⇧⌘F. When the agent changes an open file, its tab reloads; if you had
edited it too, Drakar asks which version to keep, and it asks before a window with
unsaved tabs closes. What you select (or the file you have open) goes with your next
prompt, as in the VS Code extension, and with a terminal `claude --ide`'s too. ⌥K pins a
selection so the next one can be added beside it.

`make audit` checks the network claim against the sources (one listener, on 127.0.0.1,
token-gated, nothing outgoing), and `make audit-running` against the running app.

## Layout

| Path         | What it is                                                                          |
| ------------ | ----------------------------------------------------------------------------------- |
| `apps/apple` | The app: one Xcode project, one macOS target, local SPM packages, driven by `make`. |
| `docs/`      | The protocol spike and product documentation.                                       |
| `design/`    | The brand marks: `drakar-icon.svg`, which `make icon` in `apps/apple` builds.       |

`apps/website` (the marketing site) and `apps/api` (the licence Worker) arrive
later, in the same places as every sibling under `~/Projects/apps`.

## Building

```sh
make help          # every target, from the root or from apps/apple
make build         # Debug
make test          # DrakarKit: offline, no Xcode, under a second
make test-all      # DrakarKit, then the app's hosted suite
make run           # build, quit the old copy, launch the app
```

The Swift half has no Node dependencies. Formatting is `xcrun swift-format` with the root
`.swift-format`; `make format-swift-check` is the gate CI will run.
