# Permission rules and the plan file

Approved 2026-10-31. The last two items of the parity batch that rewind came from
(docs/extension-parity.md): list, add and remove permission rules, and open the session's
plan file. PLAN.md's promise: nothing lost against the extension, permissions and plan mode
included.

## What the CLI offers (claude 2.1.312, measured 2026-10-31)

**`list_permission_rules`** (control request, no fields) answers
`{state: {rules, workspaceDirectories, originalCwd, managedOnly, errors?}}`:

- `rules[]`: `behavior` (`allow`, `deny`, `ask`), `source` (`userSettings`,
  `projectSettings`, `localSettings`, `flagSettings`, `policySettings`, `cliArg`, `command`,
  `session`, `mcpMount`, `toolsNarrowing`, `mcpServerPolicy`, `hostCredential`; read any
  other string as unknown, not as a failure), `rule` (verbatim, may hold invisible or
  control characters), `description?` (`{prefix, emphasis?, suffix?}`, the CLI's reading:
  "Any Bash command starting with **npm run test**"), `editability` (`persistent`,
  `session`, `readonly`), `notInEffect?` (true: managed settings pin
  `allowManagedPermissionRulesOnly` and this non-policy rule is ignored).
- `workspaceDirectories[]`: `{path, source}`.
- `managedOnly`: the session applies policy rules only.
- `errors?`: settings files skipped for parse errors, as `get_settings` reports them.

Real reply, a project with a local allow and deny:

```json
{"state": {"rules": [
  {"behavior": "allow", "source": "localSettings", "rule": "Bash(npm run test:*)",
   "description": {"prefix": "Any Bash command starting with ", "emphasis": "npm run test"},
   "editability": "persistent"},
  {"behavior": "deny", "source": "localSettings", "rule": "Read(./secrets/**)",
   "editability": "persistent"}],
 "workspaceDirectories": [], "originalCwd": "/…/rules", "managedOnly": false}}
```

**Rules are changed outside the stream**, as the extension does it: `claude
edit-permission-rules --json` in the session's folder, one edit as JSON on stdin.

- Add: `{"op": "add", "rules": [1…100 strings], "behavior": …, "destination":
  "userSettings" | "projectSettings" | "localSettings"}`.
- Remove: `{"op": "remove", "rule": …, "behavior": …, "source": <one of those three>}`.
- Success: exit 0, last stdout line `{"ok": true, "warnings": [String], "stored":
  [String]}` (`stored`: the rules as written, which can differ from what was sent).
- Refusal: exit 1, the reason on stderr, ready to show. Seen: a rule already present
  (`"Bash(npm run test:*)" is already in the allow rules in project local settings`; the
  whole add fails), `Bash()` (empty parentheses), a malformed rule, a remove of a rule not
  there, a remove from `session`.
- `CLAUDE_CODE_CHILD_SESSION` in its environment makes it refuse ("cannot be changed from
  an editor started inside a Claude Code session"). Drakar removes it for this command.
- A running session sees the file change by itself: in a stream-json session the listing
  showed an added rule 1.3 s after the command returned. The extension re-reads up to 14
  times, 300 ms apart.

**`get_plan`** (control request, no fields) answers `{exists: false}` or `{exists: true,
content, path}`; `path` (under the account's `plans/`) is left out only on connections that
persist frames server-side, never on Drakar's. It never creates a plan.

## 1. Permissions, a third inspector tab

`InspectorTab.permissions`, labelled "Rules", after "Skills & MCP" (amended 2026-11-01: "Permissions" did not fit the inspector's 280 pt column beside the other two, and the picker fell into the toolbar's overflow menu). It shows the
selected session's rules.

**Where the listing comes from**

- A Claude session with a process Drakar drives: `list_permission_rules` on it, so session
  approvals and `--allowedTools` rules show too.
- A Claude session with none: a rules probe, a `claude` started in the session's folder
  under the session's account (as `CapabilityProbe` starts one), sent `initialize` and
  `list_permission_rules`, let go once answered or after 20 s. The footer says this
  session's own approvals are not listed since it is not running. My call: a separate probe
  rather than a third request in `CapabilityProbe`, whose loop waits on MCP servers for up to
  10 s and would hold every rules read behind them.
- A Codex session: a `ContentUnavailableView`, "Codex sessions have no permission rules."
- A refused or failed read: the CLI's error, or why there was no reply, with a Retry button.

**The list** (a `Form`, as the Session tab)

- Sections Allow, Ask, Deny, in that order; an empty one is left out.
- A row: the description when there is one (prefix and suffix plain, emphasis semibold),
  over the rule in a monospaced caption; the rule alone, monospaced, when there is none.
  Invisible and control characters in the rule and the emphasis are shown escaped
  (`\u{200B}` style) rather than dropped. A trailing tag names the source: User, Project,
  Local, Command line, Session, Policy, Flag, Slash command, MCP, other sources by their raw
  name.
- `notInEffect` rows dimmed, with "Not in effect: managed settings allow only their own
  rules" as their help.
- `managedOnly`: a line above the sections says managed settings allow only their own rules;
  Add and Remove are off.
- Read-only sections after the rules: Directories (`workspaceDirectories`, path and source),
  and Settings Errors when `errors` is not empty.
- Toolbar of the tab: Add Rule… and Refresh.

**Remove**: a button on each `persistent` row (and the row's context menu "Remove Rule"),
nowhere else. No confirmation (my call: the rule is on screen and adds back in a second).
The row shows a progress indicator until the listing no longer has it; a refusal shows under
the list with the CLI's words.

**Add Rule…**: a sheet with

- Rules: a text field, one rule per line, blank lines ignored, placeholder
  `Bash(npm run test:*)`.
- Behavior: Allow, Ask, Deny (segmented), Allow by default.
- Save in: "This project, only you" (`localSettings`, `.claude/settings.local.json`, the
  default), "This project, shared" (`projectSettings`, `.claude/settings.json`), "All
  projects" (`userSettings`, the session account's `settings.json`).
- Add (default button) and Cancel. A refusal shows in the sheet with the CLI's words and
  the sheet stays open with what was typed. Warnings of a success show under the list.

**Writing**: `claude edit-permission-rules --json`, the session's own executable and account
environment (`ClaudeLaunch.make` for its folder and account, without checkpoints), current
directory the session's folder, `CLAUDE_CODE_CHILD_SESSION` removed, 30 s limit, through
`ProcessRunner` (only stdout's last line is read). Then the listing is read again: from the session's process up to 14 times, 300 ms
apart, until it shows the change (every `stored` rule present for an add, else the listing
changed; the rule gone for a remove); with no process, one fresh rules probe. A change that
still does not show: "Saved; not in the list yet."

**When it reads**: when the tab shows, when the selected session changes while it shows,
after an edit, after a permission answer that added rules (any `updatedPermissions`,
session ones included), and on Refresh. Never while hidden.

## 2. Open Plan

- Session › Open Plan (⌥⌘P), and an "Open Plan File" button in `PlanPanel`'s header.
- Enabled for a Claude session with a process Drakar drives (`controlsTasks`).
- Sends `get_plan`; waits up to 10 s. `exists` with a `path`: `Workspace.open` that path,
  which shows it in the side editor. `exists: false`, no path, no reply, or a refusal: a
  notice in the conversation, "No plan in this session yet." or "Couldn't read the plan."
- Unverified, for the live check: whether Claude reads back an edit made to the plan file
  before the plan is approved. The file opens editable either way; the result goes into
  docs/claude-stream-json.md.

## Not in this

Editing a rule in place (remove, then add). Removing session rules (the CLI refuses).
Adding or removing working directories (the CLI rejects `add_directory` on this connection).
Codex. A badge or count anywhere else.

## Docs

- docs/claude-stream-json.md: "Permission rules" and "Plan" sections, from the facts above.
- docs/extension-parity.md: `list_permission_rules`, `add_permission_rules`,
  `remove_permission_rule`, `open_plan` rows to `has`, the CLI section's
  `list_permission_rules` and `get_plan` rows to `sends`.

## Live checks

1. A running session lists its rules; an "always allow" answered in a permission sheet
   shows up as a Session rule after the answer.
2. Add a local allow rule; it shows within 2 s. Add the same again: the CLI's refusal shows
   in the sheet.
3. Remove it; it goes.
4. A reopened session with no process lists the files' rules, with the footer.
5. Plan mode: Open Plan opens the plan file in the side editor; before any plan, the notice.
   Edit the file before approving and note what Claude does with it.
