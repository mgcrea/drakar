# Permission Rules and Open Plan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An inspector tab that lists, adds and removes Claude Code permission rules, and a Session › Open Plan that opens the session's plan file in the side editor.

**Architecture:** The kit decodes `list_permission_rules` and `get_plan` replies and encodes rule edits. The app asks a running session's process through `ClaudeBackend` (ids it tracks, signals the session awaits), or a small rules probe when there is no process, and writes edits by running `claude edit-permission-rules --json` through `ProcessRunner`. An `@Observable` model drives the tab; the plan reply opens a file through `Workspace.open`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing; DrakarKit (`make test`) and the app target (`make -C apps/apple test-app`).

**Spec:** docs/superpowers/specs/2026-10-31-permission-rules-design.md

## Global Constraints

- CLI facts are claude 2.1.312's, measured 2026-10-31; the spec's "What the CLI offers" is the wire truth.
- A rule is sent back to the CLI verbatim, exactly as listed; only display escapes it.
- Unknown `source`, `behavior` or `editability` strings never fail a decode: an unknown source keeps its raw name; a rule with an unknown behavior is dropped; unknown editability reads as `readonly`.
- The edit command: `claude edit-permission-rules --json`, edit JSON on stdin, current directory the session's folder, environment from `ClaudeLaunch.make(…, checkpoints: false)` minus `CLAUDE_CODE_CHILD_SESSION`, 30 s timeout.
- Re-read after an edit on a live process: up to 14 times, 300 ms apart. With no process: one fresh rules probe.
- Rules probe timeout 20 s; control replies (rules, plan) awaited 10 s.
- Copy, verbatim: "Codex sessions have no permission rules." / "This session isn't running, so its own approvals aren't listed." / "Saved; not in the list yet." / "Not in effect: managed settings allow only their own rules" / "Managed settings allow only their own rules." / "No plan in this session yet." / "Couldn't read the plan." / "Claude Code didn't answer."
- Save-in labels: "This project, only you" (`localSettings`), "This project, shared" (`projectSettings`), "All projects" (`userSettings`). Source tags: User, Project, Local, Flag, Policy, Command line, Slash command, Session, MCP, else the raw name.
- Menu: Session › Open Plan, ⌥⌘P. Inspector tab label "Permissions", after "Skills & MCP".
- Follow CLAUDE.md: swift-format file by file; comments in the codebase's voice.

## Review Focus

1. A rule holding invisible characters (`Bash(rm\u{200B} -rf)`): shown escaped, removed with the verbatim string. Test in Task 4 (`removeSendsTheRuleVerbatim`) and Task 1 (`escapesInvisibleCharacters`).
2. The selected session changes while a listing is in flight: the late answer must not land on the new session's tab. Test in Task 4 (`aLateListingForAnotherSessionIsDropped`).
3. The process exits while a rules or plan request waits: the wait ends at once with no answer, never hangs to the timeout. Test in Task 2 (`aProcessEndEndsTheWait`).
4. The Add field's lines with surrounding spaces, blank lines, or nothing but blanks: lines trimmed, blanks dropped, an all-blank field sends nothing. Test in Task 4 (`addTrimsAndDropsBlankLines`).
5. The edit command can't start (no `claude` found) or is killed by the timeout: a refusal with a sentence, never a silent nothing. Test in Task 3 (`aMissingClaudeIsARefusal`, `aStalledEditTimesOut`).

---

### Task 1: Kit types for rules, edits and the plan

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/PermissionRules.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ClientMessage.swift` (two cases)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PermissionRulesTests.swift`, `ClientMessageTests.swift`

**Interfaces:**
- Produces:
  - `public enum PermissionBehavior: String, Sendable, CaseIterable { case allow, ask, deny }`
  - `public enum PermissionRuleFile: String, Sendable, CaseIterable { case localSettings, projectSettings, userSettings }`
  - `public struct PermissionRule: Sendable, Hashable { behavior: PermissionBehavior; source: String; rule: String; description: Description?; editability: Editability; notInEffect: Bool; var isRemovable: Bool /* editability == .persistent && PermissionRuleFile(rawValue: source) != nil */ }` with nested `struct Description: Sendable, Hashable { prefix: String; emphasis: String?; suffix: String? }` and `enum Editability: String, Sendable { case persistent, session, readonly }`.
  - `public struct PermissionRulesState: Sendable, Equatable { rules: [PermissionRule]; directories: [Directory]; managedOnly: Bool; errors: [String]; init?(_ response: JSONValue?) }` reading `response["state"]`; nil without `state.rules`. `Directory { path: String; source: String }`. Each `errors` element becomes its `message` string, else its compact JSON text.
  - `public enum PermissionRuleEdit: Sendable, Equatable { case add(rules: [String], behavior: PermissionBehavior, file: PermissionRuleFile); case remove(rule: String, behavior: PermissionBehavior, file: PermissionRuleFile); var json: JSONValue; static let arguments = ["edit-permission-rules", "--json"] }` (`destination` for add, `source` for remove).
  - `public enum PermissionRuleEditOutcome: Sendable, Equatable { case saved(warnings: [String], stored: [String]); case refused(String); static func read(status: Int32, output: String, errors: String) -> Self }`: status 0 reads stdout's last non-empty line as `{ok, warnings, stored}` (missing lists read empty); otherwise `.refused` with stderr trimmed and a leading `Error: ` removed, or "Claude Code couldn't save the rule (exit status N)." when stderr is empty.
  - `public struct PlanReply: Sendable, Equatable { exists: Bool; content: String?; path: String?; init?(_ response: JSONValue?) }` (nil without `exists`).
  - `public func escapedForDisplay(_ text: String) -> String` (free function or `PermissionRule.displayed(_:)`, implementer's pick): Unicode format (Cf) and control (Cc) scalars become `\u{XXXX}` (uppercase hex, at least 4 digits); everything else unchanged.
  - `ClientMessage.listPermissionRules(requestID: String)` → `{"subtype": "list_permission_rules"}`; `ClientMessage.getPlan(requestID: String)` → `{"subtype": "get_plan"}`.

- [ ] **Step 1: Write the failing tests** in `PermissionRulesTests.swift`:
  - `decodesTheRealReply`: the spec's real reply JSON → two rules; first `.allow`, source `"localSettings"`, description prefix `"Any Bash command starting with "`, emphasis `"npm run test"`, `isRemovable == true`; second `.deny`, `description == nil`; `managedOnly == false`, `directories.isEmpty`.
  - `unknownValuesDoNotFail`: a rule with source `"somethingNew"` keeps it; editability `"weird"` reads `.readonly` and `isRemovable == false`; a rule with behavior `"maybe"` is dropped; `notInEffect: true` reads true.
  - `sessionRulesAreNotRemovable`: source `"session"`, editability `"session"` → `isRemovable == false`.
  - `encodesEdits`: `.add(rules: ["A", "B"], behavior: .allow, file: .localSettings).json == {"op":"add","rules":["A","B"],"behavior":"allow","destination":"localSettings"}`; `.remove(rule: "R", behavior: .deny, file: .userSettings).json == {"op":"remove","rule":"R","behavior":"deny","source":"userSettings"}`.
  - `readsOutcomes`: status 0, output `"noise\n{\"ok\":true,\"warnings\":[\"w\"],\"stored\":[\"S\"]}\n"` → `.saved(warnings: ["w"], stored: ["S"])`; status 1, errors `"Error: rule not found: no deny rule…\n"` → `.refused("rule not found: no deny rule…")`; status 1, errors `""` → `.refused("Claude Code couldn't save the rule (exit status 1).")`.
  - `decodesPlans`: `{"exists": false}` → exists false, nil content/path; `{"exists": true, "content": "# P", "path": "/p.md"}`; `{}` → nil.
  - `escapesInvisibleCharacters`: `"Bash(rm\u{200B} -rf)"` → `"Bash(rm\\u{200B} -rf)"`; `"a\u{7}b"` → `"a\\u{0007}b"`; `"héllo ✓"` unchanged.
  - In `ClientMessageTests.swift`: `listPermissionRulesAndGetPlan` checking each encodes a `control_request` with its id and subtype.
- [ ] **Step 2: Run** `make test` from `apps/apple` (or `swift test --package-path Packages/DrakarKit --filter PermissionRules`). Expected: FAIL, types not defined.
- [ ] **Step 3: Implement** the types above in `PermissionRules.swift` and the two `ClientMessage` cases (follow `rewindFiles`'s encoding in `ClientMessage.swift`).
- [ ] **Step 4: Run** `make test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(kit): permission rules, rule edits and the plan, read and written`.

### Task 2: Asking a running process (backend, signals, session)

**Files:**
- Modify: `apps/apple/Drakar/Services/AgentBackend.swift` (commands, signals), `ClaudeBackend.swift` (encode, receive), `AgentSession.swift` (awaitable asks, rules revision)
- Test: `apps/apple/DrakarTests/ClaudeBackendTests.swift`, `apps/apple/DrakarTests/AgentSessionRepliesTests.swift`

**Interfaces:**
- Consumes: Task 1's `PermissionRulesState`, `PlanReply`, `ClientMessage.listPermissionRules`/`.getPlan`.
- Produces:
  - `AgentCommand.listPermissionRules`, `AgentCommand.getPlan` (sent without a note, as `rewindFiles`).
  - `enum PermissionRulesAnswer: Equatable { case listed(PermissionRulesState); case refused(String) }` (app, in `AgentBackend.swift`).
  - `SessionSignal.permissionRulesAnswered(requestID: String, PermissionRulesAnswer)` and `SessionSignal.planAnswered(requestID: String, PlanReply?)` (nil: refused or unreadable). `ClaudeBackend` ids `rules-<UUID>` and `plan-<UUID>`; replies to ids it never sent say nothing. A refused list carries the CLI's `error`, else "Claude Code didn't answer.".
  - On `AgentSession`: `func listPermissionRules() async -> PermissionRulesAnswer?` and `func readPlan() async -> PlanReply?`: nil at once without a process Drakar drives (`controlsTasks`) or for Codex; otherwise the answer, or nil after 10 s (`controlReplyTimeout: Duration`, settable for tests) or when the process ends first.
  - `AgentSession.hasLiveRules: Bool` (true when `listPermissionRules` would ask a process) and `AgentSession.rulesRevision: Int`, bumped after `answer(_:_:)` sends an `.allow` whose `updatedPermissions` is not empty.

- [ ] **Step 1: Write the failing tests:**
  - `ClaudeBackendTests.rulesAndPlanRepliesBecomeSignals`: send `.listPermissionRules` through a recording transport, feed back a success `control_response` for the returned id with the spec's real `state` → `.permissionRulesAnswered(id, .listed(…two rules…))`; an error response → `.refused(<its error>)`; `.getPlan` success `{"exists": false}` → `.planAnswered(id, PlanReply(exists: false…))`; a reply for an unknown `rules-x` id → no signal.
  - `AgentSessionRepliesTests.listsRulesFromItsProcess`: a session on a fake transport that answers `list_permission_rules` → `await listPermissionRules() == .listed(…)`.
  - `AgentSessionRepliesTests.aProcessEndEndsTheWait`: a fake that never answers, then exits after 50 ms → `listPermissionRules()` returns nil in well under `controlReplyTimeout` (set it to 5 s, assert < 2 s).
  - `AgentSessionRepliesTests.noProcessNoAsk`: a session without a process → nil, nothing sent.
  - `AgentSessionRepliesTests.anAlwaysAllowBumpsTheRevision`: answering a pending permission with `.allow(updatedInput:…, updatedPermissions: [<one rule update>])` raises `rulesRevision` by 1; with `[]` it doesn't.
- [ ] **Step 2: Run** `make -C apps/apple test-app` filtered (`xcodebuild test … -only-testing:DrakarTests/ClaudeBackendTests -only-testing:DrakarTests/AgentSessionRepliesTests`). Expected: FAIL to compile.
- [ ] **Step 3: Implement.** Keep the awaiting in the session: a dictionary from request id to a continuation, resumed by the signal handler, by the timeout task, or with nil by every pending entry when the process ends (where `rewinds.processEnded()` is called). Sending goes through `backend.send` as `tasks.send` does, never `write`.
- [ ] **Step 4: Run** the same tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): a running session answers for its permission rules and its plan`.

### Task 3: Reading and editing rules without a session's process

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ProcessRunner.swift` (`input: Data? = nil`, `currentDirectory: URL? = nil` parameters on `run`)
- Create: `apps/apple/Drakar/Services/PermissionRulesProbe.swift`, `apps/apple/Drakar/Services/PermissionRuleEditor.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ProcessTests.swift` (one test), `apps/apple/DrakarTests/PermissionRulesProbeTests.swift`, `apps/apple/DrakarTests/PermissionRuleEditorTests.swift`

**Interfaces:**
- Consumes: Task 1's `PermissionRuleEdit`, `PermissionRuleEditOutcome`, `PermissionRulesState`; Task 2's `PermissionRulesAnswer`; `CapabilityProbe.launch(folder:account:environment:executableOverride:)` and `CapabilityProbe.release(_:after:)`.
- Produces:
  - `enum PermissionRulesProbe { static func run(folder: URL, account: ClaudeAccount?, executableOverride: URL?, timeout: Duration = .seconds(20)) async -> PermissionRulesAnswer }`: starts `claude` as `CapabilityProbe` does, sends `initialize` (id `rules-probe-init`) then `list_permission_rules` (id `rules-probe-list`), lets the process go once the list is answered; a missing folder, missing `claude`, early exit or timeout is `.refused(<sentence>)` (reuse `CapabilityProbe`'s wording: `ClaudeLaunch.notFound`, "Claude Code took too long to answer.", "Claude Code exited with status N.", "Claude Code stopped before it answered.").
  - `enum PermissionRuleEditor { static func apply(_ edit: PermissionRuleEdit, folder: URL, account: ClaudeAccount?, executableOverride: URL?, timeout: Duration = .seconds(30)) async -> PermissionRuleEditOutcome }`: environment from `ClaudeLaunch.make(folder:resuming: nil, account:, environment: await AgentSession.environment.value, executableOverride:, checkpoints: false)` with `CLAUDE_CODE_CHILD_SESSION` removed; `PermissionRuleEdit.arguments`; edit JSON as stdin; current directory `folder`. No executable → `.refused(ClaudeLaunch.notFound)`; timed out → `.refused("Claude Code took too long to save the rule.")`; else `PermissionRuleEditOutcome.read`.

- [ ] **Step 1: Write the failing tests** (stand-in `claude` scripts, as `CapabilityProbeTests` makes them):
  - `ProcessTests.feedsInputAndRunsInTheFolder`: `/bin/sh -c 'pwd; cat'` with `input: "hi"`, `currentDirectory: <temp>` → output `"<temp resolved>\nhi"`.
  - `PermissionRulesProbeTests.readsTheListing`: a stand-in that reads stdin lines and, for the line holding `list_permission_rules`, prints a success `control_response` with id `rules-probe-list` and the spec's real `state` → `.listed` with two rules.
  - `PermissionRulesProbeTests.aRefusalIsSaid`: the stand-in answers that id with `{"subtype":"error","error":"nope"}` → `.refused("nope")`.
  - `PermissionRulesProbeTests.aSilentClaudeTimesOut`: a stand-in that sleeps; `timeout: .milliseconds(500)` → `.refused("Claude Code took too long to answer.")`.
  - `PermissionRuleEditorTests.sendsTheEditAndReadsTheOutcome`: a stand-in that writes `$PWD`, its arguments and stdin to a file in the test folder, then prints `{"ok":true,"warnings":[],"stored":["A"]}` → `.saved(warnings: [], stored: ["A"])`; the file shows `edit-permission-rules --json`, the folder, and the add JSON.
  - `PermissionRuleEditorTests.dropsTheChildSessionVariable`: the stand-in exits 1 with `inside` on stderr when `CLAUDE_CODE_CHILD_SESSION` is set; run with it set in the test process's environment override → not refused for that reason (use the editor's environment hook: `apply` takes an internal `environment: [String: String]? = nil` override for tests, merged before the removal).
  - `PermissionRuleEditorTests.aRefusalCarriesStderr`: exit 1, stderr `Empty parentheses — …` → `.refused("Empty parentheses — …")`.
  - `PermissionRuleEditorTests.aMissingClaudeIsARefusal`: `executableOverride` to a path that does not exist, with no `claude` reachable → `.refused(ClaudeLaunch.notFound)` (if `ClaudeLocator` would find the real one, point `PATH` at an empty folder through the environment override).
  - `PermissionRuleEditorTests.aStalledEditTimesOut`: stand-in `sleep 5`, `timeout: .milliseconds(300)` → `.refused("Claude Code took too long to save the rule.")`.
- [ ] **Step 2: Run** `make test` and the two app suites. Expected: FAIL.
- [ ] **Step 3: Implement** the `ProcessRunner` parameters (stdin written then closed; nil input keeps `/dev/null`), the probe (a small loop modelled on `CapabilityProbe.collect`, without the MCP re-asking) and the editor.
- [ ] **Step 4: Run** them again. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): read rules with no session running, and save rule edits through claude`.

### Task 4: The Permissions model

**Files:**
- Create: `apps/apple/Drakar/Services/PermissionRulesModel.swift`
- Test: `apps/apple/DrakarTests/PermissionRulesModelTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `@MainActor @Observable final class PermissionRulesModel` with
  - `struct Source { var key: AnyHashable /* the session's id */; var isCodex: Bool; var isLive: Bool; var list: () async -> PermissionRulesAnswer?; var edit: (PermissionRuleEdit) async -> PermissionRuleEditOutcome }` and `static func source(for item: ProjectSession) -> Source` (live: `session.listPermissionRules()`; not live: `PermissionRulesProbe.run` for the session's folder, account, executable override; edit: `PermissionRuleEditor.apply` with the same).
  - `enum Listing: Equatable { case idle, loading, codex, listed(PermissionRulesState, live: Bool), failed(String) }`; `private(set) var listing`, `private(set) var removing: Set<PermissionRule>`, `private(set) var note: String?` (warnings joined by newlines, "Saved; not in the list yet.", or a remove's refusal).
  - `func show(_ source: Source)` (switches source and reads; the same key again does not re-read), `func refresh()`, `func add(_ text: String, behavior: PermissionBehavior, file: PermissionRuleFile) async -> String?` (nil on success, else the refusal for the sheet), `func remove(_ rule: PermissionRule) async`.
  - `var rereadAttempts = 14`, `var rereadInterval: Duration = .milliseconds(300)` (tests shorten them).
  - A nil `list()` answer reads `.failed("Claude Code didn't answer.")`; `.refused(text)` reads `.failed(text)`.

- [ ] **Step 1: Write the failing tests** with a fake `Source` (closures over a mutable fake rule list):
  - `listsOnShow`, `codexSaysSo` (`isCodex` → `.codex`, `list` never called), `aRefusalFails`.
  - `addTrimsAndDropsBlankLines`: `add("  A  \n\n B\n", …)` sends `.add(rules: ["A", "B"], …)`; `add(" \n ", …)` sends nothing and returns nil.
  - `addRereadsUntilTheRuleShows`: live source whose listing gains the stored rule on the 3rd read → listing has it, `note == nil`, `list` called 1 (before) + 3 times.
  - `anAddThatNeverShowsSaysSo`: listing never changes → `note == "Saved; not in the list yet."` after `rereadAttempts` reads.
  - `notLiveReadsOnceAfterAnEdit`: `isLive == false` → exactly one read after the edit.
  - `aRefusedAddReturnsTheWords`: edit returns `.refused("dup")` → `add` returns `"dup"`, listing unchanged.
  - `removeSendsTheRuleVerbatim`: removing a rule `"Bash(rm\u{200B} -rf)"` from `localSettings` sends `.remove(rule: "Bash(rm\u{200B} -rf)", behavior: .deny, file: .localSettings)`; `removing` holds it until the reread shows it gone.
  - `warningsBecomeTheNote`: `.saved(warnings: ["w1", "w2"], …)` → `note == "w1\nw2"`.
  - `aLateListingForAnotherSessionIsDropped`: `show(A)` with a `list` that waits on a continuation, `show(B)` answers first, then A's answer arrives → listing is B's.
- [ ] **Step 2: Run** `-only-testing:DrakarTests/PermissionRulesModelTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Each read carries a generation number; an answer for an older one is dropped.
- [ ] **Step 4: Run** again. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): the permissions model, its reads, edits and rereads`.

### Task 5: The Permissions tab

**Files:**
- Create: `apps/apple/Drakar/Views/PermissionsInspector.swift`
- Modify: `apps/apple/Drakar/Views/InspectorView.swift` (`InspectorTab.permissions`, picker item "Permissions")
- Test: `apps/apple/DrakarTests/PermissionRulesModelTests.swift` (labels), plus a build

**Interfaces:**
- Consumes: Task 4's model; Task 2's `AgentSession.rulesRevision`; Task 1's `escapedForDisplay`.
- Produces: `struct PermissionsInspector: View { let project: Project }`; `static func sourceLabel(_ source: String) -> String` (on the view or a small enum) with the Global Constraints' tags; accessibility ids `permissions.add`, `permissions.refresh`, `permissions.section.<behavior>`, `permissions.rule.<behavior>.<index>`, `permissions.remove.<behavior>.<index>`, `permissions.note`, `permissions.sheet.rules`, `permissions.sheet.add`, `permissions.sheet.error`.

- [ ] **Step 1: Write the failing test** `sourceLabels`: `"userSettings"→"User"`, `"projectSettings"→"Project"`, `"localSettings"→"Local"`, `"flagSettings"→"Flag"`, `"policySettings"→"Policy"`, `"cliArg"→"Command line"`, `"command"→"Slash command"`, `"session"→"Session"`, `"mcpServerPolicy"→"MCP"`, `"mcpMount"→"MCP"`, `"hostCredential"→"hostCredential"`.
- [ ] **Step 2: Run** it. Expected: FAIL.
- [ ] **Step 3: Implement the view** per the spec's "The list", "Remove" and "Add Rule…": a `Form` like `SessionInspector`'s; sections in order Allow, Ask, Deny, empty ones left out; Directories and Settings Errors sections; the managed-only line; the not-live footer; `ContentUnavailableView` for no session, Codex and failures (failure has Retry). Add Rule… and Refresh sit in the tab's own header row (the window toolbar holds the tab picker). The sheet keeps its text on a refusal and shows the refusal under the field. The model is `@State` in the view; `.task(id:)` on the selected session's id plus its `rulesRevision` calls `show`/`refresh`; nothing reads while the tab is hidden (the view only exists when shown).
- [ ] **Step 4: Run** the test and `make -C apps/apple build`. Expected: PASS, BUILD SUCCEEDED.
- [ ] **Step 5: Commit** `feat(app): an inspector tab lists, adds and removes permission rules`.

### Task 6: Open Plan, and the docs

**Files:**
- Modify: `apps/apple/Drakar/Services/Project.swift` (`openPlanSelected`, `canOpenPlanSelected`), `apps/apple/Drakar/DrakarApp.swift` (SessionCommands item), `apps/apple/Drakar/Views/PlanPanel.swift` (header button, `openPlan: (() -> Void)?`), `apps/apple/Drakar/Views/SessionView.swift` (passes it), `docs/claude-stream-json.md`, `docs/extension-parity.md`
- Test: `apps/apple/DrakarTests/PlanApprovalSessionTests.swift` or a new `OpenPlanTests.swift`

**Interfaces:**
- Consumes: Task 2's `AgentSession.readPlan()`; `Workspace.open(_:select:)`; `Transcript.addNotice(_:parent:)` through the session.
- Produces: `Project.canOpenPlanSelected: Bool` (selected session is Claude with a driven process) and `Project.openPlanSelected() async`; `PlanPanel(… openPlan: (() -> Void)? = nil)` showing "Open Plan File" (id `plan.open`) in its header when set; Session › Open Plan (⌥⌘P), disabled unless `canOpenPlanSelected`.

- [ ] **Step 1: Write the failing tests:** `opensAnExistingPlan` (session fake answers `{"exists": true, "content": "# P", "path": <temp file>}` → the project's workspace has that file open and active); `noPlanSaysSo` (`{"exists": false}` → the transcript's last notice is "No plan in this session yet."); `aFailedReadSaysSo` (no answer → "Couldn't read the plan."); `existsWithoutPathSaysNoPlan`.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement** the project method, the menu item (beside Fork Session, its own small `View` like `ForkSessionCommand`), the panel button and the session view wiring.
- [ ] **Step 4: Docs.** `docs/claude-stream-json.md`: a "Permission rules" section (the listing shape, the real reply, the edit command, its refusals, `CLAUDE_CODE_CHILD_SESSION`, the 1.3 s pickup) and a "Plan" section (`get_plan`'s shape), both dated claude 2.1.312, 2026-10-31, taken from the spec. `docs/extension-parity.md`: `list_permission_rules`, `add_permission_rules`, `remove_permission_rule`, `open_plan` rows to `has` with evidence (`PermissionsInspector.swift`, `Project.openPlanSelected`); the CLI section's `list_permission_rules` and `get_plan` rows to `sends`.
- [ ] **Step 5: Run** the tests, `make test`, and `make -C apps/apple test-app`. Expected: PASS apart from the known flakes (CapabilityProbe timing, `aSessionOpenedElsewhereDuringTheStartIsNotWritten`), which pass rerun alone.
- [ ] **Step 6: Commit** `feat(app): Session > Open Plan opens the plan file; docs for rules and the plan`.
