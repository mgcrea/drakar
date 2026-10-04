# Window account

A project window shows, on the right of its toolbar, which Claude account it runs on and how
much of that account's plan is left: the 5-hour and 7-day windows, with their reset times.
Clicking it lists every account with its own limits and picks the one new sessions in this
folder start under. The session footer's dollar figure is labelled for what it is.

## Why

The person has two accounts, `~/.claude` (personal, Max 20x) and `~/.claude-skitrust`
(Skitrust, Team), and cannot tell from a window which one it is spending. The only account
hint today is a footer label shown when a session is not on `~/.claude`, and the only
consumption figure is `result.total_cost_usd`, which read as an API bill: it is Claude Code's
estimate at API list prices, reported whatever the login. On a subscription, the number that
matters is how close the plan's windows are to their limits.

## Decisions

Settled with the person on 2026-10-04.

| Question | Decision |
| --- | --- |
| What the toolbar account stands for | The window's account: the one new sessions in it start under. Not the selected session's, and not one account for the whole app |
| Picker in this spec | Yes, for new sessions only. Moving existing sessions between accounts is a later spec |
| Where limits come from | Each account's cached figures in `.claude.json`, plus the `rate_limit_event` Drakar's own sessions already stream. No probe process, no API call |
| How long a pick lasts | Per project folder, across windows and relaunches. A folder never picked follows Settings |
| The dollar figure | Kept, labelled as an API-equivalent estimate on a subscription login |

## Where the data comes from

| What | Source | Shape |
| --- | --- | --- |
| Account name, plan | `oauthAccount` in the account's `.claude.json`: `~/.claude.json` for the default directory, `<dir>/.claude.json` for the others | `organizationName`, `organizationType`, `organizationRateLimitTier`, `userRateLimitTier` |
| Usage, cached | `cachedUsageUtilization` in the same file, written by any `claude` of that account (sessions, Armada's probe) | `fetchedAtMs`; `utilization.five_hour` / `seven_day`: `utilization` 0–100, `resets_at` ISO-8601 |
| Usage, live | `rate_limit_event` on a running session's stdout, already parsed as `StreamMessage.rateLimit` | `rate_limit_info.status` (`allowed` / `rejected`), `rateLimitType`, `unifiedWindows.five_hour` / `seven_day`: `utilization` 0–1, `resetsAt` epoch seconds |
| Login kind | `apiKeySource` in `system/init` | `none` for a subscription login |

Both cache files were under a minute old when checked on 2026-10-04 (default 37% / 83%,
Skitrust 11% / 11%), so an account in use elsewhere stays current without Drakar doing
anything. Armada documents the same cache and probe (`armada/docs/limits-accounts-and-terms.md`);
reading the Keychain token and calling the usage endpoint directly is ruled out there on
Consumer Terms grounds, and here too.

## Model

### `AccountProfile` (DrakarKit, pure)

Parsed from one `.claude.json`:

- **Name.** `organizationName`; `Personal` when it is the generated `"<email>'s Organization"`;
  the account's directory name (`ClaudeAccount.name`) when the file or the field is missing.
  The email is never the name: one person can hold two organizations.
- **Plan.** From the tier first (`…max_20x` → `Max 20x`, `…max_5x` → `Max 5x`, `…pro` →
  `Pro`), then `organizationType` (`claude_max` → `Max`, `claude_team` → `Team`,
  `claude_pro` → `Pro`, `claude_enterprise` → `Enterprise`); nil otherwise.
- **Cached usage**, as an `AccountUsage` with source `.cache`, or nil.

`ClaudeAccount` gains `configFile: URL` (the `.claude.json` above) so the rule lives in one
place.

### `AccountUsage` (DrakarKit, pure)

```swift
public struct UsageWindow: Sendable, Equatable {
  public var percent: Int        // 0–100
  public var resetsAt: Date?
  public var isRejected: Bool    // the account hit this window's limit
}

public struct AccountUsage: Sendable, Equatable {
  public enum Source: Sendable { case live, cache }
  public var fiveHour: UsageWindow?
  public var sevenDay: UsageWindow?
  public var readAt: Date
  public var source: Source
}
```

Two initialisers, one per source, normalise the units: live `0.32` → `32`, epoch seconds and
ISO-8601 strings → `Date`. A live event with `status: rejected` marks the window named by
`rateLimitType` as rejected. `AccountUsage.merged(_:)` keeps the newer `readAt`, so a stale
cache never replaces a fresher live reading.

### `AccountStore` (app, one shared instance, `@Observable`)

- Holds `[ClaudeAccount: AccountProfile]` and `[ClaudeAccount: AccountUsage]` for
  `ClaudeAccount.discover()`.
- Watches each account's `.claude.json` with FSEvents on its parent folder, re-reading the
  file after a short debounce; also re-reads when the app becomes active.
- `record(_ info: JSONValue, for account: ClaudeAccount)`: each `ClaudeSession` forwards its
  `.rateLimit` messages here with its own `account`.

### Which account a new session uses

`ClaudeChoice.newSessionAccount` becomes `ClaudeChoice.account(forNewSessionIn folder:)`:

1. the account of the session being resumed (unchanged: a resume runs where it was written);
2. the folder's pick, from `UserDefaults` key `drakar.accountForFolder` (folder path →
   account directory path), while that directory exists;
3. the Settings default (`PreferenceKey.newSessionAccount`), while its directory exists;
4. nil: the shell's `CLAUDE_CONFIG_DIR`, or `~/.claude`.

A pick whose directory is gone is ignored, not deleted, so it comes back with the directory.
The window's account shown in the toolbar is this same resolution for the project's folder,
with step 1 skipped.

## Interface

### Toolbar item

Project windows only, `.primaryAction`, before the Keep on Top pin. Accessibility identifier
`window.account`.

```
[ 👤 Skitrust  ▮▯ 11%  ▮▯ 11% ]   📌
```

- The account name, then two thin bars with their percentage: 5h, then 7d.
- Tint: green below 70, orange below 90, red at 90 and above, and red full when the window is
  rejected.
- Figures read more than 10 minutes ago are drawn at half opacity. No reading at all: the
  name alone.
- Help: `Personal · Max 20x — ~/.claude · 5h resets 12:30 · 7d resets Mon 15:59 · updated
  2 min ago`; a rejected window reads `Limit reached — resets 12:30`.

### Popover

A popover rather than a menu, because a menu cannot draw the bars.

```
┌──────────────────────────────────────────┐
│ ✓ Personal · Max 20x          ~/.claude  │
│   5h ▮▮▮▮▯▯▯▯▯▯ 37%  resets 12:30         │
│   7d ▮▮▮▮▮▮▮▮▯▯ 83%  resets Mon 15:59     │
│──────────────────────────────────────────│
│   Skitrust · Team     ~/.claude-skitrust │
│   5h ▮▯▯▯▯▯▯▯▯▯ 11%  resets 12:40         │
│   7d ▮▯▯▯▯▯▯▯▯▯ 11%  resets Sat 07:00     │
│──────────────────────────────────────────│
│ New sessions in this folder use the      │
│ checked account. Existing sessions keep  │
│ theirs.                                  │
└──────────────────────────────────────────┘
```

- One row per discovered account, the window's checked. Identifier `account.row.<directory
  name>` (`account.row..claude`, `account.row..claude-skitrust`).
- Clicking a row stores it as the folder's pick and closes the popover. Running sessions are
  untouched.
- With one account the popover has one row and nothing to pick.

### Account badges

- A sidebar session row whose account differs from the window's shows a small capsule with
  that account's name.
- The session footer shows the session's account when it differs from the window's, instead
  of when it is not `~/.claude`. A window on `~/.claude` therefore looks as it does today.

### Cost label

`SessionInfo` (from `system/init`) gains `apiKeySource`.

- `none` (subscription login): `≈ $0.0123`, help `API-equivalent estimate from token counts.
  Your subscription is not billed per token.`
- Anything else: `$0.0123`, help `Billed to your API key`.
- Not known yet: as `none`.

## Edge cases

| Case | Behaviour |
| --- | --- |
| `.claude.json` unreadable or missing | Directory name, no plan, no bars |
| Picked account's directory deleted | Pick ignored, Settings default used; the pick is kept |
| Limit already reached | That bar full and red, help says when it resets |
| No account discovered | The shell's account shown, one row, nothing to pick |
| Cache older than its reset time | The window shows 0%: a reset window has been emptied |

## Testing

DrakarKit unit tests, on trimmed `.claude.json` fixtures with fake emails:

- name: generated organization → `Personal`, real name kept, missing file → directory name;
- plan: each tier and organization type above, unknown → nil;
- the two usage shapes decode to the same `AccountUsage` values;
- `merged` keeps the newer reading; a rejected live event marks its window;
- a window past its `resetsAt` reads 0%;
- account resolution: resume beats folder pick beats Settings beats shell, and a pick whose
  directory is gone falls through.

In the running app, through the accessibility tree by identifier (screenshots come out black
on this Mac): the toolbar item names the account; picking Skitrust then starting a session
gives it `CLAUDE_CONFIG_DIR=~/.claude-skitrust`; the pick survives a relaunch; a resumed
default-account session in that window shows its badge.

## Not in this spec

- Moving or forking existing sessions to another account (Armada's "Continue on" copies the
  transcript and resumes it with `--fork-session`); a later spec.
- A probe process for accounts nobody is using; stale figures show their age instead.
- Limits in the sessions launcher window, which has no project.
