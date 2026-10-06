# Mode and Model Pills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two pills under the composer pick the session's permission mode and model: live through control requests, on the command line before a start, remembered per folder.

**Architecture:** DrakarKit learns the two control requests, the `status` line's mode, the allow-bypass flag, the transcript's mode, `PermissionMode` and `ModelOption`. The app keeps folder picks in `ClaudeChoice`, the models per account in `ModelCatalog` (fed by sessions' and the probe's `initialize` replies), and the session's mode and picks in `ClaudeSession`. `SessionPills` draws them in `ComposerView`; the footer keeps the model only for read-only sessions.

**Tech Stack:** Swift 6, SwiftUI (macOS), Swift Testing, DrakarKit package.

**Spec:** `docs/superpowers/specs/2026-10-06-mode-and-model-pills-design.md`

## Global Constraints

- Mode values: `default` (Ask before edits), `acceptEdits` (Edit automatically), `plan` (Plan), `auto` (Auto), `bypassPermissions` (Bypass permissions), in that order. `manual` and `dontAsk` are never offered.
- Control requests: `{"subtype":"set_model","model":<value>}` and `{"subtype":"set_permission_mode","mode":<value>}`, request ids `model-N` / `mode-N` from `nextRequestID`.
- `default` (mode) and `default` (model) put nothing on the command line.
- A folder never remembers Bypass. Bypass is offered only while `ClaudeChoice.allowsBypass` (default true) and, with a process, only if it started with `--allow-dangerously-skip-permissions`.
- No model list is written into Drakar: the menu shows only what an `initialize` reply listed.
- `ClaudeChoice.testSuite` (task-local) scopes Settings in tests; never assign a global.
- Commands from `apps/apple`: `make test`, `make test-app`, `make build`. Format only touched files with `xcrun swift-format format --in-place <files>`.
- Main has uncommitted work from another session in `ClaudeSession.swift`, `ClaudeCommand.swift`, `ClientMessage.swift`, `Transcript.swift`, `History.swift`: this plan runs in a worktree from `HEAD`; expect conflicts at landing, resolved by keeping both.

## Review Focus

1. **A refused change must not leave the pill lying.** `bypass_not_launched` (or any error) reverts the pick and the shown mode, and says why. Pinned by `ClaudeSessionPillsTests.aRefusedChangeGoesBack` (Task 4).
2. **The CLI changes its own mode** (leaving Plan after a plan is approved): the pill follows `status` lines. Pinned by `ClaudeSessionPillsTests.aStatusLineMovesTheMode` (Task 4).
3. **A folder pick changed by another window must not relabel a running session**: picks freeze at spawn. Pinned by `ClaudeSessionPillsTests.aRunningSessionKeepsItsPicks` (Task 4).
4. **Bypass never starts a session**, even when Settings is turned off after a session picked it. Pinned by `SessionPicksTests.neverRemembersBypass` (Task 3) and `ClaudeSessionPillsTests.bypassNeedsTheSetting` (Task 4).
5. **⇧Tab in the field** must not be eaten by focus traversal: checked in the running app (Task 5, Step 6), since key handling is not unit-tested.

---

### Task 1: The protocol — two requests, the status line's mode, the allow flag, the transcript's mode

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ClientMessage.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ClaudeCommand.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/StreamMessage.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Transcript.swift`, `History.swift`
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/mode-and-model.jsonl` (from the 2026-10-06 spike, `<scratchpad>/spike/mode-and-model.jsonl`: the `initialize` reply cut to `models` and `current_permission_mode`, the five `set_*` replies, the three `status` lines with zeroed ids)
- Modify: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift`, `ClientMessageTests.swift`, `ProcessTests.swift`, `StreamMessageTests.swift`, `HistoryTests.swift`
- Modify: `docs/claude-stream-json.md`

**Interfaces:**
- Produces: `ClientMessage.setModel(requestID:model:)`, `.setPermissionMode(requestID:mode:)`; `ClaudeCommand.allowsBypass`; `SystemEvent.status(String?, permissionMode: String?)`; `Transcript.historyPermissionMode`; `Fixture.modeAndModel`.

- [ ] **Step 1: Copy the fixture and add its case**

```bash
cp <scratchpad>/spike/mode-and-model.jsonl apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/
```

In `Fixture`, after `capabilities`:

```swift
  /// A `claude` with no prompt (2.1.288, 2026-10-06, the mode and model spike): the
  /// `initialize` reply cut to its `models` and `current_permission_mode`, then the replies to
  /// `set_model` (`r2`) and `set_permission_mode` (`r3` acceptEdits, `r4` bypassPermissions
  /// refused, `r5` auto, `r6` plan) with the `status` lines that followed. Ids zeroed.
  case modeAndModel = "mode-and-model"
```

- [ ] **Step 2: Write the failing tests**

`ClientMessageTests`:

```swift
  @Test func encodesTheModeAndModelSwitches() throws {
    #expect(
      try text(.setModel(requestID: "model-1", model: "sonnet"))
        == #"{"request":{"model":"sonnet","subtype":"set_model"},"request_id":"model-1","type":"control_request"}"#
        + "\n")
    #expect(
      try text(.setPermissionMode(requestID: "mode-2", mode: "plan"))
        == #"{"request":{"mode":"plan","subtype":"set_permission_mode"},"request_id":"mode-2","type":"control_request"}"#
        + "\n")
  }
```

`ProcessTests` (beside the existing arguments test):

```swift
  @Test func allowsBypassOnlyWhenAsked() {
    #expect(!ClaudeCommand().arguments.contains("--allow-dangerously-skip-permissions"))
    var command = ClaudeCommand()
    command.allowsBypass = true
    #expect(command.arguments.contains("--allow-dangerously-skip-permissions"))
  }
```

`StreamMessageTests`:

```swift
  /// A mode change, the person's or the CLI's own, is a `status` line naming the mode.
  @Test func readsTheModeOffAStatusLine() throws {
    let modes = try Fixture.modeAndModel.messages.compactMap { message -> String? in
      if case .system(.status(_, let mode?)) = message { return mode }
      return nil
    }
    #expect(modes == ["acceptEdits", "auto", "plan"])
  }
```

`HistoryTests`:

```swift
  /// Each prompt line names the mode it was sent in: the newest is the session's.
  @Test func knowsTheModeOfTheNewestPrompt() {
    let transcript = history([
      #"{"type":"user","permissionMode":"default","message":{"role":"user","content":"Hi"}}"#,
      #"{"type":"user","permissionMode":"plan","message":{"role":"user","content":"Plan it"}}"#,
    ])
    #expect(transcript.historyPermissionMode == "plan")
    #expect(history([#"{"type":"ai-title","aiTitle":"Hi"}"#]).historyPermissionMode == nil)
  }
```

- [ ] **Step 3: Run to verify they fail**

Run: `cd apps/apple && make test`
Expected: build failure: `setModel`, `allowsBypass`, the `status` pattern's arity, `historyPermissionMode`.

- [ ] **Step 4: Implement**

`ClientMessage`, after `mcpStatus`:

```swift
  /// Switch the running session's model to `model` (a `value` of `initialize`'s `models`),
  /// from its next request. Answered with an empty success.
  case setModel(requestID: String, model: String)
  /// Switch the running session's permission mode; answered with `{"mode": …}`, then a
  /// `status` line. Bypass is refused unless the process started able to take it.
  case setPermissionMode(requestID: String, mode: String)
```

and in `json`:

```swift
    case .setModel(let id, let model):
      Self.controlRequest(id, ["subtype": .string("set_model"), "model": .string(model)])
    case .setPermissionMode(let id, let mode):
      Self.controlRequest(
        id, ["subtype": .string("set_permission_mode"), "mode": .string(mode)])
```

`ClaudeCommand`, after `permissionMode`:

```swift
  /// `--allow-dangerously-skip-permissions`: Bypass permissions can be switched to later,
  /// without the session starting in it.
  public var allowsBypass = false
```

and in `arguments`, after the `permissionMode` line:

```swift
    if allowsBypass { arguments.append("--allow-dangerously-skip-permissions") }
```

`SystemEvent`:

```swift
  /// `requesting` before each API call; `permissionMode` set when the mode changed, by a
  /// `set_permission_mode` or the CLI itself.
  case status(String?, permissionMode: String?)
```

and its decoding:

```swift
    case "status":
      self = .status(
        json["status"]?.stringValue, permissionMode: json["permissionMode"]?.stringValue)
```

`Transcript`, after `writerVersion`:

```swift
  /// The mode the newest prompt line was sent in, from a transcript file: what a session
  /// another process runs is in.
  public internal(set) var historyPermissionMode: String?
```

`History.applyHistory`, in `case "user":` right after the `isMeta` guard:

```swift
      if let mode = json["permissionMode"]?.stringValue { historyPermissionMode = mode }
```

`docs/claude-stream-json.md`: remove `set_permission_mode`, `set_model` from the "unverified" list and add, after "Skills and MCP status":

```markdown
## Mode and model (verified 2026-10-06, 2.1.288)

Before any prompt, no API call:

- `initialize`'s reply has `models`, each `{value, resolvedModel, displayName, description,
  supportsEffort, supportedEffortLevels, supportsAdaptiveThinking, supportsFastMode,
  supportsAutoMode}`, first `default`, then the aliases, then pinned ids; and
  `current_permission_mode`.
- `{"subtype":"set_model","model":"sonnet"}` → empty success.
- `{"subtype":"set_permission_mode","mode":"acceptEdits"}` → success `{"mode":"acceptEdits"}`,
  then `{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}`.
  `auto` and `plan` likewise.
- `bypassPermissions` without `--allow-dangerously-skip-permissions` (or
  `--dangerously-skip-permissions`) → error `bypass_not_launched`.
- Transcript prompt lines carry `permissionMode`.

Captured as the `mode-and-model` fixture.
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd apps/apple && make test`
Expected: PASS.

- [ ] **Step 6: Format and commit**

```bash
K=apps/apple/Packages/DrakarKit
xcrun swift-format format --in-place $K/Sources/DrakarKit/{ClientMessage,ClaudeCommand,StreamMessage,Transcript,History}.swift $K/Tests/DrakarKitTests/{Fixture,ClientMessageTests,ProcessTests,StreamMessageTests,HistoryTests}.swift
git add $K docs/claude-stream-json.md
git commit -m "feat(kit): switch a session's mode and model, and read the mode it reports"
```

---

### Task 2: `PermissionMode` and `ModelOption`

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ModeAndModel.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Capabilities.swift` (`ProjectCapabilities.models`, `CapabilityReplies.take`)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ModeAndModelTests.swift`

**Interfaces:**
- Consumes: `Fixture.modeAndModel` (Task 1).
- Produces: `PermissionMode` (`allCases`, `title`, `symbol`, `next(after:among:)`, `title(of:)`), `ModelOption` (`value`, `resolvedModel`, `displayName`, `description`, `supportsAutoMode`, `list(fromInitialize:)`), `ProjectCapabilities.models`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Testing

@Suite("The modes and models a session can take")
struct ModeAndModelTests {

  private func initializeReply() throws -> JSONValue? {
    let responses = try Fixture.modeAndModel.messages.compactMap { message -> ControlResponse? in
      if case .controlResponse(let response) = message { return response }
      return nil
    }
    return try #require(responses.first { $0.requestID == "r1" }).response
  }

  /// The account's own list, in the CLI's order: never one written into Drakar.
  @Test func readsTheModelsInitializeLists() throws {
    let models = try #require(ModelOption.list(fromInitialize: try initializeReply()))
    #expect(models.count == 12)
    #expect(models.prefix(5).map(\.value) == ["default", "opus", "fable", "sonnet", "haiku"])
    #expect(models[0].displayName == "Default (recommended)")
    #expect(models[0].resolvedModel == "claude-opus-5-5")
    #expect(models[0].supportsAutoMode)
    #expect(models.first { $0.value == "haiku" }?.supportsAutoMode == false)
    #expect(ModelOption.list(fromInitialize: .object([:])) == nil)
  }

  @Test func theProbeKeepsTheModels() throws {
    var replies = CapabilityReplies(initializeID: "r1", statusID: "none")
    for message in try Fixture.modeAndModel.messages {
      if case .controlResponse(let response) = message { replies.take(response) }
    }
    #expect(replies.capabilities.models?.count == 12)
  }

  @Test func cyclesThroughWhatIsOffered() {
    let offered: [PermissionMode] = [.ask, .acceptEdits, .plan]
    #expect(PermissionMode.next(after: .ask, among: offered) == .acceptEdits)
    #expect(PermissionMode.next(after: .plan, among: offered) == .ask)
    // A mode no longer offered (Bypass, after Settings turned it off) goes to the first.
    #expect(PermissionMode.next(after: .bypass, among: offered) == .ask)
    #expect(PermissionMode.allCases == [.ask, .acceptEdits, .plan, .auto, .bypass])
  }

  @Test func namesModes() {
    #expect(PermissionMode.title(of: "default") == "Ask before edits")
    #expect(PermissionMode.title(of: "bypassPermissions") == "Bypass permissions")
    #expect(PermissionMode.title(of: "dontAsk") == "dontAsk")
  }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/apple && make test`
Expected: build failure, `cannot find 'ModelOption' in scope`.

- [ ] **Step 3: Implement**

`ModeAndModel.swift`:

```swift
import Foundation

/// A permission mode the composer offers, in the order ⇧Tab goes through them
/// (docs/superpowers/specs/2026-10-06-mode-and-model-pills-design.md). The CLI's `manual`
/// (another name for `default`) and `dontAsk` are not offered.
public enum PermissionMode: String, Sendable, CaseIterable {
  case ask = "default"
  case acceptEdits
  case plan
  case auto
  case bypass = "bypassPermissions"

  public var title: String {
    switch self {
    case .ask: String(localized: "Ask before edits")
    case .acceptEdits: String(localized: "Edit automatically")
    case .plan: String(localized: "Plan")
    case .auto: String(localized: "Auto")
    case .bypass: String(localized: "Bypass permissions")
    }
  }

  public var symbol: String {
    switch self {
    case .ask: "hand.raised"
    case .acceptEdits: "pencil"
    case .plan: "list.bullet.clipboard"
    case .auto: "wand.and.stars"
    case .bypass: "exclamationmark.shield"
    }
  }

  /// The mode after `current` among `offered`, wrapping; the first when `current` is not
  /// offered any more.
  public static func next(after current: PermissionMode, among offered: [PermissionMode])
    -> PermissionMode
  {
    guard let index = offered.firstIndex(of: current) else { return offered.first ?? .ask }
    return offered[(index + 1) % offered.count]
  }

  /// `raw`'s title, or `raw` itself for a mode Drakar does not offer.
  public static func title(of raw: String) -> String {
    PermissionMode(rawValue: raw)?.title ?? raw
  }
}

/// One model an account offers, as `initialize`'s `models` lists it.
public struct ModelOption: Sendable, Hashable, Identifiable {
  /// What `--model` and `set_model` take: `default`, an alias, or a pinned id.
  public var value: String
  /// The id it stands for today (`claude-opus-5-5`).
  public var resolvedModel: String?
  public var displayName: String
  public var description: String
  public var supportsAutoMode: Bool

  public var id: String { value }

  public init(
    value: String, resolvedModel: String? = nil, displayName: String, description: String = "",
    supportsAutoMode: Bool = false
  ) {
    self.value = value
    self.resolvedModel = resolvedModel
    self.displayName = displayName
    self.description = description
    self.supportsAutoMode = supportsAutoMode
  }

  init?(_ json: JSONValue) {
    guard let value = json["value"]?.stringValue else { return nil }
    self.init(
      value: value, resolvedModel: json["resolvedModel"]?.stringValue,
      displayName: json["displayName"]?.stringValue ?? value,
      description: json["description"]?.stringValue ?? "",
      supportsAutoMode: json["supportsAutoMode"]?.boolValue ?? false)
  }

  /// The models an `initialize` reply lists, in its order; nil when it has no `models`.
  public static func list(fromInitialize reply: JSONValue?) -> [ModelOption]? {
    reply?["models"]?.arrayValue?.compactMap(ModelOption.init)
  }
}
```

`ProjectCapabilities`: add `public var models: [ModelOption]?` with doc "The models the account offers, from the same `initialize` reply; nil until one listed them.", an `models: [ModelOption]? = nil` init parameter assigned in the init; and in `CapabilityReplies.take`'s `initializeID` success branch:

```swift
        capabilities.models = ModelOption.list(fromInitialize: response.response)
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd apps/apple && make test`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
K=apps/apple/Packages/DrakarKit
xcrun swift-format format --in-place $K/Sources/DrakarKit/ModeAndModel.swift $K/Sources/DrakarKit/Capabilities.swift $K/Tests/DrakarKitTests/ModeAndModelTests.swift
git add $K
git commit -m "feat(kit): the permission modes Drakar offers, and the models an account lists"
```

---

### Task 3: Folder picks, the Bypass setting, `ModelCatalog`

**Files:**
- Modify: `apps/apple/Drakar/Views/SettingsView.swift` (`PreferenceKey`, `ClaudeChoice`, `ClaudeSection`)
- Create: `apps/apple/Drakar/Services/ModelCatalog.swift`
- Modify: `apps/apple/Drakar/Services/Capabilities.swift` (`apply` records models)
- Test: `apps/apple/DrakarTests/SessionPicksTests.swift`

**Interfaces:**
- Consumes: `PermissionMode`, `ModelOption`, `ProjectCapabilities.models` (Task 2).
- Produces: `PreferenceKey.allowsBypass`, `.sessionPicksForFolder`; `ClaudeChoice.allowsBypass`, `ClaudeChoice.SessionPicks { model, mode }`, `sessionPicks(for:)`, `pickModel(_:for:)`, `pickMode(_:for:)`; `ModelCatalog` (`shared`, `models(for:)`, `record(_:for:)`, `load(folder:account:)`); `Capabilities.catalog`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What a folder's next session starts with")
struct SessionPicksTests {

  private let folder = URL(filePath: "/tmp/drakar-picks-\(UUID().uuidString)/")

  private func scoped(_ body: () throws -> Void) rethrows {
    let suite = "drakar-picks-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    try ClaudeChoice.$testSuite.withValue(suite, operation: body)
  }

  @Test func remembersTheLastPicks() {
    scoped {
      #expect(ClaudeChoice.sessionPicks(for: folder) == .init())
      ClaudeChoice.pickModel("sonnet", for: folder)
      ClaudeChoice.pickMode(.plan, for: folder)
      #expect(ClaudeChoice.sessionPicks(for: folder) == .init(model: "sonnet", mode: "plan"))
      // Normalised like the account picks: a trailing slash is the same folder.
      let bare = URL(filePath: String(folder.path(percentEncoded: false).dropLast()))
      #expect(ClaudeChoice.sessionPicks(for: bare).model == "sonnet")
    }
  }

  /// No session starts in Bypass: picking it leaves the folder's mode as it was.
  @Test func neverRemembersBypass() {
    scoped {
      ClaudeChoice.pickMode(.acceptEdits, for: folder)
      ClaudeChoice.pickMode(.bypass, for: folder)
      #expect(ClaudeChoice.sessionPicks(for: folder).mode == "acceptEdits")
    }
  }

  @Test func allowsBypassUntilTurnedOff() {
    scoped {
      #expect(ClaudeChoice.allowsBypass)
      ClaudeChoice.defaults.set(false, forKey: PreferenceKey.allowsBypass)
      #expect(!ClaudeChoice.allowsBypass)
    }
  }

  @Test func theProbeFillsTheCatalog() async throws {
    let catalog = ModelCatalog()
    let account = ClaudeAccount(directory: URL(filePath: "/tmp/.claude-a"), isDefault: false)
    let entry = Capabilities(folder: folder, account: account)
    entry.catalog = catalog
    entry.probe = { _, _ in
      ProbeOutcome(
        capabilities: ProjectCapabilities(
          skills: [], models: [ModelOption(value: "haiku", displayName: "Haiku 4.5")]))
    }
    #expect(catalog.models(for: account) == nil)
    entry.refresh()
    for _ in 0..<100 where entry.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    #expect(catalog.models(for: account)?.map(\.value) == ["haiku"])
  }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/apple && make test-app`
Expected: build failure: `sessionPicks`, `ModelCatalog`.

- [ ] **Step 3: Implement**

`PreferenceKey`:

```swift
  /// Whether sessions start able to switch to Bypass permissions; on unless turned off.
  static let allowsBypass = "drakar.allowsBypass"
  /// Folder path → `{model, mode}`, as a JSON object: what the folder's next session starts
  /// with, from its last pills.
  static let sessionPicksForFolder = "drakar.sessionPicksForFolder"
```

`ClaudeChoice`, after `pick(_:for:)`:

```swift
  /// Sessions start with `--allow-dangerously-skip-permissions`, so the mode pill can offer
  /// Bypass. On by default.
  static var allowsBypass: Bool {
    defaults.object(forKey: PreferenceKey.allowsBypass) as? Bool ?? true
  }

  /// What a folder's next session starts with, from the last pills picked there.
  struct SessionPicks: Codable, Equatable {
    var model: String?
    var mode: String?
  }

  static func sessionPicks(for folder: URL) -> SessionPicks {
    allSessionPicks[folderKey(folder)] ?? SessionPicks()
  }

  static func pickModel(_ model: String, for folder: URL) {
    updateSessionPicks(for: folder) { $0.model = model }
  }

  /// Bypass is never remembered: no session starts in it.
  static func pickMode(_ mode: PermissionMode, for folder: URL) {
    guard mode != .bypass else { return }
    updateSessionPicks(for: folder) { $0.mode = mode.rawValue }
  }

  private static var allSessionPicks: [String: SessionPicks] {
    guard let text = stored(PreferenceKey.sessionPicksForFolder),
      let picks = try? JSONDecoder().decode([String: SessionPicks].self, from: Data(text.utf8))
    else { return [:] }
    return picks
  }

  private static func updateSessionPicks(for folder: URL, _ change: (inout SessionPicks) -> Void)
  {
    var all = allSessionPicks
    change(&all[folderKey(folder), default: SessionPicks()])
    let data = (try? JSONEncoder().encode(all)) ?? Data("{}".utf8)
    defaults.set(
      String(decoding: data, as: UTF8.self), forKey: PreferenceKey.sessionPicksForFolder)
  }
```

`ClaudeSection`: `@AppStorage(PreferenceKey.allowsBypass) private var allowsBypass = true`, and after the account picker:

```swift
      Toggle("Allow Bypass permissions", isOn: $allowsBypass)
        .accessibilityIdentifier("settings.allowsBypass")
      Text(
        "Sessions start with --allow-dangerously-skip-permissions, so Bypass can be picked in the composer. No session starts in it."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
```

`ModelCatalog.swift`:

```swift
import DrakarKit
import Foundation
import Observation

/// The models each account offers, as the newest `initialize` reply listed them: a
/// session's, or the capability probe's. In memory; no list is written into Drakar.
@Observable
final class ModelCatalog {
  static let shared = ModelCatalog()

  private var lists: [String: [ModelOption]] = [:]

  func models(for account: ClaudeAccount) -> [ModelOption]? { lists[account.key] }

  func record(_ models: [ModelOption], for account: ClaudeAccount) {
    lists[account.key] = models
  }

  /// Asks the probe for `folder` under `account` when no list is known for the account yet.
  func load(folder: URL, account: ClaudeAccount) {
    guard lists[account.key] == nil else { return }
    CapabilityStore.shared.capabilities(for: folder, account: account).loadIfNeeded()
  }
}
```

`Capabilities`: `@ObservationIgnored var catalog: ModelCatalog = .shared` (doc: "Where the probe's model list goes; tests give their own."), and at the top of `apply(_:)`:

```swift
    if let models = outcome.capabilities.models { catalog.record(models, for: account) }
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd apps/apple && make test-app`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
A=apps/apple
xcrun swift-format format --in-place $A/Drakar/Views/SettingsView.swift $A/Drakar/Services/ModelCatalog.swift $A/Drakar/Services/Capabilities.swift $A/DrakarTests/SessionPicksTests.swift
git add $A/Drakar/Views/SettingsView.swift $A/Drakar/Services/ModelCatalog.swift $A/Drakar/Services/Capabilities.swift $A/DrakarTests/SessionPicksTests.swift
git commit -m "feat(apple): a folder remembers its last mode and model, and Settings allows Bypass"
```

---

### Task 4: `ClaudeSession` — the mode it is in, the picks, the switches

**Files:**
- Modify: `apps/apple/Drakar/Services/ClaudeSession.swift`
- Test: `apps/apple/DrakarTests/ClaudeSessionPillsTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces on `ClaudeSession`: `permissionMode: String?`, `modePick: PermissionMode?`, `modelPick: String?`, `launchedWithBypass: Bool`, `pillNote: String?`, `shownMode: String`, `startingMode: PermissionMode?`, `pickedModel: String?`, `offersBypass: Bool`, `setMode(_:)`, `setModel(_:)`, `catalog: ModelCatalog`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A session's mode and model")
struct ClaudeSessionPillsTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-pills-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func standIn(_ name: String, _ body: String) throws -> URL {
    let script = folder.appending(path: name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// Settings in a scratch suite, Bypass as given.
  private func scoped(allowsBypass: Bool = true, _ body: () async throws -> Void) async rethrows {
    let suite = "drakar-pills-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(allowsBypass, forKey: PreferenceKey.allowsBypass)
    try await ClaudeChoice.$testSuite.withValue(suite, operation: body)
  }

  private func read(_ file: URL, until done: (String) -> Bool) async throws -> String {
    var text = ""
    for _ in 0..<50 {
      text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      if done(text) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    return text
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<50 where !condition() { try await Task.sleep(for: .milliseconds(100)) }
  }

  @Test func picksBeforeTheStartGoOnTheCommandLine() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      ClaudeChoice.pickModel("sonnet", for: folder)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      session.setMode(.plan)
      #expect(session.shownMode == "plan")
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(args.contains("--model sonnet"))
      #expect(args.contains("--permission-mode plan"))
      #expect(args.contains("--allow-dangerously-skip-permissions"))
      #expect(ClaudeChoice.sessionPicks(for: folder).mode == "plan")
    }
  }

  @Test func defaultsAddNothing() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      session.setModel("default")
      session.setMode(.ask)
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(!args.contains("--model"))
      #expect(!args.contains("--permission-mode"))
    }
  }

  /// Turned off in Settings after it was picked: the session starts in its folder's mode.
  @Test func bypassNeedsTheSetting() async throws {
    try await scoped(allowsBypass: false) {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      #expect(!session.offersBypass)
      session.setMode(.bypass)
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(!args.contains("--permission-mode"))
      #expect(!args.contains("--allow-dangerously-skip-permissions"))
    }
  }

  @Test func aChangeWhileRunningIsSent() async throws {
    try await scoped {
      let script = try standIn("claude", #"cat >> "$0.stdin""#)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      #expect(session.launchedWithBypass)
      session.setMode(.acceptEdits)
      session.setModel("haiku")
      let sent = try await read(script.appendingPathExtension("stdin")) {
        $0.contains("set_model")
      }
      #expect(sent.contains(#""mode":"acceptEdits","subtype":"set_permission_mode""#))
      #expect(sent.contains(#""model":"haiku","subtype":"set_model""#))
      #expect(session.shownMode == "acceptEdits")
    }
  }

  /// The CLI's refusal puts the pill back and says why.
  @Test func aRefusedChangeGoesBack() async throws {
    try await scoped {
      let script = try standIn(
        "claude",
        """
        while read -r line; do
          case "$line" in *set_permission_mode*)
            id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]*)".*/\\1/')
            printf '%s\\n' "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"error\\",\\"request_id\\":\\"$id\\",\\"error\\":\\"Not launched for it\\"}}"
          esac
        done
        """)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      session.setMode(.plan)
      #expect(session.shownMode == "plan")
      try await waitUntil { session.pillNote != nil }
      #expect(session.pillNote == "Not launched for it")
      #expect(session.modePick == nil)
      #expect(session.shownMode == "default")
    }
  }

  /// The CLI leaves Plan on its own once a plan is approved: the pill follows.
  @Test func aStatusLineMovesTheMode() async throws {
    try await scoped {
      let status =
        #"{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}"#
      let script = try standIn("claude", "read line\nprintf '%s\\n' '\(status)'\ncat > /dev/null")
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      try await waitUntil { session.permissionMode != nil }
      #expect(session.shownMode == "acceptEdits")
    }
  }

  /// Another window picking for the folder does not relabel a session already running.
  @Test func aRunningSessionKeepsItsPicks() async throws {
    try await scoped {
      let script = try standIn("claude", #"cat > /dev/null"#)
      ClaudeChoice.pickModel("sonnet", for: folder)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      ClaudeChoice.pickModel("haiku", for: folder)
      #expect(session.pickedModel == "sonnet")
    }
  }

  @Test func theStartListsTheAccountsModels() async throws {
    try await scoped {
      let reply =
        #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[],"models":[{"value":"default","displayName":"Default (recommended)"},{"value":"haiku","displayName":"Haiku 4.5"}]}}}"#
      let script = try standIn("claude", "read line\necho '\(reply)'\ncat > /dev/null")
      let catalog = ModelCatalog()
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      session.catalog = catalog
      await session.spawn()
      defer { session.stop() }
      let account = try #require(session.account)
      try await waitUntil { catalog.models(for: account) != nil }
      #expect(catalog.models(for: account)?.map(\.value) == ["default", "haiku"])
    }
  }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/apple && make test-app`
Expected: build failure: `setMode`, `shownMode`, `catalog`.

- [ ] **Step 3: Implement**

State, after `isMoving`:

```swift
  /// The mode the process last reported: `system/init`, a `status` line, a confirmed
  /// change. Nil without a process.
  private(set) var permissionMode: String?
  /// What this session's pills picked; nil follows the folder's pick. Frozen at each start.
  private(set) var modePick: PermissionMode?
  private(set) var modelPick: String?
  /// The running process started with `--allow-dangerously-skip-permissions`.
  private(set) var launchedWithBypass = false
  /// Why the last change was refused, until the next change.
  private(set) var pillNote: String?
  /// Where `initialize`'s model list goes; tests give their own.
  @ObservationIgnored var catalog: ModelCatalog = .shared
  /// What to put back if a switch is refused, by request id.
  @ObservationIgnored private var revertOnError: [String: () -> Void] = [:]
```

Computed and the switches, after `canSend`:

```swift
  /// The mode the pill shows: the process's while it runs, else what the next start takes.
  var shownMode: String {
    if isProcessRunning, let permissionMode { return permissionMode }
    return (startingMode ?? .ask).rawValue
  }

  /// The mode the next start passes: this session's pick, else the folder's; Bypass only
  /// while Settings allows it.
  var startingMode: PermissionMode? {
    let mode =
      modePick
      ?? (isProcessRunning
        ? nil
        : ClaudeChoice.sessionPicks(for: folder).mode.flatMap(PermissionMode.init(rawValue:)))
    return mode == .bypass && !ClaudeChoice.allowsBypass ? nil : mode
  }

  /// The model picked for the session: its own, else (before a start) the folder's; nil for
  /// Claude Code's default.
  var pickedModel: String? {
    modelPick ?? (isProcessRunning ? nil : ClaudeChoice.sessionPicks(for: folder).model)
  }

  /// Bypass can be picked: Settings allows it, and a running process started able to.
  var offersBypass: Bool {
    ClaudeChoice.allowsBypass && (!isProcessRunning || launchedWithBypass)
  }

  /// At once on a running process, mid-turn included; else at the next start. The folder
  /// remembers it, Bypass aside.
  func setMode(_ mode: PermissionMode) {
    pillNote = nil
    ClaudeChoice.pickMode(mode, for: folder)
    let (previousPick, previousMode) = (modePick, permissionMode)
    modePick = mode
    guard let process else { return }
    permissionMode = mode.rawValue
    let id = nextRequestID("mode")
    revertOnError[id] = { [weak self] in
      self?.modePick = previousPick
      self?.permissionMode = previousMode
    }
    try? process.send(.setPermissionMode(requestID: id, mode: mode.rawValue))
  }

  /// `value` as `initialize`'s `models` give it; `default` is Claude Code's own.
  func setModel(_ value: String) {
    pillNote = nil
    ClaudeChoice.pickModel(value, for: folder)
    let previous = modelPick
    modelPick = value
    guard let process else { return }
    let id = nextRequestID("model")
    revertOnError[id] = { [weak self] in self?.modelPick = previous }
    try? process.send(.setModel(requestID: id, model: value))
  }
```

In `spawn(unlessStoppedSince:)`, right after `var command = command`:

```swift
    // The pills' picks, frozen for this process: the session's own, else the folder's.
    modelPick = pickedModel
    modePick = startingMode
    if let model = modelPick, model != "default" { command.model = model }
    if let mode = modePick, mode != .ask { command.permissionMode = mode.rawValue }
    command.allowsBypass = ClaudeChoice.allowsBypass
```

and right after `self.process = process`:

```swift
      launchedWithBypass = command.allowsBypass
```

In `stop()` after `process = nil`, and in `handle`'s `.exited` after `process = nil`:

```swift
    permissionMode = nil
```

In `apply(_:)`, replace the `init-` block with:

```swift
    if case .controlResponse(let response) = message, response.requestID.hasPrefix("init-"),
      response.isSuccess
    {
      if let models = ModelOption.list(fromInitialize: response.response), let account {
        catalog.record(models, for: account)
      }
      onInitialized?(response.response)
    }
    if case .controlResponse(let response) = message,
      response.requestID.hasPrefix("mode-") || response.requestID.hasPrefix("model-")
    {
      let revert = revertOnError.removeValue(forKey: response.requestID)
      if response.isSuccess {
        if let mode = response.response?["mode"]?.stringValue { permissionMode = mode }
      } else {
        revert?()
        pillNote = response.error ?? String(localized: "Claude Code refused the change.")
      }
      return
    }
    if case .system(.initialized(let info)) = message { permissionMode = info.permissionMode }
    if case .system(.status(_, let mode?)) = message { permissionMode = mode }
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd apps/apple && make test-app`
Expected: PASS, including the existing `ClaudeSessionTests` (they read arguments with `contains`).

- [ ] **Step 5: Format and commit**

```bash
A=apps/apple
xcrun swift-format format --in-place $A/Drakar/Services/ClaudeSession.swift $A/DrakarTests/ClaudeSessionPillsTests.swift
git add $A/Drakar/Services/ClaudeSession.swift $A/DrakarTests/ClaudeSessionPillsTests.swift
git commit -m "feat(apple): a session switches mode and model live, or takes them at its start"
```

---

### Task 5: The pills, ⇧Tab, the footer

**Files:**
- Create: `apps/apple/Drakar/Views/SessionPills.swift`
- Modify: `apps/apple/Drakar/Views/ComposerView.swift` (`pills`, `cycleMode`, the field's layout)
- Modify: `apps/apple/Drakar/Views/SessionView.swift` (pass them; the footer)
- Test: `apps/apple/DrakarTests/SessionPillsTests.swift`

**Interfaces:**
- Consumes: Task 4's `ClaudeSession` API; `ModelCatalog`; `ModelName`.
- Produces: `SessionPills(session:folder:account:)`, `SessionPills.offeredModes(_:models:)`, `.option(for:in:)`, `.modelLabel(for:in:)`, `.cycle(_:account:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What the pills offer and say")
struct SessionPillsTests {

  private let folder = FileManager.default.temporaryDirectory.appending(
    path: "drakar-pill-\(UUID().uuidString)", directoryHint: .isDirectory)
  private let models = [
    ModelOption(
      value: "default", resolvedModel: "claude-opus-5-5", displayName: "Default (recommended)",
      supportsAutoMode: true),
    ModelOption(
      value: "haiku", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5"),
  ]

  private func scoped(allowsBypass: Bool = true, _ body: () throws -> Void) rethrows {
    let suite = "drakar-pill-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(allowsBypass, forKey: PreferenceKey.allowsBypass)
    try ClaudeChoice.$testSuite.withValue(suite, operation: body)
  }

  @Test func autoOnlyForAModelThatTakesIt() {
    scoped {
      let session = ClaudeSession(folder: folder)
      #expect(SessionPills.offeredModes(session, models: models) == PermissionMode.allCases)
      session.setModel("haiku")
      #expect(!SessionPills.offeredModes(session, models: models).contains(.auto))
      // No list yet: Auto waits for one.
      #expect(!SessionPills.offeredModes(session, models: nil).contains(.auto))
    }
  }

  @Test func bypassOnlyWhenAllowed() {
    scoped(allowsBypass: false) {
      let session = ClaudeSession(folder: folder)
      #expect(!SessionPills.offeredModes(session, models: models).contains(.bypass))
    }
  }

  /// The model's own name, not the menu's "Default (recommended)".
  @Test func labelsTheModel() {
    scoped {
      let session = ClaudeSession(folder: folder)
      #expect(SessionPills.modelLabel(for: session, in: models) == "Opus 5.5")
      #expect(SessionPills.modelLabel(for: session, in: nil) == "Default")
      session.setModel("haiku")
      #expect(SessionPills.modelLabel(for: session, in: models) == "Haiku 4.5")
      session.setModel("claude-opus-4-8")
      #expect(SessionPills.modelLabel(for: session, in: models) == "Opus 4.8")
    }
  }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/apple && make test-app`
Expected: build failure, `cannot find 'SessionPills' in scope`.

- [ ] **Step 3: Implement `SessionPills.swift`**

```swift
import DrakarKit
import SwiftUI

/// The session's permission mode and model, under the composer's field: a pick applies to a
/// running session at once, else at its start, and the folder remembers it
/// (docs/superpowers/specs/2026-10-06-mode-and-model-pills-design.md).
struct SessionPills: View {
  let session: ClaudeSession
  let folder: URL
  /// The account the session runs, or will start, under: whose models the menu lists.
  let account: ClaudeAccount

  private var catalog: ModelCatalog { .shared }

  var body: some View {
    let models = catalog.models(for: account)
    HStack(spacing: 6) {
      modeMenu(models)
      modelMenu(models)
      if let note = session.pillNote {
        Text(note).font(.caption).foregroundStyle(.red).lineLimit(1).help(note)
      }
    }
    .onAppear { catalog.load(folder: folder, account: account) }
  }

  private func modeMenu(_ models: [ModelOption]?) -> some View {
    let shown = session.shownMode
    let mode = PermissionMode(rawValue: shown)
    return Menu {
      ForEach(Self.offeredModes(session, models: models), id: \.self) { option in
        Button {
          session.setMode(option)
        } label: {
          Label(option.title, systemImage: option.rawValue == shown ? "checkmark" : option.symbol)
        }
      }
    } label: {
      Label(PermissionMode.title(of: shown), systemImage: mode?.symbol ?? "questionmark.circle")
    }
    .pill(tint: mode == .bypass ? .red : nil)
    .help("Permission mode. ⇧Tab moves to the next.")
    .accessibilityIdentifier("composer.mode")
  }

  private func modelMenu(_ models: [ModelOption]?) -> some View {
    let current = Self.option(for: session, in: models)
    return Menu {
      if let models {
        ForEach(models) { option in
          Button {
            session.setModel(option.value)
          } label: {
            if option.value == current?.value {
              Label(option.displayName, systemImage: "checkmark")
            } else {
              Text(option.displayName)
            }
            Text(option.description)
          }
        }
      } else {
        Text(loadingText)
      }
    } label: {
      Label(Self.modelLabel(for: session, in: models), systemImage: "cpu")
    }
    .pill(tint: nil)
    .help("Model")
    .accessibilityIdentifier("composer.model")
  }

  private var loadingText: String {
    let probe = CapabilityStore.shared.capabilities(for: folder, account: account)
    if probe.isLoading || !probe.hasLoaded { return String(localized: "Loading models…") }
    return probe.skillsProblem ?? String(localized: "This Claude Code version didn't list models.")
  }

  /// Ask, Edit and Plan always; Auto for a model that says it takes it; Bypass while allowed.
  static func offeredModes(_ session: ClaudeSession, models: [ModelOption]?) -> [PermissionMode] {
    PermissionMode.allCases.filter { mode in
      switch mode {
      case .auto: option(for: session, in: models)?.supportsAutoMode == true
      case .bypass: session.offersBypass
      default: true
      }
    }
  }

  /// The list's entry for the session's model: its pick, else the running model, else
  /// `default`.
  static func option(for session: ClaudeSession, in models: [ModelOption]?) -> ModelOption? {
    guard let models else { return nil }
    if let pick = session.pickedModel { return models.first { $0.value == pick } }
    if let running = session.transcript.session?.model {
      let base = running.replacingOccurrences(of: "[1m]", with: "")
      if let match = models.first(where: { $0.resolvedModel == base && $0.value != "default" }) {
        return match
      }
    }
    return models.first { $0.value == "default" }
  }

  /// The model's own name ("Opus 5.5"), never "Default (recommended)".
  static func modelLabel(for session: ClaudeSession, in models: [ModelOption]?) -> String {
    if let option = option(for: session, in: models) {
      return ModelName.display(option.resolvedModel ?? option.value)
    }
    if let pick = session.pickedModel, pick != "default" { return ModelName.display(pick) }
    if let running = session.transcript.session?.model { return ModelName.display(running) }
    return String(localized: "Default")
  }

  /// ⇧Tab: the next offered mode.
  static func cycle(_ session: ClaudeSession, account: ClaudeAccount) {
    let offered = offeredModes(session, models: ModelCatalog.shared.models(for: account))
    let current = PermissionMode(rawValue: session.shownMode) ?? .ask
    session.setMode(PermissionMode.next(after: current, among: offered))
  }
}

extension View {
  /// A composer pill: a borderless menu in a capsule, red for Bypass.
  fileprivate func pill(tint: Color?) -> some View {
    self
      .menuStyle(.borderlessButton)
      .menuIndicator(.visible)
      .fixedSize()
      .font(.caption)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background((tint ?? Color.secondary).opacity(tint == nil ? 0.12 : 0.2), in: Capsule())
      .foregroundStyle(tint ?? .primary)
  }
}
```

- [ ] **Step 4: `ComposerView` takes the pills and ⇧Tab**

Properties, after `focused`:

```swift
  /// The session's mode and model, on the row under the field, left of Send.
  var pills: SessionPills? = nil
  /// ⇧Tab in the field: the next permission mode.
  var cycleMode: (() -> Void)? = nil
```

`field` becomes the text field over a row of pills and the button:

```swift
  private var field: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Ask Claude to do something…", text: $text, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...10)
        .focused($isFocused)
        .onSubmit(submit)
        // ⇧Tab arrives as backtab; plain Tab is left to focus traversal.
        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
          guard press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}"),
            let cycleMode
          else { return .ignored }
          cycleMode()
          return .handled
        }
        .accessibilityIdentifier("composer.field")
      HStack(spacing: 8) {
        if let pills { pills }
        Spacer(minLength: 0)
        button
      }
    }
  }

  @ViewBuilder private var button: some View {
    Group {
      if isRunning {
        Button("Stop", systemImage: "stop.circle.fill", action: stop)
          .keyboardShortcut(".", modifiers: .command)
          .accessibilityIdentifier("composer.stop")
      } else {
        Button("Send", systemImage: "arrow.up.circle.fill", action: submit)
          .disabled(!canSend || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("composer.send")
      }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .font(.body)
    .imageScale(.large)
  }
```

- [ ] **Step 5: `SessionView` passes them; the footer**

In the `ComposerView(…)` call, after `focused:`:

```swift
          pills: SessionPills(session: session, folder: project.folder, account: account),
          cycleMode: { SessionPills.cycle(session, account: account) })
```

with, in `SessionView`:

```swift
  /// The account the session runs, or will start, under.
  private var account: ClaudeAccount {
    session.effectiveAccount ?? AccountStore.shared.windowAccount(for: project.folder)
  }
```

In `SessionFooter.body`, the model only for a read-only session, with its mode:

```swift
      if elsewhere != nil {
        if let mode = session.transcript.historyPermissionMode {
          Text(PermissionMode.title(of: mode))
        }
        if let modelID {
          Text(ModelName.display(modelID)).help(modelID)
        }
      }
```

(replacing the unconditional `if let modelID { … }`).

- [ ] **Step 6: Build, run the suites, check it live (with the person's go-ahead)**

Run: `cd apps/apple && make build && make test-app && make test`
Expected: `** BUILD SUCCEEDED **`; both suites PASS.

Live, only once the person says so (`make run` quits the running Drakar), through cupertino-desktop's accessibility tree: in a scratch folder, `composer.model` lists the account's models; pick Haiku, send "say hi"; open `composer.mode`, pick Plan; ⇧Tab in `composer.field` moves Plan → Auto or Bypass → Ask; the footer shows no model.

- [ ] **Step 7: Format and commit**

```bash
A=apps/apple
xcrun swift-format format --in-place $A/Drakar/Views/SessionPills.swift $A/Drakar/Views/ComposerView.swift $A/Drakar/Views/SessionView.swift $A/DrakarTests/SessionPillsTests.swift
git add $A/Drakar/Views/SessionPills.swift $A/Drakar/Views/ComposerView.swift $A/Drakar/Views/SessionView.swift $A/DrakarTests/SessionPillsTests.swift
git commit -m "feat(apple): mode and model pills under the composer, ⇧Tab cycles the mode"
```
