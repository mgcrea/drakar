# Live Codex sessions: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project window runs Codex sessions beside Claude Code ones, over `codex app-server`: streaming into the same transcript, approvals in the same sheet, steer, stop, model and effort, restored with history after a relaunch.

**Architecture:** DrakarKit gets the Codex wire (`CodexRPC`), the mappings (`CodexPolicy`, `CodexModels`, `CodexInput`), a completed `CodexTranslator` (live and history) and `CodexSession`, a pure state machine that turns commands and lines into lines to write, `AgentEvent`s and signals. The app gets `CodexBackend` (an `AgentBackend` that drives a `CodexSession` over an `AgentProcess`), `CodexLaunch`, `CodexOneShot` (a short-lived `app-server` for history and the model list), `AgentKind` stored on each `ResumeTarget`, and `AgentFeatures`, which the views read instead of asking which agent runs.

**Tech Stack:** Swift 6 (DrakarKit tools 6.3, app `SWIFT_VERSION = 6.0`, default actor isolation `MainActor` in the app target), Swift Testing, SwiftPM package `apps/apple/Packages/DrakarKit` (zero dependencies), Xcode project `apps/apple/Drakar.xcodeproj` (synchronized folders: new files join their target by sitting in its folder).

**Spec:** `docs/superpowers/specs/2026-10-07-codex-live-sessions-design.md`. Protocol reference: `docs/codex-app-server.md` (updated with this plan's probe, 2026-10-07).

## Global Constraints

- Work in the worktree `/Users/olivier/Projects/apps/drakar-codex-live`, branch `feat/codex-live`. Never edit `/Users/olivier/Projects/apps/drakar` (other sessions commit there).
- Every commit passes `make -C apps/apple test` and `make -C apps/apple test-app`. Run `make -C apps/apple format-swift` before committing. `make -C apps/apple format-swift-check` already fails on main in `LiveSessionTests.swift`, `PresentationTests.swift` and `TranscriptTests.swift`: revert the formatter's rewrites of those three files (`git checkout -- <file>` is allowed for exactly those three) and add no new failures.
- DrakarKit imports nothing above Foundation (and the frameworks it already imports) and has no dependencies.
- Claude sessions do not change: the goldens in `DrakarKitTests/Goldens/` that exist before this plan must pass unchanged at every commit. Never re-record them.
- Existing tests change only where a task says so.
- Never run `make run` (it quits the Drakar the person is using); the in-app check is Task 10 and needs the person's go-ahead.
- Comments follow the codebase: a doc comment says what a thing is for, in plain sentences; no em dashes.
- Commit messages: `feat(apple): …`, `test(apple): …`, `refactor(apple): …`, imperative, under 72 characters. **No `Co-Authored-By` trailer, no signature.** Stage files by name.
- Codex fixtures hold no account data: placeholder ids, `/Users/me/...` paths, no emails.
- Focused test commands: DrakarKit `swift test --package-path apps/apple/Packages/DrakarKit --filter <Suite>`; app `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/<Suite>` (run from the worktree root).

## Refinements of the spec

Found while planning against the code and the 2026-10-07 probe; each keeps the spec's intent.

- **The probe ran during planning** (commits `1214f63`, `5aa7836`): a delete's diff is the old content; a pure rename's is `"\n\nMoved to: <path>"`; `clientUserMessageId` comes back as the `userMessage`'s `clientId` for `turn/start` and `turn/steer`; a steer is never lost to a turn ending, only to an interrupt; a file-change request has no `availableDecisions`; `requiresOpenaiAuth` is true even when signed in (not signed in is `account: null`); the full `sandboxPolicy` object is accepted. Order of work step 1 is done.
- **The conversation logic lives in DrakarKit as `CodexSession`**, a value type with no process: `start()`, `send(_:)` and `receive(_:at:)` each return a `Step` (lines to write, events, signals). `CodexBackend` only writes the lines and maps signals. Every behaviour is tested without a process.
- **`CodexRPC.Client` is `CodexRPC.Calls<Purpose>`**: numbers our requests and returns each response's purpose once.
- **Nothing is sent before `initialize` is answered**: prompts wait, and `initialized`, `account/read` and `model/list` go with the answer.
- **Picks are not answered with `changeAnswered`**: `CodexBackend.send` returns no request id for them, so the session keeps no revert. While a turn runs, the pill note reads "From the next turn" until it ends (`AgentFeatures.picksApplyAtOnce` false).
- **A thread another process holds fails the session** with "This thread is open in another Codex process. Close it there, then send again." instead of a read-only view: there is nothing to follow until slice 3, and sending again retries.
- **`EffortLevel` names `ultra`**; unknown levels still show as they are (an existing test pins that).
- **New Codex Session is ⌃⌘N**, not ⌥⌘N, which is Answer No. The Session menu lists "New Session" (⌘N, the default agent) and "New <other agent> Session" (⌃⌘N).
- **The question and plan panels keep their wording**: Codex never reaches them in this slice (no `AskUserQuestion`, no `ExitPlanMode`).
- **Codex rows show no preview until their history is read**: `readPreview` reads Claude transcripts only; rollouts are slice 3.
- **The model pill gets Codex's list before the first prompt** from a short-lived `app-server` (`ModelCatalog.loadCodex()`), with no "default" entry: Codex's own model is `config.toml`'s, named once the thread reports it.
- **A file change of several files draws as one diff per file** (`FileChange.each(edits:)`): Codex patches several files in one item. Claude's calls touch one file each, so they draw as before.
- **Skills run in a new session are Claude Code's**: `Project.run(_:in: .newSession)` starts a Claude session whatever the default agent.

## Review Focus

1. **A second prompt sent while the thread is still opening**: it must be steered into the first turn once that turn has an id, not lost and not started as a second turn. Pinned in Task 5.
2. **Stop pressed before Codex has said the turn's id**: the interrupt must go out as soon as the id arrives. Pinned in Task 5.
3. **An approval answered after the turn was interrupted or resolved** (its request id gone): nothing is written. Pinned in Task 5.
4. **A steer that fails because the turn just ended**: it is resent as `turn/start`, its queue entry then taken as that turn's prompt. Pinned in Task 5.
5. **A window stored before this slice, and a restored Codex session whose history cannot be read**: the old window decodes every session as Claude; the Codex one opens with a note and still resumes on the next prompt. Pinned in Tasks 6 and 7.

---

## File map

DrakarKit (`apps/apple/Packages/DrakarKit/Sources/DrakarKit/`):

| File | Responsibility |
| --- | --- |
| `Codex/CodexRPC.swift` (new) | Line kinds, ids, request numbering, answers and refusals |
| `Codex/CodexPolicy.swift` (new) | Mode ↔ approval policy × sandbox; decision → Codex decision |
| `Codex/CodexModels.swift` (new) | `model/list` → `[ModelOption]` |
| `Codex/CodexInput.swift` (new) | A prompt, its editor context and attachments → `UserInput[]` |
| `Codex/CodexTranslator.swift` (modify) | Live lines and history entries → `[AgentEvent]` |
| `Codex/CodexSession.swift` (new) | The conversation as a state machine |
| `ToolKind.swift` (modify) | `FileEdit.Change.delete`, `.move` |
| `Diff.swift` (modify) | `FileChange.isDeleted`, `movedTo`, `each(edits:)` |
| `ModeAndModel.swift` (modify) | `EffortLevel` `ultra` |
| `Presentation.swift` (modify) | `PermissionSuggestion.Kind.codexDecision` |

DrakarKit tests (`apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/`): `CodexRPCTests.swift`, `CodexPolicyTests.swift`, `CodexSessionTests.swift`, `CodexGoldenTests.swift` (new); `CodexTranslatorTests.swift`, `Fixture.swift`, `DiffTests.swift` (modify); `Goldens/codex*.json` (recorded in Task 4).

App (`apps/apple/Drakar/`):

| File | Responsibility |
| --- | --- |
| `Services/AgentFeatures.swift` (new) | `AgentKind`, `AgentFeatures` |
| `Services/CodexLaunch.swift` (new) | Finding `codex`, its configuration, the app's version |
| `Services/CodexOneShot.swift` (new) | A short-lived `app-server` for history and the model list |
| `Services/CodexBackend.swift` (new) | `AgentBackend` over `CodexSession` |
| `Services/AgentBackend.swift` (modify) | `features`, `SessionSignal.unusable` |
| `Services/ClaudeBackend.swift` (modify) | `features` |
| `Services/SessionRoute.swift` (modify) | `ResumeTarget.agent` |
| `Services/AgentSession.swift` (modify) | `agent`, Codex history, defaults, `unusable`, pick note |
| `Services/ModelCatalog.swift` (modify) | Codex's list |
| `Services/Project.swift` (modify) | `newSession(agent:)`, fork gate, preview, PDF refusal, skill runs |
| `Services/SessionMoves.swift` (modify) | Claude sessions only |
| `Views/SessionPills.swift`, `SessionView.swift`, `ComposerView.swift`, `TranscriptView.swift`, `DiffView.swift`, `PermissionSheet.swift`, `ProjectSidebar.swift`, `SettingsView.swift`, `DrakarApp.swift`, `ContentView.swift` (modify) | Gating, wording, entry points |

App tests (`apps/apple/DrakarTests/`): `CodexBackendTests.swift`, `CodexSessionsTests.swift` (new).

---

### Task 1: `CodexRPC`

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexRPC.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexRPCTests.swift`

**Interfaces:**
- Produces: `CodexRPC.ID` (`.number(Int)`, `.string(String)`, `init?(_: JSONValue?)`, `json`, `text`); `CodexRPC.Line` (`.response(id:result:)`, `.failure(id:message:)`, `.notification(method:params:)`, `.request(id:method:params:)`, `init?(_: JSONValue)`); `CodexRPC.Calls<Purpose>` (`make(_:_:for:) -> JSONValue`, `take(_: ID) -> Purpose?`); `CodexRPC.notification(_:) -> JSONValue`, `answer(_:result:) -> JSONValue`, `refusal(_:message:) -> JSONValue`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Codex's JSON-RPC lines")
struct CodexRPCTests {
  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  @Test func readsEachKindOfLine() throws {
    #expect(
      CodexRPC.Line(try json(#"{"id":3,"result":{"turn":{"id":"t"}}}"#))
        == .response(id: .number(3), result: try json(#"{"turn":{"id":"t"}}"#)))
    #expect(
      CodexRPC.Line(try json(#"{"id":"init-1","error":{"code":-32600,"message":"Not initialized"}}"#))
        == .failure(id: .string("init-1"), message: "Not initialized"))
    #expect(
      CodexRPC.Line(try json(#"{"method":"turn/started","params":{"threadId":"a"},"emittedAtMs":1}"#))
        == .notification(method: "turn/started", params: try json(#"{"threadId":"a"}"#)))
    #expect(
      CodexRPC.Line(try json(#"{"method":"item/fileChange/requestApproval","id":0,"params":{}}"#))
        == .request(id: .number(0), method: "item/fileChange/requestApproval", params: .object([:])))
    #expect(CodexRPC.Line(try json(#"{"hello":1}"#)) == nil)
  }

  @Test func aResultWithNoBodyIsNull() throws {
    #expect(CodexRPC.Line(try json(#"{"id":6}"#)) == .response(id: .number(6), result: .null))
  }

  @Test func idsReadAsTheTranscriptKnowsThem() {
    #expect(CodexRPC.ID.number(0).text == "0")
    #expect(CodexRPC.ID.string("x").text == "x")
    #expect(CodexRPC.ID(.number(2)) == .number(2))
    #expect(CodexRPC.ID(.string("a")) == .string("a"))
    #expect(CodexRPC.ID(.null) == nil)
  }

  @Test func callsAreNumberedAndAnsweredOnce() throws {
    var calls = CodexRPC.Calls<String>()
    let first = calls.make("initialize", .object([:]), for: "init")
    let second = calls.make("model/list", .object([:]), for: "models")
    #expect(first["id"] == .number(1))
    #expect(first["method"] == .string("initialize"))
    #expect(first["jsonrpc"] == nil)
    #expect(second["id"] == .number(2))
    #expect(calls.take(.number(2)) == "models")
    #expect(calls.take(.number(2)) == nil)
    #expect(calls.take(.string("1")) == nil)
    #expect(calls.take(.number(1)) == "init")
  }

  @Test func writesAnswersAndRefusals() throws {
    #expect(
      CodexRPC.answer(.number(0), result: .object(["decision": .string("accept")]))
        == (try json(#"{"id":0,"result":{"decision":"accept"}}"#)))
    #expect(
      CodexRPC.refusal(.string("r"), message: "No")
        == (try json(#"{"id":"r","error":{"code":-32601,"message":"No"}}"#)))
    #expect(CodexRPC.notification("initialized") == (try json(#"{"method":"initialized"}"#)))
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexRPCTests`
Expected: FAIL to build, `cannot find 'CodexRPC' in scope`.

- [ ] **Step 3: Write `CodexRPC`**

```swift
import Foundation

/// JSON-RPC as `codex app-server` speaks it (docs/codex-app-server.md, "Framing"): one object
/// per line, no `jsonrpc` member, ids numbers or strings. The server numbers its own requests
/// from 0, so its ids and ours are never compared.
public enum CodexRPC {
  /// A request id, kept as it came so the answer echoes it.
  public enum ID: Sendable, Hashable {
    case number(Int)
    case string(String)

    public init?(_ json: JSONValue?) {
      if let number = json?.intValue {
        self = .number(number)
      } else if let string = json?.stringValue {
        self = .string(string)
      } else {
        return nil
      }
    }

    public var json: JSONValue {
      switch self {
      case .number(let number): .number(Double(number))
      case .string(let string): .string(string)
      }
    }

    /// How the transcript names a request: a number's digits, or the string.
    public var text: String {
      switch self {
      case .number(let number): String(number)
      case .string(let string): string
      }
    }
  }

  /// What one line from the server is.
  public enum Line: Sendable, Equatable {
    case response(id: ID, result: JSONValue)
    case failure(id: ID, message: String)
    case notification(method: String, params: JSONValue)
    /// The server asking: an approval, a question, a tool call.
    case request(id: ID, method: String, params: JSONValue)

    public init?(_ json: JSONValue) {
      let method = json["method"]?.stringValue
      let id = ID(json["id"])
      switch (method, id) {
      case (let method?, let id?):
        self = .request(id: id, method: method, params: json["params"] ?? .null)
      case (let method?, nil):
        self = .notification(method: method, params: json["params"] ?? .null)
      case (nil, let id?):
        if let error = json["error"] {
          self = .failure(id: id, message: error["message"]?.stringValue ?? "")
        } else {
          self = .response(id: id, result: json["result"] ?? .null)
        }
      case (nil, nil):
        return nil
      }
    }
  }

  /// Our requests in flight, numbered from 1, each remembered with what it was for until its
  /// answer comes.
  public struct Calls<Purpose: Sendable>: Sendable {
    private var next = 1
    private var pending: [Int: Purpose] = [:]

    public init() {}

    public mutating func make(_ method: String, _ params: JSONValue, for purpose: Purpose)
      -> JSONValue
    {
      let id = next
      next += 1
      pending[id] = purpose
      return .object([
        "id": .number(Double(id)), "method": .string(method), "params": params,
      ])
    }

    /// What the request `id` answers was for, once; nil for an id that is not ours.
    public mutating func take(_ id: ID) -> Purpose? {
      guard case .number(let number) = id else { return nil }
      return pending.removeValue(forKey: number)
    }
  }

  public static func notification(_ method: String) -> JSONValue {
    .object(["method": .string(method)])
  }

  /// Our answer to one of the server's requests.
  public static func answer(_ id: ID, result: JSONValue) -> JSONValue {
    .object(["id": id.json, "result": result])
  }

  /// A request the server made that Drakar does not answer: refused, so nothing waits on it.
  public static func refusal(_ id: ID, message: String) -> JSONValue {
    .object([
      "id": id.json,
      "error": .object(["code": .number(-32601), "message": .string(message)]),
    ])
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexRPCTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexRPC.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexRPCTests.swift
git commit -m "feat(apple): read and write Codex's JSON-RPC lines"
```

---

### Task 2: `CodexPolicy`, `CodexModels`, `CodexInput`, effort and suggestion names

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexPolicy.swift`, `Codex/CodexModels.swift`, `Codex/CodexInput.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ModeAndModel.swift` (`EffortLevel.title`, `symbol`), `Presentation.swift` (`PermissionSuggestion`)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexPolicyTests.swift`

**Interfaces:**
- Consumes: `PermissionMode`, `PermissionDecision`, `ModelOption`, `EditorSelection.promptContext`, `Attachment.block`.
- Produces: `CodexPolicy.offeredModes(allowsBypass:) -> [PermissionMode]`, `threadSettings(_:) -> [String: JSONValue]`, `turnSettings(_:) -> [String: JSONValue]`, `decision(_:) -> JSONValue`, `acceptForSession: JSONValue`; `CodexModels.list(_: JSONValue) -> [ModelOption]`; `CodexInput.make(text:context:attachments:) -> JSONValue`, `CodexInput.text(_:) -> JSONValue`; `PermissionSuggestion.Kind.codexDecision(String)`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Codex's policies, models and input")
struct CodexPolicyTests {
  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  @Test func modesMapOntoPolicyAndSandbox() throws {
    #expect(
      CodexPolicy.threadSettings(.ask)
        == ["approvalPolicy": .string("untrusted"), "sandbox": .string("workspace-write")])
    #expect(
      CodexPolicy.threadSettings(.acceptEdits)
        == ["approvalPolicy": .string("on-request"), "sandbox": .string("workspace-write")])
    #expect(
      CodexPolicy.threadSettings(.bypass)
        == ["approvalPolicy": .string("never"), "sandbox": .string("danger-full-access")])
    // Codex has no plan or auto mode here: they ask, as Ask before edits does.
    #expect(CodexPolicy.threadSettings(.plan) == CodexPolicy.threadSettings(.ask))
    #expect(
      CodexPolicy.turnSettings(.ask)["sandboxPolicy"]
        == (try json(
          #"{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false}"#
        )))
    #expect(
      CodexPolicy.turnSettings(.bypass)
        == [
          "approvalPolicy": .string("never"),
          "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
        ])
  }

  @Test func offersThreeModesAtMost() {
    #expect(CodexPolicy.offeredModes(allowsBypass: true) == [.ask, .acceptEdits, .bypass])
    #expect(CodexPolicy.offeredModes(allowsBypass: false) == [.ask, .acceptEdits])
  }

  @Test func decisionsMapOntoCodexs() {
    #expect(CodexPolicy.decision(.allow(updatedInput: .null)) == .string("accept"))
    #expect(
      CodexPolicy.decision(
        .allow(updatedInput: .null, updatedPermissions: [CodexPolicy.acceptForSession]))
        == .string("acceptForSession"))
    #expect(CodexPolicy.decision(.deny(message: "no")) == .string("decline"))
    #expect(CodexPolicy.decision(.deny(message: "no", interrupt: true)) == .string("cancel"))
  }

  @Test func theSessionSuggestionHasAKindOfItsOwn() {
    let suggestion = PermissionSuggestion(CodexPolicy.acceptForSession, id: 0)
    #expect(suggestion?.kind == .codexDecision("acceptForSession"))
    #expect(suggestion?.isPersistent == false)
  }

  @Test func listsVisibleModelsWithTheirEfforts() throws {
    let models = CodexModels.list(
      try json(
        #"{"data":[{"id":"gpt-6.1-sol","model":"gpt-6.1-sol","displayName":"GPT-6.1-Sol","description":"Workhorse","hidden":false,"isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"ultra","description":"Max"}]},{"id":"old","model":"old","displayName":"Old","hidden":true,"supportedReasoningEfforts":[]}],"nextCursor":null}"#
      ))
    #expect(
      models == [
        ModelOption(
          value: "gpt-6.1-sol", resolvedModel: "gpt-6.1-sol", displayName: "GPT-6.1-Sol",
          description: "Workhorse", effortLevels: ["low", "ultra"])
      ])
    #expect(EffortLevel.title(of: "ultra") == "Ultra")
  }

  @Test func aPromptBecomesCodexInput() throws {
    let selection = EditorSelection(
      filePath: "/p/a.swift", text: "", start: .init(line: 0, character: 0),
      end: .init(line: 0, character: 0))
    let image = try Attachment.image(
      try #require(Data(base64Encoded: Self.redPixel)), name: "red.png")
    let input = CodexInput.make(text: "Look", context: [selection], attachments: [image])
    let items = try #require(input.arrayValue)
    #expect(items.count == 3)
    #expect(items[0]["text"]?.stringValue == selection.promptContext)
    #expect(items[1] == CodexInput.text("Look"))
    #expect(items[2]["type"] == .string("image"))
    #expect(items[2]["url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
  }

  @Test func aTextFileGoesInline() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "codex-input-\(UUID()).txt")
    try "hello\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try Attachment.file(at: url)
    let items = try #require(CodexInput.make(text: "", context: [], attachments: [file]).arrayValue)
    #expect(items == [CodexInput.text("<attachment name=\"\(url.lastPathComponent)\">\nhello\n\n</attachment>")])
  }

  /// A 1×1 red PNG.
  static let redPixel =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
}
```

Before running, check how `EditorSelection` is built in an existing test (`grep -rn "EditorSelection(" apps/apple/Packages/DrakarKit/Tests | head -3`) and use the same initializer if its labels differ from the ones above; the assertion on `promptContext` stays.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexPolicyTests`
Expected: FAIL to build, `cannot find 'CodexPolicy' in scope`.

- [ ] **Step 3: Write `CodexPolicy.swift`**

```swift
import Foundation

/// How Drakar's permission modes and answers read in Codex's words
/// (docs/codex-app-server.md, "Mode, model, effort"): a mode is an approval policy and a
/// sandbox, sent with every `turn/start` and kept by the thread.
public enum CodexPolicy {
  /// What a Codex session's mode pill offers: Codex has no plan mode outside its
  /// experimental API, and Auto (`approvalsReviewer: auto_review`) is unverified.
  public static func offeredModes(allowsBypass: Bool) -> [PermissionMode] {
    allowsBypass ? [.ask, .acceptEdits, .bypass] : [.ask, .acceptEdits]
  }

  /// `thread/start` and `thread/resume`'s `approvalPolicy` and `sandbox` (a mode string).
  public static func threadSettings(_ mode: PermissionMode) -> [String: JSONValue] {
    let (approval, sandbox) = pair(mode)
    return ["approvalPolicy": .string(approval), "sandbox": .string(sandbox)]
  }

  /// `turn/start`'s `approvalPolicy` and `sandboxPolicy` (the object form, verified
  /// 2026-10-07).
  public static func turnSettings(_ mode: PermissionMode) -> [String: JSONValue] {
    let (approval, sandbox) = pair(mode)
    return ["approvalPolicy": .string(approval), "sandboxPolicy": sandboxPolicy(sandbox)]
  }

  /// Ask before edits asks for edits and any command not known safe; Edit automatically runs
  /// edits and sandboxed commands unasked (both verified 2026-10-06). A mode Codex has no
  /// counterpart for asks.
  private static func pair(_ mode: PermissionMode) -> (approval: String, sandbox: String) {
    switch mode {
    case .acceptEdits: ("on-request", "workspace-write")
    case .bypass: ("never", "danger-full-access")
    case .ask, .plan, .auto: ("untrusted", "workspace-write")
    }
  }

  private static func sandboxPolicy(_ sandbox: String) -> JSONValue {
    switch sandbox {
    case "danger-full-access":
      .object(["type": .string("dangerFullAccess")])
    default:
      .object([
        "type": .string("workspaceWrite"), "writableRoots": .array([]),
        "networkAccess": .bool(false), "excludeTmpdirEnvVar": .bool(false),
        "excludeSlashTmp": .bool(false),
      ])
    }
  }

  /// The "for this session" choice a request offers, as a permission suggestion the sheet
  /// shows and passes back.
  public static let acceptForSession: JSONValue = .object([
    "type": .string("codexDecision"), "decision": .string("acceptForSession"),
  ])

  /// The answer to a command or file-change approval. Reject declines and the turn goes on,
  /// as with Claude; a deny that interrupts cancels, which ends the turn.
  public static func decision(_ decision: PermissionDecision) -> JSONValue {
    switch decision {
    case .allow(_, let permissions):
      if let chosen = permissions.first, chosen["type"] == .string("codexDecision"),
        let value = chosen["decision"]?.stringValue
      {
        return .string(value)
      }
      return .string("accept")
    case .deny(_, let interrupt):
      return .string(interrupt ? "cancel" : "decline")
    }
  }
}
```

- [ ] **Step 4: Write `CodexModels.swift`**

```swift
import Foundation

/// Codex's `model/list` as the model pill lists it (docs/codex-app-server.md, "Models and
/// effort"): visible models, each with the efforts it takes. There is no "default" entry:
/// Codex's own model is `config.toml`'s, named once a thread reports it.
public enum CodexModels {
  public static func list(_ result: JSONValue) -> [ModelOption] {
    (result["data"]?.arrayValue ?? []).compactMap { model in
      guard model["hidden"]?.boolValue != true,
        let id = model["model"]?.stringValue ?? model["id"]?.stringValue
      else { return nil }
      return ModelOption(
        value: id, resolvedModel: id, displayName: model["displayName"]?.stringValue ?? id,
        description: model["description"]?.stringValue ?? "",
        effortLevels: (model["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap {
          $0["reasoningEffort"]?.stringValue
        })
    }
  }
}
```

- [ ] **Step 5: Write `CodexInput.swift`**

```swift
import Foundation

/// A prompt as `turn/start` and `turn/steer` take it (`UserInput[]`, docs/codex-app-server.md,
/// "Input"): the editor's context first, as the extension's chat puts it, then the prompt,
/// then each attachment. Codex has no document input: a text file goes inline, and a PDF is
/// refused before it gets here.
public enum CodexInput {
  public static func make(text: String, context: [EditorSelection], attachments: [Attachment])
    -> JSONValue
  {
    var items = context.map { Self.text($0.promptContext) }
    if !text.isEmpty { items.append(Self.text(text)) }
    items += attachments.compactMap { item($0.block) }
    return .array(items)
  }

  public static func text(_ text: String) -> JSONValue {
    .object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])
  }

  /// An attachment's Claude block in Codex's words: an image as a data URL (verified), a text
  /// file inline in an `<attachment>` element that history reads back.
  static func item(_ block: JSONValue) -> JSONValue? {
    let source = block["source"]
    switch (block["type"]?.stringValue, source?["type"]?.stringValue) {
    case ("image", "base64"):
      guard let media = source?["media_type"]?.stringValue,
        let data = source?["data"]?.stringValue
      else { return nil }
      return .object(["type": .string("image"), "url": .string("data:\(media);base64,\(data)")])
    case ("document", "text"):
      guard let content = source?["data"]?.stringValue else { return nil }
      let name = block["title"]?.stringValue ?? "attachment"
      return text("<attachment name=\"\(name)\">\n\(content)\n</attachment>")
    default:
      return nil
    }
  }
}
```

- [ ] **Step 6: Name `ultra`, and the session suggestion**

In `ModeAndModel.swift`, `EffortLevel.title(of:)` gains `case "ultra": String(localized: "Ultra")` after `max`, and `symbol(of:)` gains `case "ultra": "gauge.with.dots.needle.100percent"`. The `default: raw` stays (a test pins it).

In `Presentation.swift`, `PermissionSuggestion.Kind` gains, after `setMode`:

```swift
    /// One of Codex's own approval decisions (`acceptForSession`), passed back as the answer.
    case codexDecision(String)
```

and `init?(_:id:)` gains, before `default:`:

```swift
    case "codexDecision":
      kind = .codexDecision(raw["decision"]?.stringValue ?? "")
```

- [ ] **Step 7: Run the tests**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexPolicyTests`
Expected: PASS (7 tests). Then `make -C apps/apple test`: every suite passes.

- [ ] **Step 8: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexPolicy.swift apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexModels.swift apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexInput.swift apps/apple/Packages/DrakarKit/Sources/DrakarKit/ModeAndModel.swift apps/apple/Packages/DrakarKit/Sources/DrakarKit/Presentation.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexPolicyTests.swift
git commit -m "feat(apple): say Drakar's modes, answers and prompts in Codex's words"
```

---

### Task 3: Deletes, renames, and one diff per file

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ToolKind.swift:45-62` (`FileEdit.Change`), `Diff.swift:124-162` (`FileChange`)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/DiffTests.swift` (add tests)

**Interfaces:**
- Produces: `FileEdit.Change.delete(content: String)`, `.move(to: String, patch: String)`; `FileChange.isDeleted: Bool`, `movedTo: String?`, `static func each(edits: [FileEdit]) -> [FileChange]`.

- [ ] **Step 1: Write the failing tests** (append inside `DiffTests`' suite struct)

```swift
  @Test func aDeleteIsEveryLineRemoved() throws {
    let change = try #require(
      FileChange(path: "/p/b.txt", edits: [FileEdit(path: "/p/b.txt", change: .delete(content: "bye\nnow\n"))]))
    #expect(change.isDeleted)
    #expect(!change.isNewFile)
    #expect(change.diffs == [[DiffLine(.removed, "bye"), DiffLine(.removed, "now")]])
  }

  @Test func aPureRenameHasNoDiff() throws {
    let change = try #require(
      FileChange(
        path: "/p/c.txt", edits: [FileEdit(path: "/p/c.txt", change: .move(to: "/p/d.txt", patch: ""))]))
    #expect(change.movedTo == "/p/d.txt")
    #expect(change.diffs.isEmpty)
    #expect(!change.isNewFile)
  }

  @Test func aPatchOfSeveralFilesIsOneChangeEach() {
    let changes = FileChange.each(edits: [
      FileEdit(path: "/p/a.txt", change: .patch("@@ -1,1 +1,1 @@\n-two\n+TWO\n")),
      FileEdit(path: "/p/b.txt", change: .delete(content: "bye\n")),
      FileEdit(path: "/p/a.txt", change: .patch("@@ -5,1 +5,1 @@\n-x\n+y\n")),
    ])
    #expect(changes.map(\.path) == ["/p/a.txt", "/p/b.txt"])
    #expect(changes[0].diffs.count == 2)
    #expect(changes[1].isDeleted)
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter DiffTests`
Expected: FAIL to build, `type 'FileEdit.Change' has no member 'delete'`.

- [ ] **Step 3: Add the cases** in `ToolKind.swift`, after `case patch(String)`:

```swift
    /// Codex's delete: the content the file had.
    case delete(content: String)
    /// Codex's rename: where the file went, and its hunks when it changed too (a pure
    /// rename has none).
    case move(to: String, patch: String)
```

- [ ] **Step 4: Draw them** in `Diff.swift`'s `FileChange`:

Add the properties after `isNewFile`:

```swift
  /// A Codex delete: every line went.
  public var isDeleted = false
  /// Where a Codex rename took the file.
  public var movedTo: String?
```

In `init?(path:edits:existing:)`, keep the local `isNewFile` and add `var isDeleted = false` and `var movedTo: String?` beside it; add the cases to the `switch`:

```swift
      case .delete(let content):
        var removed = content.split(separator: "\n", omittingEmptySubsequences: false)
        if removed.last == "" { removed.removeLast() }
        diffs.append(removed.map { DiffLine(.removed, String($0)) })
        isDeleted = true
      case .move(let target, let patch):
        movedTo = target
        if !patch.isEmpty { diffs.append(PatchText.lines(patch).lines) }
```

and after `self.isNewFile = isNewFile`:

```swift
    self.isDeleted = isDeleted
    self.movedTo = movedTo
```

Then add, after `removedCount`:

```swift
  /// One change per file the edits touch, in the order first touched: a Codex patch can
  /// change several files in one call. Claude's calls touch one file each.
  public static func each(edits: [FileEdit]) -> [FileChange] {
    var order: [String] = []
    var byPath: [String: [FileEdit]] = [:]
    for edit in edits {
      if byPath[edit.path] == nil { order.append(edit.path) }
      byPath[edit.path, default: []].append(edit)
    }
    return order.compactMap { path in byPath[path].flatMap { FileChange(path: path, edits: $0) } }
  }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter DiffTests`, then `make -C apps/apple test`.
Expected: PASS; the existing goldens unchanged.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/ToolKind.swift apps/apple/Packages/DrakarKit/Sources/DrakarKit/Diff.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/DiffTests.swift
git commit -m "feat(apple): draw deletes, renames and one diff per file"
```

---

### Task 4: `CodexTranslator`, completed

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexTranslator.swift`
- Modify: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift`, `CodexTranslatorTests.swift`
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexGoldenTests.swift`, `Goldens/codexTurn.json`, `Goldens/codexFileChanges.json`, `Goldens/codexSteer.json`, `Goldens/codexHistory.json` (recorded)

**Interfaces:**
- Consumes: `CodexRPC.ID`, `CodexPolicy.acceptForSession`, `FileEdit.Change.delete`/`.move`, `EditorSelection.label(context:)`, `AttachmentPreview(kind:name:thumbnail:)`.
- Produces: `CodexTranslator.translate(_:at:)` (now also: `userMessage` → `.queue(id:, .started)`, `error` → `.retrying` / failure note, approval suggestions); `static func history(_ entries: [JSONValue]) -> [AgentEvent]`; `Fixture.codexFileChanges`, `.codexSteer`, `Fixture.codexItemsPage: JSONValue`.

- [ ] **Step 1: Name the new fixtures** in `Fixture.swift`, after `case codexTurn`:

```swift
  /// One `apply_patch` (codex-cli 0.160.1, 2026-10-07): `a.txt` updated, `b.txt` deleted,
  /// `c.txt` renamed to `d.txt`, after an approval answered `accept`. Hand-trimmed from a
  /// capture, ids and paths placeholders.
  case codexFileChanges = "codex-file-changes"
  /// A turn running `sleep 6` with a prompt steered into it (2026-10-07): each `userMessage`
  /// carries the `clientUserMessageId` it was sent with, `prompt-1` and `prompt-2`.
  case codexSteer = "codex-steer"
```

and after the `messages` property:

```swift
  /// One `thread/items/list` page (2026-10-07): a prompt, a commentary, a declined file
  /// change, the answer. JSON, not lines.
  static var codexItemsPage: JSONValue {
    get throws {
      let url = try #require(
        Bundle.module.url(
          forResource: "codex-items-page", withExtension: "json", subdirectory: "Fixtures"))
      return try JSONValue.parse(Data(contentsOf: url))
    }
  }
```

- [ ] **Step 2: Write the failing tests** (append inside `CodexTranslatorTests`)

```swift
  private func foldFile(_ fixture: Fixture, queued: [QueuedPrompt] = []) throws -> Transcript {
    var translator = CodexTranslator()
    var transcript = Transcript()
    transcript.addPrompt("go")
    for prompt in queued { transcript.queue(prompt) }
    for line in try fixture.lines {
      for event in translator.translate(try JSONValue.parse(line), at: nil) {
        transcript.apply(event)
      }
    }
    return transcript
  }

  @Test func aPatchUpdatesDeletesAndRenames() throws {
    let t = try foldFile(.codexFileChanges)
    guard case .tool(let call) = t.entries[1].kind, case .fileChange(_, let edits) = call.kind
    else {
      Issue.record("\(t.entries)")
      return
    }
    let changes = FileChange.each(edits: edits)
    #expect(changes.map(\.path) == ["/Users/me/project/a.txt", "/Users/me/project/b.txt", "/Users/me/project/c.txt"])
    #expect(changes[0].addedCount == 1 && changes[0].removedCount == 1)
    #expect(changes[1].isDeleted && changes[1].removedCount == 1)
    #expect(changes[2].movedTo == "/Users/me/project/d.txt")
    #expect(changes[2].diffs.isEmpty)
    #expect(call.result?.isError == false)
  }

  @Test func aFileChangeOffersAcceptingForTheSession() throws {
    var translator = CodexTranslator()
    var events: [AgentEvent] = []
    for line in try Fixture.codexFileChanges.lines.prefix(6) {
      events += translator.translate(try JSONValue.parse(line), at: nil)
    }
    guard case .permissionRequested(let pending)? = events.last else {
      Issue.record("\(events)")
      return
    }
    #expect(pending.requestID == "0")
    #expect(pending.request.suggestions == [CodexPolicy.acceptForSession])
  }

  @Test func aSteeredPromptLeavesTheQueueWhenCodexTakesIt() throws {
    let t = try foldFile(
      .codexSteer,
      queued: [QueuedPrompt(uuid: "prompt-2", text: "Also add the word BETA to your reply.")])
    #expect(t.queuedPrompts.isEmpty)
    #expect(t.entries.map(\.kind).contains(.prompt("Also add the word BETA to your reply.")))
    #expect(t.entries.last?.kind == .text("ALPHA BETA"))
    #expect(t.turnEnd == .completed)
  }

  @Test func aRetryShowsUntilTheNextLine() throws {
    let retrying = try fold([
      #"{"method":"error","params":{"error":{"message":"Overloaded"},"willRetry":true,"threadId":"t","turnId":"turn-1"}}"#
    ])
    #expect(retrying.retry != nil)
    let resumed = try fold([
      #"{"method":"error","params":{"error":{"message":"Overloaded"},"willRetry":true,"threadId":"t","turnId":"turn-1"}}"#,
      #"{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"turn-1","itemId":"m","delta":"x"}}"#,
    ])
    #expect(resumed.retry == nil)
    let given = try fold([
      #"{"method":"error","params":{"error":{"message":"Usage limit reached"},"willRetry":false,"threadId":"t","turnId":"turn-1"}}"#
    ])
    #expect(given.entries.last?.kind == .failure("Usage limit reached"))
  }

  @Test func historyFoldsAPage() throws {
    var t = Transcript()
    for event in CodexTranslator.history(try Fixture.codexItemsPage["data"]?.arrayValue ?? []) {
      t.apply(event)
    }
    let kinds = t.entries.map(\.kind)
    #expect(kinds.first == .notice("Codex keeps no record of commands that were declined."))
    #expect(
      kinds[1]
        == .prompt(
          "Run `cat a.txt`, then create e.txt containing hi with apply_patch, then reply OK."))
    #expect(kinds[2] == .text("I’ll read `a.txt`, then create `e.txt` containing `hi`.\n"))
    guard case .tool(let call) = kinds[3] else {
      Issue.record("\(kinds)")
      return
    }
    #expect(call.result?.isError == true)
    #expect(kinds[4] == .text("Both actions were rejected; I couldn’t read `a.txt` or create `e.txt`."))
    #expect(!t.isRunning)
    #expect(t.turnEnd == .completed)
  }

  @Test func historyReadsContextAndAttachmentsBack() throws {
    let selection =
      "<ide_opened_file>The user opened the file /p/a.swift in the IDE. This may or may not be related to the current task.</ide_opened_file>"
    let entry: JSONValue = .object([
      "turnId": .string("turn-1"),
      "item": .object([
        "type": .string("userMessage"), "id": .string("u"), "clientId": .null,
        "content": .array([
          CodexInput.text(selection), CodexInput.text("Look"),
          .object(["type": .string("image"), "url": .string("data:image/png;base64,AAAA")]),
          CodexInput.text("<attachment name=\"notes.txt\">\nhi\n</attachment>"),
        ]),
      ]),
    ])
    var t = Transcript()
    for event in CodexTranslator.history([entry]) { t.apply(event) }
    let prompt = try #require(t.entries.first { if case .prompt = $0.kind { true } else { false } })
    #expect(prompt.kind == .prompt("Look"))
    #expect(prompt.context == "a.swift")
    #expect(prompt.attachments.map(\.kind) == [.image, .text])
    #expect(prompt.attachments.last?.name == "notes.txt")
  }
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexTranslatorTests`
Expected: FAIL to build, `type 'CodexTranslator' has no member 'history'`.

- [ ] **Step 4: Replace `CodexTranslator.swift`** with:

```swift
import Foundation

/// Codex's app-server (docs/codex-app-server.md) as agent events: live lines through
/// `translate`, a thread's stored items through `history`. Only what was verified against
/// codex-cli 0.160.1 on 2026-10-06 and 2026-10-07, except `error`, from the types.
///
/// Codex is item-based: `item/started`, deltas by item id, `item/completed`. A tool's result
/// is its own item's completion. Approvals are JSON-RPC requests whose id answers them.
public struct CodexTranslator: Sendable {
  /// File changes by item id, which an approval request names without describing.
  private var fileChanges: [String: ToolKind] = [:]
  /// Reasoning items that started empty, placed only once their summary streams: at low
  /// effort they arrive empty and stay so (docs/codex-app-server.md).
  private var unplacedReasoning: Set<String> = []
  /// Reasoning items the transcript has, until they complete.
  private var placedReasoning: Set<String> = []
  /// An `error` said Codex retries: the next line says it is over.
  private var isRetrying = false

  public init() {}

  public mutating func translate(_ message: JSONValue, at time: Date?) -> [AgentEvent] {
    guard let method = message["method"]?.stringValue else { return [] }
    let params = message["params"] ?? .null
    if method == "error" {
      let text = params["error"]?["message"]?.stringValue ?? String(localized: "Codex failed.")
      guard params["willRetry"]?.boolValue == true else {
        isRetrying = false
        return [.retrying(nil), .note(.init(text: text, isFailure: true))]
      }
      isRetrying = true
      return [.retrying(APIRetry(attempt: nil, maxRetries: nil, delayMS: nil))]
    }
    var events: [AgentEvent] = []
    if isRetrying {
      isRetrying = false
      events.append(.retrying(nil))
    }
    switch method {
    case "thread/started":
      guard let thread = params["thread"], let id = thread["id"]?.stringValue else { break }
      events.append(
        .sessionStarted(
          SessionInfo(
            sessionID: id, cwd: thread["cwd"]?.stringValue, model: thread["model"]?.stringValue,
            agentVersion: thread["cliVersion"]?.stringValue)))
    case "item/started":
      events += item(params["item"], completed: false)
    case "item/completed":
      events += item(params["item"], completed: true)
    case "item/agentMessage/delta":
      guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue
      else { break }
      events.append(.itemDelta(id: id, .text(delta)))
    case "item/reasoning/summaryPartAdded":
      guard let id = params["itemId"]?.stringValue, let index = params["summaryIndex"]?.intValue,
        index > 0
      else { break }
      events.append(.itemDelta(id: id, .thinking("\n\n")))
    case "item/reasoning/summaryTextDelta":
      guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue
      else { break }
      if unplacedReasoning.remove(id) != nil {
        placedReasoning.insert(id)
        events.append(.itemStarted(AgentEvent.Item(id: id, parent: nil, kind: .thinking(""))))
      }
      events.append(.itemDelta(id: id, .thinking(delta)))
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      events += approval(method: method, id: message["id"], params: params)
    case "serverRequest/resolved":
      guard let id = CodexRPC.ID(params["requestId"]) else { break }
      events.append(.permissionWithdrawn(requestID: id.text))
    case "thread/tokenUsage/updated":
      guard let usage = params["tokenUsage"], let last = usage["last"],
        let input = last["inputTokens"]?.intValue, let output = last["outputTokens"]?.intValue
      else { break }
      let cached = last["cachedInputTokens"]?.intValue ?? 0
      events.append(
        .usage(
          .init(
            messageID: params["turnId"]?.stringValue ?? "",
            usage: TokenUsage(
              input: input - cached, cacheCreation: last["cacheWriteInputTokens"]?.intValue ?? 0,
              cacheRead: cached, output: output),
            model: nil, window: usage["modelContextWindow"]?.intValue, at: nil)))
    case "turn/completed":
      let turn = params["turn"] ?? .null
      let outcome: Transcript.TurnEnd =
        switch turn["status"]?.stringValue {
        case "interrupted": .interrupted
        case "failed": .failed
        default: .completed
        }
      events.append(
        .turnEnded(
          TurnSummary(
            outcome: outcome, failureText: turn["error"]?["message"]?.stringValue,
            durationMS: turn["durationMs"]?.intValue)))
    default:
      break
    }
    return events
  }

  /// A thread's stored items (`thread/items/list` entries, `{turnId, item, …}`), oldest
  /// first, as a finished conversation: each turn opened by its prompt and closed as
  /// completed. Codex keeps no declined command, which a notice says once.
  public static func history(_ entries: [JSONValue]) -> [AgentEvent] {
    guard !entries.isEmpty else { return [] }
    var translator = CodexTranslator()
    var events: [AgentEvent] = [
      .note(.init(text: String(localized: "Codex keeps no record of commands that were declined.")))
    ]
    var turn: String?
    for entry in entries {
      let id = entry["turnId"]?.stringValue
      if let turn, id != turn { events.append(.turnOutcome(.completed)) }
      turn = id
      guard let item = entry["item"] else { continue }
      if item["type"] == .string("userMessage") {
        events.append(.prompt(prompt(item["content"]?.arrayValue ?? []), running: false))
      } else {
        events += translator.item(item, completed: true)
      }
    }
    events.append(.turnOutcome(.completed))
    return events
  }

  /// A stored prompt's input read back: the editor's context as its label, `<attachment>`
  /// text and images as previews, the rest as the prompt.
  private static func prompt(_ content: [JSONValue]) -> AgentEvent.Prompt {
    var texts: [String] = []
    var labels: [String] = []
    var attachments: [AttachmentPreview] = []
    for input in content {
      switch input["type"]?.stringValue {
      case "text":
        let text = input["text"]?.stringValue ?? ""
        if let label = EditorSelection.label(context: text) {
          labels.append(label)
        } else if text.hasPrefix("<attachment name=\"") {
          let name = text.dropFirst("<attachment name=\"".count).prefix { $0 != "\"" }
          attachments.append(AttachmentPreview(kind: .text, name: String(name), thumbnail: nil))
        } else {
          texts.append(text)
        }
      case "image", "localImage":
        attachments.append(AttachmentPreview(kind: .image, name: nil, thumbnail: nil))
      default:
        break
      }
    }
    return AgentEvent.Prompt(
      text: texts.joined(separator: "\n\n"),
      context: labels.isEmpty ? nil : labels.joined(separator: ", "), attachments: attachments)
  }

  private mutating func item(_ item: JSONValue?, completed: Bool) -> [AgentEvent] {
    guard let item, let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else {
      return []
    }
    func placed(_ kind: AgentEvent.ItemKind) -> AgentEvent {
      let item = AgentEvent.Item(id: id, parent: nil, kind: kind)
      return completed ? .itemCompleted(item) : .itemStarted(item)
    }
    switch type {
    case "userMessage":
      // The session's own prompt is shown already; one it steered into a running turn
      // leaves the queue when Codex takes it, which the echoed id says.
      guard !completed, let client = item["clientId"]?.stringValue else { return [] }
      return [.queue(id: client, .started)]
    case "agentMessage":
      return [placed(.text(item["text"]?.stringValue ?? ""))]
    case "reasoning":
      let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue)
      let text = summary.joined(separator: "\n\n")
      if completed {
        unplacedReasoning.remove(id)
        // An empty completion still ends one that streamed: the transcript keeps its text.
        guard placedReasoning.remove(id) != nil || !text.isEmpty else { return [] }
      } else if text.isEmpty {
        unplacedReasoning.insert(id)
        return []
      } else {
        placedReasoning.insert(id)
      }
      return [placed(.thinking(text))]
    case "commandExecution":
      let command = item["command"]?.stringValue ?? ""
      let kind = Self.kind(command: command, actions: item["commandActions"]?.arrayValue ?? [])
      var events = [
        placed(
          .tool(
            .init(id: id, name: "Shell", input: .object(["command": .string(command)]), kind: kind))
        )
      ]
      if completed {
        let status = item["status"]?.stringValue
        events.append(
          .toolResult(
            callID: id,
            .init(
              content: item["aggregatedOutput"]?.stringValue
                ?? (status == "completed" ? "" : status ?? ""),
              isError: status != "completed" || (item["exitCode"]?.intValue ?? 0) != 0)))
      }
      return events
    case "fileChange":
      let changes = item["changes"]?.arrayValue ?? []
      let edits = changes.compactMap(Self.edit)
      let kind: ToolKind = edits.first.map { .fileChange(path: $0.path, edits: edits) } ?? .other
      fileChanges[id] = kind
      var events = [
        placed(.tool(.init(id: id, name: "Edit", input: .array(changes), kind: kind)))
      ]
      if completed {
        let status = item["status"]?.stringValue
        events.append(
          .toolResult(callID: id, .init(content: status ?? "", isError: status != "completed")))
      }
      return events
    case "contextCompaction":
      return [
        .compaction(
          completed
            ? .finished(note: String(localized: "Conversation compacted"), at: nil) : .started)
      ]
    default:
      // The rest is unverified.
      return []
    }
  }

  /// One file of a patch (verified 2026-10-07): an add's diff is the new content, an
  /// update's header-less hunks, a delete's the old content, a pure rename's the line
  /// "Moved to: <path>" and no hunks.
  static func edit(_ change: JSONValue) -> FileEdit? {
    guard let path = change["path"]?.stringValue, let diff = change["diff"]?.stringValue else {
      return nil
    }
    let kind = change["kind"]
    switch kind?["type"]?.stringValue {
    case "delete":
      return FileEdit(path: path, change: .delete(content: diff))
    case "update":
      if let target = kind?["move_path"]?.stringValue {
        let hunks =
          diff.range(of: "\n\nMoved to: ", options: .backwards).map { String(diff[..<$0.lowerBound]) }
          ?? diff
        return FileEdit(path: path, change: .move(to: target, patch: hunks))
      }
      return FileEdit(path: path, change: .patch(diff))
    default:
      return FileEdit(path: path, change: .patch(diff))
    }
  }

  private func approval(method: String, id: JSONValue?, params: JSONValue) -> [AgentEvent] {
    guard let requestID = CodexRPC.ID(id)?.text else { return [] }
    let itemID = params["itemId"]?.stringValue
    var request: PermissionRequest
    if method == "item/fileChange/requestApproval" {
      request = PermissionRequest(
        toolName: "Edit", input: .object([:]), description: params["reason"]?.stringValue,
        toolUseID: itemID, kind: itemID.flatMap { fileChanges[$0] } ?? .other)
      // File changes take `acceptForSession` (types); requests list none (verified).
      request.suggestions = [CodexPolicy.acceptForSession]
    } else {
      let command = params["command"]?.stringValue ?? ""
      let kind = Self.kind(command: command, actions: params["commandActions"]?.arrayValue ?? [])
      request = PermissionRequest(
        toolName: "Shell", input: .object(["command": .string(command)]),
        description: params["reason"]?.stringValue, toolUseID: itemID, kind: kind)
      if params["availableDecisions"]?.arrayValue?.contains(.string("acceptForSession")) == true {
        request.suggestions = [CodexPolicy.acceptForSession]
      }
    }
    return [.permissionRequested(.init(requestID: requestID, request: request))]
  }

  /// A single parsed action says what the command is for; anything else is the command,
  /// as it was asked for rather than as the shell wraps it.
  static func kind(command: String, actions: [JSONValue]) -> ToolKind {
    if actions.count == 1, let action = actions.first {
      switch action["type"]?.stringValue {
      case "read":
        if let path = action["path"]?.stringValue { return .read(path: path) }
      case "search", "listFiles":
        if let query = action["query"]?.stringValue ?? action["path"]?.stringValue {
          return .search(pattern: query)
        }
      default: break
      }
      if let asked = action["command"]?.stringValue { return .shell(command: asked) }
    }
    return .shell(command: command)
  }
}
```

`PermissionRequest.suggestions` must be settable from DrakarKit (it is `public var`); `Transcript.PendingPermission(requestID:request:)` is the initializer the slice 1 code already uses. If `AgentEvent.Prompt` has no `context:` label in its initializer, it does: `init(text:context:attachments:)`.

- [ ] **Step 5: Run the translator tests**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexTranslatorTests`
Expected: PASS, the slice 1 tests included.

- [ ] **Step 6: Write the Codex goldens' suite** `CodexGoldenTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

/// Every Codex capture, folded by the transcript as it was recorded on 2026-10-07 when Codex
/// sessions arrived. A failure here is a regression in what a Codex session shows. Re-record
/// (`DRAKAR_RECORD_GOLDENS=1 swift test --filter CodexGoldenTests`) only for a change meant to
/// be seen, reading the JSON diff before committing it.
@Suite("The transcript folds every Codex capture as it did")
struct CodexGoldenTests {
  enum Scenario: String, CaseIterable, CustomTestStringConvertible {
    case codexTurn, codexFileChanges, codexSteer, codexHistory

    var testDescription: String { rawValue }
  }

  static func fold(_ scenario: Scenario) throws -> (running: Transcript, exited: Transcript) {
    let start = TranscriptGoldenTests.start
    var transcript = Transcript()
    if scenario == .codexHistory {
      for event in CodexTranslator.history(try Fixture.codexItemsPage["data"]?.arrayValue ?? []) {
        transcript.apply(event, at: start)
      }
      return (transcript, transcript)
    }
    let fixture: Fixture =
      switch scenario {
      case .codexTurn: .codexTurn
      case .codexFileChanges: .codexFileChanges
      case .codexSteer, .codexHistory: .codexSteer
      }
    transcript.addPrompt("Run it", at: start)
    if scenario == .codexSteer {
      transcript.queue(QueuedPrompt(uuid: "prompt-2", text: "Also add the word BETA to your reply."))
    }
    var translator = CodexTranslator()
    for (offset, line) in try fixture.lines.enumerated() {
      let time = start.addingTimeInterval(Double(offset + 1))
      for event in translator.translate(try JSONValue.parse(line), at: time) {
        transcript.apply(event, at: time)
      }
    }
    var exited = transcript
    exited.processExited()
    return (transcript, exited)
  }

  static func goldenURL(_ scenario: Scenario) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "Goldens/\(scenario.rawValue).json")
  }

  @Test(arguments: Scenario.allCases)
  func foldsAsRecorded(_ scenario: Scenario) throws {
    let (running, exited) = try Self.fold(scenario)
    let now = TranscriptGoldenTests.now
    let golden = TranscriptGoldenTests.Golden(
      running: TranscriptSnapshot(running, now: now),
      exited: TranscriptSnapshot(exited, now: now))
    let url = Self.goldenURL(scenario)
    if ProcessInfo.processInfo.environment["DRAKAR_RECORD_GOLDENS"] == "1" {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(golden).write(to: url)
      // A recording run compares nothing, so it must never pass.
      Issue.record("recorded \(scenario.rawValue), not compared")
      return
    }
    let recorded = try JSONDecoder().decode(
      TranscriptGoldenTests.Golden.self, from: Data(contentsOf: url))
    #expect(golden.running == recorded.running)
    #expect(golden.exited == recorded.exited)
  }
}
```

- [ ] **Step 7: Record the Codex goldens, and only them**

Run: `cd apps/apple/Packages/DrakarKit && DRAKAR_RECORD_GOLDENS=1 swift test --filter CodexGoldenTests; cd -`
Expected: 4 issues "recorded …, not compared". Then `git status --short apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Goldens` lists exactly the four new `codex*.json` files. Read each: `codexFileChanges` shows the patch's tool entry and "DONE"; `codexSteer` shows both prompts and "ALPHA BETA"; `codexHistory` the notice, the prompt, two texts and the declined change. If any existing golden appears modified, stop: that is a regression.

- [ ] **Step 8: Run everything**

Run: `make -C apps/apple test`
Expected: PASS, the Claude goldens untouched.

- [ ] **Step 9: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexTranslator.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexTranslatorTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexGoldenTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Goldens/codexTurn.json apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Goldens/codexFileChanges.json apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Goldens/codexSteer.json apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Goldens/codexHistory.json
git commit -m "feat(apple): translate Codex steers, patches, retries and history"
```

---

### Task 5: `CodexSession`

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexSession.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexSessionTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2 and 4.
- Produces:
  - `CodexSession.init(cwd: String, resuming: String?, mode: PermissionMode, model: String?, effort: String?, version: String)`
  - `mutating func start() -> Step`, `send(_: Command) -> Step`, `receive(_: JSONValue, at: Date?) -> Step`
  - `enum Command { case prompt(input: JSONValue, uuid: String), answer(requestID: String, decision: PermissionDecision), interrupt, setMode(PermissionMode), setModel(String), setEffort(String), rename(String) }`
  - `enum Signal { case models([ModelOption]), thread(id: String, path: String?, codexHome: String?), modeAdopted(String), unusable(String) }`
  - `struct Step { var writes: [JSONValue]; var events: [AgentEvent]; var signals: [Signal] }`
  - `static func initializeParams(version: String) -> JSONValue`, `static let notSignedIn: String`, `static let heldElsewhere: String`

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("A Codex session as a state machine")
struct CodexSessionTests {
  private func json(_ text: String) -> JSONValue { (try? JSONValue.parse(Data(text.utf8))) ?? .null }
  private func methods(_ step: CodexSession.Step) -> [String] {
    step.writes.compactMap { $0["method"]?.stringValue }
  }
  private func write(_ method: String, in step: CodexSession.Step) throws -> JSONValue {
    try #require(step.writes.first { $0["method"]?.stringValue == method })
  }
  /// Answers our request `write` with `result`.
  private func answer(_ session: inout CodexSession, _ write: JSONValue, _ result: String)
    -> CodexSession.Step
  {
    let id = write["id"]?.intValue ?? -1
    return session.receive(json(#"{"id":\#(id),"result":\#(result)}"#), at: nil)
  }
  private func fail(_ session: inout CodexSession, _ write: JSONValue, _ message: String)
    -> CodexSession.Step
  {
    let id = write["id"]?.intValue ?? -1
    return session.receive(
      json(#"{"id":\#(id),"error":{"code":-32600,"message":"\#(message)"}}"#), at: nil)
  }
  private let thread =
    #"{"thread":{"id":"t-1","cwd":"/p","model":"gpt-6-astra","cliVersion":"0.160.1","path":"/home/.codex/sessions/r.jsonl"},"model":"gpt-6-astra"}"#
  private func input(_ text: String) -> JSONValue { .array([CodexInput.text(text)]) }

  /// A session past `initialize`.
  private func initialized(resuming: String? = nil, mode: PermissionMode = .ask)
    -> (CodexSession, CodexSession.Step)
  {
    var session = CodexSession(
      cwd: "/p", resuming: resuming, mode: mode, model: nil, effort: nil, version: "1.0")
    let start = session.start()
    let step = answer(&session, start.writes[0], #"{"codexHome":"/home/.codex"}"#)
    return (session, step)
  }

  /// A session whose thread runs, with a turn `turn-1` running from prompt `p-1`.
  private func running() throws -> CodexSession {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(&session, try write("thread/start", in: opening), thread)
    _ = answer(&session, try write("turn/start", in: started), #"{"turn":{"id":"turn-1"}}"#)
    return session
  }

  @Test func startsWithInitializeAloneThenTheRest() throws {
    var session = CodexSession(cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0")
    let start = session.start()
    #expect(methods(start) == ["initialize"])
    #expect(
      start.writes[0]["params"]?["capabilities"]?["optOutNotificationMethods"]
        == .array([.string("mcpServer/startupStatus/updated")]))
    let (_, step) = initialized()
    #expect(methods(step) == ["initialized", "account/read", "model/list"])
  }

  @Test func aFirstPromptOpensTheThreadThenStartsATurn() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let start = try write("thread/start", in: opening)
    #expect(start["params"]?["cwd"] == .string("/p"))
    #expect(start["params"]?["approvalPolicy"] == .string("untrusted"))
    #expect(start["params"]?["sandbox"] == .string("workspace-write"))
    #expect(start["params"]?["model"] == nil)
    let started = answer(&session, start, thread)
    #expect(
      started.events.first
        == .sessionStarted(
          SessionInfo(sessionID: "t-1", cwd: "/p", model: "gpt-6-astra", agentVersion: "0.160.1")))
    #expect(
      started.signals
        == [
          .thread(id: "t-1", path: "/home/.codex/sessions/r.jsonl", codexHome: "/home/.codex"),
          .modeAdopted("default"),
        ])
    let turn = try write("turn/start", in: started)
    #expect(turn["params"]?["threadId"] == .string("t-1"))
    #expect(turn["params"]?["clientUserMessageId"] == .string("p-1"))
    #expect(turn["params"]?["input"] == input("one"))
    #expect(turn["params"]?["sandboxPolicy"]?["type"] == .string("workspaceWrite"))
    #expect(turn["params"]?["effort"] == nil)
  }

  @Test func aPromptBeforeInitializeWaitsForIt() throws {
    var session = CodexSession(cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0")
    let start = session.start()
    #expect(session.send(.prompt(input: input("one"), uuid: "p-1")).writes.isEmpty)
    let step = answer(&session, start.writes[0], "{}")
    #expect(methods(step) == ["initialized", "account/read", "model/list", "thread/start"])
  }

  @Test func aResumePassesItsSettingsAgain() throws {
    var (session, _) = initialized(resuming: "t-1", mode: .acceptEdits)
    _ = session.send(.setModel("gpt-6.1-sol"))
    let resume = try write("thread/resume", in: session.send(.prompt(input: input("x"), uuid: "p")))
    #expect(resume["params"]?["threadId"] == .string("t-1"))
    #expect(resume["params"]?["excludeTurns"] == .bool(true))
    #expect(resume["params"]?["approvalPolicy"] == .string("on-request"))
    #expect(resume["params"]?["model"] == .string("gpt-6.1-sol"))
  }

  @Test func aPromptMidTurnIsSteeredAndLeavesTheQueueWhenEchoed() throws {
    var session = try running()
    let steer = try write("turn/steer", in: session.send(.prompt(input: input("two"), uuid: "p-2")))
    #expect(steer["params"]?["expectedTurnId"] == .string("turn-1"))
    #expect(steer["params"]?["clientUserMessageId"] == .string("p-2"))
    let echo = session.receive(
      json(
        #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"u2","clientId":"p-2","content":[]},"threadId":"t-1","turnId":"turn-1"}}"#
      ), at: nil)
    #expect(echo.events == [.queue(id: "p-2", .started)])
    let end = session.receive(
      json(#"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"completed"}}}"#),
      at: nil)
    #expect(!end.events.contains(.queue(id: "p-2", .dropped(agent: "Codex"))))
  }

  /// Review Focus 4.
  @Test func aSteerTooLateStartsATurnOfItsOwn() throws {
    var session = try running()
    let steer = try write("turn/steer", in: session.send(.prompt(input: input("two"), uuid: "p-2")))
    let retried = fail(&session, steer, "no active turn to steer")
    let turn = try write("turn/start", in: retried)
    #expect(turn["params"]?["clientUserMessageId"] == .string("p-2"))
    #expect(turn["params"]?["input"] == input("two"))
  }

  @Test func aSteerAnInterruptCutShortIsDropped() throws {
    var session = try running()
    _ = session.send(.prompt(input: input("two"), uuid: "p-2"))
    let end = session.receive(
      json(#"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"interrupted"}}}"#),
      at: nil)
    #expect(end.events.last == .queue(id: "p-2", .dropped(agent: "Codex")))
  }

  /// Review Focus 1.
  @Test func aSecondPromptWhileTheThreadOpensJoinsTheFirstTurn() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    #expect(session.send(.prompt(input: input("two"), uuid: "p-2")).writes.isEmpty)
    let started = answer(&session, try write("thread/start", in: opening), thread)
    #expect(methods(started) == ["turn/start"])
    let running = answer(&session, try write("turn/start", in: started), #"{"turn":{"id":"turn-1"}}"#)
    let steer = try write("turn/steer", in: running)
    #expect(steer["params"]?["clientUserMessageId"] == .string("p-2"))
    #expect(steer["params"]?["expectedTurnId"] == .string("turn-1"))
  }

  /// Review Focus 2.
  @Test func stopBeforeTheTurnHasAnIdInterruptsWhenItDoes() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(&session, try write("thread/start", in: opening), thread)
    #expect(session.send(.interrupt).writes.isEmpty)
    let running = session.receive(
      json(#"{"method":"turn/started","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"inProgress"}}}"#),
      at: nil)
    let interrupt = try write("turn/interrupt", in: running)
    #expect(interrupt["params"]?["turnId"] == .string("turn-1"))
    _ = started
  }

  @Test func stopCancelsAWaitingApprovalThenInterrupts() throws {
    var session = try running()
    let asked = session.receive(
      json(#"{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"t-1","turnId":"turn-1","itemId":"exec-1","command":"/bin/zsh -lc 'touch x'","commandActions":[]}}"#),
      at: nil)
    #expect(asked.events.count == 1)
    let stop = session.send(.interrupt)
    #expect(stop.writes.first == CodexRPC.answer(.number(0), result: .object(["decision": .string("cancel")])))
    #expect(try write("turn/interrupt", in: stop)["params"]?["turnId"] == .string("turn-1"))
  }

  @Test func answersMapOntoCodexDecisions() throws {
    var session = try running()
    for (id, decision, expected) in [
      (0, PermissionDecision.allow(updatedInput: .null), "accept"),
      (1, .allow(updatedInput: .null, updatedPermissions: [CodexPolicy.acceptForSession]), "acceptForSession"),
      (2, .deny(message: "no"), "decline"),
    ] {
      _ = session.receive(
        json(#"{"method":"item/fileChange/requestApproval","id":\#(id),"params":{"threadId":"t-1","turnId":"turn-1","itemId":"p"}}"#),
        at: nil)
      let step = session.send(.answer(requestID: String(id), decision: decision))
      #expect(step.writes == [CodexRPC.answer(.number(id), result: .object(["decision": .string(expected)]))])
    }
  }

  /// Review Focus 3.
  @Test func anAnswerToARequestNoLongerWaitingWritesNothing() throws {
    var session = try running()
    _ = session.receive(
      json(#"{"method":"item/fileChange/requestApproval","id":0,"params":{"threadId":"t-1","turnId":"turn-1","itemId":"p"}}"#),
      at: nil)
    _ = session.receive(
      json(#"{"method":"serverRequest/resolved","params":{"threadId":"t-1","requestId":0}}"#), at: nil)
    #expect(session.send(.answer(requestID: "0", decision: .allow(updatedInput: .null))).writes.isEmpty)
    #expect(session.send(.answer(requestID: "9", decision: .allow(updatedInput: .null))).writes.isEmpty)
  }

  @Test func anUnknownRequestIsRefusedAndNoted() throws {
    var session = try running()
    let step = session.receive(
      json(#"{"method":"item/tool/requestUserInput","id":4,"params":{"threadId":"t-1"}}"#), at: nil)
    #expect(step.writes.first?["id"] == .number(4))
    #expect(step.writes.first?["error"]?["code"] == .number(-32601))
    guard case .note(let note)? = step.events.first else {
      Issue.record("\(step.events)")
      return
    }
    #expect(note.text.contains("item/tool/requestUserInput"))
  }

  @Test func notSignedInMakesTheSessionUnusable() throws {
    var session = CodexSession(cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0")
    let start = session.start()
    let step = answer(&session, start.writes[0], "{}")
    let account = try write("account/read", in: step)
    #expect(
      answer(&session, account, #"{"account":null,"requiresOpenaiAuth":true}"#).signals
        == [.unusable(CodexSession.notSignedIn)])
    var signedIn = CodexSession(cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0")
    let opened = signedIn.start()
    let again = answer(&signedIn, opened.writes[0], "{}")
    #expect(
      answer(&signedIn, try write("account/read", in: again), #"{"account":{"type":"chatgpt"},"requiresOpenaiAuth":true}"#)
        .signals.isEmpty)
  }

  @Test func theModelListComesAsASignal() throws {
    var (session, step) = initialized()
    let models = answer(
      &session, try write("model/list", in: step),
      #"{"data":[{"id":"m","model":"m","displayName":"M","supportedReasoningEfforts":[]}]}"#)
    #expect(models.signals == [.models([ModelOption(value: "m", resolvedModel: "m", displayName: "M")])])
  }

  @Test func picksRideOnTheNextTurn() throws {
    var session = try running()
    #expect(session.send(.setMode(.acceptEdits)).writes.isEmpty)
    #expect(session.send(.setModel("gpt-6.1-sol")).writes.isEmpty)
    #expect(session.send(.setEffort("high")).writes.isEmpty)
    _ = session.receive(
      json(#"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"completed"}}}"#),
      at: nil)
    let turn = try write("turn/start", in: session.send(.prompt(input: input("x"), uuid: "p-3")))
    #expect(turn["params"]?["approvalPolicy"] == .string("on-request"))
    #expect(turn["params"]?["model"] == .string("gpt-6.1-sol"))
    #expect(turn["params"]?["effort"] == .string("high"))
  }

  @Test func aThreadAnotherProcessHoldsMakesTheSessionUnusable() throws {
    var (session, _) = initialized(resuming: "t-1")
    let resume = try write("thread/resume", in: session.send(.prompt(input: input("x"), uuid: "p")))
    #expect(
      fail(&session, resume, "thread t-1 already has an active writer").signals
        == [.unusable(CodexSession.heldElsewhere)])
  }

  @Test func aTurnThatCannotStartEndsFailed() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(&session, try write("thread/start", in: opening), thread)
    let failed = fail(&session, try write("turn/start", in: started), "Model not found")
    #expect(failed.events == [.turnEnded(TurnSummary(outcome: .failed, failureText: "Model not found"))])
    // The session takes the next prompt as a new turn.
    #expect(methods(session.send(.prompt(input: input("x"), uuid: "p-2"))) == ["turn/start"])
  }

  @Test func renameNamesTheThread() throws {
    var session = try running()
    let rename = try write("thread/name/set", in: session.send(.rename("Pineapple")))
    #expect(rename["params"] == .object(["threadId": .string("t-1"), "name": .string("Pineapple")]))
  }

  @Test func linesStillReachTheTranslator() throws {
    var session = try running()
    let step = session.receive(
      json(#"{"method":"item/agentMessage/delta","params":{"threadId":"t-1","turnId":"turn-1","itemId":"m","delta":"hi"}}"#),
      at: nil)
    #expect(step.events == [.itemDelta(id: "m", .text("hi"))])
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexSessionTests`
Expected: FAIL to build, `cannot find 'CodexSession' in scope`.

- [ ] **Step 3: Write `CodexSession.swift`**

```swift
import Foundation

/// One Codex session over `codex app-server` (docs/codex-app-server.md), with no process: each
/// command given and each line read returns what to write, what the conversation shows and
/// what the session learns. `CodexBackend` (the app) writes the lines; tests read them.
///
/// One process, one thread: the thread is started, or resumed with its settings passed again,
/// on the first prompt, and every turn after runs on it. Nothing is sent before `initialize`
/// is answered. A prompt sent while a turn runs is steered into it, named by the uuid Codex
/// echoes when it takes it; one an interrupt cut short is dropped at the turn's end.
public struct CodexSession: Sendable {
  public enum Command: Sendable, Equatable {
    /// `input` as `CodexInput.make` builds it; `uuid` names it in the transcript's queue.
    case prompt(input: JSONValue, uuid: String)
    case answer(requestID: String, decision: PermissionDecision)
    case interrupt
    /// Picks: Codex takes them with the next turn, and keeps them for the turns after.
    case setMode(PermissionMode)
    case setModel(String)
    case setEffort(String)
    case rename(String)
  }

  public enum Signal: Sendable, Equatable {
    case models([ModelOption])
    /// The thread runs: `path` its rollout file, `codexHome` where Codex keeps its files.
    case thread(id: String, path: String?, codexHome: String?)
    case modeAdopted(String)
    /// Nothing can go through: not signed in, or the thread is another process's.
    case unusable(String)
  }

  public struct Step: Sendable, Equatable {
    public var writes: [JSONValue] = []
    public var events: [AgentEvent] = []
    public var signals: [Signal] = []

    public init() {}
  }

  /// `initialize`'s params, for a session and for a short-lived process: Drakar by name, the
  /// stable API, and no MCP startup burst (222 lines in one probe).
  public static func initializeParams(version: String) -> JSONValue {
    .object([
      "clientInfo": .object([
        "name": .string("drakar"), "title": .string("Drakar"), "version": .string(version),
      ]),
      "capabilities": .object([
        "experimentalApi": .bool(false),
        "optOutNotificationMethods": .array([.string("mcpServer/startupStatus/updated")]),
      ]),
    ])
  }

  public static let notSignedIn = String(
    localized: "Codex isn't signed in. Run `codex login` in a terminal, then send again.")
  public static let heldElsewhere = String(
    localized: "This thread is open in another Codex process. Close it there, then send again.")

  private enum Call: Sendable {
    case initialize, account, models, thread, turnStart
    case steer(uuid: String, input: JSONValue)
    case other
  }

  private enum Turn: Sendable, Equatable {
    case idle
    /// `turn/start` went; Codex has not said the id.
    case starting
    case running(String)
  }

  private struct Waiting: Sendable {
    var input: JSONValue
    var uuid: String
  }

  private let cwd: String
  private let version: String
  private var threadID: String?
  private var isInitialized = false
  private var isThreadReady = false
  private var isOpeningThread = false
  private var codexHome: String?
  private var calls = CodexRPC.Calls<Call>()
  private var translator = CodexTranslator()
  private var turn = Turn.idle
  /// Prompts sent before the thread ran, oldest first.
  private var beforeThread: [Waiting] = []
  /// Prompts sent while a turn was starting, steered once it has an id.
  private var beforeTurnID: [Waiting] = []
  /// Stop was pressed while a turn was starting.
  private var interruptsWhenStarted = false
  /// Steered prompts Codex has not echoed yet, by uuid.
  private var steered: [String] = []
  /// Approval requests waiting, by the id the transcript knows them by.
  private var approvals: [String: CodexRPC.ID] = [:]
  private var mode: PermissionMode
  private var model: String?
  private var effort: String?

  /// `resuming` is the thread to resume; nil starts one. `model` and `effort` nil leave
  /// Codex's own (`config.toml`).
  public init(
    cwd: String, resuming: String?, mode: PermissionMode, model: String?, effort: String?,
    version: String
  ) {
    self.cwd = cwd
    threadID = resuming
    self.mode = mode
    self.model = model
    self.effort = effort
    self.version = version
  }

  public mutating func start() -> Step {
    var step = Step()
    step.writes.append(
      calls.make("initialize", Self.initializeParams(version: version), for: .initialize))
    return step
  }

  public mutating func send(_ command: Command) -> Step {
    var step = Step()
    switch command {
    case .prompt(let input, let uuid):
      let prompt = Waiting(input: input, uuid: uuid)
      guard isThreadReady else {
        beforeThread.append(prompt)
        if isInitialized, !isOpeningThread { step.writes.append(openThread()) }
        break
      }
      switch turn {
      case .idle: step.writes.append(startTurn(prompt))
      case .starting: beforeTurnID.append(prompt)
      case .running(let id): step.writes.append(steer(prompt, into: id))
      }
    case .answer(let requestID, let decision):
      guard let id = approvals.removeValue(forKey: requestID) else { break }
      step.writes.append(
        CodexRPC.answer(id, result: .object(["decision": CodexPolicy.decision(decision)])))
    case .interrupt:
      for key in approvals.keys.sorted() {
        if let id = approvals[key] {
          step.writes.append(
            CodexRPC.answer(id, result: .object(["decision": .string("cancel")])))
        }
      }
      approvals.removeAll()
      switch turn {
      case .running(let id): step.writes.append(interrupt(id))
      case .starting: interruptsWhenStarted = true
      case .idle: break
      }
    case .setMode(let mode):
      self.mode = mode
    case .setModel(let model):
      self.model = model
    case .setEffort(let effort):
      self.effort = effort
    case .rename(let name):
      guard isThreadReady, let threadID else { break }
      step.writes.append(
        calls.make(
          "thread/name/set",
          .object(["threadId": .string(threadID), "name": .string(name)]), for: .other))
    }
    return step
  }

  public mutating func receive(_ message: JSONValue, at time: Date?) -> Step {
    var step = Step()
    guard let line = CodexRPC.Line(message) else { return step }
    switch line {
    case .response(let id, let result):
      if let call = calls.take(id) { answered(call, result: result, into: &step) }
    case .failure(let id, let text):
      if let call = calls.take(id) { failed(call, message: text, into: &step) }
    case .request(let id, let method, _):
      if method == "item/commandExecution/requestApproval"
        || method == "item/fileChange/requestApproval"
      {
        approvals[id.text] = id
        step.events += translator.translate(message, at: time)
      } else {
        step.writes.append(CodexRPC.refusal(id, message: "Drakar does not answer \(method)."))
        step.events.append(
          .note(
            .init(
              text: String(
                localized:
                  "Codex asked for something Drakar can't answer yet (\(method)), so it was refused."
              ))))
      }
    case .notification(let method, let params):
      let endsTurn = notified(method, params: params, into: &step)
      step.events += translator.translate(message, at: time)
      if endsTurn {
        step.events += steered.map { AgentEvent.queue(id: $0, .dropped(agent: "Codex")) }
        steered = []
      }
    }
    return step
  }

  private mutating func answered(_ call: Call, result: JSONValue, into step: inout Step) {
    switch call {
    case .initialize:
      isInitialized = true
      codexHome = result["codexHome"]?.stringValue
      step.writes += [
        CodexRPC.notification("initialized"),
        calls.make("account/read", .object([:]), for: .account),
        calls.make("model/list", .object([:]), for: .models),
      ]
      if !beforeThread.isEmpty, !isOpeningThread { step.writes.append(openThread()) }
    case .account:
      // Signed in or not, `requiresOpenaiAuth` is true: not signed in is no account
      // (verified 2026-10-07).
      if result["account"] == nil || result["account"] == .null {
        step.signals.append(.unusable(Self.notSignedIn))
      }
    case .models:
      step.signals.append(.models(CodexModels.list(result)))
    case .thread:
      isOpeningThread = false
      let thread = result["thread"] ?? .null
      guard let id = thread["id"]?.stringValue else { return }
      threadID = id
      isThreadReady = true
      step.events.append(
        .sessionStarted(
          SessionInfo(
            sessionID: id, cwd: thread["cwd"]?.stringValue ?? cwd,
            model: result["model"]?.stringValue ?? thread["model"]?.stringValue,
            agentVersion: thread["cliVersion"]?.stringValue)))
      step.signals += [
        .thread(id: id, path: thread["path"]?.stringValue, codexHome: codexHome),
        .modeAdopted(mode.rawValue),
      ]
      let waiting = beforeThread
      beforeThread = []
      guard let first = waiting.first else { return }
      step.writes.append(startTurn(first))
      beforeTurnID += waiting.dropFirst()
    case .turnStart:
      if let id = result["turn"]?["id"]?.stringValue { turnStarted(id, into: &step) }
    case .steer, .other:
      break
    }
  }

  private mutating func failed(_ call: Call, message: String, into step: inout Step) {
    switch call {
    case .initialize:
      step.signals.append(.unusable(message))
    case .thread:
      isOpeningThread = false
      let waiting = beforeThread
      beforeThread = []
      if message.contains("active writer") {
        step.signals.append(.unusable(Self.heldElsewhere))
        return
      }
      guard !waiting.isEmpty else { return }
      step.events.append(.turnEnded(TurnSummary(outcome: .failed, failureText: message)))
      step.events += waiting.dropFirst().map {
        AgentEvent.queue(id: $0.uuid, .dropped(agent: "Codex"))
      }
    case .turnStart:
      turn = .idle
      interruptsWhenStarted = false
      step.events.append(.turnEnded(TurnSummary(outcome: .failed, failureText: message)))
      step.events += beforeTurnID.map { AgentEvent.queue(id: $0.uuid, .dropped(agent: "Codex")) }
      beforeTurnID = []
    case .steer(let uuid, let input):
      steered.removeAll { $0 == uuid }
      if message.contains("no active turn") {
        // The turn ended between the prompt and the steer: it starts the next one.
        turn = .idle
        step.writes.append(startTurn(Waiting(input: input, uuid: uuid)))
      } else {
        step.events.append(.queue(id: uuid, .dropped(agent: "Codex")))
      }
    case .account, .models, .other:
      break
    }
  }

  /// The session's bookkeeping for a notification; true when it ended the running turn.
  private mutating func notified(_ method: String, params: JSONValue, into step: inout Step)
    -> Bool
  {
    switch method {
    case "turn/started":
      if let id = params["turn"]?["id"]?.stringValue { turnStarted(id, into: &step) }
    case "turn/completed":
      let id = params["turn"]?["id"]?.stringValue
      if case .running(let current) = turn, let id, id != current { return false }
      if turn == .starting { return false }
      turn = .idle
      approvals.removeAll()
      return true
    case "serverRequest/resolved":
      if let id = CodexRPC.ID(params["requestId"]) { approvals[id.text] = nil }
    case "item/started":
      if params["item"]?["type"] == .string("userMessage"),
        let client = params["item"]?["clientId"]?.stringValue
      {
        steered.removeAll { $0 == client }
      }
    default:
      break
    }
    return false
  }

  /// The turn has its id, from `turn/start`'s answer or `turn/started`, whichever comes
  /// first: what waited for it goes now.
  private mutating func turnStarted(_ id: String, into step: inout Step) {
    guard turn != .running(id) else { return }
    turn = .running(id)
    let waiting = beforeTurnID
    beforeTurnID = []
    step.writes += waiting.map { steer($0, into: id) }
    if interruptsWhenStarted {
      interruptsWhenStarted = false
      step.writes.append(interrupt(id))
    }
  }

  private mutating func openThread() -> JSONValue {
    isOpeningThread = true
    var params = CodexPolicy.threadSettings(mode)
    params["cwd"] = .string(cwd)
    if let model { params["model"] = .string(model) }
    guard let threadID else { return calls.make("thread/start", .object(params), for: .thread) }
    params["threadId"] = .string(threadID)
    params["excludeTurns"] = .bool(true)
    return calls.make("thread/resume", .object(params), for: .thread)
  }

  private mutating func startTurn(_ prompt: Waiting) -> JSONValue {
    turn = .starting
    var params = CodexPolicy.turnSettings(mode)
    params["threadId"] = .string(threadID ?? "")
    params["input"] = prompt.input
    params["clientUserMessageId"] = .string(prompt.uuid)
    if let model { params["model"] = .string(model) }
    if let effort { params["effort"] = .string(effort) }
    return calls.make("turn/start", .object(params), for: .turnStart)
  }

  private mutating func steer(_ prompt: Waiting, into turn: String) -> JSONValue {
    steered.append(prompt.uuid)
    return calls.make(
      "turn/steer",
      .object([
        "threadId": .string(threadID ?? ""), "expectedTurnId": .string(turn),
        "input": prompt.input, "clientUserMessageId": .string(prompt.uuid),
      ]), for: .steer(uuid: prompt.uuid, input: prompt.input))
  }

  private mutating func interrupt(_ turn: String) -> JSONValue {
    calls.make(
      "turn/interrupt",
      .object(["threadId": .string(threadID ?? ""), "turnId": .string(turn)]), for: .other)
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexSessionTests`
Expected: PASS (20 tests). Then `make -C apps/apple test`.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexSession.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexSessionTests.swift
git commit -m "feat(apple): run a Codex conversation as a state machine"
```

---

### Task 6: `CodexBackend`, `AgentKind`, `AgentFeatures`

**Files:**
- Create: `apps/apple/Drakar/Services/AgentFeatures.swift`, `Services/CodexLaunch.swift`, `Services/CodexBackend.swift`
- Modify: `apps/apple/Drakar/Services/AgentBackend.swift`, `Services/ClaudeBackend.swift`, `Services/SessionRoute.swift`
- Test: `apps/apple/DrakarTests/CodexBackendTests.swift`

**Interfaces:**
- Consumes: `CodexSession` (Task 5), `CodexInput.make` (Task 2).
- Produces:
  - `enum AgentKind: String, Codable, CaseIterable { case claude, codex }` with `name`, `shortName`, `features`, `makeBackend()`
  - `struct AgentFeatures` with `agent`, `cancelsQueued`, `slashCommands`, `forks`, `moves`, `showsAccount`, `showsPromptCache`, `acceptsPDF`, `usesSettingsDefaults`, `picksApplyAtOnce`, and the statics `.claude` and `.codex`
  - `AgentBackend.features`
  - `SessionSignal.unusable(String)`
  - `ResumeTarget.agent: AgentKind?`, `agentKind`, `init(…, agent:)`
  - `CodexLaunch.locate(path:isExecutable:)`, `configuration(executable:environment:folder:)`, `notFound`, `appVersion`
  - `final class CodexBackend: AgentBackend`

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Codex behind the backend")
struct CodexBackendTests {
  private func line(_ json: String) throws -> AgentProcess.Line {
    .json(try JSONValue.parse(Data(json.utf8)))
  }

  /// A `cat` stands in for the process: what the backend writes is not read here (the
  /// conversation's writes are `CodexSessionTests`'). Each test terminates its own.
  private func process() throws -> AgentProcess {
    let process = AgentProcess(
      .init(
        executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
        currentDirectory: FileManager.default.temporaryDirectory))
    _ = try process.start()
    return process
  }

  private func start(resuming: ResumeTarget? = nil) -> AgentStart {
    AgentStart(
      folder: URL(filePath: "/p"), resuming: resuming, environment: ["PATH": "/nowhere"],
      executableOverride: URL(filePath: "/bin/cat"), model: nil, mode: .acceptEdits,
      effort: nil, allowsBypass: true, name: nil)
  }

  @Test func launchesAppServerUnderNoClaudeAccount() {
    let launch = CodexBackend().launch(start())
    #expect(launch.configuration?.arguments == ["app-server"])
    #expect(launch.configuration?.currentDirectory == URL(filePath: "/p"))
    #expect(launch.executable == URL(filePath: "/bin/cat"))
    #expect(launch.account == nil)
  }

  @Test func findsCodexOnThePathThenHomebrew() {
    let found = CodexLaunch.locate(path: "/a:/b") { $0.path == "/b/codex" }
    #expect(found == URL(filePath: "/b/codex"))
    let brewed = CodexLaunch.locate(path: "/a") { $0.path == "/opt/homebrew/bin/codex" }
    #expect(brewed == URL(filePath: "/opt/homebrew/bin/codex"))
    #expect(CodexLaunch.locate(path: nil) { _ in false } == nil)
  }

  @Test func signalsReachTheSessionAndTheThreadIsLocated() throws {
    let backend = CodexBackend()
    _ = backend.launch(start())
    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)
    _ = backend.receive(try line(#"{"id":1,"result":{"codexHome":"/home/.codex"}}"#), from: process, at: .now)
    let models = backend.receive(
      try line(#"{"id":3,"result":{"data":[{"id":"m","model":"m","displayName":"M","supportedReasoningEfforts":[]}]}}"#),
      from: process, at: .now)
    #expect(models.signals == [.models([ModelOption(value: "m", resolvedModel: "m", displayName: "M")])])
    _ = try backend.send(
      .prompt(text: "hi", context: [], uuid: "p-1", attachments: []), to: process)
    let thread = backend.receive(
      try line(
        #"{"id":4,"result":{"thread":{"id":"t-1","cwd":"/p","cliVersion":"0.160.1","path":"/home/.codex/sessions/r.jsonl"},"model":"gpt-6-astra"}}"#
      ), from: process, at: .now)
    #expect(thread.signals == [.modeAdopted("acceptEdits")])
    #expect(thread.events.contains { if case .sessionStarted = $0 { true } else { false } })
    let target = backend.locateTarget(sessionID: "t-1", cwd: "/p", in: [])
    #expect(target?.agentKind == .codex)
    #expect(target?.sessionID == "t-1")
    #expect(target?.file == "/home/.codex/sessions/r.jsonl")
    #expect(target?.accountDirectory == "/home/.codex")
  }

  @Test func notSignedInIsUnusable() throws {
    let backend = CodexBackend()
    _ = backend.launch(start())
    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)
    _ = backend.receive(try line(#"{"id":1,"result":{}}"#), from: process, at: .now)
    let output = backend.receive(
      try line(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#), from: process,
      at: .now)
    #expect(output.signals == [.unusable(CodexSession.notSignedIn)])
  }

  @Test func picksAndCancelsAnswerWithNoRequest() throws {
    let backend = CodexBackend()
    _ = backend.launch(start())
    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)
    #expect(try backend.send(.setMode("default"), to: process) == nil)
    #expect(try backend.send(.setEffort("high"), to: process) == nil)
    #expect(try backend.send(.cancelQueued(uuid: "u"), to: process) == nil)
  }

  @Test func featuresSayWhatACodexSessionLacks() {
    #expect(CodexBackend().features == .codex)
    #expect(ClaudeBackend().features == .claude)
    #expect(!AgentFeatures.codex.cancelsQueued && AgentFeatures.claude.cancelsQueued)
    #expect(AgentKind.codex.name == "Codex")
  }

  /// Review Focus 5, the stored half: windows stored before this slice decode as Claude.
  @Test func aTargetStoredWithoutAnAgentIsClaudes() throws {
    let old = #"{"sessionID":"s","cwd":"/p","file":"/f.jsonl","accountDirectory":"/a","accountIsDefault":true}"#
    let target = try JSONDecoder().decode(ResumeTarget.self, from: Data(old.utf8))
    #expect(target.agentKind == .claude)
    var codex = target
    codex.agent = .codex
    let again = try JSONDecoder().decode(ResumeTarget.self, from: JSONEncoder().encode(codex))
    #expect(again.agentKind == .codex)
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/CodexBackendTests`
Expected: FAIL to build, `cannot find 'CodexBackend' in scope`.

- [ ] **Step 3: Write `AgentFeatures.swift`**

```swift
import DrakarKit
import Foundation

/// Which agent a session runs. Stored with a session's target, so a window reopens each of
/// its sessions with its own agent; a target stored before Codex arrived is Claude Code's.
enum AgentKind: String, Codable, CaseIterable {
  case claude, codex

  /// The product's name: "Claude Code exited", the footer's version.
  var name: String {
    switch self {
    case .claude: String(localized: "Claude Code")
    case .codex: String(localized: "Codex")
    }
  }

  /// How a sentence addresses it: "Ask Claude to do something…".
  var shortName: String {
    switch self {
    case .claude: String(localized: "Claude")
    case .codex: String(localized: "Codex")
    }
  }

  var features: AgentFeatures { self == .claude ? .claude : .codex }

  func makeBackend() -> AgentBackend { self == .claude ? ClaudeBackend() : CodexBackend() }
}

/// What an agent's sessions can do beyond a conversation. The views ask this, never which
/// agent runs (docs/superpowers/specs/2026-10-07-codex-live-sessions-design.md).
struct AgentFeatures: Equatable {
  var agent: AgentKind
  /// A prompt sent mid-turn can be taken back.
  var cancelsQueued: Bool
  /// The composer's `/` menu lists the agent's commands and skills.
  var slashCommands: Bool
  var forks: Bool
  /// Its files can move to another account.
  var moves: Bool
  /// The footer names its account and the sidebar marks another one: Codex's accounts are
  /// slice 4.
  var showsAccount: Bool
  var showsPromptCache: Bool
  var acceptsPDF: Bool
  /// Settings' model, mode and effort for new sessions apply: they are Claude Code's.
  var usesSettingsDefaults: Bool
  /// A mode, model or effort pick reaches a running process at once; Codex's wait for the
  /// next turn.
  var picksApplyAtOnce: Bool

  var name: String { agent.name }

  static let claude = AgentFeatures(
    agent: .claude, cancelsQueued: true, slashCommands: true, forks: true, moves: true,
    showsAccount: true, showsPromptCache: true, acceptsPDF: true, usesSettingsDefaults: true,
    picksApplyAtOnce: true)

  static let codex = AgentFeatures(
    agent: .codex, cancelsQueued: false, slashCommands: false, forks: false, moves: false,
    showsAccount: false, showsPromptCache: false, acceptsPDF: false,
    usesSettingsDefaults: false, picksApplyAtOnce: false)
}
```

- [ ] **Step 4: Write `CodexLaunch.swift`**

```swift
import DrakarKit
import Foundation

/// How a `codex app-server` starts for a session or a short-lived read: the binary from the
/// login shell's PATH, else Homebrew's places; the environment as it is, so a `CODEX_HOME`
/// in it still picks the account until Codex accounts (slice 4).
enum CodexLaunch {
  static var notFound: String {
    String(localized: "Codex was not found. Install it with `brew install --cask codex`, then send again.")
  }

  static func locate(
    path: String?,
    isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
  ) -> URL? {
    let folders =
      (path ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    return folders.lazy.map { URL(filePath: $0).appending(path: "codex") }.first(
      where: isExecutable)
  }

  static func configuration(executable: URL, environment: [String: String], folder: URL)
    -> AgentProcess.Configuration
  {
    .init(
      executable: executable, arguments: ["app-server"], environment: environment,
      currentDirectory: folder)
  }

  /// What `initialize` says Drakar is.
  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }
}
```

- [ ] **Step 5: Extend the backend protocol and Claude's**

In `AgentBackend.swift`, add to `protocol AgentBackend` after `notFoundMessage`:

```swift
  /// What its sessions can do beyond a conversation.
  var features: AgentFeatures { get }
```

and to `enum SessionSignal`, after `queueChanged`:

```swift
  /// Nothing can go through this process: not signed in, or its session held by another
  /// process. The session stops and says why.
  case unusable(String)
```

In `ClaudeBackend.swift`, after `var notFoundMessage`:

```swift
  let features = AgentFeatures.claude
```

- [ ] **Step 6: Give `ResumeTarget` its agent** in `SessionRoute.swift`:

Add after `var forks: Bool?`:

```swift
  /// The agent that writes it. Optional so that a target stored before Codex arrived still
  /// decodes, as Claude Code's.
  var agent: AgentKind?
```

Give the memberwise `init` a trailing `agent: AgentKind? = nil` parameter and `self.agent = agent`. Add:

```swift
  var agentKind: AgentKind { agent ?? .claude }
```

- [ ] **Step 7: Write `CodexBackend.swift`**

```swift
import DrakarKit
import Foundation

/// Codex over `codex app-server` (docs/codex-app-server.md): `CodexSession` decides what is
/// written and what it means; this writes it to the process and says it in the session's
/// signals.
final class CodexBackend: AgentBackend {
  let features = AgentFeatures.codex
  private var session: CodexSession?
  /// Where the thread's files are, once it runs: what reopening the window resumes.
  private var threadPath: String?
  private var codexHome: String?

  var notFoundMessage: String { CodexLaunch.notFound }

  func launch(_ start: AgentStart) -> AgentLaunch {
    let executable = start.executableOverride ?? CodexLaunch.locate(path: start.environment["PATH"])
    // A new process starts afresh: a stopped session resumes its thread on its first prompt.
    session = CodexSession(
      cwd: start.folder.path(percentEncoded: false), resuming: start.resuming?.sessionID,
      mode: start.mode ?? .ask, model: start.model == "default" ? nil : start.model,
      effort: start.effort, version: CodexLaunch.appVersion)
    return AgentLaunch(
      configuration: executable.map {
        CodexLaunch.configuration(
          executable: $0, environment: start.environment, folder: start.folder)
      },
      executable: executable, account: nil)
  }

  func started(_ process: AgentProcess, then first: AgentCommand?) throws {
    guard var session else { return }
    var writes = session.start().writes
    if let first, let command = Self.command(first) { writes += session.send(command).writes }
    self.session = session
    for line in writes { try process.send(line) }
  }

  @discardableResult func send(_ command: AgentCommand, to process: AgentProcess) throws
    -> String?
  {
    guard var session, let command = Self.command(command) else { return nil }
    let step = session.send(command)
    self.session = session
    for line in step.writes { try process.send(line) }
    // Picks take with the next turn and are never refused: nothing to wait for.
    return nil
  }

  func receive(_ line: AgentProcess.Line, from process: AgentProcess, at time: Date)
    -> BackendOutput
  {
    guard case .json(let json) = line, var session else { return BackendOutput() }
    let step = session.receive(json, at: time)
    self.session = session
    // Not `write`: an answer that cannot be written must not mark the session failed.
    for line in step.writes { try? process.send(line) }
    var output = BackendOutput(events: step.events)
    for signal in step.signals {
      switch signal {
      case .models(let models): output.signals.append(.models(models))
      case .modeAdopted(let mode): output.signals.append(.modeAdopted(mode))
      case .unusable(let message): output.signals.append(.unusable(message))
      case .thread(_, let path, let home):
        threadPath = path
        codexHome = home
      }
    }
    return output
  }

  /// The thread is its own target: no disk search.
  func locateTarget(sessionID id: String, cwd: String, in accounts: [ClaudeAccount])
    -> ResumeTarget?
  {
    ResumeTarget(
      sessionID: id, cwd: cwd, file: threadPath ?? "",
      accountDirectory: codexHome
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        .path(percentEncoded: false),
      accountIsDefault: true, agent: .codex)
  }

  /// `command` in the session's words; nil for what Codex cannot do (take back a steer).
  private static func command(_ command: AgentCommand) -> CodexSession.Command? {
    switch command {
    case .prompt(let text, let context, let uuid, let attachments):
      .prompt(input: CodexInput.make(text: text, context: context, attachments: attachments), uuid: uuid)
    case .answer(let id, let decision): .answer(requestID: id, decision: decision)
    case .interrupt: .interrupt
    case .cancelQueued: nil
    case .setMode(let raw): PermissionMode(rawValue: raw).map { .setMode($0) }
    case .setModel(let model): .setModel(model)
    case .setEffort(let level): .setEffort(level)
    case .rename(let title, _): .rename(title)
    }
  }
}
```

`AgentSession.handle(_ signal:)` must now cover `.unusable`; until Task 7 handles it, add a case that does nothing beyond what Task 7 replaces:

```swift
    case .unusable(let message):
      stop()
      phase = .failed(message)
```

(This is Task 7's final behaviour; it lands here so the switch stays exhaustive.)

- [ ] **Step 8: Run the tests**

Run the focused `CodexBackendTests` command, then `make -C apps/apple test-app`.
Expected: PASS; no existing app test changes.

- [ ] **Step 9: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar/Services/AgentFeatures.swift apps/apple/Drakar/Services/CodexLaunch.swift apps/apple/Drakar/Services/CodexBackend.swift apps/apple/Drakar/Services/AgentBackend.swift apps/apple/Drakar/Services/ClaudeBackend.swift apps/apple/Drakar/Services/SessionRoute.swift apps/apple/Drakar/Services/AgentSession.swift apps/apple/DrakarTests/CodexBackendTests.swift
git commit -m "feat(apple): drive codex app-server behind AgentBackend"
```

---

### Task 7: Codex sessions in `AgentSession` and `Project`

**Files:**
- Create: `apps/apple/Drakar/Services/CodexOneShot.swift`
- Modify: `apps/apple/Drakar/Services/AgentSession.swift`, `Services/ModelCatalog.swift`, `Services/Project.swift`, `Services/SessionMoves.swift`
- Test: `apps/apple/DrakarTests/CodexSessionsTests.swift`

**Interfaces:**
- Consumes: Task 6.
- Produces:
  - `AgentSession.init(folder:resuming:agent:backend:)`, plus `agent` and `features`
  - `ModelCatalog.codexModels`, `recordCodex(_:)`, `loadCodex()`
  - `Project.newSession(agent: AgentKind? = nil)`
  - `ClaudeChoice.defaultAgent` (here; its Settings picker comes in Task 9)
  - `CodexOneShot(configuration:).run(_:) async throws -> [JSONValue]`
  - `CodexHistory.events(threadID:configuration:) async throws -> [AgentEvent]`

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Codex sessions in a project")
struct CodexSessionsTests {
  private let folder = FileManager.default.temporaryDirectory

  @Test func aSessionTakesItsAgentFromItsTarget() {
    let target = ResumeTarget(
      sessionID: "t-1", cwd: folder.path(percentEncoded: false), file: "", accountDirectory: "/h",
      accountIsDefault: true, agent: .codex)
    #expect(AgentSession(folder: folder, resuming: target).agent == .codex)
    #expect(AgentSession(folder: folder).agent == .claude)
    #expect(AgentSession(folder: folder, agent: .codex).backend is CodexBackend)
  }

  @Test func newSessionStartsTheAgentAsked() {
    let project = Project(folder: folder)
    #expect(project.newSession(agent: .codex).session.agent == .codex)
    #expect(project.newSession(agent: .claude).session.agent == .claude)
  }

  @Test func settingsDefaultsAreClaudesOnly() {
    ClaudeChoice.$testSuite.withValue("codex-sessions-\(UUID())") {
      ClaudeChoice.defaults.set("claude-opus-5-5", forKey: PreferenceKey.defaultModel)
      ClaudeChoice.defaults.set("high", forKey: PreferenceKey.defaultEffort)
      ClaudeChoice.defaults.set("acceptEdits", forKey: PreferenceKey.defaultMode)
      let codex = AgentSession(folder: folder, agent: .codex)
      #expect(codex.pickedModel == nil)
      #expect(codex.shownEffort == nil)
      #expect(codex.startingMode == nil)
      let claude = AgentSession(folder: folder, agent: .claude)
      #expect(claude.pickedModel == "claude-opus-5-5")
    }
  }

  @Test func aCodexSessionCannotFork() {
    let project = Project(folder: folder)
    let item = project.newSession(agent: .codex)
    item.session.relocate(
      to: ResumeTarget(
        sessionID: "t-1", cwd: folder.path(percentEncoded: false), file: "",
        accountDirectory: "/h", accountIsDefault: true, agent: .codex))
    #expect(!project.canFork(item))
  }

  /// Review Focus 5, the history half: a restored Codex session whose history cannot be read
  /// opens with a note and stays sendable.
  @Test func anUnreadableHistoryLeavesANoteAndTheSessionUsable() async {
    let target = ResumeTarget(
      sessionID: "t-1", cwd: folder.path(percentEncoded: false), file: "", accountDirectory: "/h",
      accountIsDefault: true, agent: .codex)
    let session = AgentSession(folder: folder, resuming: target)
    session.executableOverride = URL(filePath: "/nonexistent/codex")
    await session.loadHistory()
    #expect(session.hasLoadedHistory)
    #expect(session.canSend)
    #expect(
      session.transcript.entries.contains {
        if case .notice(let text) = $0.kind { text.contains("history") } else { false }
      })
  }
}
```

Before running, check `ClaudeChoice.$testSuite` usage in an existing test (`grep -rn "testSuite" apps/apple/DrakarTests | head -3`) and match it if it differs (it is `@TaskLocal static var testSuite: String?`).

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test … -only-testing:DrakarTests/CodexSessionsTests` (the focused command from Global Constraints).
Expected: FAIL to build, `extra argument 'agent' in call`.

- [ ] **Step 3: Write `CodexOneShot.swift`**

```swift
import DrakarKit
import Foundation

/// A `codex app-server` started for one exchange and closed: a session's history, Codex's
/// model list. `initialize` and `initialized`, then each request `next` builds from the
/// previous answer, until it returns nil. Ended after 30 seconds whatever it is doing.
struct CodexOneShot {
  let configuration: AgentProcess.Configuration

  struct Failure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
  }

  func run(_ next: (JSONValue?) -> (method: String, params: JSONValue)?) async throws
    -> [JSONValue]
  {
    let process = AgentProcess(configuration)
    let events = try process.start()
    let deadline = Task {
      try? await Task.sleep(for: .seconds(30))
      process.terminate()
    }
    defer {
      deadline.cancel()
      process.closeInput()
      process.terminate()
    }
    var calls = CodexRPC.Calls<Int>()
    try process.send(
      calls.make(
        "initialize", CodexSession.initializeParams(version: CodexLaunch.appVersion), for: 0))
    var results: [JSONValue] = []
    var isInitialized = false
    for await event in events {
      guard case .lines(let lines) = event else { continue }
      for line in lines {
        guard case .json(let json) = line, let rpc = CodexRPC.Line(json) else { continue }
        switch rpc {
        case .response(let id, let result):
          guard calls.take(id) != nil else { continue }
          let previous: JSONValue?
          if isInitialized {
            results.append(result)
            previous = result
          } else {
            isInitialized = true
            try process.send(CodexRPC.notification("initialized"))
            previous = nil
          }
          guard let request = next(previous) else { return results }
          try process.send(calls.make(request.method, request.params, for: 0))
        case .failure(let id, let message):
          guard calls.take(id) != nil else { continue }
          throw Failure(message: message)
        case .notification, .request:
          continue
        }
      }
    }
    throw Failure(message: String(localized: "Codex ended before it answered."))
  }
}

/// A Codex session's history, from its thread's stored items (`thread/items/list`, which
/// needs no resume and takes no lock: verified 2026-10-06).
enum CodexHistory {
  static func events(threadID: String, configuration: AgentProcess.Configuration) async throws
    -> [AgentEvent]
  {
    let pages = try await CodexOneShot(configuration: configuration).run { previous in
      var params: [String: JSONValue] = ["threadId": .string(threadID), "limit": .number(200)]
      if let previous {
        guard let cursor = previous["nextCursor"]?.stringValue else { return nil }
        params["cursor"] = .string(cursor)
      }
      return ("thread/items/list", .object(params))
    }
    return CodexTranslator.history(pages.flatMap { $0["data"]?.arrayValue ?? [] })
  }
}
```

- [ ] **Step 4: Codex's models in the catalog** (`ModelCatalog.swift`), add:

```swift
  /// Codex's models, from the newest `model/list`: one list until Codex accounts (slice 4).
  private(set) var codexModels: [ModelOption]?
  @ObservationIgnored private var isLoadingCodex = false

  func recordCodex(_ models: [ModelOption]) { codexModels = models }

  /// Asks a short-lived `codex app-server` for its models, once, when no list is known yet:
  /// the pill lists them before a Codex session's first prompt.
  func loadCodex() {
    guard codexModels == nil, !isLoadingCodex else { return }
    isLoadingCodex = true
    Task {
      defer { isLoadingCodex = false }
      let environment = await AgentSession.environment.value
      guard let executable = CodexLaunch.locate(path: environment["PATH"]) else { return }
      let configuration = CodexLaunch.configuration(
        executable: executable, environment: environment,
        folder: FileManager.default.homeDirectoryForCurrentUser)
      let results = try? await CodexOneShot(configuration: configuration).run { previous in
        previous == nil ? ("model/list", .object([:])) : nil
      }
      if let list = results?.first { recordCodex(CodexModels.list(list)) }
    }
  }
```

- [ ] **Step 5: Teach `AgentSession` its agent** (`AgentSession.swift`):

Replace `init(folder:resuming:backend:)` with:

```swift
  /// `agent` nil takes the target's, else Claude Code. `backend` stands in for tests.
  init(
    folder: URL, resuming: ResumeTarget? = nil, agent: AgentKind? = nil,
    backend: AgentBackend? = nil
  ) {
    self.folder = folder
    self.resuming = resuming
    self.backend = backend ?? (agent ?? resuming?.agentKind ?? .claude).makeBackend()
    savedTarget = resuming?.forks == true ? nil : resuming
    isLoadingHistory = resuming != nil
  }

  /// What its sessions can do beyond a conversation, which the views ask.
  var features: AgentFeatures { backend.features }
  var agent: AgentKind { features.agent }
```

Settings' defaults are Claude Code's. In `startingMode`, `pickedModel` and `shownEffort`, the fallback reads Settings only when `features.usesSettingsDefaults`:

```swift
  var startingMode: PermissionMode? {
    let mode =
      modePick ?? (isProcessRunning || !features.usesSettingsDefaults ? nil : ClaudeChoice.defaultMode)
    return mode == .bypass && !ClaudeChoice.allowsBypass ? nil : mode
  }

  var pickedModel: String? {
    modelPick ?? (isProcessRunning || !features.usesSettingsDefaults ? nil : ClaudeChoice.defaultModel)
  }

  var shownEffort: String? {
    effortPick ?? appliedEffort
      ?? (isProcessRunning || !features.usesSettingsDefaults ? nil : ClaudeChoice.defaultEffort)
  }
```

and in `spawn(unlessStoppedSince:)`:

```swift
    let effort = effortPick ?? (features.usesSettingsDefaults ? ClaudeChoice.defaultEffort : nil)
```

Picks that wait for the next turn say so. At the end of `setMode`, `setModel` and `setEffort`, after `pillNote = nil` and the pick is stored, before the `guard let process`:

```swift
    if !features.picksApplyAtOnce, transcript.isRunning {
      pillNote = String(localized: "From the next turn")
    }
```

and in `receive(_:)`, where `turnEnded` is true (before `if savedTarget == nil`):

```swift
      if !features.picksApplyAtOnce { pillNote = nil }
```

A Codex rename with no process waits for the next start: in `rename(to:)`, change `} else if let target = ownTarget() {` to `} else if agent == .claude, let target = ownTarget() {`.

Another process's registry is Claude Code's: `isLiveElsewhere(_:)` begins with `guard target.agentKind == .claude else { return false }`.

The catalog keeps Codex's list apart: `handle(.models)` becomes:

```swift
    case .models(let models):
      if agent == .codex {
        catalog.recordCodex(models)
      } else if let account {
        catalog.record(models, for: account)
      }
```

History: at the top of `readHistory()`:

```swift
    if let resuming, resuming.agentKind == .codex { return await readCodexHistory(resuming) }
```

and the `noteColdCache()` call there reads `if !isReadOnly, features.showsPromptCache { self.transcript.noteColdCache() }`. Add:

```swift
  /// A Codex session's history, from a short-lived `codex app-server`. Unreadable, the session
  /// opens empty with a note and still resumes its thread on the next prompt.
  private func readCodexHistory(_ target: ResumeTarget) async {
    let environment = await Self.environment.value
    var loaded: [AgentEvent] = []
    var problem: String?
    if let executable = executableOverride ?? CodexLaunch.locate(path: environment["PATH"]) {
      do {
        loaded = try await CodexHistory.events(
          threadID: target.sessionID,
          configuration: CodexLaunch.configuration(
            executable: executable, environment: environment, folder: folder))
      } catch {
        problem = error.localizedDescription
      }
    } else {
      problem = CodexLaunch.notFound
    }
    isLoadingHistory = false
    var transcript = Transcript()
    for event in loaded { transcript.apply(event) }
    if let problem {
      transcript.apply(
        .note(.init(text: String(localized: "Codex's history of this session could not be read: \(problem)"))))
    }
    self.transcript = transcript
    hasLoadedHistory = true
    for prompt in promptsDuringLoad {
      self.transcript.addPrompt(prompt.text, context: prompt.context, attachments: prompt.attachments)
    }
    promptsDuringLoad = []
  }
```

- [ ] **Step 6: `Project` and `SessionMoves`**

In `SettingsView.swift`, add to `PreferenceKey`:

```swift
  /// The agent New Session starts (`AgentKind`'s raw value); empty for Claude Code.
  static let defaultAgent = "drakar.defaultAgent"
```

and to `ClaudeChoice`:

```swift
  /// The agent New Session starts; ⌥-click starts the other.
  static var defaultAgent: AgentKind {
    _ = AttentionDefaults.shared.revision
    return stored(PreferenceKey.defaultAgent).flatMap(AgentKind.init(rawValue:)) ?? .claude
  }
```

In `Project.swift`:

- `newSession()` becomes:

  ```swift
  /// A new session in the project's folder, on top and shown, running `agent` (Settings'
  /// default when nil). No process until it is prompted.
  @discardableResult func newSession(agent: AgentKind? = nil) -> ProjectSession {
    let item = make(AgentSession(folder: folder, agent: agent ?? ClaudeChoice.defaultAgent))
    sessions.insert(item, at: 0)
    select(item)
    return item
  }
  ```

- In `run(_:in:)`, `case .newSession: item = newSession()` becomes `case .newSession: item = newSession(agent: .claude)` (skills are Claude Code's).
- `canFork(_:)` begins with `item.session.features.forks &&`.
- `readPreview(_:)`'s guard becomes `guard let target = item.session.resuming, target.agentKind == .claude else { return }` (a Codex rollout is not a Claude transcript; slice 3 reads rollouts).
- `ProjectSession.attach(_ sources:)` refuses what the agent cannot read. Replace its `Task` body with:

  ```swift
    Task {
      var (attachments, notes) = await AttachmentIntake.load(sources)
      if !session.features.acceptsPDF {
        let refused = attachments.filter { $0.kind == .pdf }
        attachments.removeAll { $0.kind == .pdf }
        notes += refused.map {
          String(localized: "\(session.features.name) can't read PDFs here: \($0.preview.name ?? "PDF")")
        }
      }
      self.attachments += attachments
      attachmentNote = notes.isEmpty ? nil : notes.joined(separator: "\n")
      focusRequest += 1
    }
  ```

In `SessionMoves.swift`, `candidate(for item: ProjectSession)` begins with `guard item.session.features.moves else { return nil }`.

- [ ] **Step 7: Run the tests**

Run the focused `CodexSessionsTests` command, then `make -C apps/apple test-app`.
Expected: PASS; every existing suite unchanged.

- [ ] **Step 8: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar/Services/CodexOneShot.swift apps/apple/Drakar/Services/AgentSession.swift apps/apple/Drakar/Services/ModelCatalog.swift apps/apple/Drakar/Services/Project.swift apps/apple/Drakar/Services/SessionMoves.swift apps/apple/Drakar/Views/SettingsView.swift apps/apple/DrakarTests/CodexSessionsTests.swift
git commit -m "feat(apple): start, restore and resume Codex sessions in a project"
```

---

### Task 8: A Codex session's composer, footer and diffs

**Files:**
- Modify: `apps/apple/Drakar/Views/SessionPills.swift`, `Views/SessionView.swift`, `Views/ComposerView.swift`, `Views/TranscriptView.swift`, `Views/DiffView.swift`, `Views/PermissionSheet.swift`
- Test: `apps/apple/DrakarTests/CodexSessionsTests.swift` (add pill tests)

**Interfaces:**
- Consumes: `AgentSession.features`/`agent`, `ModelCatalog.codexModels`/`loadCodex()`, `CodexPolicy.offeredModes`, `FileChange.each`/`movedTo`/`isDeleted`, `PermissionSuggestion.Kind.codexDecision`.
- Produces: `SessionPills.models(for:account:) -> [ModelOption]?`.

- [ ] **Step 1: Write the failing tests** (append to `CodexSessionsTests`)

```swift
  @Test func aCodexPillOffersCodexsModes() {
    let session = AgentSession(folder: folder, agent: .codex)
    let modes = SessionPills.offeredModes(session, models: nil)
    #expect(!modes.contains(.plan) && !modes.contains(.auto))
    #expect(modes.prefix(2) == [.ask, .acceptEdits])
  }

  @Test func aCodexPillNamesTheModelByItsListedName() {
    let session = AgentSession(folder: folder, agent: .codex)
    session.setModel("gpt-6.1-sol")
    let models = [ModelOption(value: "gpt-6.1-sol", resolvedModel: "gpt-6.1-sol", displayName: "GPT-6.1-Sol")]
    #expect(SessionPills.modelLabel(for: session, in: models) == "GPT-6.1-Sol")
  }
```

- [ ] **Step 2: Run them to see them fail**

Run the focused `CodexSessionsTests` command.
Expected: FAIL: `offeredModes` includes `.plan`, and the label reads `gpt-6.1-sol`.

- [ ] **Step 3: The pills** (`SessionPills.swift`):

Add:

```swift
  /// The list the session's pills offer: Codex's own, else the account's.
  static func models(for session: AgentSession, account: ClaudeAccount) -> [ModelOption]? {
    session.agent == .codex
      ? ModelCatalog.shared.codexModels : ModelCatalog.shared.models(for: account)
  }
```

In `var model`, `let models = catalog.models(for: account)` becomes `let models = Self.models(for: session, account: account)`, and the `.onAppear` becomes:

```swift
    .onAppear {
      if session.agent == .codex {
        catalog.loadCodex()
      } else {
        catalog.load(folder: folder, account: account)
      }
    }
```

`var mode` becomes `modeMenu(Self.models(for: session, account: account))`. In `loadingText`, first line: `if session.agent == .codex { return String(localized: "Loading Codex's models…") }`. `offeredModels` keeps Codex's list whole:

```swift
  static func offeredModels(_ session: AgentSession, models: [ModelOption]?) -> [ModelOption]? {
    guard session.agent == .claude else { return models }
    return models.map { ClaudeChoice.offered($0, keeping: option(for: session, in: $0)?.value) }
  }
```

`offeredModes` begins with:

```swift
    if session.agent == .codex { return CodexPolicy.offeredModes(allowsBypass: session.offersBypass) }
```

`modelLabel(for:in:)` begins with:

```swift
    if session.agent == .codex {
      return option(for: session, in: models)?.displayName ?? session.pickedModel
        ?? session.transcript.session?.model ?? String(localized: "Codex's default")
    }
```

`cycle(_:account:)` takes `models(for: session, account: account)` in place of `ModelCatalog.shared.models(for: account)`, and so does `SessionView.offersAutoMode`.

- [ ] **Step 4: The composer and the transcript**

`ComposerView.swift`: add a stored property `var agentName = "Claude"` after `isRunning`, and the field's placeholder becomes `isRunning && canSend ? "Queue another message…" : "Ask \(agentName) to do something…"`.

`TranscriptView.swift`: `var cancelQueued: (QueuedPrompt) -> Void = { _ in }` becomes `var cancelQueued: ((QueuedPrompt) -> Void)? = { _ in }`; the queued row passes `cancel: cancelQueued.map { cancel in { cancel(prompt) } }`; `QueuedPromptView.cancel` becomes `let cancel: (() -> Void)?` and its Cancel button sits in `if let cancel { … }`. In `ToolCallView`, the file-change branch becomes:

```swift
        if case .fileChange(_, let edits) = call.kind, !FileChange.each(edits: edits).isEmpty {
          ForEach(FileChange.each(edits: edits), id: \.path) { change in
            FileChangeView(change: change)
          }
        } else if case .shell = call.kind, !call.summary.isEmpty {
```

`DiffView.swift`, in `FileChangeView.body`: the icon is `Image(systemName: change.isDeleted ? "trash" : change.isNewFile ? "doc.badge.plus" : "doc.text")`, and after `Text(displayedPath)…` add:

```swift
        if let movedTo = change.movedTo {
          Text("→ \(URL(filePath: movedTo).lastPathComponent)")
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
```

`PermissionSheet.swift`: `title(_:)` gains the case

```swift
    case .codexDecision:
      return String(localized: "Allow for this session")
```

- [ ] **Step 5: The session view** (`SessionView.swift`):

- `cancelQueued: session.cancelQueued` becomes `cancelQueued: session.features.cancelsQueued ? session.cancelQueued : nil`.
- The composer gets `agentName: session.agent.shortName` and `commands: session.features.slashCommands ? (project.capabilities.lists.commands ?? project.capabilities.lists.skills ?? []) : []`. If `ComposerView` is built with a memberwise initializer, pass `agentName:` right after `isRunning:`.
- `problem`'s exit case reads `String(localized: "\(session.agent.name) exited with status \(status).")`.
- In the footer: `account` is shown only `if session.features.showsAccount`; the prompt cache label's condition becomes `session.features.showsPromptCache && session.transcript.promptCache.state(at: .now) != .unknown`; `VersionLabel(version:executable:)` gains `agent: session.agent`, and its body begins with `if agent == .codex { Text("Codex \(version)").help(path) } else { … }` around the existing `switch` (its drift is Claude Code's tested range).

- [ ] **Step 6: Run the tests**

Run the focused `CodexSessionsTests` command, then `make -C apps/apple test-app` and `make -C apps/apple test`.
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar/Views/SessionPills.swift apps/apple/Drakar/Views/SessionView.swift apps/apple/Drakar/Views/ComposerView.swift apps/apple/Drakar/Views/TranscriptView.swift apps/apple/Drakar/Views/DiffView.swift apps/apple/Drakar/Views/PermissionSheet.swift apps/apple/DrakarTests/CodexSessionsTests.swift
git commit -m "feat(apple): a Codex session's pills, composer, footer and diffs"
```

---

### Task 9: Starting a Codex session

**Files:**
- Modify: `apps/apple/Drakar/Views/ProjectSidebar.swift`, `DrakarApp.swift`, `Views/SettingsView.swift`, `ContentView.swift`
- Test: `apps/apple/DrakarTests/CodexSessionsTests.swift` (add)

**Interfaces:**
- Consumes: `Project.newSession(agent:)`, `ClaudeChoice.defaultAgent`, `CodexLaunch.locate`.
- Produces: the `sessions.new` button's ⌥-click and menu; Session > New <other> Session (⌃⌘N); Settings' "New sessions run" picker and Codex section; the sidebar's Codex tag; `-drakar.debugAgent codex`.

- [ ] **Step 1: Write the failing test** (append)

```swift
  @Test func theOtherAgentIsTheOneNotDefault() {
    ClaudeChoice.$testSuite.withValue("codex-default-\(UUID())") {
      #expect(ClaudeChoice.defaultAgent == .claude)
      #expect(ClaudeChoice.defaultAgent.other == .codex)
      ClaudeChoice.defaults.set("codex", forKey: PreferenceKey.defaultAgent)
      #expect(ClaudeChoice.defaultAgent == .codex)
      #expect(ClaudeChoice.defaultAgent.other == .claude)
    }
  }
```

- [ ] **Step 2: Run it to see it fail**

Expected: FAIL to build, `value of type 'AgentKind' has no member 'other'`.

- [ ] **Step 3: `AgentKind.other`** in `AgentFeatures.swift`:

```swift
  /// The agent ⌥-click and ⌃⌘N start.
  var other: AgentKind { self == .claude ? .codex : .claude }
```

- [ ] **Step 4: The sidebar** (`ProjectSidebar.swift`; `NSEvent` comes with SwiftUI on macOS, add `import AppKit` only if the build asks):

The `sessions.new` button becomes:

```swift
      Button("New Session", systemImage: "plus") {
        // ⌥-click starts the agent that is not the default.
        let other = NSEvent.modifierFlags.contains(.option)
        project.newSession(agent: other ? ClaudeChoice.defaultAgent.other : nil)
      }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("New \(ClaudeChoice.defaultAgent.name) session (⌘N); ⌥-click for \(ClaudeChoice.defaultAgent.other.name) (⌃⌘N)")
        .contextMenu {
          ForEach(AgentKind.allCases, id: \.self) { agent in
            Button("New \(agent.name) Session") { project.newSession(agent: agent) }
          }
        }
        .accessibilityIdentifier("sessions.new")
```

In `SessionRow`, after the unread dot:

```swift
          if item.session.agent == .codex {
            Text("Codex")
              .font(.caption2)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Capsule().fill(.quaternary))
              .accessibilityIdentifier("sessions.agent.codex")
          }
```

and `otherAccount` returns nil when `!item.session.features.showsAccount`.

- [ ] **Step 5: The Session menu** (`DrakarApp.swift`, `SessionCommands`): after the New Session button add:

```swift
    Button("New \(ClaudeChoice.defaultAgent.other.name) Session") {
      project?.newSession(agent: ClaudeChoice.defaultAgent.other)
    }
    .keyboardShortcut("n", modifiers: [.command, .control])
    .disabled(project == nil)
```

- [ ] **Step 6: Settings** (`SettingsView.swift`, `GeneralPane`): before `ClaudeSection()` add a section:

```swift
      Section {
        Picker("New sessions run", selection: $defaultAgent) {
          ForEach(AgentKind.allCases, id: \.self) { agent in
            Text(agent.name).tag(agent.rawValue)
          }
        }
        .accessibilityIdentifier("settings.defaultAgent")
        LabeledContent("Codex") {
          Text(codexPath.map { ContentView.abbreviated(URL(filePath: $0)) } ?? String(localized: "Not found: brew install --cask codex"))
        }
      } footer: {
        Text("⌥-click New Session, or press ⌃⌘N, to start the other one.")
      }
      .task {
        let environment = await AgentSession.environment.value
        codexPath = CodexLaunch.locate(path: environment["PATH"])?.path(percentEncoded: false)
      }
```

with `@AppStorage(PreferenceKey.defaultAgent) private var defaultAgent = AgentKind.claude.rawValue` and `@State private var codexPath: String?` on `GeneralPane`.

- [ ] **Step 7: The debug launch** (`ContentView.swift`, `openFromLaunchArguments`): after `guard let project, let item = project.selected else { return }`, replace the `item` binding so a Codex debug launch gets its own session:

```swift
      let codex = defaults.string(forKey: "drakar.debugAgent") == "codex"
      guard let project else { return }
      let item = codex ? project.newSession(agent: .codex) : project.selected
      guard let item else { return }
      if codex, let model = defaults.string(forKey: "drakar.debugModel") {
        item.session.setModel(model)
      }
```

(the `ClaudeBackend` cast after it stays; it is a no-op for Codex). Add `-drakar.debugAgent codex` to the doc comment's list of arguments above the function.

- [ ] **Step 8: Run the tests**

Run the focused `CodexSessionsTests` command, then `make -C apps/apple test-app` and `make -C apps/apple test`.
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar/Services/AgentFeatures.swift apps/apple/Drakar/Views/ProjectSidebar.swift apps/apple/Drakar/DrakarApp.swift apps/apple/Drakar/Views/SettingsView.swift apps/apple/Drakar/ContentView.swift apps/apple/DrakarTests/CodexSessionsTests.swift
git commit -m "feat(apple): start a Codex session from the sidebar, menu or Settings"
```

---

### Task 10: Check in the running app

Needs the person's go-ahead: `make run` quits the Drakar they are using. Nothing is committed unless a fix is needed.

- [ ] **Step 1: Ask the person** whether to run the check now.
- [ ] **Step 2: Launch on a scratch repo**

```bash
S=$(mktemp -d)/codex-check && mkdir -p "$S" && cd "$S" && git init -q && printf 'one\ntwo\n' > notes.txt && git add . && git -c user.name=t -c user.email=t@t commit -qm init && cd -
make -C apps/apple run ARGS="-drakar.debugFolder $S -drakar.debugAgent codex -drakar.debugPrompt 'Change two to TWO in notes.txt with apply_patch, then reply DONE.'"
```

- [ ] **Step 3: Check, through cupertino-desktop's accessibility tree** (bundle `io.mgcrea.Drakar`, `maxDepth` 30; screenshots come back black on this Mac):
  - the row carries `sessions.agent.codex`; the mode pill reads "Ask before edits" and ⇧Tab offers only the three Codex modes;
  - the approval sheet shows the diff; Accept writes the file (check on disk); a second prompt with Reject declines it and the turn goes on;
  - a prompt sent during a `sleep 10` turn shows as queued, then as a prompt when Codex takes it; Stop ends a turn;
  - the footer reads "Codex 0.160.1", no cost, no cache timer; the model pill lists Codex's models;
  - after `make run` again with no arguments, the window reopens the Codex session with its history;
  - a Claude session started with ⌃⌘N beside it behaves as before.
- [ ] **Step 4: Delete the scratch thread** if it should not stay in Codex's history (`codex app-server` → `thread/delete`), and report what was checked and anything that failed.
