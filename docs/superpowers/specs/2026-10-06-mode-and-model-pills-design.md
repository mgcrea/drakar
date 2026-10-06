# Mode and model pills in the composer

The composer gets two pills, as the VS Code extension has: the session's permission mode and
its model. A change applies to a running session at once, without a restart; for one not
started it goes on the command line. New sessions start with the mode and model set in
Settings. Bypass permissions is offered when a Settings switch allows it, on by default.

## Why

Drakar starts every session with Claude Code's defaults and offers no way to change them: the
model is whatever `settings.json` says, the mode is "Ask before edits", and switching either
means a terminal. The footer names the model since `2026-10-05` but cannot change it.

## Decisions

Settled with the person on 2026-10-06.

| Question | Decision |
| --- | --- |
| Where | Two pills under the composer's field, left of Send |
| A new session's mode and model | Settings' default mode and model, else Claude Code's. A pill change lasts for its session (revised the same day: folders no longer remember picks) |
| Effort | Not now |
| Bypass permissions | A Settings switch, on by default. On, sessions start with `--allow-dangerously-skip-permissions`, which makes Bypass available. Bypass is not tinted. Settings' default mode can be Bypass while the switch is on |

## What the CLI does (verified 2026-10-06, Claude Code 2.1.288)

A process started with Drakar's arguments, sent control requests before any prompt (no API
call, no transcript):

- **`initialize`**'s reply carries `models`: each `{value, resolvedModel, displayName,
  description, supportsEffort, supportedEffortLevels, supportsAdaptiveThinking,
  supportsFastMode, supportsAutoMode}`, in the CLI's order, first `value: "default"`
  ("Default (recommended)", resolved `claude-opus-5-5`), then the aliases (`opus`, `fable`,
  `sonnet`, `haiku`), then pinned ids (`claude-opus-4-8`, …). The list depends on the account.
  The reply also has `current_permission_mode` (`default`).
- **`{"subtype":"set_model","model":"sonnet"}`** answers `success` with no body.
- **`{"subtype":"set_permission_mode","mode":"acceptEdits"}`** answers `success` with
  `{"mode":"acceptEdits"}`, then the CLI writes
  `{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits",…}`.
  `auto` and `plan` likewise.
- **`bypassPermissions`** on a process started without the flag answers `error`:
  `"Cannot set permission mode to bypassPermissions because the session was not launched with
  --dangerously-skip-permissions"`, `error_code: "bypass_not_launched"`.
  `--allow-dangerously-skip-permissions` makes it settable without starting in it.
- `--permission-mode` choices: `acceptEdits`, `auto`, `bypassPermissions`, `manual`,
  `dontAsk`, `plan`; `system/init` and `initialize` report the default as `default`.
- Every prompt line of a transcript carries `permissionMode`, the mode it was sent in.

## The modes

In the pill's order, which ⇧Tab cycles through as the CLI does:

| Value | Title | Symbol | Offered |
| --- | --- | --- | --- |
| `default` | Ask before edits | `hand.raised` | Always |
| `acceptEdits` | Edit automatically | `pencil` | Always |
| `plan` | Plan | `list.bullet.clipboard` | Always |
| `auto` | Auto | `wand.and.stars` | When the session's model says `supportsAutoMode` |
| `bypassPermissions` | Bypass permissions | `exclamationmark.shield` | Settings allows it, and the process (if any) started with the flag |

`manual` (the CLI's other name for `default`) and `dontAsk` are not offered. A mode the CLI
reports that is not in the table shows as its raw value.

## The session's state

`ClaudeSession` gains:

- `permissionMode`: what the process last reported (`system/init`, a `status` line with
  `permissionMode`, a confirmed `set_permission_mode`); nil with no process.
- `modePick` and `modelPick`: what this session's pills picked; nil follows Settings.
- `launchedWithBypass`: the running process had `--allow-dangerously-skip-permissions`.
- `pillNote`: why the last change was refused, until the next change.

What the pills show:

- **Mode:** `permissionMode` while a process runs, else `modePick`, else Settings' default,
  else `default`.
- **Model:** `modelPick`, else Settings' default, else the running model
  (`ModelName.current`), as the catalog's `displayName` for a picked value and
  `ModelName.display` for an id. Nothing known: "Default".

### A change

- **Process running:** the control request goes at once, mid-turn included. Success: the
  pick stands (and for the mode, `permissionMode` takes the reply's `mode`). Error: the pick
  goes back to what it was and `pillNote` says the CLI's reason.
- **No process:** the pick waits for the next start.
- A change is the session's alone: Settings is not touched.

### Starting

`spawn` passes `--model` from `modelPick ?? Settings'` (`default` passes nothing) and
`--permission-mode` from `modePick ?? Settings'` (nothing for `default`, and nothing for
Bypass when Settings no longer allows it). Verified at launch (2.1.288): `--permission-mode
bypassPermissions --allow-dangerously-skip-permissions` starts in Bypass; `--permission-mode
auto` with a model without Auto (`haiku`) starts in `default`, which the pill then shows. With the Settings switch on, every start adds
`--allow-dangerously-skip-permissions`. This holds for resumed sessions too: the CLI does not
keep a session's model or mode across a resume.

## The model list (`ModelCatalog`)

Per account, in memory: the newest `models` an `initialize` reply gave, from a session's
start or from the capability probe (which already asks `initialize`). The menu lists them as
`displayName` over `description`, the current one checked. With no list for the account yet,
opening the menu starts the probe for the window's folder and account and shows "Loading
models…"; a probe that fails shows its reason. No list is written into Drakar.

## Interface

```
┌──────────────────────────────────────────────────────────┐
│ Ask Claude…                                               │
│ [✎ Edit automatically ▾] [Opus 5.5 ▾]               [↑]  │
└──────────────────────────────────────────────────────────┘
```

- The pills sit on a row under the field, left of Send, `.caption`, capsule backgrounds as
  the context chips have; Bypass looks like the others.
- Menus: the mode menu lists the offered modes with their symbols, the current one checked;
  the model menu as above.
- ⇧Tab in the field moves to the next offered mode.
- `pillNote` shows in `.caption` red beside the pills.
- Read-only sessions (open in another app) show no composer, so no pills: their footer shows
  the mode of the newest prompt line (`Transcript.historyPermissionMode`) beside the model.

### The footer

The model leaves the footer while the composer shows (the pill names it); it stays for a
read-only session. A read-only session's footer also shows its mode's title.

### Settings

Under Claude Code, each applying to sessions started after the change:

- **"Model for new sessions"** (`drakar.defaultModel`): "Claude Code's default" (empty), then
  the models listed for the account new sessions take (Settings' account, else the shell's),
  from `ModelCatalog`; while none is known the probe is asked in the home folder, and a stored
  value not in the list still shows.
- **"Mode for new sessions"** (`drakar.defaultMode`): "Claude Code's default" (empty), Ask
  before edits, Edit automatically, Plan, Auto, and Bypass permissions while the switch below
  is on. Caption: "Auto falls back to Ask before edits on a model without it."
- **"Allow Bypass permissions"** (`drakar.allowsBypass`), on by default: "Sessions start with
  --allow-dangerously-skip-permissions, so Bypass can be picked in the composer." Turning it
  off makes a Bypass default start in Claude Code's default.

## Testing

DrakarKit:

- `ClientMessage.setModel` / `.setPermissionMode` encode as above.
- `ClaudeCommand.allowsBypass` adds the flag.
- `SystemEvent.status` carries `permissionMode`.
- `ModelOption.list(fromInitialize:)` reads the captured reply, keeps the order, and nil
  without `models`.
- `PermissionMode`: titles, the cycle order skipping what is not offered, unknown raw values.
- `Transcript.historyPermissionMode` from prompt lines.

App:

- Settings' defaults: read back, Bypass only while allowed, a redraw on a change; a test
  suite's own defaults.
- `ClaudeSession` with a stand-in `claude` that records its arguments and answers control
  requests: a pick before the start lands on the command line (Settings', then session's);
  `default` adds nothing; a change while running sends the request; an error reply reverts
  the pick and sets `pillNote`; a `status` line moves `permissionMode`.

In the running app, with the person's go-ahead: start a scratch session on haiku, switch to
Plan and back, check the CLI's mode follows (a prompt asking it to edit a file).

## Not in this spec

- Effort, fast mode, thinking.
- Changing a read-only session's mode or model.
- A Drakar default mode or model in Settings.
