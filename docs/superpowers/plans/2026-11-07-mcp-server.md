# Drakar MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An MCP server inside Drakar, on 127.0.0.1 behind a Keychain token, off by default,
through which an agent lists, reads, starts and steers Drakar's sessions on this Mac and on
the runner, and (behind its own switch) answers their permission prompts.

**Architecture:** Cadence's shape. A new SwiftPM package `DrakarMCP` holds the tool table,
argument parsing and encoding, written against a `SessionSource` protocol and tested offline
against a fake. The app answers `SessionSource` from `OpenSessions`, `SessionMonitor`,
`SessionHost` and `Project` on the main actor (`Drakar/MCP/`), owns the listener through
`MCPServerController`, and adds a Settings › MCP Server pane from `MCPKitUI`.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit, swift-mcp-kit 1.6.x (`MCPKit`, `MCPKitLoopback`,
`MCPKitUI`, `MCPKitWiring`), DrakarKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-07-mcp-server-design.md` (read it; its §-numbers
are cited below).

## Global Constraints

- DrakarKit keeps zero dependencies; nothing here adds one to it.
- Kit dependency: `.package(url: "https://github.com/mgcrea/swift-mcp-kit.git", .upToNextMinor(from: "1.6.1"))`; in the Xcode project an `XCRemoteSwiftPackageReference` with `kind = upToNextMinorVersion; minimumVersion = 1.6.1;`.
- `DrakarMCP` package: swift-tools 6.3, `platforms: [.macOS(.v26)]`, path `apps/apple/Packages/DrakarMCP`.
- **Two `JSONValue`s.** DrakarKit and MCPKit each define `JSONValue`. In any file importing both, always write `DrakarKit.JSONValue` / `MCPKit.JSONValue`; never the bare name.
- Tool names: `drakar_list_sessions`, `drakar_needs_attention`, `drakar_get_session`, `drakar_read_transcript`, `drakar_wait`, `drakar_list_projects`, `drakar_start_session`, `drakar_send_message`, `drakar_interrupt`, `drakar_end_session`, `drakar_answer_question`, `drakar_answer_permission`. Arguments snake_case, result fields camelCase.
- Ports: Release `8811`, Debug `8812` (`#if DEBUG`).
- Preference keys: `drakar.mcp.enabled`, `drakar.mcp.port`, `drakar.mcp.allowWrites`, `drakar.mcp.allowPermissions`; all Bool ones default `false`.
- Keychain service: Release `io.mgcrea.Drakar.mcp`, Debug `io.mgcrea.Drakar.mcp-dev`.
- Server name: Release `drakar`, Debug `drakar-dev`. Bastion display name `Drakar` / `Drakar (Debug)`, summary `Starts, reads and steers Claude Code and Codex sessions in Drakar, on this Mac and its runner.`
- Logger: `Logger(subsystem: "io.mgcrea.Drakar", category: "MCP")`. The audit line is method, tool name, outcome, duration; never arguments, prompts, answers or transcript text.
- Every write goes through the call the window's own control makes (spec Anti-goals). No new path into a session's process.
- No MCP call makes a Drakar window key or main, orders one front, or activates the app (spec §3 start_session).
- Never `make run` / `make quit` / relaunch Drakar: the person's live Drakar holds their sessions.
- Swift 6.3 on CI: give `Task`s in generic closures an explicit type (`Task<Void, Never>`).
- Formatting: `make -C apps/apple format-swift-check` must pass (CI runs it).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A prompt id that was already answered** (the person clicked Allow in the window a second before the agent called): `answer_permission` / `answer_question` must say "already answered" and change nothing, never answer the next prompt. Test in Task 5 and Task 8.
2. **A prefix matching two sessions**: refused with both candidates listed, never the first match. Test in Task 2.
3. **The project's window is open on another Drakar window the person is typing in**: `start_session` must leave `NSApp.keyWindow` unchanged. Test in Task 8.
4. **A runner that is set up but unreachable**: `start_session(runner:)` refuses with the reason and leaves no blank row behind; `list_sessions` still answers for this Mac's sessions. Test in Task 8 (refusal) and Task 7 (listing).
5. **A huge tool input or result** (a 2 MB file write in a permission request, a long Bash output): truncated with a `truncated: true` marker, never sent whole. Test in Task 2 (permission input, 4 KB per string) and Task 3 (tool result, 2 KB).

---

### Task 1: DrakarMCP package, the source protocol, and the test wiring

**Files:**
- Create: `apps/apple/Packages/DrakarMCP/Package.swift`
- Create: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/SessionSource.swift`
- Create: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/JSONBridge.swift`
- Create: `apps/apple/Packages/DrakarMCP/Tests/DrakarMCPTests/FakeSessionSource.swift`
- Create: `apps/apple/Packages/DrakarMCP/Tests/DrakarMCPTests/JSONBridgeTests.swift`
- Modify: `apps/apple/Makefile` (`test` target), `.github/workflows/ci.yml` (only if `make -C apps/apple test` is not already what CI runs; it is at line ~257, so the Makefile change suffices)

**Interfaces:**
- Produces (all `public`, in `DrakarMCP`):

```swift
public enum Agent: String, Sendable, CaseIterable { case claude, codex }
public enum SessionState: String, Sendable { case working, waiting, idle, reconnecting, unreachable, ended }
public enum SessionPlace: String, Sendable { case window, background, elsewhere }

public struct SessionRow: Sendable, Equatable {
  public var id: String; public var title: String?; public var agent: Agent
  public var folder: String; public var runner: String?          // runner display name, nil = this Mac
  public var state: SessionState; public var waitingFor: String?
  public var model: String?; public var contextUsed: Int?; public var contextLimit: Int?
  public var lastActivity: Date?; public var place: SessionPlace
  public var readOnly: Bool; public var heldBy: String?
}

public enum PendingItem: Sendable, Equatable {
  case permission(requestID: String, request: PermissionRequest)   // DrakarKit type
  case elicitation(requestID: String, elicitation: Elicitation)   // DrakarKit type
  public var requestID: String { get }
}

public enum AttentionKind: String, Sendable {
  case permission, question, plan, elicitation
  case askedInText = "asked_in_text", offeredInText = "offered_in_text"
}

public struct AttentionItem: Sendable, Equatable {
  public var session: SessionRow; public var kind: AttentionKind
  public var pending: PendingItem?   // nil for askedInText / offeredInText
  public var text: String?           // the ask's text for the in-text kinds
}

public struct SessionDetail: Sendable, Equatable {
  public var row: SessionRow; public var pending: [PendingItem]
  public var queued: [String]; public var permissionMode: String?; public var accountFolder: String?
}

public struct ProjectRow: Sendable, Equatable { public var folder: String; public var runner: String?; public var isOpen: Bool }
public struct RunnerStatus: Sendable, Equatable {
  public var name: String; public var isConnected: Bool
  public var drakarVersion: String?; public var claudeVersion: String?; public var lastError: String?
}
public struct StartRequest: Sendable, Equatable {
  public var folder: String; public var runner: String?; public var prompt: String
  public var agent: Agent?; public var model: String?
}
public enum SendOutcome: String, Sendable { case sent, queued }

/// A refusal whose sentence is meant for the caller.
public struct SessionError: LocalizedError, Sendable, Equatable {
  public var message: String
  public init(_ message: String)
  public var errorDescription: String? { message }
}

public protocol SessionSource: Sendable {
  /// Live sessions (window, background, elsewhere), then, when `includeEnded`, up to
  /// `endedLimit` ended ones newest first.
  func sessions(includeEnded: Bool, endedLimit: Int) async -> [SessionRow]
  func detail(of id: String) async -> SessionDetail?
  /// Most urgent first, Drakar's `Urgency` order (permission, choice, question, offer).
  func attention() async -> [AttentionItem]
  func transcript(of id: String) async throws -> Transcript     // DrakarKit.Transcript
  func projects() async -> [ProjectRow]
  func runner() async -> RunnerStatus?
  /// Nil when work may be sent; otherwise the composer's sentence.
  func workRefusal() async -> String?
  /// Settings › MCP Server › Let agents answer permission prompts, read at each call.
  func permissionsAllowed() async -> Bool
  /// Returns the new session's id.
  func start(_ request: StartRequest) async throws -> String
  func send(to id: String, text: String) async throws -> SendOutcome
  func interrupt(_ id: String) async throws
  func end(_ id: String) async throws
  func answer(_ id: String, requestID: String, with decision: PermissionDecision) async throws
  func answer(_ id: String, requestID: String, with answer: ElicitationAnswer) async throws
}

public enum JSONBridge {
  public static func mcp(_ value: DrakarKit.JSONValue) -> MCPKit.JSONValue
  public static func drakar(_ value: MCPKit.JSONValue) -> DrakarKit.JSONValue
}
```

Give every struct a memberwise `public init` (Swift does not synthesize public ones).
`FakeSessionSource` is a `final class … @unchecked Sendable` with a lock, settable stored
answers for every read, a `refusal: String?`, `allowsPermissions: Bool`, and a `calls: [String]`
log of the writes it received with their arguments (e.g. `"send 1a2b… hello"`).

- [ ] **Step 1: Write the package manifest.** Products: library `DrakarMCP`. Dependencies: the kit (Global Constraints) and `.package(path: "../DrakarKit")`. Target `DrakarMCP` depends on `.product(name: "MCPKit", package: "swift-mcp-kit")` and `DrakarKit`; test target `DrakarMCPTests` depends on `DrakarMCP`. Head comment in Cadence's manner: why a package apart (DrakarKit's zero dependencies), why remote.
- [ ] **Step 2: Write the failing tests** in `JSONBridgeTests.swift`:

```swift
@Test("A nested value crosses both ways unchanged")
func roundTrip() {
  let value: DrakarKit.JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": "d"]]
  #expect(JSONBridge.drakar(JSONBridge.mcp(value)) == value)
}
@Test("Integers stay integers") func ints() {
  #expect(JSONBridge.mcp(DrakarKit.JSONValue.int(3)) == MCPKit.JSONValue.int(3))
}
```

(Check DrakarKit's `JSONValue` cases first, `Packages/DrakarKit/Sources/DrakarKit/JSONValue.swift`, and map case by case; if DrakarKit has no separate int case, map its number to `.int` when it is integral and adjust `ints()` to that.)
- [ ] **Step 3: Run** `swift test --package-path apps/apple/Packages/DrakarMCP` — expected: compile failure (no `JSONBridge`).
- [ ] **Step 4: Implement** `SessionSource.swift` and `JSONBridge.swift` as above, and the fake.
- [ ] **Step 5: Run** the same command — expected: PASS.
- [ ] **Step 6: Wire the suite into `make test`.** In `apps/apple/Makefile` add `MCP := Packages/DrakarMCP` beside `KIT`, and make `test` run `swift test --package-path $(KIT)` then `swift test --package-path $(MCP)`; update its help text ("DrakarKit and DrakarMCP tests (offline, no Xcode)") and the comment above it (DrakarMCP resolves the kit from GitHub, the one network fetch of the offline suite; once resolved it runs offline). Run `make -C apps/apple test` — expected: both suites pass.
- [ ] **Step 7: Commit** `feat(mcp): DrakarMCP package and the session source it reads through`.

### Task 2: The read tools: list, get, attention, projects

**Files:**
- Create: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/Tools.swift` (table, instructions, `writeTools`, shared schema)
- Create: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/Encoding.swift` (rows, pending items, attention → `MCPKit.JSONValue`)
- Create: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/Arguments.swift` (argument reading, `SessionIDs.resolve`)
- Test: `apps/apple/Packages/DrakarMCP/Tests/DrakarMCPTests/ReadToolsTests.swift`

**Interfaces:**
- Consumes: Task 1's types.
- Produces:

```swift
public enum Tools {
  public static let instructions: String
  public static let writeTools: [String]   // every tool with gate .requiresWrites, in table order
  public static func table(source: some SessionSource, pollInterval: Duration = .seconds(1),
                           clock: any Clock<Duration> = ContinuousClock()) -> ToolTable
}
enum SessionIDs {
  /// Exact id, or a unique prefix of ≥ 8 characters among `known`.
  static func resolve(_ given: String, among known: [String]) throws -> String   // throws SessionError
}
enum Encoding {
  static func row(_ row: SessionRow) -> MCPKit.JSONValue
  static func pending(_ item: PendingItem) -> MCPKit.JSONValue
  static func attention(_ item: AttentionItem) -> MCPKit.JSONValue
  /// Every string value longer than `limit` UTF-8 bytes cut there; returns whether any was.
  static func truncating(_ value: MCPKit.JSONValue, limit: Int) -> (MCPKit.JSONValue, truncated: Bool)
}
```

Tools in this task: `drakar_list_sessions`, `drakar_get_session`, `drakar_needs_attention`,
`drakar_list_projects`, all `annotations: .readOnly`, gate `.always`. Schemas and fields per
spec §3 Reads. Specifics the tests pin:

- `list_sessions` arguments: `folder`, `runner` (`"this-mac"` matches `runner == nil`, any other string matches the runner's name case-insensitively), `state`, `include_ended` (default false), `limit` (default 20, clamped to 1…100; applies to ended sessions only). Result `{sessions: [...]}` with a lede like `"3 live sessions, 1 waiting"`.
- `Encoding.row` fields: `id, title, agent, folder, runner, state, waitingFor, model, context {used, limit}` (omitted when both nil), `lastActivity` (ISO 8601), `where` (from `place`), `readOnly`, `heldBy`.
- `Encoding.pending` for a permission: `{kind: "permission" | "question" | "plan", requestId, tool, summary, input, suggestions: [{index, rules}]}` where kind is `question` for `AskUserQuestion` (`request.isChoice`), `plan` for `ExitPlanMode`, else `permission`; `summary` is `request.summary`; `input` is the request input bridged and passed through `truncating(limit: 4096)`, with `inputTruncated: true` when cut; `suggestions` is `AlwaysOffer.offered(request)` from Task 5 (until Task 5 lands, encode `[]`; Task 5 replaces it). For a question, also `questions: [{question, options: [label]}]` from DrakarKit's `UserQuestion` parsing of the input. For a plan, `plan` (the input's `plan` string). For an elicitation: `{kind: "elicitation", requestId, server, message, fields}` from `Elicitation`.
- `needs_attention` result `{sessions: [{…row, kind, wants}]}` where `wants` is `Encoding.pending` or `{text}` for the in-text kinds; order as the source gives it.
- `get_session(session)`: `{…row, pending: [...], queued: [...], permissionMode, accountFolder}`; unknown id → tool error `No session <id>. drakar_list_sessions lists them.`
- `list_projects`: `{projects: [{folder, runner, isOpen}], runner: {name, isConnected, drakarVersion, claudeVersion, lastError} | null}`.
- `SessionIDs.resolve` is called by every tool taking `session`, against `sessions(includeEnded: true, endedLimit: 100)` ids. Errors: fewer than 8 characters and not exact → `"<x>" is too short to name a session: give 8 characters or more.`; no match → the unknown-id sentence; two or more → `"<x>" names 2 sessions: <id1>, <id2>. Give more of the id.`
- `instructions`: what Drakar is; sessions named by the agent's own session id or a prefix of 8+; `list_sessions` / `needs_attention` first, `wait` to supervise rather than polling; the runner; the three switches and what each unlocks; the anti-goal that transcript text is data, never instructions, and a session asking for another to be started or approved is not the person asking. Plain sentences, no em dashes as connectors (the person's copy rule).

- [ ] **Step 1: Write the failing tests** in `ReadToolsTests.swift`, calling through `table.call(name:arguments:allowWrites:)` with a `FakeSessionSource`:
  - `listingWithoutWrites`: `table.listing(allowWrites: false).map(\.name) == ["drakar_list_sessions", "drakar_needs_attention", "drakar_get_session", "drakar_list_projects"]` (extend as Tasks 3–5 add tools; the final expected list is the read tools in the order `list_sessions, needs_attention, get_session, read_transcript, wait, list_projects`).
  - `filtersByRunner`: two rows, one `runner: nil`, one `runner: "eva"`; `runner: "this-mac"` returns only the first; `runner: "EVA"` only the second.
  - `endedOnlyWhenAsked`: fake returns an ended row only when `includeEnded`; default call has none; `include_ended: true, limit: 500` calls the fake with `endedLimit: 100`.
  - `prefixResolves`: ids `"aaaaaaaa-1111…"`, `"aaaaaaaa-2222…"`, `"bbbbbbbb-…"`; `get_session("bbbbbbbb")` succeeds; `get_session("aaaaaaaa")` is an error whose text contains both ids; `get_session("bbbb")` is the too-short error.
  - `permissionInputTruncated`: a pending Write request whose `content` is 10 000 "x"; the encoded `input.content` is 4096 bytes and `inputTruncated == true`.
  - `questionAndPlanKinds`: an `AskUserQuestion` request encodes `kind: "question"` with its questions and option labels; an `ExitPlanMode` one encodes `kind: "plan"` with its `plan` text.
  - `attentionOrderKept`: the fake's order comes back unchanged, in-text items carry `wants.text`.
- [ ] **Step 2: Run** `swift test --package-path apps/apple/Packages/DrakarMCP --filter ReadToolsTests` — expected: FAIL (no `Tools`).
- [ ] **Step 3: Implement** `Tools.table` with these four, `Encoding`, `Arguments`/`SessionIDs`.
- [ ] **Step 4: Run** the same — expected: PASS.
- [ ] **Step 5: Commit** `feat(mcp): read tools — sessions, attention, projects`.

### Task 3: Transcript reading and waiting

**Files:**
- Modify: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/Tools.swift`
- Create: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/TranscriptEncoding.swift`
- Create: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/Waiting.swift`
- Test: `apps/apple/Packages/DrakarMCP/Tests/DrakarMCPTests/TranscriptToolTests.swift`, `WaitToolTests.swift`

**Interfaces:**
- Produces:

```swift
enum TranscriptEncoding {
  /// Entries after `after` (an entry index; nil = the last `last` entries), and the cursor
  /// to pass next time (the index one past the last entry of the transcript).
  static func page(_ transcript: Transcript, after: Int?, last: Int) -> (entries: [MCPKit.JSONValue], cursor: Int)
}
enum WaitUntil: String { case attention, turnEnd = "turn_end", change }
enum Waiting {
  /// What moved between two snapshots, for `until`, restricted to `watched` (nil = all).
  static func moved(from old: [SessionRow], attention oldAttention: Set<String>,
                    to new: [SessionRow], attention newAttention: Set<String>,
                    until: WaitUntil, watched: Set<String>?) -> [SessionRow]
}
```

- `drakar_read_transcript(session, after?, last?)`: `last` default 20, clamped 1…200. Entry encoding by `Transcript.Entry.kind`: `.prompt` → `role: "user"`; `.text` → `"assistant"`; `.tool` → `role: "tool", name, summary (ToolCall.summary), status ("running" | "done" | "error" from result nil / isError), result (content cut at 2048 bytes, resultTruncated)`; `.notice`, `.failure` → `"system"`; `.thinking` skipped. Each entry carries `index` (its position in `transcript.entries`). Result `{entries, cursor}`.
- `drakar_wait(sessions?, until?, timeout_seconds?)`: `until` default `attention`; timeout default 30, clamped 1…120. Polls the source every `pollInterval` on `clock`: snapshot `sessions(includeEnded: false, endedLimit: 0)` and the attention ids, compare with `Waiting.moved`. Rules: `attention` = a session id in the new attention set not in the old; `turnEnd` = a session `working` before and anything else now; `change` = any state change, a session appearing or disappearing. Returns `{moved: [rows], timedOut: false}` or `{moved: [], timedOut: true}`. Read-only, gate `.always`.

- [ ] **Step 1: Write the failing tests.**
  - `pagesWithCursor`: a `Transcript` built from DrakarKit fixture lines (`Packages/DrakarKit/Tests/DrakarKitTests/Fixtures`, pick a short session) via `History.history(lines:)`; `last: 2` returns the final two non-thinking entries and `cursor == transcript.entries.count`; a second call with `after: cursor` returns `[]`.
  - `toolResultTruncated`: a tool entry with a 5000-byte result encodes 2048 bytes and `resultTruncated: true`.
  - `thinkingSkipped`: a transcript with a `.thinking` entry never encodes one.
  - `waitAttention`: fake starts with no attention; after one poll the fake's attention gains session A; `wait` returns `moved` = [A]. Use a `pollInterval: .milliseconds(10)`.
  - `waitTurnEnd`: A `working` then `idle` → returned with `until: "turn_end"`; with `until: "attention"` and no attention change it times out.
  - `waitTimesOut`: nothing changes, `timeout_seconds: 1` with a test clock (or real 1 s if a test clock is awkward) returns `timedOut: true`.
  - `waitWatchesOnlyNamed`: B changes, `sessions: [A]` → times out.
- [ ] **Step 2: Run** `swift test --package-path apps/apple/Packages/DrakarMCP --filter "TranscriptToolTests|WaitToolTests"` — expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — expected: PASS.
- [ ] **Step 5: Commit** `feat(mcp): read a session's transcript, and wait for one to move`.

### Task 4: The write tools: start, send, interrupt, end, answer a question

**Files:**
- Modify: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/Tools.swift`
- Test: `apps/apple/Packages/DrakarMCP/Tests/DrakarMCPTests/WriteToolsTests.swift`

**Interfaces:**
- Consumes: `SessionSource` writes; `UserQuestion.answering(_:with:)` (DrakarKit, `UserQuestion.swift:78`).
- Produces: tools `drakar_start_session`, `drakar_send_message`, `drakar_interrupt`, `drakar_end_session`, `drakar_answer_question`, gate `.requiresWrites`. Annotations: start/send `readOnlyHint: false, destructiveHint: false`; interrupt/end `destructiveHint: true`; answer_question `destructiveHint: false`.

Behaviour the tests pin:
- `start_session(folder, runner?, prompt, agent?, model?)`: `folder` must be absolute (`/` or `~/`), else error. `runner` given with `agent: "codex"` → `A runner's sessions are Claude Code's: leave agent out or pass "claude".` `workRefusal()` non-nil → that sentence as a tool error, `start` never called. Success → `{session: <row from detail(of:)> }` lede `Started <id> in <folder>`.
- `send_message(session, text)`: empty text → error; `workRefusal()` → refused; result `{outcome: "sent" | "queued"}`.
- `interrupt`, `end_session(session)`: pass through; result `{ok: true}`.
- `answer_question(session, request_id, answers? | action?, content?)`: the tool reads `detail(of:)` and finds the pending item by `request_id`; missing → `Request <id> is no longer waiting: already answered, or the turn ended.` If it is a permission whose request `isChoice` (AskUserQuestion): `answers` (object of question → string) required; calls `answer(id, requestID:, with: .allow(updatedInput: UserQuestion.answering(request.input, with: answers)))`. If it is an elicitation: `action` ∈ accept/decline/cancel; `.accept(content bridged to [String: DrakarKit.JSONValue] or nil)`. If it is any other permission → `Request <id> is a permission prompt: use drakar_answer_permission.`
- `Tools.writeTools` equals every `.requiresWrites` tool name in table order (test it).

- [ ] **Step 1: Write the failing tests:** `writesHiddenWithoutGate` (listing without writes has none of these; with writes has all), `writeToolsMatchesGates`, `startRefusedByLicence` (fake `refusal = "Your trial has ended."` → error text equals it, `calls` empty), `codexOnRunnerRefused`, `relativeFolderRefused`, `sendQueued` (fake returns `.queued` → `outcome == "queued"`), `answerQuestionBuildsInput` (fake pending AskUserQuestion with one question "Which?" options A/B; `answers: {"Which?": "B"}` → fake receives `.allow(updatedInput: UserQuestion.answering(input, with: ["Which?": "B"]))`), `answerQuestionAlreadyAnswered`, `answerQuestionOnPermissionRefused`, `elicitationDecline` (→ `.decline`).
- [ ] **Step 2: Run** `swift test --package-path apps/apple/Packages/DrakarMCP --filter WriteToolsTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS. Also run the whole package suite.
- [ ] **Step 5: Commit** `feat(mcp): start sessions, send them work, answer their questions`.

### Task 5: Answering permission prompts

**Files:**
- Create: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/PermissionAnswer.swift`
- Modify: `apps/apple/Packages/DrakarMCP/Sources/DrakarMCP/Tools.swift`, `Encoding.swift` (suggestions)
- Test: `apps/apple/Packages/DrakarMCP/Tests/DrakarMCPTests/PermissionToolTests.swift`

**Interfaces:**
- Consumes: DrakarKit `PermissionSuggestion` (`Presentation.swift`, `init?(_ raw:id:)`, `.kind`, `.destination`, `.raw`), `PlanApproval.approve(_:editsManually:)`, `PlanApproval.keepPlanning(feedback:)`, `PermissionDecision`.
- Produces:

```swift
public enum AlwaysOffer {
  /// The request's suggestions an agent may apply: `.addRules` with destination "session",
  /// and `.codexDecision` (Codex's session-long yes). Index = the suggestion's own `id`.
  public static func offered(_ request: PermissionRequest) -> [PermissionSuggestion]
}
public enum PermissionAnswer {
  public enum Verdict: String { case allow, deny }
  /// The decision the window would send for this choice. Throws SessionError for an
  /// AskUserQuestion request, or an `always` index not in `AlwaysOffer.offered`.
  public static func decision(for request: PermissionRequest, verdict: Verdict,
                              message: String?, interrupt: Bool, always: [Int]) throws -> PermissionDecision
}
```

Rules (spec §3 Permissions):
- `ExitPlanMode`: allow → `PlanApproval.approve(request.input, editsManually: true)`; deny → `PlanApproval.keepPlanning(feedback: message ?? "")`; `always` must be empty.
- Other tools: allow → `.allow(updatedInput: request.input, updatedPermissions: chosen.map(\.raw))`, where `chosen` are the `AlwaysOffer.offered` suggestions whose `id`s are in `always`; deny → `.deny(message: message ?? "Denied by an agent through Drakar's MCP server.", interrupt: interrupt)`.
- **Codex:** before writing the `.codexDecision` branch, read `Drakar/Views/PermissionSheet.swift` around line 127 and build exactly the decision it builds for that suggestion; the test asserts equality with a decision constructed the same way.
- Tool `drakar_answer_permission(session, request_id, decision, message?, interrupt?, always?)`, gate `.requiresWrites`, `destructiveHint: false`. Order of checks: `permissionsAllowed()` false → `Answering permission prompts is off. The person can turn on "Let agents answer permission prompts" in Drakar's Settings › MCP Server.`; then the pending lookup (already-answered sentence from Task 4); then `PermissionAnswer.decision`; then `source.answer`.
- `Encoding.pending`'s `suggestions` now `AlwaysOffer.offered(request).map { ["index": $0.id, "rules": …] }` with the rule strings from `.addRules`, or `["decision": …]` for Codex.

- [ ] **Step 1: Write the failing tests:** `refusedWhenSwitchOff` (fake `allowsPermissions = false` → that sentence, no `answer` call), `listedWithWritesEvenWhenSwitchOff`, `allowPassesInputThrough`, `denyCarriesMessageAndInterrupt`, `onlySessionRulesOffered` (request with three suggestions: addRules/session, addRules/localSettings, setMode/acceptEdits → `offered` has only the first; `always: [<localSettings id>]` throws), `planApprovedManually` (decision == `PlanApproval.approve(input, editsManually: true)`), `planDeniedKeepsPlanning` (== `PlanApproval.keepPlanning(feedback: "tighter")`), `questionRedirected` (AskUserQuestion → error naming `drakar_answer_question`), `alreadyAnswered`, `codexDecisionMatchesSheet`.
- [ ] **Step 2: Run** `swift test --package-path apps/apple/Packages/DrakarMCP --filter PermissionToolTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole package suite — PASS. Update Task 2's listing test to the final read list and Task 4's `writeTools` test now includes `drakar_answer_permission`.
- [ ] **Step 5: Commit** `feat(mcp): answer permission prompts, behind a switch of their own`.

### Task 6: The app's server controller, preferences and Xcode wiring

**Files:**
- Modify: `apps/apple/Drakar.xcodeproj/project.pbxproj` (local package `Packages/DrakarMCP`; remote `swift-mcp-kit` 1.6.1 upToNextMinor; app target product deps `DrakarMCP`, `MCPKit`, `MCPKitLoopback`, `MCPKitUI`, `MCPKitWiring`; test target `DrakarMCP`, `MCPKit` if tests import them)
- Create: `apps/apple/Drakar/MCP/MCPServerController.swift` (controller, `MCPSettingsKey`, `MCPSetup`, `WritesFlag`)
- Modify: `apps/apple/Drakar/DrakarApp.swift` (drive `sync`)
- Test: `apps/apple/DrakarTests/MCPServerControllerTests.swift`

**Interfaces:**
- Consumes: `Tools.table(source:)`, `Tools.instructions`, `Tools.writeTools`; Task 7's `SessionMCPSource()` (until it lands, construct the server with a placeholder that returns empty reads and throws `SessionError("Not ready")` on writes, deleted in Task 7).
- Produces:

```swift
enum MCPSettingsKey { static let enabled, port, allowsWrites, allowsPermissions: String }  // values per Global Constraints
@MainActor @Observable final class MCPServerController {
  static let shared: MCPServerController
  nonisolated static let defaultPort: Int        // 8812 Debug / 8811 Release
  nonisolated static let keychainService: String // per Global Constraints
  nonisolated static let ports: ClosedRange<Int> // 1024...65_535
  private(set) var state: LoopbackListener.State
  private(set) var tokenError: String?
  private(set) var activity: MCPActivity
  var token: String
  func regenerateToken()
  nonisolated static func shouldRun(isEnabled: Bool, port: Int, isHosted: Bool) -> Bool
  nonisolated static func needsStart(state: LoopbackListener.State, boundPort: Int?, port: Int) -> Bool
  nonisolated static func draft(_ typed: Int?, stored: Int) -> PortDraft   // Cadence's enum
  struct Configuration: Hashable { var isEnabled: Bool; var allowsWrites: Bool; var port: Int }
  func sync(_ configuration: Configuration)
  static func server(source: some SessionSource) -> MCPServer
}
enum MCPSetup { static var serverName: String; static func bastionLink(port: Int, token: String) -> BastionLink }
```

Copy Cadence's `MCPServerController` (`~/Projects/apps/cadence/apps/apple/Cadence/MCP/MCPServerController.swift`) and change: no Pro / coordinator; `isHosted` is `ProcessInfo` running tests (find Drakar's own check: grep `isRunningTests` or `XCTestConfigurationFilePath` in `Drakar/`); `allowPermissions` is **not** in `Configuration` (the source reads the default at each call). The pbxproj: add entries by hand in the existing sections' style (the `DrakarKit` local reference at line ~672 and `swift-support-kit` remote at ~679 are the models), new 24-hex ids not colliding with existing ones; the `Drakar/MCP` folder needs no pbxproj entry (synchronized root group). `DrakarApp` drives `sync` from the scene with `.onChange(of: configuration, initial: true)` over `@AppStorage` values, as `CadenceApp.swift:~128` does.

- [ ] **Step 1: Write the failing tests** (`MCPServerControllerTests`): `shouldRun` is false when disabled, false for port 80, false when hosted, true for (enabled, 8811, not hosted); `needsStart` true for `.stopped`, true for `.running` on another port, false for `.running` on the same; `draft(nil, …) == .revert`, `draft(8811, stored: 8811) == .keep`, `draft(9000, stored: 8811) == .write(9000)`; `defaultPort == 8812` and `keychainService == "io.mgcrea.Drakar.mcp-dev"` and `MCPSetup.serverName == "drakar-dev"` under `#if DEBUG` (else the Release values); `Tools.writeTools` ⊆ the server's table tool names.
- [ ] **Step 2: Run** `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build/xcode -only-testing:DrakarTests/MCPServerControllerTests` (check `apps/apple/Makefile`'s `DERIVED_DATA` and use the same path) — expected: FAIL (build error).
- [ ] **Step 3: Implement** the pbxproj wiring, the controller, the `DrakarApp` sync.
- [ ] **Step 4: Run** the same — expected: PASS. Then `make -C apps/apple build` — expected: BUILD SUCCEEDED.
- [ ] **Step 5: Commit** `feat(mcp): the app runs the server when Settings says so`.

### Task 7: The app's session source: reads

**Files:**
- Create: `apps/apple/Drakar/MCP/SessionMCPSource.swift` (the `SessionSource` conformance; reads here, writes in Task 8)
- Create: `apps/apple/Drakar/MCP/SessionMCPSource+Rows.swift` (building `SessionRow`, `AttentionItem` from `ProjectSession`, held processes and summaries)
- Modify: `apps/apple/Drakar/MCP/MCPServerController.swift` (use it; delete Task 6's placeholder)
- Test: `apps/apple/DrakarTests/SessionMCPSourceTests.swift`

**Interfaces:**
- Consumes: `OpenSessions.shared.projects`, `Project.sessions`, `ProjectSession.{sessionID, urgency, waitingFor, knownTitle, preview}`, `AgentSession.{status, transcript, phase, isReadOnly, heldElsewhere, isReconnecting, isOutOfReach, isGoneOnRunner, runnerName, agent, runningModel, reportedContext, effectiveAccount, permissionMode, queued prompts}`, `SessionMonitor.shared.{all, liveSessions, liveIDs}`, `SessionHost.shared` / `SessionHost.runner` `.listed()`, `SessionMeta` decoding as `BackgroundSessions.count` does, `ProjectList.shared.tracked`, `RunnerSettings.current`, `EntitlementMonitor.allowsWorkNow`, `History.history(contentsOf:)`.
- Produces: `final class SessionMCPSource: SessionSource` (`@unchecked Sendable`; every method hops with `await MainActor.run { … }`), `init(defaults: UserDefaults = .standard, openSessions: OpenSessions = .shared, monitor: SessionMonitor = .shared)` so tests inject.

Mapping (spec §3):
- **Window rows:** every `ProjectSession` with a `sessionID` in every open project. `state`: `reconnecting` if `isReconnecting`; `unreachable` if `isOutOfReach || isGoneOnRunner`; `waiting` if `status.isWaitingOnPerson`; `working` if `status.isRunning`; else `idle`. `waitingFor`: `ProjectSession.waitingFor`, else `urgency`'s text for `.question`/`.offer`. `readOnly`: `isReadOnly || heldElsewhere != nil`, `heldBy: heldElsewhere`. `runner`: `runnerName`.
- **Background:** processes from `SessionHost.shared.listed()` (and the runner host's) that are `running`, `attachedApp == nil`, whose `SessionMeta` decodes with a `sessionID` not already a window row; `place: .background`, state `working` if the registry says busy, `waiting` if waiting, else `idle`.
- **Elsewhere:** `SessionMonitor.shared.all` summaries with `live != nil` whose id is neither of the above; `place: .elsewhere`, `readOnly: true`, `heldBy` = `SessionMonitor.shared.host(of:)`, state from `live.status` (`busy` → working, `waiting` → waiting, else idle).
- **Ended** (only when asked): newest `SessionMonitor.shared.all` summaries not live, up to `endedLimit`, `state: .ended`.
- **attention():** window rows with a pending permission/elicitation (one item per pending, kind by request: `isChoice` → question, `ExitPlanMode` → plan, else permission; elicitation → elicitation), window rows whose `urgency` is `.question`/`.offer` (in-text kinds, `text` = the closing ask), and elsewhere sessions whose `Urgency.of(summary, recognisesAsks: true, dismissed: nil)` is non-nil (no `pending`; kind from the urgency). Sorted by `Urgency` descending.
- **transcript(of:):** a window row's `session.displayedTranscript`; else the summary's file through `History.history(contentsOf:)` (Codex: use whatever Home's preview uses for a Codex file; find it from `SessionMonitor`/`ProjectSessions`). A runner session with no window and no local file → `SessionError("Open <title> in Drakar first: its transcript is on <runner>.")`.
- **workRefusal():** nil when `EntitlementMonitor.allowsWorkNow`, else the composer's locked sentence (find it in `LockedComposerCard.swift`).
- **permissionsAllowed():** `defaults.bool(forKey: MCPSettingsKey.allowsPermissions)`.

- [ ] **Step 1: Write the failing tests** using the fixtures the existing session tests use (read `DrakarTests/PlanApprovalSessionTests.swift` and `HostedSessionTests.swift` for how they build a `Project` with `executableOverride` and a replay transport, and reuse their helpers): `windowRowListed` (a project registered in a test `OpenSessions` with one session that has an id → one row, `place == .window`, `state == .idle`); `pendingPermissionIsWaiting` (feed a `can_use_tool` control request through the replay → `state == .waiting`, `attention()` has one `.permission` item with its request id); `askUserQuestionIsQuestionKind`; `planIsPlanKind`; `transcriptOfWindowRow` (entries equal `displayedTranscript.entries`); `permissionsSwitchReadPerCall` (flip the defaults key between two calls).
- [ ] **Step 2: Run** `… -only-testing:DrakarTests/SessionMCPSourceTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS. Run the known flakes (memory: CapabilityProbe, AgentSession opened-elsewhere, SessionMoves) alone before calling anything a regression.
- [ ] **Step 5: Commit** `feat(mcp): the app answers the read tools from its windows, its host and its monitor`.

### Task 8: The app's session source: writes, and windows that never take the keyboard

**Files:**
- Create: `apps/apple/Drakar/MCP/MCPWindows.swift`
- Modify: `apps/apple/Drakar/MCP/SessionMCPSource.swift` (writes)
- Modify: `apps/apple/Drakar/ContentView.swift` (only if `MCPWindows` needs a hook in `WindowTabs.adopt` to learn the window it opened)
- Test: `apps/apple/DrakarTests/SessionMCPWritesTests.swift`, `apps/apple/DrakarTests/MCPWindowsTests.swift`

**Interfaces:**
- Produces:

```swift
@MainActor enum MCPWindows {
  /// The open project for `route`, opening its window behind the others if none is, with the
  /// key window and the app's activation left as they were. Nil, with the reason, when it
  /// cannot (no `WindowTabs.openWindow` yet; the window did not register within 10 s).
  static func project(for route: WindowRoute) async -> Result<Project, SessionError>
}
```

Opening: remember `NSApp.keyWindow` and `NSApp.isActive`; call `WindowTabs.openWindow?(value: route)` (not `WindowTabs.open`); wait (poll every 50 ms, up to 10 s) for `OpenSessions.shared.project(for: route)`; then `orderBack` its window and give the key back to the remembered window if the app was active (`makeKey()` only on the remembered one, never `makeKeyAndOrderFront` on the new one); if the app was not active, never call `NSApp.activate`. `WindowTabs.openWindow == nil` → `SessionError("Open a Drakar window once, then try again.")`.

Writes (spec §3 Writes), each `await MainActor.run`:
- `start`: runner given → `RunnerSettings.current` must exist with a matching `displayName` (case-insensitive) and `SessionHost.runner?.reaches(runner: id) == true`, else `SessionError("No runner named <x> is set up.")` / `("<name> can't be reached: <last error>.")`. This Mac: the folder must exist as a directory. `workRefusal` re-checked. Route = `WindowRoute.project(URL(filePath: folder), runner: runnerID)`; project from `MCPWindows.project(for:)`; the row = the project's blank row if it was just opened and has one (`isBlank` is private in `Project`; add an `internal func blankRow() -> ProjectSession?` beside it), else `project.newSession(agent:select: false)`; apply `model` via `session.setModel` if given; `session.send(prompt)`; wait (poll 100 ms, up to 30 s) for `sessionID`; timeout → `SessionError("Started in <folder>, but it has no session id yet. drakar_list_sessions will show it once it does.")`.
- `send`: locate (`OpenSessions.shared.locate(id)`); in a window: `canSend` → `send`, `.sent`; `canQueue` → `send` (it queues), `.queued`; else `SessionError` naming why (read-only, held by `heldElsewhere`, licence). Background: open its project (route from the meta's window folder and runner) through `MCPWindows`, then `project.reopen(hostID, among: await host.listed())` as `RunnerSection.open` does, then send. Ended: open the project, `project.openEnded(summary, focusingComposer: false)`, then send. Elsewhere: `SessionError("<title> runs in <host>; Drakar only follows it.")`.
- `interrupt`: `session.interrupt()` (keeps the queue). `end`: `project.end(item)`. Both refuse elsewhere/held rows.
- `answer(_:requestID:with: PermissionDecision)`: find the pending permission by id in `session.status.pendingPermissions`; absent → the already-answered `SessionError`; else `session.answer(pending, decision)`. Elicitation likewise with `pendingElicitations` and `session.answer(_:_: ElicitationAnswer)`.

- [ ] **Step 1: Write the failing tests:**
  - `MCPWindowsTests.keyWindowUnchanged`: with a test window key, open a project route through `MCPWindows.project(for:)` → returns the project, `NSApp.keyWindow` is still the test window. (If the hosted test runner cannot open SwiftUI windows, test the ordering step on a plain `NSWindow` via an internal `MCPWindows.settle(new:previousKey:wasActive:)` and say so in the commit.)
  - `noOpenWindowActionRefused`: `WindowTabs.openWindow = nil` → the "Open a Drakar window once" error.
  - `startInOpenProjectDoesNotSwitchTab`: project open with tab A selected → after `start`, `selectedID` is still A and a new row exists with the prompt sent.
  - `startUnreachableRunnerLeavesNoRow`: runner settings set, host not reaching → error, no row added anywhere.
  - `sendQueuesMidTurn`: a session `isRunning` → `.queued`, its queue has the text.
  - `answerAlreadyAnswered`: answer once (ok), the same id again → already-answered error, the session received exactly one answer.
  - `answerPermissionReachesSession`: the replay transport's captured outbound line is the `control_response` with `behavior: "allow"`.
  - `endKeepsRow`: after `end`, the row is still in `project.sessions`, `isProcessRunning == false`.
- [ ] **Step 2: Run** `… -only-testing:DrakarTests/SessionMCPWritesTests -only-testing:DrakarTests/MCPWindowsTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS. Then `make -C apps/apple test-app` — expected: the suite green but for the known flakes, each rerun alone and passing.
- [ ] **Step 5: Commit** `feat(mcp): agents start, steer and answer sessions, never taking the keyboard`.

### Task 9: Settings › MCP Server

**Files:**
- Create: `apps/apple/Drakar/MCP/MCPSettingsPane.swift`
- Modify: `apps/apple/Drakar/Views/SettingsView.swift` (new `SettingsPane` case `.mcp`, title "MCP Server", symbol `"point.3.connected.trianglepath.dotted"`, last in the `.configuration` group)
- Test: extend `apps/apple/DrakarTests/MCPServerControllerTests.swift`

**Interfaces:**
- Consumes: `MCPServerController.shared`, `MCPSettingsKey`, `MCPSetup.bastionLink`, MCPKitUI (`MCPStatusLabel`, `MCPStatus`, `BastionRow`, the wiring list and snippet views Cadence's pane uses).

Port Cadence's `MCPSettingsPane` (`~/Projects/apps/cadence/apps/apple/Cadence/MCP/MCPSettingsPane.swift`), dropping Pro, import folders and recording, and with Drakar's copy:
- Server toggle "Run the MCP server", sub-text: "Lets an AI agent on this Mac, such as Claude Code or Codex, see your Drakar sessions, here and on your runner, and read their transcripts. It listens on 127.0.0.1 only: nothing is reachable from another machine."
- Footer: "The server runs while Drakar is open."
- "Allow writes", sub-text: "Off, an agent can only read. On, it can also start sessions, send them messages, interrupt and end them, and answer their questions."
- "Let agents answer permission prompts" (disabled unless Allow writes), sub-text: "Lets an agent allow or deny the tool calls your sessions ask permission for. A rule it allows lasts only for that session; it never edits your permission settings or changes a session's mode."
- Port field (`MCPServerController.draft`), token (reveal, Copy, Regenerate), client wiring, `BastionRow { MCPSetup.bastionLink(port:token:) }`, and a caption "From another Mac: `ssh -L 8811:127.0.0.1:8811 <this Mac>`, then use http://127.0.0.1:8811/mcp there." with the current port substituted.

- [ ] **Step 1: Write the failing test** `settingsPaneListed`: `SettingsPane.allCases` contains `.mcp`, in the `.configuration` group, after `.runner`.
- [ ] **Step 2: Run** it — FAIL.
- [ ] **Step 3: Implement** the pane and the case.
- [ ] **Step 4: Run** — PASS; `make -C apps/apple build` succeeds. No screenshot by relaunching Drakar: the look is in the person's live check.
- [ ] **Step 5: Commit** `feat(mcp): Settings › MCP Server`.

### Task 10: The network audit, the docs, the changelog

**Files:**
- Modify: `scripts/audit-network.sh`
- Create: `docs/mcp.md`
- Modify: `docs/runner.md` (one paragraph pointing at `docs/mcp.md` for driving runner sessions from an agent)
- Modify: `CHANGELOG.md` (Unreleased: Added)

Audit rules to add (Sources section, same `pass`/`fail` style, comments stripped by `code()`):
1. `NWListener(` count still exactly 1 (unchanged; proves the MCP listener added none).
2. No `bind(`, `listen(` or `socket(` call in Drakar's own `$SOURCES` (the kit's are outside them).
3. `LoopbackListener(` appears exactly once, in `apps/apple/Drakar/MCP/MCPServerController.swift`.
4. `MCPSettingsKey.enabled` read with a `false` default everywhere it is an `@AppStorage` (grep `@AppStorage(MCPSettingsKey.enabled) private var [a-zA-Z]* = false`) and nowhere `= true`.
5. `KeychainTokenStore(service:` appears and only in the controller.
`--running`: when `lsof` shows a listener beyond the IDE bridge's port, it must be on `defaults read io.mgcrea.Drakar drakar.mcp.port` (or the Release/Debug default when unset), else FAIL. `--app`: run it on a fresh `make -C apps/apple build-release XCARGS="CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"` bundle; if the sweep flags a kit symbol, add a named allowance in the existing style and say why in a comment. Update the script's header claim to the two-listener wording drafted in Task 11, marked as pending that task's review if Task 11's wording changes.

`docs/mcp.md` contents: spec §6.

- [ ] **Step 1: Run** `make audit` on the branch before editing — record which checks pass.
- [ ] **Step 2: Add the rules**; temporarily break rule 3 (duplicate the call in a scratch line) and confirm `make audit` FAILs, then revert.
- [ ] **Step 3: Run** `make audit` — expected: all ok. Run `scripts/audit-network.sh --app <bundle>` on the unsigned Release bundle — expected: all ok.
- [ ] **Step 4: Write** `docs/mcp.md`, the `runner.md` paragraph, the CHANGELOG entry (person's style: plain sentences, no em-dash connectors). Run `make changelog-check`; if it fails because Unreleased feeds generated files, run `make changelog` and include the regenerated files.
- [ ] **Step 5: Commit** `feat(mcp): the network audit knows the second listener; docs`.

### Task 11: The public wording (for the person's review)

**Files:**
- Modify: `README.md` (~line 18, ~49), `SECURITY.md` (~18, ~81, ~98), `apps/website/src/pages/privacy.astro` (~86), `apps/website/public/llms.txt` (~52), `apps/website/src/components/Trust.astro` (heading ~48 and the socket list ~19/~96), `apps/apple/EULA` (§8 ~169)

Each "one network socket" / "two sockets" statement becomes true with the server on, in the person's register (look at the surrounding sentences; no em-dash connectors). The base sentence: "…and, only if you turn on its MCP server, a second one on 127.0.0.1, which answers only a client holding the token in your Keychain." The EULA's "It listens on two sockets" becomes "two sockets, or three with its MCP server on". `Trust.astro` gains a third item for the MCP server in the same shape as the IDE bridge's.

- [ ] **Step 1: Edit** every place listed; `grep -rn "one network socket\|two sockets\|One loopback port" README.md SECURITY.md apps/website/src apps/website/public apps/apple/EULA` shows none left in the old form.
- [ ] **Step 2: Run** `make site-build` — expected: builds.
- [ ] **Step 3: Commit, alone,** `docs: the network promise with the MCP server (for review)`. The final report names this commit and says the person approves it before the branch lands; the EULA line is called out separately.

---

## After the last task

Final whole-branch review on Opus 5.5, then the report to the person, which lists the live
check owed (spec Testing): turn the server on in the Debug build, wire Claude Code from the
pane, `drakar_list_sessions`, start a session on eva, answer its permission from the agent
with the switch on and see it refused with it off, read its transcript, end it; and look at
Settings › MCP Server by eye.
