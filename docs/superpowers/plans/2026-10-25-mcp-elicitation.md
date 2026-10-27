# Answering MCP elicitations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An MCP server's mid-call question (form or link) shows as a card the person answers,
and the answer goes back to the server. Today Drakar declines it.

**Architecture:** DrakarKit parses the request into an `Elicitation`, including its form (the
MCP schema subset, ordered, validated). It keeps waiting ones on `Transcript` beside
`pendingPermissions`, and encodes the answer. The app answers through a new `AgentCommand`,
counts a waiting elicitation as permission-level urgency, and draws `ElicitationPanel` in the
asking MCP call's card, or docked above the composer when there is none. Slice 1 is Claude.
Slice 2 (Codex) is gated on its own live capture (Task 7).

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI/AppKit, swift-testing, DrakarKit
SPM package. Python 3 standard library for the test MCP server.

**Spec:** `docs/superpowers/specs/2026-10-25-mcp-elicitation-design.md`

## Global Constraints

- Work in a worktree under `.claude/worktrees/mcp-elicitation` (never `../`). Merge `main` in,
  run `make -C apps/apple test test-app` before landing, and land with `git merge --ff-only`
  in the main checkout. If main has uncommitted edits in files this branch touches, stop and
  ask.
- Ask before `make run`: it quits the running Drakar, which may hold live sessions.
- Check the UI through the accessibility tree (cupertino-desktop, by identifier). Screenshots
  are black on this Mac.
- Never write a value the person typed into a note, a log line, `os_log`, or anything else
  Drakar writes. Notes name the server and the question only.
- Never open a link without the person clicking Open in Browser. Only `http`/`https` links
  get that button.
- A waiting elicitation is always on screen: in its call's card, or docked.
- Strings go through `String(localized:)`, matching the surrounding code. No em dashes in UI
  copy.
- Deployment target macOS 26.0. No new dependencies.
- Format with `make -C apps/apple format-swift` before each commit.

## Review Focus

1. **Esc in the card.** Esc while the card has focus should decline the question, not
   interrupt the turn. That is checked by hand in Task 5, Step 6.
2. **A server name with a space or a dot** (`my server` → tool `mcp__my_server__…`). The card
   should still land in that call's card. Pinned by
   `TranscriptElicitationTests.anchorsToACallWhoseServerNameWasNormalised` (Task 3).
3. **A number typed loosely** (`" 42 "`, `"4.0"` for an integer, `"1,5"`, `"1e3"`). Trimmed
   whole numbers are accepted, anything ambiguous is refused with the field's own error, and
   an integer is sent as `42`, not `42.0`. Pinned in Tasks 2 and 3.
4. **The first of two waiting questions withdrawn.** The second should show, and the count
   should read 1 of 1. Pinned by `TranscriptElicitationTests.aWithdrawnFirstLeavesTheSecond`
   (Task 3).
5. **The process dies while a question waits.** The card should go and the session should
   stop counting as waiting. Pinned by `TranscriptElicitationTests.anExitClearsTheQuestions`
   (Task 3).

---

### Task 1: Capture live elicitations from Claude Code

The spec's request and reply shapes were read from the 2.1.308 binary. This task captures
them for real. Its fixture is what every later DrakarKit test quotes.

**Files:**
- Create: `scripts/elicit-mcp-server.py` (stdio MCP server, Python 3 stdlib only)
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/elicitation.jsonl`
- Modify: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift` (add a case)
- Modify: `docs/claude-stream-json.md:244` (the `elicitation` row) and add an
  `elicitation_complete` row in the same table

**Interfaces:**
- Produces: `Fixture.elicitation` (`"elicitation"`), whose lines are, in order: a form
  `control_request`, the CLI's lines up to the tool result, a URL `control_request`, and a
  `system` `elicitation_complete`.

- [ ] **Step 1: Write the server.** Newline-delimited JSON-RPC over stdio. It answers
  `initialize` (echoing the client's `protocolVersion`, `capabilities: {tools: {}}`),
  `tools/list` with two tools, and `tools/call`:
  - `ask_team`: sends `elicitation/create` with `{mode: "form", message: "Which team?",
    requestedSchema: {type: "object", properties: {team: {type: "string", title: "Team",
    enum: ["core", "web"]}, size: {type: "integer", title: "Size", minimum: 1, maximum: 9},
    api_token: {type: "string", title: "API token"}, notify: {type: "boolean", title:
    "Notify"}}, required: ["team", "size"]}}`. It returns the client's reply verbatim as the
    tool's text.
  - `sign_in`: sends `{mode: "url", message: "Sign in to continue", url:
    "https://example.com/auth?x=1", elicitationId: "el-1"}`. On `accept` it sends
    `notifications/elicitation/complete {elicitationId: "el-1"}`, then returns the reply.
- [ ] **Step 2: Capture.** In a scratch folder with a project `.mcp.json` registering the
  server as `elicit`, run `ClaudeCommand`'s arguments, `--model claude-haiku-4-5-20251001
  --setting-sources project`, and drive it from a throwaway script over stream-json, as in
  `docs/claude-stream-json.md` "Checking a new release". Prompt it to call `ask_team`, then
  `sign_in`. Answer the form with
  `{"action":"accept","content":{"team":"core","size":3,"api_token":"SECRET-123","notify":true}}`
  and the URL with `{"action":"accept"}`.
- [ ] **Step 3: Record three answers in the doc rows.**
  - The exact request keys.
  - Whether the tool result shows the server got `content` unchanged.
  - Whether `SECRET-123` appears in the session's JSONL under `~/.claude/projects/`
    (`grep -c SECRET-123`).
  
  If the reply shape differs from `{action, content}`, stop and bring it back: Tasks 3–5
  depend on it.
- [ ] **Step 4: Trim the capture into `elicitation.jsonl`.** Replace `SECRET-123` with
  `<secret>` in the fixture, then delete the scratch transcripts.
- [ ] **Step 5: Commit**

```bash
git add scripts/elicit-mcp-server.py apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/elicitation.jsonl apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift docs/claude-stream-json.md
git commit -m "test(kit): capture MCP elicitations from claude 2.1.308"
```

### Task 2: `Elicitation` and its form

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Elicitation.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ElicitationTests.swift`

**Interfaces:**
- Produces:

```swift
public struct Elicitation: Sendable, Equatable {
  public enum Content: Sendable, Equatable {
    case form(ElicitationForm)
    case url(URL)          // http or https only
    case unsupported       // a schema outside the subset, a bad or non-web URL, an unknown mode
  }
  public var serverName: String
  public var displayName: String?
  public var message: String
  public var elicitationID: String?
  public var title: String?
  public var description: String?
  public var content: Content
  public var serverLabel: String { get }   // displayName ?? serverName
  /// `request` is the control_request's `request` object (Claude's snake_case keys).
  public init?(claudeRequest request: JSONValue)
}

public struct ElicitationForm: Sendable, Equatable {
  public var fields: [ElicitationField]
  /// Nil when the schema isn't a flat object of the supported kinds.
  public init?(schema: JSONValue, order: [String]?)
  /// Each problem keyed by field key; empty when the inputs can be sent.
  public func problems(in inputs: [String: ElicitationInput]) -> [String: String]
  /// Nil while `problems` is non-empty. Omits optional fields left empty.
  public func content(from inputs: [String: ElicitationInput]) -> [String: JSONValue]?
  /// Each field's starting input, from its `default`.
  public var initialInputs: [String: ElicitationInput] { get }
}

public struct ElicitationField: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    case text(minLength: Int?, maxLength: Int?, format: String?)  // format: email, uri, date, date-time
    case number(isInteger: Bool, minimum: Double?, maximum: Double?)
    case flag
    case choice([Option])
    case choices([Option], minItems: Int?, maxItems: Int?)
  }
  public struct Option: Sendable, Equatable { public var value: String; public var title: String }
  public var id: String { key }
  public var key: String
  public var title: String          // schema title, else the key
  public var description: String?
  public var isRequired: Bool
  public var isSecret: Bool
  public var kind: Kind
}

public enum ElicitationInput: Sendable, Equatable {
  case text(String)        // text and number fields
  case flag(Bool)
  case picks(Set<String>)  // choice (at most one) and choices
}
```

- [ ] **Step 1: Write the failing tests** in `ElicitationTests.swift` (`@Suite("An MCP
  server's question")`). The request lines come from `Fixture.elicitation`.
  - `readsAFormRequest`: `serverName == "elicit"`, `message == "Which team?"`, and `content`
    is `.form` with field keys `["team", "size", "api_token", "notify"]` (`property_order`
    from the capture).
  - `readsALinkRequest`: `.url(URL(string: "https://example.com/auth?x=1")!)` and
    `elicitationID == "el-1"`.
  - `ordersRequiredFirstWithoutPropertyOrder`: `ElicitationForm(schema:order: nil)` on the
    Task 1 schema gives `["team", "size", "api_token", "notify"]` (required in `required`'s
    order, then alphabetical).
  - `keysMissingFromTheOrderComeLast`: order `["notify"]` gives
    `["notify", "api_token", "size", "team"]`.
  - `marksSecrets`: `api_token` → `isSecret`. The keys or titles `password`, `Passphrase`,
    `client_secret` and `API key` → secret. `passport` and `tokens_used_label` → not secret.
    The rule is a case-insensitive match of
    `(^|[^a-z0-9])(password|passphrase|secret|token|api[ _-]?key)($|[^a-z0-9])` on the key or
    the title.
  - `readsEveryKind`: `enum` + `enumNames` → `.choice` with titles. `oneOf: [{const, title}]`
    → `.choice`. `type: array, items: {enum}` → `.choices`. `format: "email"` kept.
  - `refusesWhatItCannotShow`: a nested object property, `type: array` without enum items, a
    top-level `type` other than `object`, and `mode: "url"` with `url: "file:///etc/passwd"`
    each give `.unsupported`. An unknown `mode` also gives `.unsupported`.
  - `requiresRequiredFields`: empty inputs give
    `problems == ["team": "Required", "size": "Required"]`.
  - `readsNumbersStrictly`: for `size` (integer, 1…9), `" 4 "` → no problem and content `4`.
    `"4.0"` → no problem, content `4`. `"4.5"` → `"Must be a whole number"`. `"1,5"` and
    `"1e3"` → `"Must be a number"`. `"12"` → `"Must be at most 9"`.
  - `checksLengthAndFormat`: `minLength: 3` with `"ab"` → `"At least 3 characters"`.
    `format: email` with `"x"` → `"Must be an email address"` (the check is one `@` with text
    on both sides).
  - `omitsEmptyOptionalFields`: with only `team` and `size` filled, `content` has exactly
    those two keys.
  - `startsFromDefaults`: `default: true` on a flag → `initialInputs["notify"] == .flag(true)`.
- [ ] **Step 2: Run the tests and watch them fail.**
  `swift test --package-path apps/apple/Packages/DrakarKit --filter ElicitationTests`.
  Expected: build failure, `Elicitation` undefined.
- [ ] **Step 3: Implement `Elicitation.swift`** with the interfaces above. The problem strings
  are exactly the ones in the tests, through `String(localized:)`. A whole-number `Double` in
  content is still `.number(4)`: Task 3 checks that it encodes as `4`.
- [ ] **Step 4: Run the tests and watch them pass.** Same command. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/Elicitation.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ElicitationTests.swift
git commit -m "feat(kit): read an MCP server's question and its form"
```

### Task 3: The protocol and the transcript keep it waiting

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/StreamMessage.swift:380-418`
  (`ControlRequest.Kind`, `reply`, parsing) and `:66-120` (`SystemEvent`)
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ClientMessage.swift:41-42,107-114`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/AgentEvent.swift:30-31`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Transcript.swift` (`:104-112`,
  `:153`, `:281-295`, `:334`, `:354-357`, `:459-465`)
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Claude/ClaudeTranslator.swift:66-68`
  (and wherever it switches on `SystemEvent`)
- Modify: `docs/claude-stream-json.md:244`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/NothingSilentTests.swift:26-80`,
  `ClientMessageTests.swift`, create `TranscriptElicitationTests.swift`

**Interfaces:**
- Consumes: `Elicitation`, `ElicitationForm` (Task 2), `Fixture.elicitation` (Task 1)
- Produces:

```swift
// StreamMessage.swift
case elicitation(Elicitation)                        // ControlRequest.Kind; replaces (serverName:message:)
// ControlRequest.reply is nil for .elicitation: the person answers it.
case elicitationComplete(serverName: String, elicitationID: String?)   // SystemEvent

// ClientMessage.swift (replaces declineElicitation)
public enum ElicitationAnswer: Sendable, Equatable {
  case accept([String: JSONValue]?)   // nil for a link
  case decline
  case cancel
}
case answerElicitation(requestID: String, ElicitationAnswer)

// AgentEvent.swift
case elicitationRequested(Transcript.PendingElicitation)
// .permissionWithdrawn(requestID:) also withdraws an elicitation with that id.

// Transcript.swift
public struct PendingElicitation: Sendable, Equatable, Identifiable {
  public var id: String { requestID }
  public var requestID: String
  public var elicitation: Elicitation
}
public private(set) var pendingElicitations: [PendingElicitation]
public var isWaitingOnPerson: Bool { get }   // either list non-empty
public var waitingCount: Int { get }         // both lists' counts summed
/// Removes it and notes what became of it.
public mutating func resolveElicitation(requestID: String, with answer: ElicitationAnswer)
/// The newest tool call of `serverName`'s tools still without a result, or nil.
public func elicitationAnchor(for serverName: String) -> String?
```

- [ ] **Step 1: Write the failing tests.**
  - In `NothingSilentTests`, replace `declinesAnElicitation` with
    `leavesAnElicitationToThePerson`: the form line parses to `.elicitation`, with
    `serverLabel == "linear"`, and `request.reply == nil`.
  - Replace `saysWhatADeclinedQuestionAsked` with `anElicitationWaits`: after the line,
    `pendingElicitations.count == 1` and no notice was added.
  - Add `notesALinkFinished`: the fixture's `elicitation_complete` line adds a notice
    containing `"elicit"` and `"finished the step in the browser"`.
  - `ClientMessageTests.answersAnElicitation`:
    `.answerElicitation(requestID: "e1", .accept(["size": .number(4), "team": .string("core")]))`
    encodes as
    `{"response":{"request_id":"e1","response":{"action":"accept","content":{"size":4,"team":"core"}},"subtype":"success"},"type":"control_response"}`.
    `.accept(nil)` → `"response":{"action":"accept"}`. `.decline` and `.cancel` → their
    `action` with no `content`.
  - `TranscriptElicitationTests` (`@Suite("A question from an MCP server waits")`):
    - `notesTheAnswerWithoutItsValues`: `resolveElicitation(requestID:with: .accept(["api_token": .string("SECRET")]))`
      leaves `pendingElicitations` empty, and its notice is exactly
      `Answered linear's question: Which team?`. No entry's text contains `SECRET`.
    - The notes for `.decline`, `.cancel`, a link's `.accept(nil)` and a withdrawal are
      `Declined linear's question: Which team?`,
      `Cancelled linear's question: Which team?`,
      `Opened linear's link to example.com`, and
      `linear withdrew its question: Which team?`.
    - `aWithdrawnFirstLeavesTheSecond`: two requests, then `.permissionWithdrawn("e1")`,
      leaves only `e2`.
    - `aTurnEndClearsTheQuestions` (`.turnEnded`) and `anExitClearsTheQuestions`
      (`processExited()`): `pendingElicitations` empty and `isWaitingOnPerson == false`.
    - `anchorsToTheOpenCall`: tool calls `mcp__linear__a` (with a result) and
      `mcp__linear__b` (without one) give `"b"`'s id. With no open call it gives nil.
    - `anchorsToACallWhoseServerNameWasNormalised`: server `my server.v2` matches tool
      `mcp__my_server_v2__find` (every character outside `[A-Za-z0-9_-]` becomes `_`).
- [ ] **Step 2: Run the tests and watch them fail.**
  `swift test --package-path apps/apple/Packages/DrakarKit --filter 'NothingSilentTests|ClientMessageTests|TranscriptElicitationTests'`.
  Expected: build failure on the new cases.
- [ ] **Step 3: Implement.**
  - `ClaudeTranslator` emits `.elicitationRequested` instead of the declined note, and
    `elicitationComplete` as a notice `"\(server) finished the step in the browser"`.
  - Delete `Transcript.declinedQuestionNote`.
  - `turnEnded` and `processExited` clear both lists.
  - Point `Transcript.swift:153`'s guard at `isWaitingOnPerson`.
  - Rewrite the doc row at `docs/claude-stream-json.md:244`: shown as a card and answered by
    the person. The CLI waits with no deadline.
- [ ] **Step 4: Run the whole kit suite and watch it pass.** `make -C apps/apple test`.
  Expected: PASS. Fix any other test that matched `.elicitation(serverName:message:)`.
- [ ] **Step 5: Commit**

```bash
git add -A apps/apple/Packages/DrakarKit docs/claude-stream-json.md
git commit -m "feat(kit): an MCP server's question waits for the person"
```

### Task 4: The session answers it and counts it as waiting

**Files:**
- Modify: `apps/apple/Drakar/Services/AgentBackend.swift:54-63` (`AgentCommand`)
- Modify: `apps/apple/Drakar/Services/ClaudeBackend.swift:63-64`,
  `apps/apple/Drakar/Services/CodexBackend.swift:102-108`
- Modify: `apps/apple/Drakar/Services/AgentSession.swift:99, 512-516, 522, 581-584, 595, 648-654, 679-689`
- Modify: `apps/apple/Drakar/Services/Project.swift:132-160, 490, 1172-1175`
- Modify: `apps/apple/Drakar/Services/SessionMoves.swift:40`,
  `apps/apple/Drakar/Services/Attention.swift:131-137`
- Test: `apps/apple/DrakarTests/AgentSessionRepliesTests.swift:43-56`

**Interfaces:**
- Consumes: `ElicitationAnswer`, `Transcript.PendingElicitation`, `isWaitingOnPerson`,
  `waitingCount`, `resolveElicitation` (Task 3)
- Produces:

```swift
case answerElicitation(requestID: String, ElicitationAnswer)   // AgentCommand
func answer(_ pending: Transcript.PendingElicitation, _ answer: ElicitationAnswer)  // AgentSession
@ObservationIgnored var onPermissionRequested: (() -> Void)?   // was ((PendingPermission) -> Void)?; fires when waitingCount grows
var pendingElicitation: Transcript.PendingElicitation? { get } // ProjectSession: the first one
```

- [ ] **Step 1: Write the failing tests.** In `AgentSessionRepliesTests`, replace
  `anElicitationIsDeclined` with:
  - `anElicitationWaitsForThePerson`: after the stand-in's form line,
    `transcript.pendingElicitations.count == 1`. Nothing containing `"request_id":"e1"` is
    written within 1 s.
  - `anAnsweredElicitationGoesBack`: `session.answer(pending, .accept(["team": .string("core")]))`
    writes a line containing `"action":"accept"` and `"team":"core"`, and empties
    `pendingElicitations`.
  - `anInterruptCancelsTheQuestion`: with one waiting, `session.interrupt()` writes
    `"action":"cancel"` for `e1` before the interrupt request.
- [ ] **Step 2: Run them and watch them fail.**
  `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -only-testing:DrakarTests/AgentSessionRepliesTests`.
  Expected: build failure on `answer(_:_:)` for an elicitation.
- [ ] **Step 3: Implement.**
  - `ClaudeBackend` maps the new command to `ClientMessage.answerElicitation`.
  - `CodexBackend` writes nothing for it until Task 7: Codex never raises one in slice 1.
    Leave a one-line comment saying so.
  - `AgentSession.answer` writes, resolves, and calls `onReplied`.
  - `interrupt` first answers `.cancel` to every waiting elicitation.
  - Every `pendingPermissions.count` used as "waiting" becomes `waitingCount`, and every
    `.isEmpty` check becomes `!isWaitingOnPerson`: `AgentSession.swift:522`,
    `Project.swift:490` and `SessionMoves.swift:40`. Leave the permission-only sites in
    `SessionView` and `TranscriptView:51` alone.
  - `Project.urgency` returns `.permission` when an elicitation waits and no permission does.
  - `wants` and `waitingFor` give `"\(serverLabel): \(message)"`.
  - `Attention.permissionRequested` posts `wants` verbatim, without "Wants to use", when
    `item.pendingElicitation != nil`.
- [ ] **Step 4: Run the suite and watch it pass.** `make -C apps/apple test-app`. Expected:
  PASS. A timing-only failure in `CapabilityProbeTests` or
  `AgentSessionTests.aSessionOpenedElsewhereDuringTheStartIsNotWritten` gets rerun alone
  before you call it a regression.
- [ ] **Step 5: Commit**

```bash
git add -A apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a session waits on an MCP server's question and answers it"
```

### Task 5: The card

**Files:**
- Create: `apps/apple/Drakar/Views/ElicitationPanel.swift`
- Modify: `apps/apple/Drakar/Views/TranscriptView.swift:299-300` (the plain `.tool` row)
- Modify: `apps/apple/Drakar/Views/SessionView.swift:30-35, 55-72, 255-280`

**Interfaces:**
- Consumes: `Elicitation`, `ElicitationForm`, `ElicitationInput`, `ElicitationAnswer`
  (Tasks 2–3), `AgentSession.answer(_:_:)`, `ProjectSession.pendingElicitation` (Task 4),
  `Transcript.elicitationAnchor(for:)`
- Produces:

```swift
struct ElicitationPanel: View {
  let elicitation: Elicitation
  let position: (index: Int, count: Int)?   // "1 of 3" when count > 1
  let answer: (ElicitationAnswer) -> Void
  var focusRequest: Int?                    // same contract as QuestionPanel.focusRequest
}
struct AskedElicitation: Equatable {        // environment value, like AskedQuestion
  let callID: String
  let requestID: String                     // in ==, as 86e86b7 learned
  let focusRequest: Int
  let panel: () -> ElicitationPanel         // excluded from ==
}
extension EnvironmentValues { @Entry var askedElicitation: AskedElicitation? }
```

- [ ] **Step 1: Build the panel.**
  - **Header:** `serverLabel` and `message`, plus `description` when present.
  - **Form:** one control per field. Text uses a `TextField`, or a `SecureField` when
    `isSecret`. Numbers use a `TextField`. A flag is a `Toggle`, a choice a `Picker`, choices
    are `Toggle`s. Each field's problem shows under it once the field has been edited. Submit
    is disabled while `problems` is non-empty.
  - **Link:** the host in `.title3`, the full URL as selectable text, and Open in Browser.
    Open calls `answer(.accept(nil))` and then `NSWorkspace.shared.open(url)`.
  - **Unsupported:** "Drakar can't show this form." and Decline only.
  - **Keys:** ⌘↩ submits or opens (`.keyboardShortcut(.return, modifiers: .command)`), and
    Esc declines (`.cancelAction`).
  - **Accessibility identifiers:** `elicitation.panel`, `elicitation.field.<key>`,
    `elicitation.submit`, `elicitation.open`, `elicitation.decline`.
  - **Layout:** no inner `ScrollView`, and no state change in `onAppear`. Focus moves only on
    `onChange(of: focusRequest)` (d19c1fa).
- [ ] **Step 2: Place it.**
  - `SessionView` builds `askedElicitation` from the first pending elicitation when
    `elicitationAnchor(for: serverName)` finds a call, sets the environment, and bumps
    `item.questionFocusRequest` in `.task(id: pending.requestID)`.
  - `TranscriptView`'s plain `.tool(call)` row shows `ToolCallView(call:)` with the panel
    under it when `askedElicitation?.callID == call.id`.
  - Otherwise `SessionView` docks the panel above the composer (after the plan branch, before
    `pendingChoice`).
  - When anchored, the composer's place shows `QuestionWaitingStrip`.
  - `position` is `(1, pendingElicitations.count)`, so the panel shows "1 of N" only when more
    than one waits.
  - If Task 1 found the answer's `content` in the session's JSONL, the panel's footnote reads
    "Claude Code keeps what you send here in the session's transcript." under any form with
    a secret field. If it didn't, there is no footnote.
- [ ] **Step 3: Build.** `make -C apps/apple build`. Expected: succeeds with no new warnings.
- [ ] **Step 4: Commit**

```bash
git add apps/apple/Drakar/Views
git commit -m "feat(apple): answer an MCP server's question in its card"
```

- [ ] **Step 5: Ask the person before `make run`, then check live** against
  `scripts/elicit-mcp-server.py` registered in a scratch project. Check each of these by
  identifier:
  - The form card sits in the `mcp__elicit__ask_team` card.
  - Submit stays disabled until Team and Size are filled.
  - `api_token` is masked.
  - The tool result shows the content.
  - The note has no token.
  - The link card shows `example.com`, opens the browser only on click, and the "finished"
    note follows.
- [ ] **Step 6: Check Esc (Review Focus 1).** With focus in the card, Esc declines the
  question. The turn keeps running, and the note reads "Declined…". Release the desktop
  session afterwards.

### Task 6: Land slice 1

- [ ] **Step 1:** In the worktree, `git merge main`, then `make -C apps/apple test test-app`.
  Expected: PASS.
- [ ] **Step 2:** Check the main checkout for uncommitted edits in files this branch touches
  (`git -C <main> status --short`). If there are any, stop and ask. Otherwise run
  `git -C <main> merge --ff-only mcp-elicitation`.
- [ ] **Step 3:** Update the memory index: a `mcp-elicitation` memory with the landed commit
  and what was or wasn't checked live.

### Task 7: Codex (slice 2, gated on a live capture)

Start only after slice 1 has landed.

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexSession.swift:207-227`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Elicitation.swift` (a Codex
  initializer)
- Modify: `docs/codex-app-server.md:495-500`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexSessionTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–4
- Produces: `Elicitation.init?(codexParams: JSONValue)` (camelCase keys `serverName`,
  `requestedSchema`, `elicitationId`; no field order, so required first, then alphabetical)

- [ ] **Step 1:** Register `scripts/elicit-mcp-server.py` with Codex 0.164.0, then capture
  `mcpServer/elicitation/request` for both tools and the answer Codex accepts. Save it as
  `Fixtures/codex-elicitation.jsonl`. If the shape differs from
  `docs/codex-app-server.md:497-498`, stop and bring it back.
- [ ] **Step 2: Write the failing tests:**
  - `anElicitationWaits`: the request yields `.elicitationRequested` and no write.
  - `answersAnElicitation`: the answer is `{action, content, _meta: null}` for the request's
    id.
  - `aResolvedRequestIsWithdrawn`: `serverRequest/resolved` for it yields
    `.permissionWithdrawn`.
  - `openaiFormIsUnsupported`: `mode: "openai/form"` gives `.unsupported`.
- [ ] **Step 3:** Route the method to the pending list instead of refusing it. Map
  `AgentCommand.answerElicitation` in `CodexBackend`. Correct the doc line ("Drakar declines")
  to describe what it does now.
- [ ] **Step 4:** Run `make -C apps/apple test test-app`. Expected: PASS. Then check live
  against Codex, the same way as Task 5 Step 5.
- [ ] **Step 5:** Commit as
  `feat(apple): answer a Codex MCP server's question in its card`, then land as in Task 6.
