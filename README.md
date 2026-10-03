# Amiral

A native macOS app to drive Claude Code: the conversation, the tool calls, the permission
prompts and the diffs, in a window as light as Zed. It runs the `claude` you installed over
its stream-json protocol, the same way the VS Code extension does. The product and technical
plan is [PLAN.md](PLAN.md); the protocol is [docs/claude-stream-json.md](docs/claude-stream-json.md).

Distributed directly (Developer ID, Sparkle), never through the Mac App Store: it spawns
processes that work on your files, which App Sandbox forbids.

## Layout

| Path         | What it is                                                                          |
| ------------ | ----------------------------------------------------------------------------------- |
| `apps/apple` | The app: one Xcode project, one macOS target, local SPM packages, driven by `make`. |
| `docs/`      | The protocol spike and product documentation.                                       |

`apps/website` (the marketing site), `apps/api` (the licence Worker) and `design/` arrive
later, in the same places as every sibling under `~/Projects/apps`.

## Building

```sh
make help          # every target, from the root or from apps/apple
make build         # Debug
make test          # AmiralKit: offline, no Xcode, under a second
make test-all      # AmiralKit, then the app's hosted suite
make run           # build, quit the old copy, launch the app
```

The Swift half has no Node dependencies. Formatting is `xcrun swift-format` with the root
`.swift-format`; `make format-swift-check` is the gate CI will run.
