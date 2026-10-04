# Window Account Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project window shows, on the right of its toolbar, the Claude account it runs on with its 5-hour and 7-day plan usage, and lets the person pick which account new sessions in that folder start under.

**Architecture:** Pure parsing lives in DrakarKit: `AccountUsage` (both usage shapes, merge, tint level, staleness) and `AccountProfile` (name, plan, cached usage from `.claude.json`). The app gains `AccountStore` (one shared, observable: profiles polled from disk, live readings forwarded by each `ClaudeSession`), a per-folder pick in `ClaudeChoice`, a toolbar item with a popover, account badges, and a labelled cost.

**Tech Stack:** Swift 6, SwiftUI (macOS), Swift Testing (`import Testing`, `@Test`, `#expect`), DrakarKit Swift package.

**Spec:** `docs/superpowers/specs/2026-10-04-window-account-design.md`

## Global Constraints

- No network call, no Keychain read, no extra `claude` process: limits come only from `.claude.json` `cachedUsageUtilization` and the `rate_limit_event` Drakar's own sessions stream.
- The default account (`~/.claude`) is always run with `CLAUDE_CONFIG_DIR` unset; its `.claude.json` is `~/.claude.json`. Any other account's is `<dir>/.claude.json`.
- Account resolution for a new session: resumed session's account → folder pick (`drakar.accountForFolder`) while its directory exists → Settings default (`drakar.newSessionAccount`) while its directory exists → nil (the shell's).
- A pick whose directory is gone is ignored, never deleted.
- Tint: green below 70, orange below 90, red at 90 and above; a rejected window is red and full.
- Figures read more than 10 minutes ago are stale (drawn at half opacity).
- Accessibility identifiers: `window.account` (toolbar item), `account.row.<directory name>` (popover rows, e.g. `account.row..claude-skitrust`).
- Toolbar item in project windows only, `.primaryAction`, before the Keep on Top pin.
- The email is never shown as an account name.
- New files in `apps/apple/Drakar/` and `apps/apple/Packages/DrakarKit/` are picked up automatically (synchronized folders, Swift package); no project-file edits.
- Commands run from `apps/apple`: `make test` (DrakarKit), `make test-app` (app target), `make build`, `make run`, `make format-swift`.
- Comments follow the codebase: a `///` line or two saying why, in plain sentences.

## Review Focus

1. **One account, two spellings.** A `ClaudeAccount` built from a `ResumeTarget` (`/Users/x/.claude-skitrust`) and one from discovery (`/Users/x/.claude-skitrust/`) must count as the same account for usage lookup and badges. Pinned by `ClaudeAccountKeyTests` (Task 2) and `AccountStoreTests.liveReadingFindsTheAccountWhateverItsSpelling` (Task 5).
2. **A folder picked with a trailing slash** is the same folder without one. Pinned by `AccountChoiceTests.aFolderIsTheSameWithOrWithoutItsTrailingSlash` (Task 4).
3. **A session created before the pick, prompted after it,** starts on the new pick: resolution happens at spawn, not at creation. Pinned by `AccountChoiceTests.aSessionCreatedBeforeThePickStartsOnIt` (Task 4).
4. **A live event without `unifiedWindows`** (an older or newer CLI) must not blank a known reading. Pinned by `AccountUsageTests.aLiveEventWithoutWindowsIsNoReading` (Task 1) and `AccountStoreTests.anEventWithoutWindowsKeepsTheLastReading` (Task 5).
5. **A cache older than its reset** reads 0%, not the old figure. Pinned by `AccountUsageTests.aWindowPastItsResetIsEmpty` (Task 1).

---

### Task 1: `AccountUsage` — both usage shapes, merge, level, staleness

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/AccountUsage.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/AccountUsageTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (subscript, `numberValue`, `stringValue`, `JSONValue.parse(_ data: Data)`).
- Produces:
  - `public struct UsageWindow: Sendable, Equatable { percent: Int; resetsAt: Date?; isRejected: Bool; init(percent:resetsAt:isRejected:); func current(at: Date) -> UsageWindow; var level: UsageWindow.Level }`
  - `public enum UsageWindow.Level { case normal, high, critical }`
  - `public struct AccountUsage: Sendable, Equatable { fiveHour: UsageWindow?; sevenDay: UsageWindow?; readAt: Date; source: Source; init(fiveHour:sevenDay:readAt:source:); init?(cache: JSONValue); init?(live: JSONValue, at: Date = .now); func merged(_ other: AccountUsage?) -> AccountUsage; func isStale(at: Date) -> Bool }`
  - `public enum AccountUsage.Source: Sendable, Equatable { case live, cache }`

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("An account's plan usage")
struct AccountUsageTests {

  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  /// `cachedUsageUtilization` as Claude Code 2.1.288 wrote it on 2026-10-04: whole percents,
  /// ISO-8601 resets with six fractional digits.
  private let cache = #"""
    {"accountUuid":"a","fetchedAtMs":1791023000000,"utilization":{
      "five_hour":{"utilization":37,"resets_at":"2026-10-03T10:30:00.633102+00:00","limit_dollars":null},
      "seven_day":{"utilization":83,"resets_at":"2026-10-05T13:59:59.633120+00:00"},
      "seven_day_oauth_apps":null}}
    """#

  /// `rate_limit_info` from the turn-with-tool capture: fractions, epoch seconds.
  private let live = #"""
    {"status":"allowed","resetsAt":1791023400,"rateLimitType":"five_hour","overageStatus":"rejected",
     "isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.32,"resetsAt":1791023400},
     "seven_day":{"utilization":0.54,"resetsAt":1791208800}}}
    """#

  @Test func readsTheCache() throws {
    let usage = try #require(AccountUsage(cache: json(cache)))
    #expect(usage.source == .cache)
    #expect(usage.readAt == Date(timeIntervalSince1970: 1_791_023_000))
    #expect(usage.fiveHour?.percent == 37)
    #expect(usage.fiveHour?.resetsAt.map { Int($0.timeIntervalSince1970) } == 1_791_023_400)
    #expect(usage.sevenDay?.percent == 83)
  }

  @Test func readsALiveEvent() throws {
    let now = Date(timeIntervalSince1970: 1_791_023_100)
    let usage = try #require(AccountUsage(live: json(live), at: now))
    #expect(usage.source == .live)
    #expect(usage.readAt == now)
    #expect(usage.fiveHour == UsageWindow(percent: 32, resetsAt: Date(timeIntervalSince1970: 1_791_023_400)))
    #expect(usage.sevenDay?.percent == 54)
    #expect(usage.fiveHour?.isRejected == false)
  }

  /// The two shapes differ in units, not in meaning.
  @Test func bothShapesMeanTheSame() throws {
    let fromCache = try #require(
      AccountUsage(
        cache: json(
          #"{"fetchedAtMs":0,"utilization":{"five_hour":{"utilization":32,"resets_at":"2026-10-03T10:30:00+00:00"}}}"#
        )))
    let fromLive = try #require(
      AccountUsage(
        live: json(#"{"unifiedWindows":{"five_hour":{"utilization":0.32,"resetsAt":1791023400}}}"#)))
    #expect(fromCache.fiveHour == fromLive.fiveHour)
  }

  @Test func aRejectedEventMarksTheWindowItNames() throws {
    let usage = try #require(
      AccountUsage(
        live: json(
          #"{"status":"rejected","rateLimitType":"seven_day","unifiedWindows":{"five_hour":{"utilization":0.4,"resetsAt":1},"seven_day":{"utilization":0.97,"resetsAt":2}}}"#
        )))
    #expect(usage.sevenDay?.isRejected == true)
    #expect(usage.fiveHour?.isRejected == false)
    #expect(usage.sevenDay?.level == .critical)
  }

  /// A shape change drops the reading; it must not read as an empty plan.
  @Test func aLiveEventWithoutWindowsIsNoReading() throws {
    #expect(AccountUsage(live: try json(#"{"status":"allowed","resetsAt":1791023400}"#)) == nil)
    #expect(AccountUsage(live: .null) == nil)
  }

  @Test func aCacheWithoutWindowsIsNoReading() throws {
    #expect(AccountUsage(cache: try json(#"{"fetchedAtMs":1,"utilization":{}}"#)) == nil)
  }

  @Test func theNewerReadingWins() {
    let old = AccountUsage(fiveHour: UsageWindow(percent: 10, resetsAt: nil), sevenDay: nil,
      readAt: Date(timeIntervalSince1970: 100), source: .cache)
    let new = AccountUsage(fiveHour: UsageWindow(percent: 20, resetsAt: nil), sevenDay: nil,
      readAt: Date(timeIntervalSince1970: 200), source: .live)
    #expect(old.merged(new) == new)
    #expect(new.merged(old) == new)
    #expect(new.merged(nil) == new)
  }

  /// A cache read before the window reset describes a window that has since been emptied.
  @Test func aWindowPastItsResetIsEmpty() {
    let window = UsageWindow(percent: 83, resetsAt: Date(timeIntervalSince1970: 1000), isRejected: true)
    #expect(window.current(at: Date(timeIntervalSince1970: 999)) == window)
    #expect(window.current(at: Date(timeIntervalSince1970: 1000)).percent == 0)
    #expect(window.current(at: Date(timeIntervalSince1970: 1000)).isRejected == false)
  }

  @Test(arguments: [(0, UsageWindow.Level.normal), (69, .normal), (70, .high), (89, .high), (90, .critical), (100, .critical)])
  func tintsByThreshold(_ percent: Int, _ level: UsageWindow.Level) {
    #expect(UsageWindow(percent: percent, resetsAt: nil).level == level)
  }

  @Test func isStaleAfterTenMinutes() {
    let usage = AccountUsage(fiveHour: nil, sevenDay: nil, readAt: Date(timeIntervalSince1970: 0), source: .cache)
    #expect(!usage.isStale(at: Date(timeIntervalSince1970: 600)))
    #expect(usage.isStale(at: Date(timeIntervalSince1970: 601)))
  }

  @Test func clampsPercentages() throws {
    let usage = try #require(
      AccountUsage(live: json(#"{"unifiedWindows":{"five_hour":{"utilization":1.4,"resetsAt":1}}}"#)))
    #expect(usage.fiveHour?.percent == 100)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/apple && make test`
Expected: build failure, `cannot find 'AccountUsage' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// How much of one plan window (5 hours, 7 days) an account has used.
public struct UsageWindow: Sendable, Equatable {
  /// 0–100.
  public var percent: Int
  public var resetsAt: Date?
  /// The CLI refused a request against this window: the limit is reached, whatever the
  /// percentage says.
  public var isRejected: Bool

  public enum Level: Sendable, Equatable {
    /// Below 70 %.
    case normal
    /// From 70 %.
    case high
    /// From 90 %, or rejected.
    case critical
  }

  public init(percent: Int, resetsAt: Date?, isRejected: Bool = false) {
    self.percent = min(max(percent, 0), 100)
    self.resetsAt = resetsAt
    self.isRejected = isRejected
  }

  public var level: Level {
    if isRejected || percent >= 90 { return .critical }
    return percent >= 70 ? .high : .normal
  }

  /// As it stands at `now`: a window past its reset has been emptied, whatever was read
  /// before.
  public func current(at now: Date) -> UsageWindow {
    guard let resetsAt, resetsAt <= now else { return self }
    return UsageWindow(percent: 0, resetsAt: nil)
  }
}

/// An account's plan windows, from whichever source read them last.
public struct AccountUsage: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    /// A `rate_limit_event` from a running session.
    case live
    /// `cachedUsageUtilization` in the account's `.claude.json`.
    case cache
  }

  public var fiveHour: UsageWindow?
  public var sevenDay: UsageWindow?
  public var readAt: Date
  public var source: Source

  public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, readAt: Date, source: Source) {
    self.fiveHour = fiveHour
    self.sevenDay = sevenDay
    self.readAt = readAt
    self.source = source
  }

  /// `cachedUsageUtilization`: `fetchedAtMs`, and `utilization.five_hour` / `seven_day` with a
  /// whole `utilization` and an ISO-8601 `resets_at`.
  public init?(cache json: JSONValue) {
    guard let milliseconds = json["fetchedAtMs"]?.numberValue, let windows = json["utilization"]
    else { return nil }
    let fiveHour = Self.cacheWindow(windows["five_hour"])
    let sevenDay = Self.cacheWindow(windows["seven_day"])
    guard fiveHour != nil || sevenDay != nil else { return nil }
    self.init(
      fiveHour: fiveHour, sevenDay: sevenDay,
      readAt: Date(timeIntervalSince1970: milliseconds / 1000), source: .cache)
  }

  /// `rate_limit_info`: `unifiedWindows.five_hour` / `seven_day` with a fractional
  /// `utilization` and `resetsAt` in epoch seconds. `status: rejected` names the refused
  /// window in `rateLimitType`.
  public init?(live info: JSONValue, at now: Date = .now) {
    guard let windows = info["unifiedWindows"] else { return nil }
    let rejected =
      info["status"]?.stringValue == "rejected" ? info["rateLimitType"]?.stringValue : nil
    let fiveHour = Self.liveWindow(windows["five_hour"], rejected: rejected == "five_hour")
    let sevenDay = Self.liveWindow(windows["seven_day"], rejected: rejected == "seven_day")
    guard fiveHour != nil || sevenDay != nil else { return nil }
    self.init(fiveHour: fiveHour, sevenDay: sevenDay, readAt: now, source: .live)
  }

  /// The newer of the two: a stale cache never replaces a fresher live reading.
  public func merged(_ other: AccountUsage?) -> AccountUsage {
    guard let other, other.readAt > readAt else { return self }
    return other
  }

  /// Read more than ten minutes before `now`.
  public func isStale(at now: Date) -> Bool {
    now.timeIntervalSince(readAt) > 600
  }

  private static func cacheWindow(_ json: JSONValue?) -> UsageWindow? {
    guard let value = json?["utilization"]?.numberValue else { return nil }
    let resets = json?["resets_at"]?.stringValue.flatMap(date(iso:))
    return UsageWindow(percent: Int(value.rounded()), resetsAt: resets)
  }

  private static func liveWindow(_ json: JSONValue?, rejected: Bool) -> UsageWindow? {
    guard let value = json?["utilization"]?.numberValue else { return nil }
    let resets = json?["resetsAt"]?.numberValue.map { Date(timeIntervalSince1970: $0) }
    return UsageWindow(percent: Int((value * 100).rounded()), resetsAt: resets, isRejected: rejected)
  }

  /// The CLI writes six fractional digits, which `ISO8601DateFormatter` refuses: the
  /// fraction is dropped, a reset time needs no better than the second.
  private static func date(iso text: String) -> Date? {
    let trimmed = text.replacingOccurrences(
      of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/apple && make test`
Expected: PASS, including every `AccountUsageTests` case.

- [ ] **Step 5: Format and commit**

```bash
cd apps/apple && make format-swift && cd ../..
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/AccountUsage.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/AccountUsageTests.swift
git commit -m "feat(kit): an account's plan usage, read from the cache or a live event"
```

---

### Task 2: `AccountProfile`, `ClaudeAccount.configFile` and `ClaudeAccount.key`

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/AccountProfile.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/SessionIndex.swift` (extend `ClaudeAccount`, after `environment(_:)` around line 30)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/AccountProfileTests.swift`

**Interfaces:**
- Consumes: `AccountUsage.init?(cache:)` (Task 1), `ClaudeAccount.name`, `JSONValue.parse`.
- Produces:
  - `ClaudeAccount.configFile: URL`
  - `ClaudeAccount.key: String` — the directory as one normalized path; equal for two spellings of the same folder.
  - `public struct AccountProfile: Sendable, Equatable { name: String; plan: String?; cachedUsage: AccountUsage?; init(name:plan:cachedUsage:); init(reading: ClaudeAccount); init(json: JSONValue?, fallbackName: String) }`

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("An account's name and plan")
struct AccountProfileTests {

  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  /// The personal account as it is on disk: the organization Claude generates from the email.
  @Test func aGeneratedOrganizationIsPersonal() throws {
    let profile = AccountProfile(
      json: try json(
        #"{"oauthAccount":{"emailAddress":"me@example.com","organizationName":"me@example.com's Organization","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x","userRateLimitTier":null},"cachedUsageUtilization":{"fetchedAtMs":1,"utilization":{"five_hour":{"utilization":37,"resets_at":"2026-10-04T10:29:59.633102+00:00"}}}}"#
      ), fallbackName: "default")
    #expect(profile.name == "Personal")
    #expect(profile.plan == "Max 20x")
    #expect(profile.cachedUsage?.fiveHour?.percent == 37)
  }

  /// A team account's tier names nothing Drakar knows; its type does.
  @Test func aTeamKeepsItsName() throws {
    let profile = AccountProfile(
      json: try json(
        #"{"oauthAccount":{"emailAddress":"me@example.com","organizationName":"Skitrust","organizationType":"claude_team","organizationRateLimitTier":"default_raven"}}"#
      ), fallbackName: "skitrust")
    #expect(profile.name == "Skitrust")
    #expect(profile.plan == "Team")
    #expect(profile.cachedUsage == nil)
  }

  @Test func noFileFallsBackToTheDirectoryName() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: ".claude-nowhere-\(UUID().uuidString)", directoryHint: .isDirectory)
    let account = ClaudeAccount(directory: directory, isDefault: false)
    let profile = AccountProfile(reading: account)
    #expect(profile.name == account.name)
    #expect(profile.plan == nil)
    #expect(profile.cachedUsage == nil)
  }

  @Test func readsTheFileInsideAnOtherAccount() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: ".claude-t\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"oauthAccount":{"organizationName":"Acme","organizationType":"claude_pro"}}"#.utf8)
      .write(to: directory.appending(path: ".claude.json"))
    let profile = AccountProfile(reading: ClaudeAccount(directory: directory, isDefault: false))
    #expect(profile.name == "Acme")
    #expect(profile.plan == "Pro")
  }

  @Test(arguments: [
    ("default_claude_max_20x", nil, "Max 20x"),
    ("default_claude_max_5x", nil, "Max 5x"),
    ("default_claude_pro", nil, "Pro"),
    ("default_raven", "claude_team", "Team"),
    (nil, "claude_max", "Max"),
    (nil, "claude_enterprise", "Enterprise"),
    ("something_new", "something_else", nil),
  ] as [(String?, String?, String?)])
  func namesThePlan(_ tier: String?, _ type: String?, _ plan: String?) throws {
    var oauth: [String: JSONValue] = ["organizationName": .string("Acme")]
    if let tier { oauth["organizationRateLimitTier"] = .string(tier) }
    if let type { oauth["organizationType"] = .string(type) }
    let profile = AccountProfile(json: .object(["oauthAccount": .object(oauth)]), fallbackName: "x")
    #expect(profile.plan == plan)
  }

  /// The default account's file sits beside its folder, every other one's inside it.
  @Test func findsTheConfigFile() {
    let home = URL(filePath: "/Users/me/", directoryHint: .isDirectory)
    let standard = ClaudeAccount(directory: home.appending(path: ".claude", directoryHint: .isDirectory), isDefault: true)
    let other = ClaudeAccount(directory: home.appending(path: ".claude-work", directoryHint: .isDirectory), isDefault: false)
    #expect(standard.configFile.path(percentEncoded: false) == "/Users/me/.claude.json")
    #expect(other.configFile.path(percentEncoded: false) == "/Users/me/.claude-work/.claude.json")
  }
}

@Suite("One account, two spellings")
struct ClaudeAccountKeyTests {
  /// A `ResumeTarget` stores the path without its slash; discovery builds it with one.
  @Test func theTrailingSlashDoesNotMakeAnotherAccount() {
    let a = ClaudeAccount(directory: URL(filePath: "/Users/me/.claude-work"), isDefault: false)
    let b = ClaudeAccount(
      directory: URL(filePath: "/Users/me/.claude-work/", directoryHint: .isDirectory), isDefault: false)
    #expect(a.key == b.key)
    #expect(a.key == "/Users/me/.claude-work")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/apple && make test`
Expected: build failure, `cannot find 'AccountProfile' in scope` / `value of type 'ClaudeAccount' has no member 'configFile'`.

- [ ] **Step 3: Implement**

In `SessionIndex.swift`, inside `ClaudeAccount`, after `environment(_:)`:

```swift
  /// The `.claude.json` holding the login and the cached plan usage: beside `~/.claude` for
  /// the default directory, inside every other one.
  public var configFile: URL {
    isDefault
      ? directory.deletingLastPathComponent().appending(path: ".claude.json")
      : directory.appending(path: ".claude.json")
  }

  /// The directory as one path: a resumed session's account and a discovered one name the
  /// same folder with and without a trailing slash.
  public var key: String {
    ProjectPath.normalize(directory.standardizedFileURL.path(percentEncoded: false))
  }
```

`AccountProfile.swift`:

```swift
import Foundation

/// Who an account is, in the words its `.claude.json` gives: the organization and the plan,
/// with the plan usage Claude Code last cached there.
public struct AccountProfile: Sendable, Equatable {
  public var name: String
  public var plan: String?
  public var cachedUsage: AccountUsage?

  public init(name: String, plan: String?, cachedUsage: AccountUsage?) {
    self.name = name
    self.plan = plan
    self.cachedUsage = cachedUsage
  }

  /// `account.configFile`, or the directory's name alone when it cannot be read.
  public init(reading account: ClaudeAccount) {
    let json = (try? Data(contentsOf: account.configFile)).flatMap { try? JSONValue.parse($0) }
    self.init(json: json, fallbackName: account.name)
  }

  public init(json: JSONValue?, fallbackName: String) {
    let oauth = json?["oauthAccount"]
    name =
      Self.name(
        organization: oauth?["organizationName"]?.stringValue,
        email: oauth?["emailAddress"]?.stringValue) ?? fallbackName
    plan = Self.plan(
      tiers: [
        oauth?["userRateLimitTier"]?.stringValue, oauth?["organizationRateLimitTier"]?.stringValue,
      ],
      type: oauth?["organizationType"]?.stringValue)
    cachedUsage = json?["cachedUsageUtilization"].flatMap { AccountUsage(cache: $0) }
  }

  /// The organization, except the one Claude generates for a personal login,
  /// `"<email>'s Organization"`. Never the email: one person can hold two organizations.
  static func name(organization: String?, email: String?) -> String? {
    guard let organization, !organization.isEmpty else { return nil }
    let generated =
      email.map { organization == "\($0)'s Organization" }
      ?? organization.hasSuffix("'s Organization")
    return generated ? String(localized: "Personal") : organization
  }

  /// The tier says which Max; the organization type covers the rest.
  static func plan(tiers: [String?], type: String?) -> String? {
    for tier in tiers.compactMap({ $0 }) {
      if tier.hasSuffix("max_20x") { return "Max 20x" }
      if tier.hasSuffix("max_5x") { return "Max 5x" }
      if tier == "pro" || tier.hasSuffix("_pro") { return "Pro" }
    }
    return switch type {
    case "claude_max": "Max"
    case "claude_team": "Team"
    case "claude_pro": "Pro"
    case "claude_enterprise": "Enterprise"
    default: nil
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/apple && make test`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
cd apps/apple && make format-swift && cd ../..
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): an account's name, plan and cached usage from its .claude.json"
```

---

### Task 3: `apiKeySource` and the labelled cost

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/StreamMessage.swift` (`SessionInfo`, around lines 78–94)
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Billing.swift`
- Modify: `apps/apple/Drakar/Views/SessionView.swift:153-157` (the cost in `SessionFooter`)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/StreamMessageTests.swift` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces: `SessionInfo.apiKeySource: String?`; `public enum Billing: Sendable, Equatable { case subscription, apiKey; init(apiKeySource: String?) }`.

- [ ] **Step 1: Write the failing tests**

Append inside `StreamMessageTests`:

```swift
  /// `none` is a subscription login: the cost is an estimate, not a bill.
  @Test func readsTheLoginKindFromInit() throws {
    let message = try StreamMessage(
      line: Data(#"{"type":"system","subtype":"init","session_id":"s","apiKeySource":"none"}"#.utf8))
    guard case .system(.initialized(let info)) = message else {
      Issue.record("not an init: \(message)")
      return
    }
    #expect(info.apiKeySource == "none")
    #expect(Billing(apiKeySource: info.apiKeySource) == .subscription)
  }

  @Test(arguments: [
    (nil, Billing.subscription), ("none", .subscription), ("ANTHROPIC_API_KEY", .apiKey),
    ("apiKeyHelper", .apiKey),
  ] as [(String?, Billing)])
  func tellsAnEstimateFromABill(_ source: String?, _ billing: Billing) {
    #expect(Billing(apiKeySource: source) == billing)
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/apple && make test`
Expected: build failure, `value of type 'SessionInfo' has no member 'apiKeySource'`.

- [ ] **Step 3: Implement**

In `SessionInfo`, add the property after `claudeCodeVersion` and read it in `init?(_:)`:

```swift
  /// `none` for a subscription login, else where the API key came from.
  public var apiKeySource: String?
```

```swift
    apiKeySource = json["apiKeySource"]?.stringValue
```

`Billing.swift`:

```swift
/// What `result.total_cost_usd` is to the person: Claude Code reports it at API list prices
/// whatever the login, and only an API key turns it into a bill.
public enum Billing: Sendable, Equatable {
  case subscription
  case apiKey

  /// Unknown counts as a subscription: an estimate shown as a bill is the worse mistake.
  public init(apiKeySource: String?) {
    self = apiKeySource == nil || apiKeySource == "none" ? .subscription : .apiKey
  }
}
```

In `SessionFooter` (`SessionView.swift`), replace the cost block:

```swift
      if let cost = session.transcript.lastResult?.totalCostUSD {
        let billing = Billing(apiKeySource: session.transcript.session?.apiKeySource)
        let amount = cost.formatted(.currency(code: "USD").precision(.fractionLength(4)))
        Text(billing == .subscription ? "≈ \(amount)" : amount)
          .monospacedDigit()
          .help(
            billing == .subscription
              ? "API-equivalent estimate from token counts. Your subscription is not billed per token."
              : "Billed to your API key")
      }
```

- [ ] **Step 4: Run tests and build**

Run: `cd apps/apple && make test && make build`
Expected: PASS, then `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Format and commit**

```bash
cd apps/apple && make format-swift && cd ../..
git add apps/apple/Packages/DrakarKit apps/apple/Drakar/Views/SessionView.swift
git commit -m "feat(apple): the session's cost says it is an estimate on a subscription"
```

---

### Task 4: The folder's account pick

**Files:**
- Modify: `apps/apple/Drakar/Views/SettingsView.swift` (`PreferenceKey` around line 51, `ClaudeChoice` lines 54–89)
- Modify: `apps/apple/Drakar/Services/ClaudeSession.swift:192-195`
- Test: `apps/apple/DrakarTests/AccountChoiceTests.swift`

**Interfaces:**
- Consumes: `ClaudeChoice.account(at:)`, `ClaudeChoice.newSessionAccount`, `ProjectPath.normalize`.
- Produces:
  - `PreferenceKey.accountForFolder = "drakar.accountForFolder"` — a JSON object string, folder path → account directory path (a string so `@AppStorage` can observe it).
  - `ClaudeChoice.pickedAccount(for folder: URL) -> ClaudeAccount?`
  - `ClaudeChoice.pick(_ account: ClaudeAccount, for folder: URL)`
  - `ClaudeChoice.account(forNewSessionIn folder: URL) -> ClaudeAccount?`

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Which account a new session starts under: the folder's pick, then Settings, then the
/// shell's. Each test runs against a scratch defaults suite.
@MainActor
@Suite("The account a folder picks", .serialized)
struct AccountChoiceTests {

  private let root: URL
  private let project: URL
  private let picked: URL
  private let settings: URL
  private let suite = "drakar-tests-\(UUID().uuidString)"

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-choice-\(UUID().uuidString)", directoryHint: .isDirectory)
    project = root.appending(path: "project", directoryHint: .isDirectory)
    picked = root.appending(path: ".claude-picked", directoryHint: .isDirectory)
    settings = root.appending(path: ".claude-settings", directoryHint: .isDirectory)
    for folder in [project, picked, settings] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    ClaudeChoice.defaults = try #require(UserDefaults(suiteName: suite))
  }

  private func cleanUp() {
    ClaudeChoice.defaults.removePersistentDomain(forName: suite)
    ClaudeChoice.defaults = .standard
    try? FileManager.default.removeItem(at: root)
  }

  private func setSettingsAccount() {
    ClaudeChoice.defaults.set(
      settings.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
  }

  @Test func theFolderPickBeatsSettings() {
    defer { cleanUp() }
    setSettingsAccount()
    ClaudeChoice.pick(ClaudeChoice.account(at: picked.path(percentEncoded: false)), for: project)
    #expect(ClaudeChoice.account(forNewSessionIn: project)?.name == "picked")
  }

  @Test func aFolderNeverPickedFollowsSettings() {
    defer { cleanUp() }
    setSettingsAccount()
    #expect(ClaudeChoice.account(forNewSessionIn: project)?.name == "settings")
  }

  @Test func nothingPickedLeavesItToTheShell() {
    defer { cleanUp() }
    #expect(ClaudeChoice.account(forNewSessionIn: project) == nil)
  }

  /// The directory may come back: the pick is skipped, not forgotten.
  @Test func aPickWhoseDirectoryIsGoneFallsThroughAndIsKept() throws {
    defer { cleanUp() }
    setSettingsAccount()
    ClaudeChoice.pick(ClaudeChoice.account(at: picked.path(percentEncoded: false)), for: project)
    try FileManager.default.removeItem(at: picked)
    #expect(ClaudeChoice.account(forNewSessionIn: project)?.name == "settings")
    try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
    #expect(ClaudeChoice.account(forNewSessionIn: project)?.name == "picked")
  }

  @Test func aFolderIsTheSameWithOrWithoutItsTrailingSlash() {
    defer { cleanUp() }
    let bare = URL(filePath: String(project.path(percentEncoded: false).dropLast()))
    ClaudeChoice.pick(ClaudeChoice.account(at: picked.path(percentEncoded: false)), for: bare)
    #expect(ClaudeChoice.pickedAccount(for: project)?.name == "picked")
  }

  /// The pick is read when the process starts, not when the row was made.
  @Test func aSessionCreatedBeforeThePickStartsOnIt() async throws {
    defer { cleanUp() }
    let fake = root.appending(path: "claude")
    try Data(
      "#!/bin/sh\nprintf '%s' \"$CLAUDE_CONFIG_DIR\" > \"$0.account\"\ncat > /dev/null\n".utf8
    ).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    let session = ClaudeSession(folder: project)
    session.executableOverride = fake
    ClaudeChoice.pick(ClaudeChoice.account(at: picked.path(percentEncoded: false)), for: project)
    await session.spawn()
    defer { session.stop() }

    let written = fake.appendingPathExtension("account")
    var configDirectory: String?
    for _ in 0..<50 {
      configDirectory = try? String(contentsOf: written, encoding: .utf8)
      if configDirectory != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(configDirectory == picked.path(percentEncoded: false))
    #expect(session.account?.name == "picked")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/apple && make test-app`
Expected: build failure, `type 'ClaudeChoice' has no member 'pick'`.

- [ ] **Step 3: Implement**

In `PreferenceKey`, after `newSessionAccount`:

```swift
  /// Folder path → account directory, as a JSON object: the account a folder's new sessions
  /// start under. A string so a view can observe it with `@AppStorage`.
  static let accountForFolder = "drakar.accountForFolder"
```

In `ClaudeChoice`, after `newSessionAccount`:

```swift
  /// The account a new session in `folder` starts under: the folder's pick, else Settings',
  /// else nil for the shell's. A resumed session ignores both and runs where it was written.
  static func account(forNewSessionIn folder: URL) -> ClaudeAccount? {
    pickedAccount(for: folder) ?? newSessionAccount
  }

  /// The folder's pick while its directory is there. A missing directory skips the pick and
  /// keeps it, for when the directory comes back.
  static func pickedAccount(for folder: URL) -> ClaudeAccount? {
    guard let path = picks[folderKey(folder)], FileManager.default.fileExists(atPath: path)
    else { return nil }
    return account(at: path)
  }

  static func pick(_ account: ClaudeAccount, for folder: URL) {
    var picks = picks
    picks[folderKey(folder)] = account.directory.path(percentEncoded: false)
    let data = (try? JSONEncoder().encode(picks)) ?? Data("{}".utf8)
    defaults.set(String(decoding: data, as: UTF8.self), forKey: PreferenceKey.accountForFolder)
  }

  private static var picks: [String: String] {
    guard let text = stored(PreferenceKey.accountForFolder),
      let picks = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))
    else { return [:] }
    return picks
  }

  private static func folderKey(_ folder: URL) -> String {
    ProjectPath.normalize(folder.path(percentEncoded: false))
  }
```

In `ClaudeSession.spawn(unlessStoppedSince:)`, replace the two lines that pick the account:

```swift
    // A resume under the account that wrote it; a new session under its folder's pick, else
    // the one in Settings, else left to the shell.
    let chosen = resuming?.account ?? ClaudeChoice.account(forNewSessionIn: folder)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/apple && make test-app`
Expected: PASS, including `runsTheClaudeAndAccountPickedInSettings` (unchanged behaviour with no folder pick).

- [ ] **Step 5: Format and commit**

```bash
cd apps/apple && make format-swift && cd ../..
git add apps/apple/Drakar/Views/SettingsView.swift apps/apple/Drakar/Services/ClaudeSession.swift apps/apple/DrakarTests/AccountChoiceTests.swift
git commit -m "feat(apple): a folder remembers the account its new sessions start under"
```

---

### Task 5: `AccountStore` — profiles from disk, live readings from sessions

**Files:**
- Create: `apps/apple/Drakar/Services/AccountStore.swift`
- Modify: `apps/apple/Drakar/Services/ClaudeSession.swift` (a stored `accountStore` beside `accounts` at line 48; `apply(_:)` around line 314)
- Modify: `apps/apple/Drakar/DrakarApp.swift:114` (start the store at launch)
- Test: `apps/apple/DrakarTests/AccountStoreTests.swift`

**Interfaces:**
- Consumes: `AccountProfile(reading:)`, `AccountUsage(live:at:)`, `AccountUsage.merged(_:)`, `ClaudeAccount.key`, `ClaudeAccount.configFile`, `ClaudeAccount.discover(extra:)`, `ClaudeSession.environment`, `ClaudeChoice.account(at:)`.
- Produces:
  - `@Observable final class AccountStore { static let shared; init(discover: (() async -> (accounts: [ClaudeAccount], shell: ClaudeAccount))? = nil); private(set) var accounts: [ClaudeAccount]; private(set) var shellAccount: ClaudeAccount; func start() async; func reloadChanged(); func profile(for: ClaudeAccount) -> AccountProfile; func usage(for: ClaudeAccount) -> AccountUsage?; func record(_ info: JSONValue, for: ClaudeAccount, at: Date = .now) }`
  - `ClaudeSession.accountStore: AccountStore` (defaults to `.shared`; tests swap it).

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Every account's plan usage")
struct AccountStoreTests {

  private let root: URL
  private let account: ClaudeAccount

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    let directory = root.appending(path: ".claude-work", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    account = ClaudeAccount(directory: directory, isDefault: false)
  }

  private func writeConfig(percent: Int, fetchedAt: Int, modified: Date) throws {
    try Data(
      #"{"oauthAccount":{"organizationName":"Acme","organizationType":"claude_team"},"cachedUsageUtilization":{"fetchedAtMs":\#(fetchedAt),"utilization":{"five_hour":{"utilization":\#(percent),"resets_at":"2099-01-01T00:00:00+00:00"}}}}"#
        .utf8
    ).write(to: account.configFile)
    try FileManager.default.setAttributes(
      [.modificationDate: modified], ofItemAtPath: account.configFile.path(percentEncoded: false))
  }

  private func store() async -> AccountStore {
    let account = self.account
    let store = AccountStore(discover: { (accounts: [account], shell: account) })
    await store.start()
    store.stopPolling()
    return store
  }

  private let event = #"{"unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":4070908800}}}"#

  @Test func readsEachAccountAtStart() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConfig(percent: 12, fetchedAt: 1000, modified: Date(timeIntervalSince1970: 10))
    let store = await store()
    #expect(store.profile(for: account).name == "Acme")
    #expect(store.profile(for: account).plan == "Team")
    #expect(store.usage(for: account)?.fiveHour?.percent == 12)
  }

  @Test func rereadsAFileThatChanged() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConfig(percent: 12, fetchedAt: 1000, modified: Date(timeIntervalSince1970: 10))
    let store = await store()
    try writeConfig(percent: 40, fetchedAt: 2000, modified: Date(timeIntervalSince1970: 20))
    store.reloadChanged()
    #expect(store.usage(for: account)?.fiveHour?.percent == 40)
  }

  @Test func aLiveReadingNewerThanTheCacheWins() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConfig(percent: 12, fetchedAt: 1000, modified: Date(timeIntervalSince1970: 10))
    let store = await store()
    store.record(try JSONValue.parse(Data(event.utf8)), for: account, at: Date(timeIntervalSince1970: 5))
    #expect(store.usage(for: account)?.fiveHour?.percent == 50)
    #expect(store.usage(for: account)?.source == .live)
  }

  /// A cache written after the live reading (another process's turn) is the newer figure.
  @Test func aNewerCacheBeatsAnOlderLiveReading() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConfig(percent: 70, fetchedAt: 9_000_000, modified: Date(timeIntervalSince1970: 10))
    let store = await store()
    store.record(try JSONValue.parse(Data(event.utf8)), for: account, at: Date(timeIntervalSince1970: 5))
    #expect(store.usage(for: account)?.fiveHour?.percent == 70)
  }

  @Test func anEventWithoutWindowsKeepsTheLastReading() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let store = await store()
    store.record(try JSONValue.parse(Data(event.utf8)), for: account, at: Date(timeIntervalSince1970: 5))
    store.record(try JSONValue.parse(Data(#"{"status":"allowed"}"#.utf8)), for: account)
    #expect(store.usage(for: account)?.fiveHour?.percent == 50)
  }

  /// A resumed session names its account without the trailing slash discovery gives it.
  @Test func liveReadingFindsTheAccountWhateverItsSpelling() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let store = await store()
    let respelled = ClaudeAccount(
      directory: URL(filePath: String(account.directory.path(percentEncoded: false).dropLast())),
      isDefault: false)
    store.record(try JSONValue.parse(Data(event.utf8)), for: respelled)
    #expect(store.usage(for: account)?.fiveHour?.percent == 50)
  }

  /// What a running session streams reaches the store under the session's account.
  @Test func aSessionForwardsItsRateLimitEvents() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let fake = root.appending(path: "claude")
    try Data(
      "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"rate_limit_event\",\"rate_limit_info\":\(event)}'\ncat > /dev/null\n"
        .utf8
    ).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let suite = "drakar-tests-\(UUID().uuidString)"
    ClaudeChoice.defaults = try #require(UserDefaults(suiteName: suite))
    ClaudeChoice.defaults.set(
      account.directory.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
    defer {
      ClaudeChoice.defaults.removePersistentDomain(forName: suite)
      ClaudeChoice.defaults = .standard
    }

    let store = await store()
    let session = ClaudeSession(folder: root)
    session.executableOverride = fake
    session.accountStore = store
    await session.spawn()
    defer { session.stop() }
    for _ in 0..<50 where store.usage(for: account) == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(store.usage(for: account)?.fiveHour?.percent == 50)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/apple && make test-app`
Expected: build failure, `cannot find 'AccountStore' in scope`.

- [ ] **Step 3: Implement**

`AccountStore.swift`:

```swift
import DrakarKit
import Foundation
import Observation

/// Every account's name, plan and plan usage, for the toolbar's account item. One for the
/// app, since every window reads the same accounts.
///
/// Usage comes from two places and the newer reading wins: the `.claude.json` cache any
/// `claude` of the account rewrites (polled, see `start()`), and the `rate_limit_event` each
/// of Drakar's own sessions streams (`record`). Nothing here starts a process or calls the
/// network.
@Observable
final class AccountStore {
  static let shared = AccountStore()

  private(set) var accounts: [ClaudeAccount] = []
  /// The account a `claude` runs under when Drakar names none: the shell's
  /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
  private(set) var shellAccount: ClaudeAccount
  /// By `ClaudeAccount.key`.
  private var profiles: [String: AccountProfile] = [:]
  private var live: [String: AccountUsage] = [:]

  @ObservationIgnored private var modified: [String: Date] = [:]
  @ObservationIgnored private var poll: Timer?
  @ObservationIgnored private var started: Task<Void, Never>?
  @ObservationIgnored private let discover: () async -> (accounts: [ClaudeAccount], shell: ClaudeAccount)

  /// `discover` replaces the login-shell discovery, for tests.
  init(discover: (() async -> (accounts: [ClaudeAccount], shell: ClaudeAccount))? = nil) {
    shellAccount = ClaudeChoice.account(
      at: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        .path(percentEncoded: false))
    self.discover =
      discover ?? {
        let shellDirectory = (await ClaudeSession.environment.value)["CLAUDE_CONFIG_DIR"]
        let extra = shellDirectory.map { [URL(filePath: $0, directoryHint: .isDirectory)] } ?? []
        let shell = ClaudeChoice.account(
          at: shellDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
            .path(percentEncoded: false))
        return (ClaudeAccount.discover(extra: extra), shell)
      }
  }

  /// Finds the accounts once, reads them, then rereads any whose file changed every 5 s.
  /// Polled, not watched: an FSEvents stream is recursive, and `~/.claude.json` sits in the
  /// home folder.
  func start() async {
    if let started { return await started.value }
    let task = Task {
      let found = await discover()
      accounts = found.accounts
      shellAccount = found.shell
      reloadChanged()
      poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.reloadChanged() }
      }
    }
    started = task
    await task.value
  }

  /// For tests: no timer outliving the test.
  func stopPolling() {
    poll?.invalidate()
    poll = nil
  }

  /// Rereads each account whose `.claude.json` changed since it was last read.
  func reloadChanged() {
    for account in Set(accounts + [shellAccount]) {
      let path = account.configFile.path(percentEncoded: false)
      let date =
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
      guard profiles[account.key] == nil || modified[account.key] != date else { continue }
      modified[account.key] = date
      profiles[account.key] = AccountProfile(reading: account)
    }
  }

  func profile(for account: ClaudeAccount) -> AccountProfile {
    profiles[account.key] ?? AccountProfile(json: nil, fallbackName: account.name)
  }

  /// The newer of the live reading and the cache.
  func usage(for account: ClaudeAccount) -> AccountUsage? {
    let cached = profiles[account.key]?.cachedUsage
    guard let live = live[account.key] else { return cached }
    return live.merged(cached)
  }

  /// A session's `rate_limit_info`. One that names no window keeps the last reading.
  func record(_ info: JSONValue, for account: ClaudeAccount, at now: Date = .now) {
    guard let usage = AccountUsage(live: info, at: now) else { return }
    live[account.key] = usage.merged(live[account.key])
  }
}
```

Note: `Set(accounts + [shellAccount])` requires `ClaudeAccount: Hashable` (it is). Two spellings of one folder may both be read; that is harmless, both land under the same key.

In `ClaudeSession`, beside `accounts` (line 48):

```swift
  /// Where the session's `rate_limit_event`s go; tests give it their own.
  @ObservationIgnored var accountStore: AccountStore = .shared
```

In `ClaudeSession.apply(_:)`, first lines of the method, before the context-response check:

```swift
    if case .rateLimit(let info) = message, let account {
      accountStore.record(info, for: account)
    }
```

In `AppDelegate.applicationDidFinishLaunching` (`DrakarApp.swift`), after the `SessionMonitor` line:

```swift
    Task { await AccountStore.shared.start() }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/apple && make test-app`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
cd apps/apple && make format-swift && cd ../..
git add apps/apple/Drakar/Services/AccountStore.swift apps/apple/Drakar/Services/ClaudeSession.swift apps/apple/Drakar/DrakarApp.swift apps/apple/DrakarTests/AccountStoreTests.swift
git commit -m "feat(apple): every account's plan usage, from its cache and Drakar's own sessions"
```

---

### Task 6: The toolbar item and its popover

**Files:**
- Create: `apps/apple/Drakar/Views/AccountToolbarItem.swift`
- Modify: `apps/apple/Drakar/ContentView.swift:75-84` (the `.toolbar`)

**Interfaces:**
- Consumes: `AccountStore.shared` (`accounts`, `shellAccount`, `profile(for:)`, `usage(for:)`, `reloadChanged()`), `ClaudeChoice.account(forNewSessionIn:)`, `ClaudeChoice.pick(_:for:)`, `PreferenceKey.accountForFolder`, `PreferenceKey.newSessionAccount`, `UsageWindow.current(at:)`, `.level`, `AccountUsage.isStale(at:)`, `ContentView.abbreviated(_ url: URL)`.
- Produces: `struct AccountToolbarItem: View { let folder: URL }`; `extension AccountStore { func windowAccount(for folder: URL) -> ClaudeAccount }` (used by Task 7).

- [ ] **Step 1: Implement the view**

```swift
import DrakarKit
import SwiftUI

extension AccountStore {
  /// The account new sessions in `folder` start under, as the toolbar names it.
  func windowAccount(for folder: URL) -> ClaudeAccount {
    ClaudeChoice.account(forNewSessionIn: folder) ?? shellAccount
  }
}

/// The window's account and its plan usage, on the right of the toolbar. A click lists every
/// account and picks the one this folder's new sessions start under.
struct AccountToolbarItem: View {
  let folder: URL
  @State private var isShown = false
  /// Read only to redraw when a pick or the Settings default changes.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""

  private var store: AccountStore { .shared }

  var body: some View {
    let _ = (picks, settingsAccount)
    let account = store.windowAccount(for: folder)
    Button {
      store.reloadChanged()
      isShown.toggle()
    } label: {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        HStack(spacing: 6) {
          Image(systemName: "person.crop.circle")
          Text(store.profile(for: account).name)
          UsageMeters(usage: store.usage(for: account), now: context.date, compact: true)
        }
      }
    }
    .help(help(for: account))
    .accessibilityIdentifier("window.account")
    .popover(isPresented: $isShown, arrowEdge: .bottom) {
      AccountPicker(folder: folder, current: account) { isShown = false }
    }
  }

  private func help(for account: ClaudeAccount) -> String {
    let profile = store.profile(for: account)
    var parts = [
      [profile.name, profile.plan].compactMap { $0 }.joined(separator: " · ") + " — "
        + ContentView.abbreviated(account.directory)
    ]
    let now = Date.now
    if let usage = store.usage(for: account) {
      for (label, window) in [("5h", usage.fiveHour), ("7d", usage.sevenDay)] {
        guard let window = window?.current(at: now) else { continue }
        parts.append(UsageMeters.resetText(label, window))
      }
      parts.append(
        String(localized: "updated \(usage.readAt.formatted(.relative(presentation: .named)))"))
    }
    return parts.joined(separator: " · ")
  }
}

/// Every account with its limits; a click picks it for the folder.
private struct AccountPicker: View {
  let folder: URL
  let current: ClaudeAccount
  let dismiss: () -> Void

  private var store: AccountStore { .shared }

  var body: some View {
    let accounts = store.accounts.isEmpty ? [store.shellAccount] : store.accounts
    VStack(alignment: .leading, spacing: 0) {
      ForEach(accounts, id: \.key) { account in
        Button {
          ClaudeChoice.pick(account, for: folder)
          dismiss()
        } label: {
          row(account)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account.row.\(account.directory.lastPathComponent)")
        Divider()
      }
      Text("New sessions in this folder use the checked account. Existing sessions keep theirs.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
    }
    .frame(width: 340)
  }

  private func row(_ account: ClaudeAccount) -> some View {
    let profile = store.profile(for: account)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "checkmark").opacity(account.key == current.key ? 1 : 0)
        Text([profile.name, profile.plan].compactMap { $0 }.joined(separator: " · "))
          .fontWeight(.medium)
        Spacer()
        Text(ContentView.abbreviated(account.directory))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      UsageMeters(usage: store.usage(for: account), now: .now, compact: false)
        .padding(.leading, 22)
    }
    .padding(10)
    .contentShape(Rectangle())
  }
}

/// The 5h and 7d bars: compact in the toolbar, with their reset times in the popover.
struct UsageMeters: View {
  let usage: AccountUsage?
  let now: Date
  let compact: Bool

  var body: some View {
    if let usage {
      let layout = compact ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
      layout {
        ForEach([("5h", usage.fiveHour), ("7d", usage.sevenDay)], id: \.0) { entry in
          if let window = entry.1?.current(at: now) {
            HStack(spacing: 4) {
              if !compact { Text(entry.0).foregroundStyle(.secondary).frame(width: 18, alignment: .leading) }
              UsageBar(window: window).frame(width: compact ? 22 : 120, height: compact ? 4 : 6)
              Text(window.isRejected ? "100%" : "\(window.percent)%").monospacedDigit()
              if !compact { Text(Self.resetText(nil, window)).foregroundStyle(.secondary) }
            }
          }
        }
      }
      .font(compact ? .caption : .callout)
      .opacity(usage.isStale(at: now) ? 0.5 : 1)
    }
  }

  /// `5h resets 12:30`, `Limit reached — resets 12:30`; a reset beyond today names its day.
  static func resetText(_ label: String?, _ window: UsageWindow) -> String {
    guard let resetsAt = window.resetsAt else { return label ?? "" }
    let time =
      Calendar.current.isDateInToday(resetsAt)
      ? resetsAt.formatted(date: .omitted, time: .shortened)
      : resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    if window.isRejected { return String(localized: "Limit reached — resets \(time)") }
    return [label, String(localized: "resets \(time)")].compactMap { $0 }.joined(separator: " ")
  }
}

/// One window's share, tinted green, orange, red; full and red once rejected.
private struct UsageBar: View {
  let window: UsageWindow

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule()
          .fill(tint)
          .frame(width: proxy.size.width * CGFloat(window.isRejected ? 100 : window.percent) / 100)
      }
    }
  }

  private var tint: Color {
    switch window.level {
    case .normal: .green
    case .high: .orange
    case .critical: .red
    }
  }
}
```

- [ ] **Step 2: Wire it into the toolbar**

In `ContentView.body`, make the `.toolbar` content:

```swift
    .toolbar {
      if let project {
        ToolbarItem(placement: .primaryAction) {
          AccountToolbarItem(folder: project.folder)
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Toggle(isOn: $keepsOnTop) {
          Label("Keep on Top", systemImage: keepsOnTop ? "pin.fill" : "pin")
        }
        .toggleStyle(.button)
        .help(keepsOnTop ? "Stop keeping this window on top" : "Keep this window on top")
        .accessibilityIdentifier("window.keepOnTop")
      }
    }
```

- [ ] **Step 3: Build**

Run: `cd apps/apple && make build`
Expected: `** BUILD SUCCEEDED **`. If `ContentView.abbreviated` takes a `URL` with another label, adapt the three call sites to its signature (it is used as `ContentView.abbreviated(account.directory)` in `SessionView.swift:156`).

- [ ] **Step 4: Check it in the running app**

Run: `cd apps/apple && make run ARGS='<a project folder, as openFromLaunchArguments takes it>'` (or open a project from the launcher).

Screenshots come out black on this Mac: use cupertino-desktop's accessibility tree by identifier.
- `apple_desktop_find_elements` for identifier `window.account` in Drakar: its label names the account (e.g. `Personal`) and two percentages.
- Press it, then find `account.row..claude-skitrust` and press it.
- `window.account` now reads `Skitrust`.
- Quit (`make quit`), relaunch on the same folder: `window.account` still reads `Skitrust`.
- `defaults read io.mgcrea.drakar drakar.accountForFolder` (or the app's bundle id) shows the folder → `~/.claude-skitrust` pair.
- Pick the default account back so the folder is left as found.

- [ ] **Step 5: Format and commit**

```bash
cd apps/apple && make format-swift && cd ../..
git add apps/apple/Drakar/Views/AccountToolbarItem.swift apps/apple/Drakar/ContentView.swift
git commit -m "feat(apple): the window's account and its plan limits in the toolbar, picked per folder"
```

---

### Task 7: Account badges on rows and in the footer

**Files:**
- Modify: `apps/apple/Drakar/Views/ProjectSidebar.swift` (`SessionRow`, around lines 176–215; its call site at line 83)
- Modify: `apps/apple/Drakar/Views/SessionView.swift` (`SessionFooter` at line 136 and its call site at line 34)
- Modify: `apps/apple/Drakar/Services/ClaudeSession.swift` (add `effectiveAccount`)
- Test: `apps/apple/DrakarTests/AccountChoiceTests.swift` (append)

**Interfaces:**
- Consumes: `AccountStore.windowAccount(for:)` (Task 6), `AccountStore.profile(for:)`, `ClaudeAccount.key`.
- Produces: `ClaudeSession.effectiveAccount: ClaudeAccount?` — the running account, else the resumed one, else nil (a new session not yet started runs on the window's account). Accounts are compared by `key`, never with `==`, which tells two spellings of one folder apart.

- [ ] **Step 1: Write the failing test**

Append to `AccountChoiceTests`:

```swift
  /// A resumed session not yet started is on the account that wrote it; a new one has none
  /// until it starts, and runs on the window's.
  @Test func aSessionNamesItsAccountBeforeItStarts() {
    defer { cleanUp() }
    let target = ResumeTarget(
      sessionID: "s", cwd: project.path(percentEncoded: false),
      file: project.appending(path: "s.jsonl").path(percentEncoded: false),
      accountDirectory: String(picked.path(percentEncoded: false).dropLast()), accountIsDefault: false)
    #expect(ClaudeSession(folder: project, resuming: target).effectiveAccount?.name == "picked")
    #expect(ClaudeSession(folder: project).effectiveAccount == nil)
  }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd apps/apple && make test-app`
Expected: build failure, `value of type 'ClaudeSession' has no member 'effectiveAccount'`.

- [ ] **Step 3: Implement**

In `ClaudeSession`, after `private(set) var account`:

```swift
  /// The account the session runs, or will resume, under; nil for a new session not yet
  /// started, which takes the window's.
  var effectiveAccount: ClaudeAccount? { account ?? resuming?.account }
```

In `ProjectSidebar.swift`, give `SessionRow` the window's account and show a capsule when the session's differs:

```swift
struct SessionRow: View {
  let item: ProjectSession
  let isSelected: Bool
  /// The account new sessions in this window start under.
  let windowAccount: ClaudeAccount
```

Inside the inner `HStack(spacing: 4)` after the unread dot:

```swift
          if let other = otherAccount {
            Text(AccountStore.shared.profile(for: other).name)
              .font(.caption2)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Capsule().fill(.quaternary))
              .help("Runs under the account in \(ContentView.abbreviated(other.directory))")
          }
```

And a property:

```swift
  /// The session's account when it is not the window's.
  private var otherAccount: ClaudeAccount? {
    guard let account = item.session.effectiveAccount, account.key != windowAccount.key
    else { return nil }
    return account
  }
```

At the call site (line 83):

```swift
          SessionRow(
            item: item, isSelected: item.id == project.selectedID,
            windowAccount: AccountStore.shared.windowAccount(for: project.folder))
```

In `SessionView.swift`, pass the window's account to the footer (line 34):

```swift
      SessionFooter(
        session: session, windowAccount: AccountStore.shared.windowAccount(for: project.folder))
```

In `SessionFooter`, add `let windowAccount: ClaudeAccount` and replace the account label:

```swift
      if let account = session.effectiveAccount, account.key != windowAccount.key {
        Label(AccountStore.shared.profile(for: account).name, systemImage: "person.crop.circle")
          .help("Runs under the account in \(ContentView.abbreviated(account.directory))")
      }
```

Both views read `AccountStore.shared`, which is `@Observable`; the pick is `@AppStorage`-backed in the toolbar item only. Add `@AppStorage(PreferenceKey.accountForFolder) private var picks = ""` to `ProjectSidebar` and to `SessionView` and reference it once in `body` (`let _ = picks`) so a pick redraws the badges.

- [ ] **Step 4: Run tests and build**

Run: `cd apps/apple && make test-app && make build`
Expected: PASS, `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Check it in the running app**

With a project window on the default account that holds a session resumed from `~/.claude-skitrust` (or: pick Skitrust in the toolbar, start a session, pick the default back): the sidebar row's accessibility label includes `Skitrust`; the footer shows `Skitrust`. With the window on Skitrust, that row has no badge. Leave the folder's pick as it was found.

- [ ] **Step 6: Format and commit**

```bash
cd apps/apple && make format-swift && cd ../..
git add apps/apple/Drakar apps/apple/DrakarTests/AccountChoiceTests.swift
git commit -m "feat(apple): a session on another account than its window's says which"
```

---

### Task 8: Spec note and docs

**Files:**
- Modify: `docs/superpowers/specs/2026-10-04-window-account-design.md` (already updated: polling instead of FSEvents — commit it here if not yet committed)
- Modify: `docs/claude-stream-json.md` (the `rate_limit_event` row, line 45)

- [ ] **Step 1: Record the live shape**

Replace the `rate_limit_event` row's notes with:

```
| `rate_limit_event` | `rate_limit_info` | `status` (`allowed` / `rejected`), `rateLimitType`, `unifiedWindows.five_hour` / `seven_day`: `utilization` 0–1, `resetsAt` epoch seconds. The account's `.claude.json` caches the same windows as `cachedUsageUtilization` (0–100, ISO-8601 `resets_at`). |
```

- [ ] **Step 2: Commit**

```bash
git add docs/claude-stream-json.md docs/superpowers/specs/2026-10-04-window-account-design.md
git commit -m "docs: the rate-limit event's shape, and the account cache polled rather than watched"
```
