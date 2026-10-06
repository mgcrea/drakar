# An agent behind a protocol: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put Claude Code behind an `AgentBackend` protocol, change `Transcript` only through a neutral `AgentEvent`, and classify tool calls by `ToolKind`, with no change a person can see; then prove the vocabulary against Codex with a translator connected to nothing.

**Architecture:** `AgentProcess` (DrakarKit) parses JSON lines; `ClaudeBackend` (app) launches `claude`, encodes commands and turns each line into `AgentEvent`s (through `ClaudeTranslator`, DrakarKit) plus `SessionSignal`s; `AgentSession` (app, today's `ClaudeSession`) keeps the generic lifecycle and applies events to `Transcript`, which knows no wire format. Characterization goldens recorded before anything moves pin the refactor to "identical transcripts".

**Tech Stack:** Swift 6 (DrakarKit tools 6.3, app `SWIFT_VERSION = 6.0`, default actor isolation `MainActor` in the app target), Swift Testing, SwiftPM package `apps/apple/Packages/DrakarKit` (zero dependencies), Xcode project `apps/apple/Drakar.xcodeproj`.

**Spec:** `docs/superpowers/specs/2026-10-06-agent-backend-design.md`. Protocol reference: `docs/claude-stream-json.md`, `docs/codex-app-server.md`.

## Global Constraints

- Work in the worktree `/Users/olivier/Projects/apps/drakar-agent-backend`, branch `feat/agent-backend`. Never edit `/Users/olivier/Projects/apps/drakar` (other sessions commit there).
- Every commit passes `make -C apps/apple test` and `make -C apps/apple test-app`, and `make -C apps/apple format-swift-check`. Run `make -C apps/apple format-swift` before committing.
- DrakarKit imports nothing above Foundation and has no dependencies.
- No visible change: the goldens from Task 1 must pass unchanged at every later commit. Never re-record them after Task 1; a golden failure is a bug in the refactor.
- Existing tests change only as listed in the task that changes them (mechanical renames, `Transcript()` → `ClaudeFeed()`); any other test edit is a red flag to stop and report.
- Never run `make run` (it quits the Drakar in use); the app check is the person's call at landing.
- Comments follow the codebase: a doc comment says what a thing is for, in plain sentences; no em dashes.
- Commit messages: `refactor(apple): …` / `test(apple): …` / `feat(apple): …`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Refinements of the spec

Found while planning against the code; each keeps the spec's intent.

- **`SessionSignal`** carries `changeAnswered(requestID:refusal:)` (one signal for success and refusal, so the session drops its revert either way), `settingsApplied(effort:model:)` (one `get_settings` reply carries both), and `queueChanged` (every `command_lifecycle` line, which the session's deferred turn end waits on).
- **`AgentEvent`** gains `turnOutcome(TurnEnd)` (history's `stop_reason: end_turn` sets how a turn ended without the end-of-turn bookkeeping a `result` does) and `requestSent(at:)` (the prompt cache's anchor), and item events carry no time: `Transcript.apply(_:at:)` takes it, as `apply(StreamMessage, at:)` does today.
- **`FileEdit`** carries its path (`struct FileEdit { path; change }`) and `ToolKind.fileChange(path:edits:)` keeps the call's own path, so a summary still names the file when no edit parses.
- **No `historyReader` on `AgentBackend`:** reading transcript files is disk-side and stays `TranscriptFollower` (Claude-only until slice 3), now driven by `ClaudeTranslator`.
- **`FileChange(toolName:input:existing:)` stays** as a Claude convenience in `ClaudeTools.swift` (built on `ClaudeTools.kind`), so `DiffTests` stay as written; views use `FileChange(path:edits:existing:)`.
- **`launch(_:) -> AgentLaunch` is synchronous**, instead of `configuration(for:) async throws`: the login shell's environment is read asynchronously by the session, which passes it in `AgentStart`.
- **The backend holds no process:** `receive(_:from:at:)` takes one line, the process that wrote it and the time, and `send(_:to:)` takes the process. The session owns the process; the backend keeps only the stream's state (its translator, its request ids).
- **`locateTarget(sessionID:cwd:in:)` lives on the backend**, which knows where its agent writes a session's transcript (Claude-typed until slice 3).
- **No `approvePlan` command:** the session builds `PlanApproval.approve` and sends it as `.answer`.
- **`ClaudeBackend.started` makes a fresh `ClaudeTranslator` per process**, so a restart never carries a previous process's stream state.
- **`AgentCommand.prompt` carries `[EditorSelection]` and `[Attachment]`**, not wire text: the backend writes them in its agent's words (`promptContext` and `block` for Claude Code).
- **`AgentEvent.Item` uses `AgentEvent.ItemKind`** (text, thinking or a tool call), not `Transcript.Kind`, so an agent can never place a prompt or a notice and bypass the transcript's own bookkeeping.

## Review Focus

1. **A tool result that arrives before its call, or a completion after its turn ended** (Codex completes an interrupted turn's command later): `Transcript.apply` must update the entry by id whatever `isRunning` says, and a result with no entry must be dropped silently. Pinned in Task 4.
2. **A streamed text block whose whole block lands empty** (thinking with the text withheld): the streamed text must stay. Pinned in Task 4.
3. **History then live on one session:** history and live use different translators; a live line must never be merged into a history message. Pinned in Task 5 (a history then a live turn with a new message id fold side by side).
4. **A `control_response` or `rate_limit_event` mid-retry** must not clear the retry note; any other line must. Pinned in Task 5.
5. **A mode change the CLI refuses while another is in flight:** each refusal reverts its own pick only. Pinned in Task 8.

---

## File map

DrakarKit (`apps/apple/Packages/DrakarKit/Sources/DrakarKit/`):

| File | Responsibility |
| --- | --- |
| `AgentEvent.swift` (new) | The neutral vocabulary and its payload types |
| `ToolKind.swift` (new) | `ToolKind`, `FileEdit`, summaries, patch parsing |
| `Transcript.swift` (modify) | The neutral model and `apply(_ event: AgentEvent, at:)`; loses `apply(StreamMessage)` |
| `Claude/ClaudeTranslator.swift` (new) | Stream-json and transcript lines → `[AgentEvent]` |
| `Claude/ClaudeTools.swift` (new) | Claude tool names → `ToolKind`; `FileChange(toolName:…)` convenience |
| `Claude/ClaudeFeed.swift` (new) | A `Transcript` fed stream-json, for tests and `Transcript.history` |
| `History.swift` (modify) | `UserText` stays; `applyHistory` moves into the translator; `Transcript.history` goes through `ClaudeFeed` |
| `TranscriptFollower.swift` (modify) | Owns a `ClaudeTranslator` |
| `AgentProcess.swift` (modify) | Emits `.lines([Line])`, sends `JSONValue` or `Data` |
| `Codex/CodexTranslator.swift` (new, Task 9) | The fit check |

App (`apps/apple/Drakar/Services/`):

| File | Responsibility |
| --- | --- |
| `AgentSession.swift` (renamed from `ClaudeSession.swift`) | Generic lifecycle |
| `AgentBackend.swift` (new) | The protocol, `AgentStart`, `AgentLaunch`, `AgentCommand`, `BackendOutput`, `SessionSignal` |
| `ClaudeBackend.swift` (new) | Launch, handshake, encode, receive, locate target |

---

### Task 1: Characterization goldens

Record what today's `Transcript` makes of every capture, before anything moves.

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptSnapshot.swift`
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptGoldenTests.swift`
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Goldens/*.json` (recorded)
- Modify: `apps/apple/Packages/DrakarKit/Package.swift` (exclude `Goldens`)

**Interfaces:**
- Produces: `TranscriptSnapshot(_ transcript: Transcript, now: Date)`; `TranscriptGoldenTests` with scenarios `live:<fixture>` and `history:<fixture>`. Later tasks change only the line that builds the transcript.

- [ ] **Step 1: Exclude the goldens from the package's resources**

In `Package.swift`, the test target becomes:

```swift
    .testTarget(
      name: "DrakarKitTests", dependencies: ["DrakarKit"],
      // Goldens are read from the source tree by path, not bundled.
      exclude: ["Goldens"],
      // Lines captured from the real CLI; docs/claude-stream-json.md says how.
      resources: [.copy("Fixtures")]),
```

- [ ] **Step 2: Write the snapshot**

`TranscriptSnapshot.swift`:

```swift
import DrakarKit
import Foundation

/// Everything a transcript shows, as plain values a golden file can hold: the refactor's
/// contract (docs/superpowers/specs/2026-10-06-agent-backend-design.md, "Testing"). Built
/// from public properties only, so it reads the same before and after the transcript's
/// insides move. `revision` is left out: it counts changes, not what they made.
struct TranscriptSnapshot: Codable, Equatable {
  struct Entry: Codable, Equatable {
    var id: String
    var kind: String
    var text: String?
    var tool: Tool?
    var parent: String?
    var context: String?
    var attachments: [String]
    var thinkingLive: Bool
    var thinkingTimed: Bool
  }

  struct Tool: Codable, Equatable {
    var id: String
    var name: String
    var input: String
    var summary: String
    var result: String?
    var isError: Bool?
    var answers: [String: String]?
    var agentReport: String?
    var earlierAnswers: [String: String]?
  }

  var entries: [Entry]
  var session: String?
  var pending: [String]
  var turnEnd: String?
  var lastTurn: String?
  var title: String?
  var customTitle: String?
  var aiTitle: String?
  var writerVersion: String?
  var historyPermissionMode: String?
  var historyEffort: String?
  var contextUsage: String?
  var contextModelID: String?
  var promptCache: String
  var isRunning: Bool
  var isCompacting: Bool
  var retry: String?
  var queued: [String]
  var todos: [String]?
  var agentTasks: [String]
  var closingText: String?
  var unansweredQuestion: String?

  init(_ t: Transcript, now: Date) {
    entries = t.entries.map(Self.entry)
    session = t.session.map {
      [$0.sessionID, $0.cwd ?? "-", $0.model ?? "-", $0.permissionMode ?? "-",
       $0.claudeCodeVersion ?? "-", $0.apiKeySource ?? "-", $0.tools.joined(separator: ",")]
        .joined(separator: "|")
    }
    pending = t.pendingPermissions.map { "\($0.requestID)|\($0.request.toolName)" }
    turnEnd = t.turnEnd.map { "\($0)" }
    lastTurn = t.lastResult.map {
      "text=\($0.text ?? "-")|cost=\($0.totalCostUSD.map { "\($0)" } ?? "-")"
        + "|duration=\($0.durationMS.map(String.init) ?? "-")"
    }
    title = t.title
    customTitle = t.customTitle
    aiTitle = t.aiTitle
    writerVersion = t.writerVersion
    historyPermissionMode = t.historyPermissionMode
    historyEffort = t.historyEffort
    contextUsage = t.contextUsage.map {
      "\($0.input)/\($0.cacheCreation)/\($0.cacheRead)/\($0.output)/\($0.cacheWriteTTL.map { "\($0)" } ?? "-")"
    }
    contextModelID = t.contextModelID
    promptCache = "\(t.promptCache.state(at: now))"
    isRunning = t.isRunning
    isCompacting = t.isCompacting
    retry = t.retry.map { "\($0.attempt ?? -1)/\($0.maxRetries ?? -1)/\($0.delayMS ?? -1)" }
    queued = t.queuedPrompts.map { "\($0.uuid)|\($0.text)" }
    todos = t.todos?.map { "\($0.status.rawValue)|\($0.content)" }
    agentTasks = t.agentTasks.keys.sorted().map { call in
      let task = t.agentTasks[call]!
      return [call, "\(task.status)", task.description ?? "-", task.prompt ?? "-",
              "\(task.isBackgrounded)", task.summary ?? "-", task.progressLine ?? "-"]
        .joined(separator: "|")
    }
    closingText = t.closingText.map { "\($0.messageID)|\($0.text)" }
    unansweredQuestion = t.unansweredQuestion?.id
  }

  private static func entry(_ e: Transcript.Entry) -> Entry {
    var kind = ""
    var text: String?
    var tool: Tool?
    switch e.kind {
    case .prompt(let s): (kind, text) = ("prompt", s)
    case .text(let s): (kind, text) = ("text", s)
    case .thinking(let s): (kind, text) = ("thinking", s)
    case .notice(let s): (kind, text) = ("notice", s)
    case .failure(let s): (kind, text) = ("failure", s)
    case .tool(let call):
      kind = "tool"
      tool = Tool(
        id: call.id, name: call.name, input: call.input.prettyPrinted, summary: call.summary,
        result: call.result?.content, isError: call.result?.isError,
        answers: call.result?.answers,
        agentReport: call.result?.agentReport.map { "\($0.status)|\($0.text ?? "-")" },
        earlierAnswers: call.earlierAnswers)
    }
    return Entry(
      id: e.id, kind: kind, text: text, tool: tool, parent: e.parentToolUseID,
      context: e.context, attachments: e.attachments.map { "\($0)" },
      thinkingLive: e.thinkingSince != nil, thinkingTimed: e.thinkingDuration != nil)
  }
}
```

If `AttachmentPreview`'s `"\($0)"` is not stable across runs (it should be: a value type's description), replace it with its public fields joined by `|`.

- [ ] **Step 3: Write the golden test**

`TranscriptGoldenTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

/// Every capture, folded by the transcript as it is on 2026-10-06, before the agent went
/// behind a protocol: what each refactoring commit must reproduce exactly. Record once with
/// `DRAKAR_RECORD_GOLDENS=1 swift test --filter TranscriptGoldenTests`; never again in this
/// branch (the plan's Global Constraints).
@Suite("The transcript folds every capture as it did")
struct TranscriptGoldenTests {
  static let start = Date(timeIntervalSince1970: 1_800_000_000)
  static let now = start.addingTimeInterval(600)

  enum Scenario: String, CaseIterable, CustomTestStringConvertible {
    case turnWithTool, permissionRequest, interruptThenTurn, contextUsage, modeAndModel
    case subagentAndTodos, planRequest, queuedPrompts
    case historyWithTool, historyWithAttachments

    var testDescription: String { rawValue }

    var fixture: Fixture {
      switch self {
      case .turnWithTool: .turnWithTool
      case .permissionRequest: .permissionRequest
      case .interruptThenTurn: .interruptThenTurn
      case .contextUsage: .contextUsage
      case .modeAndModel: .modeAndModel
      case .subagentAndTodos: .subagentAndTodos
      case .planRequest: .planRequest
      case .queuedPrompts: .queuedPrompts
      case .historyWithTool: .historyWithTool
      case .historyWithAttachments: .historyWithAttachments
      }
    }

    var isHistory: Bool { self == .historyWithTool || self == .historyWithAttachments }
  }

  struct Golden: Codable, Equatable {
    var running: TranscriptSnapshot
    var exited: TranscriptSnapshot
  }

  /// The one line later tasks change: what folds the capture.
  static func fold(_ scenario: Scenario) throws -> (running: Transcript, exited: Transcript) {
    if scenario.isHistory {
      let history = Transcript.history(lines: try scenario.fixture.lines)
      return (history, history)
    }
    var transcript = Transcript()
    if scenario == .queuedPrompts {
      transcript.addPrompt("Count to five.", at: start)
      transcript.queue(
        QueuedPrompt(
          uuid: "bbbbbbbb-2222-4222-8222-222222222222", text: "Now say the word banana."))
      transcript.queue(
        QueuedPrompt(
          uuid: "cccccccc-3333-4333-8333-333333333333", text: "Now say the word cherry."))
    } else {
      transcript.addPrompt("Run it", at: start)
    }
    for (offset, message) in try scenario.fixture.messages.enumerated() {
      transcript.apply(message, at: start.addingTimeInterval(Double(offset + 1)))
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
    let golden = Golden(
      running: TranscriptSnapshot(running, now: Self.now),
      exited: TranscriptSnapshot(exited, now: Self.now))
    let url = Self.goldenURL(scenario)
    if ProcessInfo.processInfo.environment["DRAKAR_RECORD_GOLDENS"] == "1" {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(golden).write(to: url)
      return
    }
    let recorded = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    #expect(golden.running == recorded.running)
    #expect(golden.exited == recorded.exited)
  }
}
```

- [ ] **Step 4: Run it without goldens to see it fail**

Run: `cd apps/apple && swift test --package-path Packages/DrakarKit --filter TranscriptGoldenTests`
Expected: FAIL, 10 cases, each "The file … couldn't be opened".

- [ ] **Step 5: Record**

Run: `cd apps/apple && DRAKAR_RECORD_GOLDENS=1 swift test --package-path Packages/DrakarKit --filter TranscriptGoldenTests`
Expected: PASS; `ls Packages/DrakarKit/Tests/DrakarKitTests/Goldens` lists 10 `.json` files.

- [ ] **Step 6: Read two goldens before trusting them**

Open `Goldens/turnWithTool.json` and `Goldens/subagentAndTodos.json`. Check by eye: `turnWithTool` has 5 entries (prompt, thinking, tool `Bash` with result `amiral`, thinking, text `Amiral.`), `exited.isRunning` false; `subagentAndTodos` has `todos` with two items and one `agentTasks` line. If a golden shows something the tests in `TranscriptTests`/`AgentTaskTests` contradict, stop and report: the snapshot is wrong.

- [ ] **Step 7: Run it again without recording, then the whole suite**

Run: `make -C apps/apple test`
Expected: PASS, including 10 `foldsAsRecorded` cases.

- [ ] **Step 8: Commit**

```bash
git add apps/apple/Packages/DrakarKit/Package.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptSnapshot.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptGoldenTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Goldens
git commit -m "test(apple): goldens of every capture, folded as the transcript folds them today"
```

---

### Task 2: Rename `ClaudeSession` to `AgentSession`

Mechanical only.

**Files:**
- Rename: `apps/apple/Drakar/Services/ClaudeSession.swift` → `AgentSession.swift`
- Rename: `apps/apple/DrakarTests/ClaudeSession*Tests.swift` → `AgentSession*Tests.swift`
- Modify: every file naming `ClaudeSession` (about 20, listed by the grep below), and `Drakar.xcodeproj/project.pbxproj` only if the target lists files explicitly

**Interfaces:**
- Produces: `final class AgentSession` (same members as `ClaudeSession`).

- [ ] **Step 1: Find every use**

Run: `cd apps/apple && grep -rln '\bClaudeSession\b' Drakar DrakarTests Packages docs ../../docs 2>/dev/null`
Note the list.

- [ ] **Step 2: Rename files and identifiers**

```bash
cd apps/apple
git mv Drakar/Services/ClaudeSession.swift Drakar/Services/AgentSession.swift
for f in DrakarTests/ClaudeSession*Tests.swift; do git mv "$f" "${f/ClaudeSession/AgentSession}"; done
grep -rlZ '\bClaudeSession\b' Drakar DrakarTests | xargs -0 perl -pi -e 's/\bClaudeSession\b/AgentSession/g'
grep -rlZ 'ClaudeSession' Drakar DrakarTests | xargs -0 perl -pi -e 's/ClaudeSession(?=(Tests|PillsTests|QueueTests|RelocateTests|RepliesTests)\b)/AgentSession/g'
```

Check `grep -c ClaudeSession Drakar.xcodeproj/project.pbxproj`: if non-zero, the project lists files by name; apply the same `perl` substitution to it. If zero, the target uses a synchronized folder and needs nothing.

- [ ] **Step 3: Fix the one doc comment that names the class**

In `AgentSession.swift` the class comment reads "One session in a project window: its history from disk, and a `claude` process from its first prompt on." Leave it: still true of the Claude backend until Task 8 rewrites it.

- [ ] **Step 4: Build and test**

Run: `make -C apps/apple test-app && make -C apps/apple test`
Expected: PASS, same counts as before the rename.

- [ ] **Step 5: Commit**

```bash
git add -A apps/apple
git commit -m "refactor(apple): ClaudeSession is AgentSession"
```

---

### Task 3: `ToolKind` and `FileEdit`

Every tool-name comparison outside one Claude file goes.

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ToolKind.swift`
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Claude/ClaudeTools.swift`
- Modify: `Transcript.swift` (`ToolCall.kind`, `place`, `unansweredQuestionIndex`, `questionOutcome`), `Presentation.swift` (summary), `Diff.swift` (`FileChange.init(path:edits:existing:)`; the `toolName` init moves to `ClaudeTools.swift`), `StreamMessage.swift` (`PermissionRequest.kind`, `isChoice`), `PlanApproval.swift` (`isPlan`, `planOutcome`)
- Modify: `apps/apple/Drakar/Views/TranscriptView.swift:269,296,379,381`, `apps/apple/Drakar/Views/PermissionSheet.swift:67-74`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ToolKindTests.swift` (new); `PresentationTests.swift:9` (passes a kind)

**Interfaces:**
- Produces:
  - `public enum ToolKind` with cases `shell(command:)`, `read(path:)`, `search(pattern:)`, `fileChange(path:edits:)`, `web(_:)`, `subagent(description:)`, `question`, `planApproval`, `todos`, `mcp(server:tool:)`, `other`; `func summary(input: JSONValue) -> String`.
  - `public struct FileEdit { path: String; change: Change }`, `enum Change { replace(old:new:), write(content:), patch(String) }`.
  - `public enum ClaudeTools { static func kind(name: String, input: JSONValue) -> ToolKind }`.
  - `Transcript.ToolCall.init(id:name:input:kind:result:)`, `ToolCall.kind`, `PermissionRequest.kind`.
  - `FileChange.init?(path: String, edits: [FileEdit], existing: String? = nil)`; `PatchText.lines(_:) -> (lines: [DiffLine], isNewFile: Bool)`.

- [ ] **Step 1: Write the failing tests**

`ToolKindTests.swift`:

```swift
import DrakarKit
import Testing

@Suite("What a tool call is for")
struct ToolKindTests {
  private func kind(_ name: String, _ input: [String: String] = [:]) -> ToolKind {
    ClaudeTools.kind(name: name, input: .object(input.mapValues(JSONValue.string)))
  }

  @Test func readsEveryClaudeToolItKnows() {
    #expect(kind("Bash", ["command": "ls"]) == .shell(command: "ls"))
    #expect(kind("Read", ["file_path": "/a"]) == .read(path: "/a"))
    #expect(kind("Grep", ["pattern": "x"]) == .search(pattern: "x"))
    #expect(kind("Glob", ["pattern": "*.swift"]) == .search(pattern: "*.swift"))
    #expect(kind("WebFetch", ["url": "https://e.com"]) == .web("https://e.com"))
    #expect(kind("WebSearch", ["query": "swift"]) == .web("swift"))
    #expect(kind("Agent", ["description": "Look"]) == .subagent(description: "Look"))
    #expect(kind("Task") == .subagent(description: nil))
    #expect(kind("AskUserQuestion") == .question)
    #expect(kind("ExitPlanMode") == .planApproval)
    #expect(kind("TodoWrite") == .todos)
    #expect(kind("mcp__github__get_me") == .mcp(server: "github", tool: "get_me"))
    #expect(kind("NotebookEdit", ["notebook_path": "/n"]) == .other)
  }

  @Test func readsTheEditingTools() {
    let edit = FileEdit(path: "/a", change: .replace(old: "x", new: "y"))
    #expect(
      kind("Edit", ["file_path": "/a", "old_string": "x", "new_string": "y"])
        == .fileChange(path: "/a", edits: [edit]))
    #expect(
      kind("Write", ["file_path": "/a", "content": "hi"])
        == .fileChange(path: "/a", edits: [FileEdit(path: "/a", change: .write(content: "hi"))]))
    let multi = ClaudeTools.kind(
      name: "MultiEdit",
      input: .object([
        "file_path": .string("/a"),
        "edits": .array([
          .object(["old_string": .string("a"), "new_string": .string("b")]), .object([:]),
        ]),
      ]))
    #expect(
      multi
        == .fileChange(path: "/a", edits: [FileEdit(path: "/a", change: .replace(old: "a", new: "b"))]))
    #expect(kind("Edit", ["file_path": "/a"]) == .fileChange(path: "/a", edits: []))
  }

  /// A known tool missing the argument it is known by reads as any other tool, which is what
  /// the summary did before kinds: its first string argument.
  @Test func aKnownToolMissingItsArgumentIsOther() {
    #expect(kind("Bash", ["description": "d"]) == .other)
    #expect(kind("Read") == .other)
    #expect(kind("Edit", ["old_string": "x"]) == .other)
  }

  @Test func summarisesByKindThenByFirstStringArgument() {
    #expect(ToolKind.shell(command: "ls").summary(input: .object([:])) == "ls")
    #expect(
      ToolKind.subagent(description: nil).summary(input: .object(["prompt": .string("p")])) == "p")
    #expect(
      ToolKind.other.summary(input: .object(["b": .string("2"), "a": .string("1")])) == "1")
    #expect(ToolKind.question.summary(input: .null) == "")
  }

  @Test func readsCodexPatches() {
    let added = PatchText.lines("hi\nthere\n")
    #expect(added.isNewFile)
    #expect(added.lines == [DiffLine(.added, "hi"), DiffLine(.added, "there")])
    let update = PatchText.lines("@@ -1,2 +1,2 @@\n a\n-b\n+c\n")
    #expect(!update.isNewFile)
    #expect(
      update.lines == [DiffLine(.context, "a"), DiffLine(.removed, "b"), DiffLine(.added, "c")])
    let change = FileChange(path: "/a", edits: [FileEdit(path: "/a", change: .patch("hi\n"))])
    #expect(change?.isNewFile == true)
    #expect(change?.addedCount == 1)
    #expect(FileChange(path: "/a", edits: []) == nil)
  }
}
```

In `PresentationTests.swift` line 9, the helper becomes:

```swift
    Transcript.ToolCall(
      id: "t", name: name, input: .object(input),
      kind: ClaudeTools.kind(name: name, input: .object(input)))
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/apple && swift test --package-path Packages/DrakarKit --filter ToolKindTests`
Expected: FAIL to compile: `ToolKind`, `ClaudeTools`, `FileEdit`, `PatchText` not found.

- [ ] **Step 3: Write `ToolKind.swift`**

```swift
import Foundation

/// What a tool call does, whatever its agent calls it: read once, where the call is made
/// (`ClaudeTools.kind`, and Codex's item types), so nothing downstream compares tool names.
public enum ToolKind: Sendable, Equatable {
  case shell(command: String)
  case read(path: String)
  case search(pattern: String)
  /// `path` is the call's own; `edits` the changes that could be read from it, maybe none.
  case fileChange(path: String, edits: [FileEdit])
  /// A URL fetched or a query searched.
  case web(String)
  case subagent(description: String?)
  case question
  case planApproval
  case todos
  case mcp(server: String, tool: String)
  case other

  /// One line saying what the call does: the command, the file, the pattern. A kind that
  /// names nothing falls back to the call's first string argument, by key order, so the same
  /// call always summarises the same way.
  public func summary(input: JSONValue) -> String {
    switch self {
    case .shell(let command): return command
    case .read(let path): return path
    case .search(let pattern): return pattern
    case .fileChange(let path, _): return path
    case .web(let target): return target
    case .subagent(let description?): return description
    case .subagent(nil), .question, .planApproval, .todos, .mcp, .other: break
    }
    if case .object(let object) = input {
      for key in object.keys.sorted() {
        if let value = object[key]?.stringValue { return value }
      }
    }
    return ""
  }
}

/// One change to one file, as its agent described it.
public struct FileEdit: Sendable, Equatable {
  public enum Change: Sendable, Equatable {
    /// Claude's Edit, and each of MultiEdit's edits.
    case replace(old: String, new: String)
    /// Claude's Write: diffed against the file on disk when drawn.
    case write(content: String)
    /// Codex's `fileChange` diff: a new file's content, or header-less hunks.
    case patch(String)
  }

  public var path: String
  public var change: Change

  public init(path: String, change: Change) {
    self.path = path
    self.change = change
  }
}

/// Codex's diff text (docs/codex-app-server.md, "Items"): a new file's diff is its content,
/// an update's is `@@` hunks with no file headers.
public enum PatchText {
  public static func lines(_ text: String) -> (lines: [DiffLine], isNewFile: Bool) {
    var raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if raw.last == "" { raw.removeLast() }
    guard raw.contains(where: { $0.hasPrefix("@@") }) else {
      return (raw.map { DiffLine(.added, $0) }, true)
    }
    var lines: [DiffLine] = []
    for line in raw where !line.hasPrefix("@@") && !line.hasPrefix("\\") {
      switch line.first {
      case "+": lines.append(DiffLine(.added, String(line.dropFirst())))
      case "-": lines.append(DiffLine(.removed, String(line.dropFirst())))
      default: lines.append(DiffLine(.context, String(line.dropFirst())))
      }
    }
    return (lines, false)
  }
}
```

- [ ] **Step 4: Write `Claude/ClaudeTools.swift`**

```swift
import Foundation

/// The one place that knows Claude Code's tool names and the arguments each is known by
/// (docs/claude-stream-json.md).
public enum ClaudeTools {
  public static func kind(name: String, input: JSONValue) -> ToolKind {
    func string(_ key: String) -> String? { input[key]?.stringValue }
    switch name {
    case "Bash": return string("command").map { .shell(command: $0) } ?? .other
    case "Read": return string("file_path").map { .read(path: $0) } ?? .other
    case "Grep", "Glob": return string("pattern").map { .search(pattern: $0) } ?? .other
    case "WebFetch": return string("url").map(ToolKind.web) ?? .other
    case "WebSearch": return string("query").map(ToolKind.web) ?? .other
    case "Task", "Agent": return .subagent(description: string("description"))
    case UserQuestion.toolName: return .question
    case PlanApproval.toolName: return .planApproval
    case TodoList.toolName: return .todos
    case "Edit", "MultiEdit", "Write":
      guard let path = string("file_path") else { return .other }
      return .fileChange(path: path, edits: edits(name: name, input: input, path: path))
    default:
      let parts = name.components(separatedBy: "__")
      if parts.count >= 3, parts[0] == "mcp" {
        return .mcp(server: parts[1], tool: parts[2...].joined(separator: "__"))
      }
      return .other
    }
  }

  private static func edits(name: String, input: JSONValue, path: String) -> [FileEdit] {
    func replace(_ edit: JSONValue) -> FileEdit? {
      guard let old = edit["old_string"]?.stringValue, let new = edit["new_string"]?.stringValue
      else { return nil }
      return FileEdit(path: path, change: .replace(old: old, new: new))
    }
    switch name {
    case "Edit": return replace(input).map { [$0] } ?? []
    case "MultiEdit": return (input["edits"]?.arrayValue ?? []).compactMap(replace)
    default:
      return input["content"]?.stringValue.map {
        [FileEdit(path: path, change: .write(content: $0))]
      } ?? []
    }
  }
}

extension FileChange {
  /// What a Claude Edit, MultiEdit or Write call does; nil for any other tool.
  public init?(toolName: String, input: JSONValue, existing: String? = nil) {
    guard case .fileChange(let path, let edits) = ClaudeTools.kind(name: toolName, input: input)
    else { return nil }
    self.init(path: path, edits: edits, existing: existing)
  }
}
```

- [ ] **Step 5: Replace `FileChange.init(toolName:…)` in `Diff.swift`**

Delete the `init?(toolName:input:existing:)` body (lines 134–158 today) and put in its place:

```swift
  /// Nil when no edit could be read. `existing` is the file's current content, which only a
  /// write needs (to diff a rewrite against what it replaces); nil means it does not exist.
  public init?(path: String, edits: [FileEdit], existing: String? = nil) {
    guard !edits.isEmpty else { return nil }
    self.path = path
    var diffs: [[DiffLine]] = []
    var isNewFile = false
    for edit in edits {
      switch edit.change {
      case .replace(let old, let new):
        diffs.append(LineDiff.lines(old: old, new: new))
      case .write(let content):
        diffs.append(LineDiff.hunks(old: existing ?? "", new: content, context: 3))
        isNewFile = existing == nil
      case .patch(let text):
        let patch = PatchText.lines(text)
        diffs.append(patch.lines)
        isNewFile = patch.isNewFile
      }
    }
    self.diffs = diffs
    self.isNewFile = isNewFile
  }
```

Update the struct's doc comment: "What a file-changing call does to a file, as diffs a view can draw." A MultiEdit whose edits all lack strings now makes no `FileChange` (it made one with no diffs): a deliberate, invisible-in-practice difference.

- [ ] **Step 6: Give `ToolCall` and `PermissionRequest` their kind**

In `Transcript.swift`, `ToolCall`:

```swift
  public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue
    /// What it does, read once where it was made.
    public var kind: ToolKind
    public var result: ToolResult?
    /// On an `AskUserQuestion` its process never got the answer to, the answers a later
    /// prompt gave it (`UserQuestion.earlierAnswerPrompt`).
    public var earlierAnswers: [String: String]?

    public init(
      id: String, name: String, input: JSONValue, kind: ToolKind, result: ToolResult? = nil
    ) {
      self.id = id
      self.name = name
      self.input = input
      self.kind = kind
      self.result = result
    }
  }
```

In `place`, the tool case:

```swift
    case .toolUse(let toolID, let name, let input):
      key = toolID
      var call = ToolCall(
        id: toolID, name: name, input: input, kind: ClaudeTools.kind(name: name, input: input))
      if let index = indexByID[toolID], case .tool(let existing) = entries[index].kind {
        call.result = existing.result
      }
      kind = .tool(call)
      // Whole, not from a block start, whose input is still empty.
      if replacing, parent == nil, call.kind == .todos { todos = TodoList.todos(input) }
```

In `unansweredQuestionIndex`: `guard call.kind == .question else { return nil }`.
In `questionOutcome`: `guard kind == .question else { return nil }`.

In `StreamMessage.swift`, `PermissionRequest`: add `public var kind: ToolKind` after `toolUseID`, set at the end of `init?`: `kind = ClaudeTools.kind(name: toolName, input: input)`, and `public var isChoice: Bool { kind == .question }`.

In `PlanApproval.swift`: `public var isPlan: Bool { kind == .planApproval }` and in `planOutcome`: `guard kind == .planApproval else { return nil }`.

- [ ] **Step 7: Summaries from the kind**

`Presentation.swift`, the first two extensions become:

```swift
extension Transcript.ToolCall {
  /// One line saying what the call does: the command, the file, the pattern. What a
  /// collapsed tool card shows next to the tool's name.
  public var summary: String { kind.summary(input: input) }
}

extension PermissionRequest {
  public var summary: String { kind.summary(input: input) }
}
```

- [ ] **Step 8: The views**

`TranscriptView.swift`:
- line ~269: `case .tool(let call) where call.name == UserQuestion.toolName:` → `case .tool(let call) where call.kind == .question:`
- line ~296: `case .tool(let call) where call.name == "Agent" || call.name == "Task":` → `case .tool(let call) where { if case .subagent = call.kind { true } else { false } }():` — or, cleaner, add to `ToolKind`: `public var isSubagent: Bool { if case .subagent = self { true } else { false } }` and write `where call.kind.isSubagent`.
- lines ~379–381:

```swift
        if case .fileChange(let path, let edits) = call.kind,
          let change = FileChange(path: path, edits: edits)
        {
          // (the existing body, as it is)
        } else if case .shell = call.kind, !call.summary.isEmpty {
```

`PermissionSheet.swift`, `change(for:)` becomes:

```swift
  private static func change(for request: PermissionRequest) -> FileChange? {
    guard case .fileChange(let path, let edits) = request.kind else { return nil }
    var existing: String?
    if edits.contains(where: { if case .write = $0.change { true } else { false } }) {
      let url = URL(filePath: path)
      // A diff against a huge file is unreadable anyway; past 1 MB it shows as a new file.
      if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000 {
        existing = try? String(contentsOf: url, encoding: .utf8)
      }
    }
    return FileChange(path: path, edits: edits, existing: existing)
  }
```

Finally: `grep -rn '"Bash"\|"Edit"\|"Write"\|"MultiEdit"\|"Agent"\|"Task"\|toolName ==\|\.name == UserQuestion\|\.name == PlanApproval' apps/apple/Drakar apps/apple/Packages/DrakarKit/Sources` must list only `ClaudeTools.swift` and `ContextUsage.swift`'s raw-JSON tail scan (disk-side, out of scope).

- [ ] **Step 9: Run everything**

Run: `make -C apps/apple test && make -C apps/apple test-app`
Expected: PASS, including `ToolKindTests`, `DiffTests` unchanged, and the 10 goldens.

- [ ] **Step 10: Commit**

```bash
make -C apps/apple format-swift
git add -A apps/apple
git commit -m "refactor(apple): tool calls say what they do (ToolKind), not what Claude Code calls them"
```

---

### Task 4: `AgentEvent` and `Transcript.apply(_ event:)`

The neutral reducer, beside the old one; nothing uses it yet but its tests.

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/AgentEvent.swift`
- Modify: `Transcript.swift` (add `apply(_ event: AgentEvent, at:)`, `lastTurn`, `contextWindow`), `AgentTask.swift` (`apply(_ update: AgentTaskUpdate)`), `StreamMessage.swift` (`SessionInfo` memberwise init, `TurnSummary`)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/AgentEventTests.swift` (new)

**Interfaces:**
- Consumes: `ToolKind` (Task 3).
- Produces (exact):

```swift
public enum AgentEvent: Sendable, Equatable {
  case sessionStarted(SessionInfo)
  case prompt(Prompt, running: Bool)
  case turnOutcome(Transcript.TurnEnd)
  case turnEnded(TurnSummary)
  case itemStarted(Item)
  case itemDelta(id: String, Delta)
  case itemCompleted(Item)
  case toolResult(callID: String, Transcript.ToolResult)
  case note(Note)
  case permissionRequested(Transcript.PendingPermission)
  case permissionWithdrawn(requestID: String)
  case requestSent(at: Date)
  case usage(ContextSample)
  case retrying(APIRetry?)
  case compaction(Compaction)
  case todos([Todo])
  case agentTask(callID: String, AgentTaskUpdate)
  case queue(id: String, QueueChange)
  case title(Title)
  case historyMeta(HistoryMeta)
}
// nested: Item{id, parent, kind}, Delta{text, thinking}, Prompt{text, context, attachments},
// Note{text, isFailure, parent}, ContextSample{messageID, usage, model, window, at},
// Compaction{started, stopped, finished(note:at:)}, QueueChange{started, cancelled, dropped(agent:)},
// Title{custom, ai}, HistoryMeta{writerVersion, permissionMode, effort}
public struct TurnSummary { outcome; failureText; text; costUSD; durationMS }
public struct AgentTaskUpdate { isStart; description; isBackgrounded; status; summary; lastToolName; toolUses; totalTokens; durationMS; prompt }
Transcript.apply(_ event: AgentEvent, at time: Date = .now)
Transcript.lastTurn: TurnSummary?   Transcript.contextWindow: Int?
```

- [ ] **Step 1: Write the failing tests**

`AgentEventTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

/// The transcript's own rules, driven by neutral events: what any agent's translator can
/// rely on (docs/superpowers/specs/2026-10-06-agent-backend-design.md, "AgentEvent").
@Suite("Applying agent events")
struct AgentEventTests {
  let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func text(_ id: String, _ s: String) -> AgentEvent.Item {
    AgentEvent.Item(id: id, parent: nil, kind: .text(s))
  }

  private func shell(_ id: String) -> AgentEvent.Item {
    AgentEvent.Item(
      id: id, parent: nil,
      kind: .tool(.init(id: id, name: "Shell", input: .object([:]), kind: .shell(command: "ls"))))
  }

  @Test func streamsThenCompletesOneEntry() {
    var t = Transcript()
    t.apply(.itemStarted(text("m#0", "")))
    t.apply(.itemDelta(id: "m#0", .text("Hel")))
    t.apply(.itemDelta(id: "m#0", .text("lo")))
    #expect(t.entries.map(\.kind) == [.text("Hello")])
    t.apply(.itemCompleted(text("m#0", "Hello!")))
    #expect(t.entries.map(\.kind) == [.text("Hello!")])
  }

  /// Review Focus 2: a block that lands with its text withheld keeps what streamed.
  @Test func aCompletionNeverBlanksStreamedText() {
    var t = Transcript()
    t.apply(.itemStarted(AgentEvent.Item(id: "m#0", parent: nil, kind: .thinking(""))), at: start)
    t.apply(.itemDelta(id: "m#0", .thinking("Weighing")))
    t.apply(
      .itemCompleted(AgentEvent.Item(id: "m#0", parent: nil, kind: .thinking(""))),
      at: start.addingTimeInterval(3))
    #expect(t.entries.first?.kind == .thinking("Weighing"))
    #expect(t.entries.first?.thinkingDuration == 3)
  }

  /// Review Focus 1: Codex completes an interrupted turn's command during a later turn.
  @Test func anItemCompletesAfterItsTurnEnded() {
    var t = Transcript()
    t.addPrompt("first")
    t.apply(.itemStarted(shell("c1")))
    t.apply(.turnEnded(TurnSummary(outcome: .interrupted)))
    t.addPrompt("second")
    t.apply(.toolResult(callID: "c1", .init(content: "done", isError: false)))
    guard case .tool(let call) = t.entries[1].kind else {
      Issue.record("\(t.entries)")
      return
    }
    #expect(call.result?.content == "done")
    #expect(t.isRunning)
  }

  @Test func aResultForNoCallIsDropped() {
    var t = Transcript()
    t.apply(.toolResult(callID: "nobody", .init(content: "x", isError: false)))
    #expect(t.entries.isEmpty)
  }

  @Test func aCompletedCallKeepsAResultThatCameFirst() {
    var t = Transcript()
    t.apply(.itemStarted(shell("c1")))
    t.apply(.toolResult(callID: "c1", .init(content: "out", isError: false)))
    t.apply(.itemCompleted(shell("c1")))
    guard case .tool(let call) = t.entries.first?.kind else { return }
    #expect(call.result?.content == "out")
  }

  @Test func theEndOfATurnClearsWhatWaited() {
    var t = Transcript()
    t.addPrompt("go")
    t.apply(.itemStarted(AgentEvent.Item(id: "m#0", parent: nil, kind: .thinking(""))))
    t.apply(.retrying(APIRetry(attempt: 1, maxRetries: 3, delayMS: 500)))
    t.apply(.turnEnded(TurnSummary(outcome: .failed, failureText: "Overloaded")))
    #expect(!t.isRunning)
    #expect(t.turnEnd == .failed)
    #expect(t.entries.last?.kind == .failure("Overloaded"))
    #expect(t.entries[1].thinkingSince == nil)
    #expect(t.lastTurn?.outcome == .failed)
  }

  @Test func aQueuedPromptJoinsWhenTaken() {
    var t = Transcript()
    t.addPrompt("first")
    t.queue(QueuedPrompt(uuid: "q", text: "second"))
    t.apply(.queue(id: "q", .started))
    #expect(t.queuedPrompts.isEmpty)
    #expect(t.lastPrompt?.kind == .prompt("second"))
    t.queue(QueuedPrompt(uuid: "r", text: "third"))
    t.apply(.queue(id: "r", .dropped(agent: "Codex")))
    #expect(t.entries.last?.kind == .notice("Codex did not take a queued message: third"))
  }

  @Test func usageCarriesTheWindowWhenTheAgentSaysIt() {
    var t = Transcript()
    let usage = TokenUsage(input: 10, cacheCreation: 0, cacheRead: 5, output: 1)
    t.apply(.usage(.init(messageID: "turn-1", usage: usage, model: nil, window: 258_400, at: nil)))
    #expect(t.contextUsage == usage)
    #expect(t.contextWindow == 258_400)
  }
}
```

If `APIRetry` has no public memberwise init, add one in `StreamMessage.swift`: `public init(attempt: Int?, maxRetries: Int?, delayMS: Int?)` (check its stored properties and keep their order).

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/apple && swift test --package-path Packages/DrakarKit --filter AgentEventTests`
Expected: FAIL to compile: `AgentEvent`, `TurnSummary` not found.

- [ ] **Step 3: Write `AgentEvent.swift`**

```swift
import Foundation

/// What changed in a conversation, in no agent's words: how a `Transcript` learns what its
/// agent said. Each agent's translator turns its wire format into these
/// (`ClaudeTranslator`; Codex's in slice 2), so the transcript knows no wire format.
///
/// Items are addressed by their own id, never by "the current turn": Codex completes a
/// command its interrupted turn left running during a later turn (docs/codex-app-server.md).
/// What the person does (a prompt sent, a request answered, the process gone) stays the
/// transcript's own methods.
public enum AgentEvent: Sendable, Equatable {
  case sessionStarted(SessionInfo)
  /// A prompt the agent's record shows: a history line. `running` false for one whose turn
  /// ended long ago.
  case prompt(Prompt, running: Bool)
  /// How the newest turn ended is known, without the end-of-turn bookkeeping: Claude's
  /// history marks `stop_reason: end_turn` and has no result line.
  case turnOutcome(Transcript.TurnEnd)
  case turnEnded(TurnSummary)
  /// A text, a thinking block or a tool call begins: streaming follows.
  case itemStarted(Item)
  case itemDelta(id: String, Delta)
  /// The whole item. Never blanks text that streamed.
  case itemCompleted(Item)
  case toolResult(callID: String, Transcript.ToolResult)
  case note(Note)
  case permissionRequested(Transcript.PendingPermission)
  case permissionWithdrawn(requestID: String)
  /// A main-thread request went out: what the prompt cache is reckoned from.
  case requestSent(at: Date)
  case usage(ContextSample)
  /// Nil: whatever was being retried is over.
  case retrying(APIRetry?)
  case compaction(Compaction)
  case todos([Todo])
  case agentTask(callID: String, AgentTaskUpdate)
  case queue(id: String, QueueChange)
  case title(Title)
  case historyMeta(HistoryMeta)

  public struct Item: Sendable, Equatable {
    public var id: String
    /// The subagent call it runs under; nil on the main thread.
    public var parent: String?
    /// `.text`, `.thinking` or `.tool`.
    public var kind: Transcript.Kind

    public init(id: String, parent: String?, kind: Transcript.Kind) {
      self.id = id
      self.parent = parent
      self.kind = kind
    }
  }

  public enum Delta: Sendable, Equatable {
    case text(String)
    case thinking(String)
  }

  public struct Prompt: Sendable, Equatable {
    public var text: String
    public var context: String?
    public var attachments: [AttachmentPreview]

    public init(text: String, context: String? = nil, attachments: [AttachmentPreview] = []) {
      self.text = text
      self.context = context
      self.attachments = attachments
    }
  }

  public struct Note: Sendable, Equatable {
    public var text: String
    public var isFailure: Bool
    public var parent: String?

    public init(text: String, isFailure: Bool = false, parent: String? = nil) {
      self.text = text
      self.isFailure = isFailure
      self.parent = parent
    }
  }

  /// A main-thread request's tokens: the session's context.
  public struct ContextSample: Sendable, Equatable {
    /// What the prompt cache keys its anchor by: every block of one message repeats it.
    public var messageID: String
    public var usage: TokenUsage
    public var model: String?
    /// The model's context window, when the agent says it (Codex does, Claude does not).
    public var window: Int?
    /// When it arrived or was written; nil leaves the prompt cache as it was.
    public var at: Date?

    public init(
      messageID: String, usage: TokenUsage, model: String?, window: Int? = nil, at: Date?
    ) {
      self.messageID = messageID
      self.usage = usage
      self.model = model
      self.window = window
      self.at = at
    }
  }

  public enum Compaction: Sendable, Equatable {
    case started
    case stopped
    /// `at` nil leaves the prompt cache as it was.
    case finished(note: String, at: Date?)
  }

  public enum QueueChange: Sendable, Equatable {
    /// Taken into a turn, or joined the running one.
    case started
    case cancelled
    /// Refused or discarded, by the agent named.
    case dropped(agent: String)
  }

  public enum Title: Sendable, Equatable {
    case custom(String)
    case ai(String)
  }

  /// What a transcript file says of the session another process runs.
  public enum HistoryMeta: Sendable, Equatable {
    case writerVersion(String)
    case permissionMode(String)
    /// Nil when the newest reply names none (a model without effort).
    case effort(String?)
  }
}

/// How a turn ended, as far as its agent said.
public struct TurnSummary: Sendable, Equatable {
  public var outcome: Transcript.TurnEnd
  /// Why it failed, when it did and the agent said.
  public var failureText: String?
  /// What it ended on, when the agent repeats it with the end.
  public var text: String?
  public var costUSD: Double?
  public var durationMS: Int?

  public init(
    outcome: Transcript.TurnEnd, failureText: String? = nil, text: String? = nil,
    costUSD: Double? = nil, durationMS: Int? = nil
  ) {
    self.outcome = outcome
    self.failureText = failureText
    self.text = text
    self.costUSD = costUSD
    self.durationMS = durationMS
  }
}

/// What became known of a subagent, by the call that started it. Nil fields say nothing.
public struct AgentTaskUpdate: Sendable, Equatable {
  /// The first word of it: its description wins over one guessed earlier.
  public var isStart = false
  public var description: String?
  public var isBackgrounded: Bool?
  public var status: String?
  public var summary: String?
  public var lastToolName: String?
  public var toolUses: Int?
  public var totalTokens: Int?
  public var durationMS: Int?
  /// What it was asked, forwarded from inside it.
  public var prompt: String?

  public init() {}
}
```

- [ ] **Step 4: `AgentTask` applies updates**

In `AgentTask.swift`, replace `mutating func apply(_ event: TaskEvent)` with:

```swift
  mutating func apply(_ update: AgentTaskUpdate) {
    if let description = update.description, update.isStart || self.description == nil {
      self.description = description
    }
    if let isBackgrounded = update.isBackgrounded { self.isBackgrounded = isBackgrounded }
    if let status = update.status { self.status = Status(status) }
    if let summary = update.summary { self.summary = summary }
    if let prompt = update.prompt { self.prompt = prompt }
    lastToolName = update.lastToolName ?? lastToolName
    toolUses = update.toolUses ?? toolUses
    totalTokens = update.totalTokens ?? totalTokens
    durationMS = update.durationMS ?? durationMS
  }
```

and add to `TaskEvent`:

```swift
  /// The same, in no agent's words.
  var update: AgentTaskUpdate {
    var update = AgentTaskUpdate()
    update.isStart = kind == .started
    update.description = description
    update.isBackgrounded = isBackgrounded
    update.status = status
    update.summary = summary
    update.lastToolName = lastToolName
    update.toolUses = toolUses
    update.totalTokens = totalTokens
    update.durationMS = durationMS
    return update
  }
```

In `Transcript.apply(StreamMessage)`, `.system(.task(let event))` now calls `.apply(event.update)`; the subagent-prompt line becomes `agentTasks[user.parentToolUseID!, default: AgentTask()].prompt = prompt` unchanged.

- [ ] **Step 5: `SessionInfo` memberwise init**

In `StreamMessage.swift`, `SessionInfo` gains (keep the JSON `init?`):

```swift
  public init(
    sessionID: String, cwd: String? = nil, model: String? = nil, permissionMode: String? = nil,
    claudeCodeVersion: String? = nil, apiKeySource: String? = nil, tools: [String] = []
  ) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.model = model
    self.permissionMode = permissionMode
    self.claudeCodeVersion = claudeCodeVersion
    self.apiKeySource = apiKeySource
    self.tools = tools
  }
```

- [ ] **Step 6: `Transcript.apply(_ event:)`**

In `Transcript.swift` add, below `contextModelID`:

```swift
  /// How the newest turn ended, as its agent summed it up.
  public private(set) var lastTurn: TurnSummary?
  /// The model's context window, when the agent says it.
  public private(set) var contextWindow: Int?
```

and the reducer (after `apply(_ message: StreamMessage, time:)`; both coexist until Task 5):

```swift
  /// `time` is when the event arrived: what times thinking streamed live and a prompt taken
  /// from the queue.
  public mutating func apply(_ event: AgentEvent, at time: Date = .now) {
    revision += 1
    switch event {
    case .sessionStarted(let info):
      session = info
    case .prompt(let prompt, let running):
      addPrompt(
        prompt.text, context: prompt.context, attachments: prompt.attachments, running: running,
        at: time)
    case .turnOutcome(let end):
      turnEnd = end
    case .turnEnded(let summary):
      lastTurn = summary
      turnEnd = summary.outcome
      isRunning = false
      isCompacting = false
      if let failure = summary.failureText, !endsSaying(failure) { addNote(.failure(failure)) }
      // A turn that ended cannot still be asking, nor thinking.
      pendingPermissions.removeAll()
      stopThinking()
    case .itemStarted(let item):
      place(item, replacing: false, at: time)
    case .itemCompleted(let item):
      place(item, replacing: true, at: time)
    case .itemDelta(let id, let delta):
      guard let position = indexByID[id] else { return }
      switch (entries[position].kind, delta) {
      case (.text(let text), .text(let more)): entries[position].kind = .text(text + more)
      case (.thinking(let text), .thinking(let more)):
        entries[position].kind = .thinking(text + more)
      default: break
      }
    case .toolResult(let id, let result):
      guard let index = indexByID[id], case .tool(var call) = entries[index].kind else { return }
      call.result = result
      entries[index].kind = .tool(call)
    case .note(let note):
      addNote(note.isFailure ? .failure(note.text) : .notice(note.text), parent: note.parent)
    case .permissionRequested(let pending):
      pendingPermissions.append(pending)
    case .permissionWithdrawn(let id):
      resolvePermission(requestID: id)
    case .requestSent(let at):
      requestAt = at
    case .usage(let sample):
      contextUsage = sample.usage
      contextModelID = sample.model ?? contextModelID
      if let window = sample.window { contextWindow = window }
      if let at = sample.at {
        promptCache.record(
          messageID: sample.messageID, usage: sample.usage, at: at, requestAt: requestAt)
        requestAt = nil
      }
    case .retrying(let retry):
      self.retry = retry
    case .compaction(.started):
      isCompacting = true
    case .compaction(.stopped):
      isCompacting = false
    case .compaction(.finished(let note, let at)):
      isCompacting = false
      if let at { promptCache.compacted(at: at) }
      addNotice(note)
    case .todos(let todos):
      self.todos = todos
    case .agentTask(let call, let update):
      agentTasks[call, default: AgentTask()].apply(update)
    case .queue(let id, let change):
      guard let index = queuedPrompts.firstIndex(where: { $0.uuid == id }) else { return }
      let prompt = queuedPrompts.remove(at: index)
      switch change {
      case .started:
        addPrompt(prompt.text, context: prompt.context, attachments: prompt.attachments, at: time)
      case .cancelled:
        break
      case .dropped(let agent):
        addNotice(String(localized: "\(agent) did not take a queued message: \(prompt.text)"))
      }
    case .title(.custom(let title)):
      customTitle = title
    case .title(.ai(let title)):
      aiTitle = title
    case .historyMeta(.writerVersion(let version)):
      writerVersion = version
    case .historyMeta(.permissionMode(let mode)):
      historyPermissionMode = mode
    case .historyMeta(.effort(let effort)):
      historyEffort = effort
    }
  }

  /// Puts an item at its id. A tool call keeps a result that reached it first.
  private mutating func place(_ item: AgentEvent.Item, replacing: Bool, at time: Date) {
    var kind = item.kind
    if case .tool(var call) = kind, let index = indexByID[item.id],
      case .tool(let existing) = entries[index].kind, call.result == nil
    {
      call.result = existing.result
      kind = .tool(call)
    }
    if let index = indexByID[item.id] {
      // A started item is empty by definition, and a thinking block can land whole with its
      // text withheld after its deltas showed some: never replace with nothing.
      if replacing && !Self.isEmptyText(kind) { entries[index].kind = kind }
      if replacing, let since = entries[index].thinkingSince {
        entries[index].thinkingSince = nil
        entries[index].thinkingDuration = time.timeIntervalSince(since)
        thinkingIDs.remove(item.id)
      }
    } else {
      var entry = Entry(id: item.id, kind: kind, parentToolUseID: item.parent)
      if !replacing, case .thinking = kind {
        entry.thinkingSince = time
        thinkingIDs.insert(item.id)
      }
      upsert(entry)
    }
  }
```

Rename the old `place(_ block: ContentBlock, …)` to `placeBlock(_:id:parent:replacing:at:)` (both call sites in `apply(StreamMessage)` and `apply(StreamEvent)`) so the two overloads cannot be confused; it is deleted in Task 5.

- [ ] **Step 7: Run the new tests and the goldens**

Run: `make -C apps/apple test`
Expected: PASS: `AgentEventTests` (8), goldens unchanged.

- [ ] **Step 8: Commit**

```bash
make -C apps/apple format-swift
git add -A apps/apple/Packages/DrakarKit
git commit -m "feat(apple): AgentEvent, the transcript's neutral vocabulary, and its reducer"
```

---

### Task 5: `ClaudeTranslator` (live) and `ClaudeFeed`

Stream-json becomes events; `Transcript.apply(StreamMessage)` goes.

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Claude/ClaudeTranslator.swift`
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Claude/ClaudeFeed.swift`
- Modify: `Transcript.swift` (delete `apply(StreamMessage…)`, `apply(StreamEvent…)`, `placeBlock`, `blockCount`, `streamingMessage`, `agentCallByTask`; keep `compactionNote`, `declinedQuestionNote`, `messageID(ofEntry:)`), `History.swift` (`applyHistory` calls the translator: done fully in Task 6; here it builds a temporary `ClaudeTranslator` per call so it compiles), `apps/apple/Drakar/Services/AgentSession.swift` (owns a translator)
- Modify tests: every `Transcript()` that is then fed `apply(StreamMessage)`/`applyHistory` becomes `ClaudeFeed()`; `TranscriptGoldenTests.fold` likewise
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ClaudeTranslatorTests.swift` (new)

**Interfaces:**
- Consumes: `AgentEvent`, `Transcript.apply(_:at:)` (Task 4), `ClaudeTools.kind` (Task 3).
- Produces:
  - `public struct ClaudeTranslator: Sendable { public init(); public mutating func translate(_ message: StreamMessage, at time: Date?) -> [AgentEvent] }`
  - `@dynamicMemberLookup public struct ClaudeFeed: Sendable` with `transcript`, `apply(_ message: StreamMessage, at:)`, `applyHistory(_ json: JSONValue)`, and forwarders `addPrompt`, `queue`, `resolvePermission`, `processExited`, `noteColdCache`, `grouped`.

- [ ] **Step 1: Write the failing translator tests**

`ClaudeTranslatorTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Claude Code's stream as agent events")
struct ClaudeTranslatorTests {
  private func lines(_ json: String...) throws -> [StreamMessage] {
    try json.map { try StreamMessage(line: Data($0.utf8)) }
  }

  /// Per-block `assistant` lines share a message id: block n is `<id>#n`; a tool call is
  /// keyed by its own id.
  @Test func keysBlocksByMessageAndToolsByTheirOwnID() throws {
    var translator = ClaudeTranslator()
    let messages = try lines(
      #"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"a"}]}}"#,
      #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls"}}]}}"#)
    let events = messages.flatMap { translator.translate($0, at: nil) }
    let items = events.compactMap { event -> String? in
      if case .itemCompleted(let item) = event { return item.id }
      return nil
    }
    #expect(items == ["m#0", "t"])
  }

  /// Review Focus 4: a control response or a rate-limit line leaves a retry standing.
  @Test func clearsTheRetryOnAnythingButAnswersAndLimits() throws {
    var translator = ClaudeTranslator()
    let messages = try lines(
      #"{"type":"control_response","response":{"subtype":"success","request_id":"r"}}"#,
      #"{"type":"rate_limit_event","rate_limit_info":{}}"#,
      #"{"type":"system","subtype":"status","status":"requesting"}"#)
    #expect(!translator.translate(messages[0], at: nil).contains(.retrying(nil)))
    #expect(!translator.translate(messages[1], at: nil).contains(.retrying(nil)))
    #expect(translator.translate(messages[2], at: nil).first == .retrying(nil))
  }

  /// Review Focus 3: history and a live turn fold side by side, each with its translator.
  @Test func historyThenALiveTurnStayApart() throws {
    var feed = ClaudeFeed()
    for line in try Fixture.historyWithTool.lines {
      feed.applyHistory(try JSONValue.parse(line))
    }
    let before = feed.entries.count
    feed.addPrompt("again")
    for message in try Fixture.turnWithTool.messages { feed.apply(message) }
    #expect(feed.entries.count == before + 5)
    #expect(feed.entries.last?.kind == .text("Amiral."))
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/apple && swift test --package-path Packages/DrakarKit --filter ClaudeTranslatorTests`
Expected: FAIL to compile: `ClaudeTranslator`, `ClaudeFeed` not found.

- [ ] **Step 3: Write `Claude/ClaudeTranslator.swift`**

Move the quirks out of `Transcript`'s doc comment into this one.

```swift
import Foundation

/// Claude Code's stream-json, and its transcript files, as agent events: the only place that
/// knows the protocol's quirks (docs/claude-stream-json.md).
///
/// - the CLI sends one `assistant` line **per content block**, every one carrying the same
///   message id, so the n-th line for an id is block n of that message, keyed `<id>#<n>`;
/// - under `--include-partial-messages` the same block also arrives as a
///   `content_block_start` and its deltas, *before* its `assistant` line, under the same key;
/// - a tool call is keyed by its own id, so that its result, in another message, finds it;
/// - the CLI does not echo the user's prompt live: the session adds it.
///
/// One per process, and one per transcript file read: its state is the stream's.
public struct ClaudeTranslator: Sendable {
  /// Blocks seen per assistant message, which is how a per-block `assistant` line learns
  /// its index.
  private var blockCount: [String: Int] = [:]
  /// The message a stream event belongs to, per subagent (nil key: the main thread).
  private var streamingMessage: [String?: String] = [:]
  /// A streamed block's position key, for a tool call keyed by its own id.
  private var toolAtPosition: [String: String] = [:]
  /// `task_updated` names only the task; this finds its call.
  private var agentCallByTask: [String: String] = [:]

  public init() {}

  /// `time` is when the line arrived or was written; nil for a history line that says not.
  public mutating func translate(_ message: StreamMessage, at time: Date?) -> [AgentEvent] {
    var events: [AgentEvent] = []
    switch message {
    case .system(.apiRetry), .rateLimit, .controlResponse: break
    default: events.append(.retrying(nil))
    }
    switch message {
    case .system(.initialized(let info)):
      events.append(.sessionStarted(info))
    case .system(.apiRetry(let retry)):
      events.append(.retrying(retry))
    case .system(.status(let status, _)):
      events.append(.compaction(status == "compacting" ? .started : .stopped))
    case .system(.compacted(let trigger, let preTokens)):
      events.append(
        .compaction(
          .finished(
            note: Transcript.compactionNote(trigger: trigger, preTokens: preTokens), at: time)))
    case .system(.notification(let text, let isError)):
      events.append(.note(.init(text: text, isFailure: isError)))
    case .system(.task(let event)):
      if let call = event.toolUseID { agentCallByTask[event.taskID] = call }
      if let call = event.toolUseID ?? agentCallByTask[event.taskID] {
        events.append(.agentTask(callID: call, event.update))
      }
    case .assistant(let assistant):
      events += translate(assistant, at: time)
    case .streamEvent(let event, let parent):
      events += translate(event, parent: parent)
    case .user(let user):
      events += translate(user, at: time)
    case .controlRequest(let request):
      switch request.kind {
      case .canUseTool(let permission):
        events.append(
          .permissionRequested(.init(requestID: request.requestID, request: permission)))
      case .elicitation(let server, let question):
        events.append(
          .note(.init(text: Transcript.declinedQuestionNote(server: server, question: question))))
      case .other: break
      }
    case .controlCancelRequest(let id):
      events.append(.permissionWithdrawn(requestID: id))
    case .commandLifecycle(let uuid, let state):
      switch state {
      case "started": events.append(.queue(id: uuid, .started))
      case "cancelled": events.append(.queue(id: uuid, .cancelled))
      case "discarded", "refused": events.append(.queue(id: uuid, .dropped(agent: "Claude Code")))
      default: break
      }
    case .result(let result):
      events.append(
        .turnEnded(
          TurnSummary(
            outcome: result.wasInterrupted ? .interrupted : result.isError ? .failed : .completed,
            failureText: result.failureText, text: result.text, costUSD: result.totalCostUSD,
            durationMS: result.durationMS)))
    case .system, .controlResponse, .rateLimit, .unknown:
      break
    }
    return events
  }

  private mutating func translate(_ assistant: AssistantMessage, at time: Date?) -> [AgentEvent] {
    var events: [AgentEvent] = []
    // A `<synthetic>` turn ("You've hit your session limit", an API error) is written by
    // the CLI, not the API: its usage is all zeros and says nothing of the context.
    if assistant.parentToolUseID == nil, assistant.model != TranscriptTail.syntheticModel,
      let usage = assistant.usage
    {
      events.append(
        .usage(.init(messageID: assistant.messageID, usage: usage, model: assistant.model, at: time)))
    }
    if assistant.parentToolUseID == nil, assistant.stopReason == "end_turn" {
      events.append(.turnOutcome(.completed))
    }
    let index = blockCount[assistant.messageID, default: 0]
    for (offset, block) in assistant.content.enumerated() {
      let position = "\(assistant.messageID)#\(index + offset)"
      guard let item = item(block, position: position, parent: assistant.parentToolUseID) else {
        continue
      }
      events.append(.itemCompleted(item))
      // Whole, not from a block start, whose input is still empty.
      if assistant.parentToolUseID == nil, case .tool(let call) = item.kind, call.kind == .todos {
        events.append(.todos(TodoList.todos(call.input)))
      }
    }
    blockCount[assistant.messageID] = index + assistant.content.count
    return events
  }

  private mutating func translate(_ event: StreamEvent, parent: String?) -> [AgentEvent] {
    switch event {
    case .messageStart(let id):
      streamingMessage[parent] = id
    case .blockStart(let index, let block):
      guard let message = streamingMessage[parent],
        let item = item(block, position: "\(message)#\(index)", parent: parent)
      else { return [] }
      return [.itemStarted(item)]
    case .blockDelta(let index, let delta):
      guard let message = streamingMessage[parent] else { return [] }
      let position = "\(message)#\(index)"
      let id = toolAtPosition[position] ?? position
      switch delta {
      case .text(let text): return [.itemDelta(id: id, .text(text))]
      case .thinking(let text): return [.itemDelta(id: id, .thinking(text))]
      default: return []  // tool input fragments only parse whole; the `assistant` line brings it
      }
    case .messageStop:
      streamingMessage[parent] = nil
    case .blockStop, .messageDelta, .other:
      break
    }
    return []
  }

  private func translate(_ user: UserMessage, at time: Date?) -> [AgentEvent] {
    var events: [AgentEvent] = []
    if user.parentToolUseID == nil, let time { events.append(.requestSent(at: time)) }
    // Live, the CLI never echoes our prompts, so any text it writes as a user turn is a note
    // of its own: an interrupt, a background task finishing.
    for case .text(let text) in user.content {
      switch UserText.classify(text) {
      // A subagent's prompt, forwarded from inside it: the card's, not a note.
      case .prompt(let prompt) where user.parentToolUseID != nil:
        var update = AgentTaskUpdate()
        update.prompt = prompt
        events.append(.agentTask(callID: user.parentToolUseID!, update))
      case .prompt(let note), .notice(let note):
        events.append(.note(.init(text: note, parent: user.parentToolUseID)))
      case .context, .hidden: break
      }
    }
    let results = user.content.filter {
      if case .toolResult = $0 { return true }
      return false
    }
    for case .toolResult(let id, let content, let isError) in results {
      events.append(
        .toolResult(
          callID: id,
          .init(
            content: content, isError: isError,
            answers: results.count == 1 ? user.questionAnswers : nil,
            agentReport: results.count == 1 ? user.agentReport : nil)))
    }
    return events
  }

  /// A block as an item at `position`; a tool call at its own id. Nil for what is not one.
  private mutating func item(_ block: ContentBlock, position: String, parent: String?)
    -> AgentEvent.Item?
  {
    switch block {
    case .text(let text): return .init(id: position, parent: parent, kind: .text(text))
    case .thinking(let text): return .init(id: position, parent: parent, kind: .thinking(text))
    case .toolUse(let id, let name, let input):
      toolAtPosition[position] = id
      return .init(
        id: id, parent: parent,
        kind: .tool(
          .init(id: id, name: name, input: input, kind: ClaudeTools.kind(name: name, input: input))))
    case .toolResult, .other: return nil
    }
  }
}
```

Note one behavioural subtlety to verify against the goldens: `Transcript.place` today, on a *replacing* tool call, keeps the existing entry's result; `Transcript.place(item:)` (Task 4) does the same only when the incoming call has no result, which an `assistant` line's never has. Equivalent.

- [ ] **Step 4: Write `Claude/ClaudeFeed.swift`**

```swift
import Foundation

/// A transcript fed Claude Code's stream-json and transcript lines: a `Transcript` and the
/// `ClaudeTranslator` that reads for it. What tests and `Transcript.history` use; a session
/// keeps the two apart, its translator in its backend.
@dynamicMemberLookup
public struct ClaudeFeed: Sendable {
  public private(set) var transcript = Transcript()
  private var translator = ClaudeTranslator()

  public init() {}

  public subscript<Value>(dynamicMember path: KeyPath<Transcript, Value>) -> Value {
    transcript[keyPath: path]
  }

  /// `time` is when the line arrived.
  public mutating func apply(_ message: StreamMessage, at time: Date = .now) {
    for event in translator.translate(message, at: time) { transcript.apply(event, at: time) }
  }

  /// One transcript-file line.
  public mutating func applyHistory(_ json: JSONValue) {
    let time = ClaudeTranslator.timestamp(of: json)
    for event in translator.history(json) { transcript.apply(event, at: time ?? .now) }
  }

  // What the person does, as on a `Transcript`.

  public mutating func addPrompt(
    _ text: String, context: String? = nil, attachments: [AttachmentPreview] = [],
    running: Bool = true, at time: Date = .now
  ) {
    transcript.addPrompt(
      text, context: context, attachments: attachments, running: running, at: time)
  }

  public mutating func queue(_ prompt: QueuedPrompt) { transcript.queue(prompt) }
  public mutating func resolvePermission(requestID: String) {
    transcript.resolvePermission(requestID: requestID)
  }
  public mutating func processExited() { transcript.processExited() }
  public mutating func noteColdCache(at now: Date = .now) { transcript.noteColdCache(at: now) }
  public func grouped() -> (top: [Transcript.Entry], children: [String: [Transcript.Entry]]) {
    transcript.grouped()
  }
}
```

`translator.history(_:)` and `ClaudeTranslator.timestamp(of:)` arrive in Task 6; for this task add them as a first cut that reproduces today's `applyHistory` by calling `translate` (Step 5), so `ClaudeFeed` compiles.

- [ ] **Step 5: History through the translator (first cut)**

In `ClaudeTranslator.swift`, add:

```swift
extension ClaudeTranslator {
  /// When a transcript line was written.
  public static func timestamp(of json: JSONValue) -> Date? {
    json["timestamp"]?.stringValue.flatMap {
      try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0)
    }
  }

  /// One transcript-file line (`<config>/projects/<encoded cwd>/<session id>.jsonl`).
  /// Unknown entry types (attachments, snapshots, cost records) and subagent sidechains say
  /// nothing.
  public mutating func history(_ json: JSONValue) -> [AgentEvent] {
    guard json["isSidechain"]?.boolValue != true else { return [] }
    var events: [AgentEvent] = []
    if let version = json["version"]?.stringValue, !version.isEmpty {
      events.append(.historyMeta(.writerVersion(version)))
    }
    let time = Self.timestamp(of: json)
    switch json["type"]?.stringValue {
    case "ai-title":
      if let title = json["aiTitle"]?.stringValue, !title.isEmpty { events.append(.title(.ai(title))) }
    case "custom-title":
      if let title = json["customTitle"]?.stringValue, !title.isEmpty {
        events.append(.title(.custom(title)))
      }
    case "assistant":
      events.append(.historyMeta(.effort(json["effort"]?.stringValue)))
      if let message = try? StreamMessage(json: json) { events += translate(message, at: time) }
    case "user":
      if json["isMeta"]?.boolValue == true { return events }
      if let time { events.append(.requestSent(at: time)) }
      if let mode = json["permissionMode"]?.stringValue {
        events.append(.historyMeta(.permissionMode(mode)))
      }
      if json["isCompactSummary"]?.boolValue == true {
        events.append(
          .compaction(.finished(note: String(localized: "Earlier conversation compacted"), at: time)))
        return events
      }
      guard case .user(let user)? = try? StreamMessage(json: json) else { return events }
      var prompt: [String] = []
      var context: [String] = []
      for case .text(let text) in user.content {
        switch UserText.classify(text) {
        case .prompt(let part): prompt.append(part)
        case .notice(let note): events.append(.note(.init(text: note, parent: user.parentToolUseID)))
        case .context(let label): context.append(label)
        case .hidden: break
        }
      }
      if !prompt.isEmpty || !user.attachments.isEmpty {
        events.append(
          .prompt(
            .init(
              text: prompt.joined(separator: "\n\n"),
              context: context.isEmpty ? nil : context.joined(separator: ", "),
              attachments: user.attachments),
            running: false))
      }
      // Tool results go through the live path, which pairs them with their calls.
      let results = user.content.filter {
        if case .toolResult = $0 { return true }
        return false
      }
      if !results.isEmpty {
        var resultsOnly = user
        resultsOnly.content = results
        events += translate(.user(resultsOnly), at: time)
      }
    default:
      break
    }
    return events
  }
}
```

Check against `History.swift` today, line by line: (1) `applyHistory` set `historyEffort` *before* applying the assistant line: same order here; (2) it set `requestAt` before the compact-summary check: same; (3) the compact-summary notice did not touch `isCompacting`, which `.finished` sets false: it is already false in history (no `status` lines there), so the goldens hold. `UserMessage.content` must be `var` for `resultsOnly` (it is today).

Then in `History.swift`: delete `applyHistory`, delete `timestamp(of:)` (now `ClaudeTranslator.timestamp`), and make `Transcript.history(lines:)`:

```swift
  public static func history(lines: [Data]) -> Transcript {
    var feed = ClaudeFeed()
    for line in lines {
      guard let json = try? JSONValue.parse(line) else { continue }
      feed.applyHistory(json)
    }
    feed.processExited()
    return feed.transcript
  }
```

Move the `history(lines:)` / `history(contentsOf:)` extension's doc comment unchanged. `TranscriptFollower.catchUp`:

```swift
public struct TranscriptFollower: Sendable {
  public let file: URL
  /// Bytes read so far.
  public private(set) var offset: UInt64 = 0
  private var buffer = LineBuffer()
  private var translator = ClaudeTranslator()
  …
    if size < offset {
      offset = 0
      buffer = LineBuffer()
      translator = ClaudeTranslator()
      transcript = Transcript()
    }
    …
    for line in buffer.append(data) {
      guard let json = try? JSONValue.parse(line) else { continue }
      let time = ClaudeTranslator.timestamp(of: json)
      for event in translator.history(json) { transcript.apply(event, at: time ?? .now) }
    }
    transcript.processExited()
```

- [ ] **Step 6: Delete the old reducer**

In `Transcript.swift` delete: `public mutating func apply(_ message: StreamMessage, at:)`, `mutating func apply(_ message: StreamMessage, time:)`, `private mutating func apply(_ event: StreamEvent, …)`, `placeBlock`, and the properties `blockCount`, `streamingMessage`, `agentCallByTask`. Replace the type's doc comment with:

```swift
/// A session's conversation, as its agent's events built it (`AgentEvent`): what the view
/// draws. It knows no wire format; each agent's translator does (`ClaudeTranslator`).
```

Keep `compactionNote`, `declinedQuestionNote` and `messageID(ofEntry:)` (the closing text's message: entries of one message share the id before `#`).

- [ ] **Step 7: The session translates**

In `AgentSession.swift`: add `@ObservationIgnored private var translator = ClaudeTranslator()` beside `process`, and in `apply(_ message: StreamMessage)` replace `transcript.apply(message)` with:

```swift
    for event in translator.translate(message, at: .now) { transcript.apply(event) }
```

(Task 8 moves this into `ClaudeBackend`.)

- [ ] **Step 8: Tests feed through `ClaudeFeed`**

Mechanical: in each DrakarKit test file that calls `.apply(` with a `StreamMessage` or `.applyHistory(`, change the `Transcript()` it feeds to `ClaudeFeed()` (files from the earlier count: `TranscriptTests`, `AgentTaskTests`, `ContextUsageTests`, `PromptCacheTests`, `QueuedPromptTests`, `PlanApprovalTests`, `TodoListTests`, `InterruptTests`, `NothingSilentTests`, `AttachmentTests`, `PresentationTests`). Leave a `Transcript()` that is only passed to `TranscriptFollower.catchUp(&)` or never fed. Helpers returning `Transcript` (e.g. `TranscriptTests.transcript(_:prompt:)`) return `ClaudeFeed`. Where a test passes the value to an API typed `Transcript` (a `#expect(a.entries == b.entries)` across a `Transcript` and a `ClaudeFeed` is fine through dynamic member lookup), pass `.transcript`. In `TranscriptTests.swift:64`, `transcript.lastResult?.text` becomes `transcript.lastTurn?.text`. In `TranscriptGoldenTests.fold`, `var transcript = Transcript()` becomes `var transcript = ClaudeFeed()`, `exited` takes `transcript` as a `ClaudeFeed`, and the return is `(transcript.transcript, exited.transcript)`; `TranscriptSnapshot` reads `t.lastTurn` instead of `t.lastResult`, with `$0.costUSD` for `$0.totalCostUSD` (same string otherwise; how the turn ended is already in `turnEnd`).

Remove `Transcript.lastResult` (`SessionView.swift:449` reads `session.transcript.lastTurn?.costUSD`).

- [ ] **Step 9: Run everything**

Run: `make -C apps/apple test && make -C apps/apple test-app`
Expected: PASS: `ClaudeTranslatorTests` (3), `AgentEventTests`, every existing test, the 10 goldens unchanged.

- [ ] **Step 10: Commit**

```bash
make -C apps/apple format-swift
git add -A apps/apple
git commit -m "refactor(apple): Claude Code's stream reaches the transcript as agent events"
```

---

### Task 6: `SessionInfo.agentVersion`

The last Claude-named field the transcript holds.

**Files:**
- Modify: `StreamMessage.swift` (`claudeCodeVersion` → `agentVersion`, JSON key unchanged), `Drakar/Views/SessionView.swift:440`, `StreamMessageTests.swift:37`, `TranscriptSnapshot.swift`

- [ ] **Step 1: Rename**

```bash
cd apps/apple
grep -rlZ 'claudeCodeVersion' Drakar DrakarTests Packages | xargs -0 perl -pi -e 's/\bclaudeCodeVersion\b/agentVersion/g'
```

In `SessionInfo`, the doc comment of `agentVersion`: "The version of the agent's CLI that runs the session: `claude_code_version` for Claude Code."

- [ ] **Step 2: Run everything**

Run: `make -C apps/apple test && make -C apps/apple test-app`
Expected: PASS, goldens unchanged.

- [ ] **Step 3: Commit**

```bash
git add -A apps/apple
git commit -m "refactor(apple): a session names its agent's version, not Claude Code's"
```

---

### Task 7: `AgentProcess` speaks lines

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/AgentProcess.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Claude/ClaudeTranslator.swift` (Claude conveniences), `apps/apple/Drakar/Services/AgentSession.swift`, `apps/apple/Drakar/Services/CapabilityProbe.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ProcessTests.swift` (`messages` helper only)

**Interfaces:**
- Produces: `AgentProcess.Event.lines([AgentProcess.Line])` (replacing `.messages`), `public enum Line: Sendable, Equatable { case json(JSONValue); case invalid(String) }`, `func send(_ json: JSONValue) throws`, `func send(line: Data) throws`; in the Claude file: `extension AgentProcess { func send(_ message: ClientMessage) throws }`, `extension StreamMessage { init(_ line: AgentProcess.Line) }`.

- [ ] **Step 1: Change the helper the process tests read through**

In `ProcessTests.swift`:

```swift
  private func messages(_ events: [AgentProcess.Event]) -> [StreamMessage] {
    events.flatMap { event -> [StreamMessage] in
      if case .lines(let batch) = event { return batch.map(StreamMessage.init) }
      return []
    }
  }
```

Run: `cd apps/apple && swift test --package-path Packages/DrakarKit --filter AgentProcessTests`
Expected: FAIL to compile: no `.lines`.

- [ ] **Step 2: The process**

In `AgentProcess.swift`: the doc comment's first line becomes "An agent's CLI speaking JSON lines over its pipes."; `Event.messages([StreamMessage])` becomes:

```swift
    /// What the process wrote, a line each, parsed off the main thread.
    case lines([Line])
```

add:

```swift
  /// One line of stdout: JSON, or text kept as it was (a warning printed to stdout).
  public enum Line: Sendable, Equatable {
    case json(JSONValue)
    case invalid(String)
  }
```

the readability handler yields `.lines(lines.map(Self.parse))` with

```swift
  private static func parse(_ line: Data) -> Line {
    (try? JSONValue.parse(line)).map(Line.json) ?? .invalid(String(decoding: line, as: UTF8.self))
  }
```

(delete `decode`), and `send` becomes:

```swift
  public func send(line: Data) throws {
    guard process.isRunning else { throw Failure.notRunning }
    try input.fileHandleForWriting.write(contentsOf: line)
  }

  /// `json` as one line, encoded as `ClientMessage` encodes its own (`JSONValue.line()`).
  public func send(_ json: JSONValue) throws {
    try send(line: json.line())
  }
```

- [ ] **Step 3: Claude conveniences**

At the end of `ClaudeTranslator.swift`:

```swift
extension AgentProcess {
  public func send(_ message: ClientMessage) throws { try send(line: message.line()) }
}

extension StreamMessage {
  /// A line as stream-json; one that is not (no JSON, or no `type`) is kept, not dropped.
  public init(_ line: AgentProcess.Line) {
    switch line {
    case .json(let json):
      self = (try? StreamMessage(json: json)) ?? .unknown(type: "invalid-line", raw: json)
    case .invalid(let text):
      self = .unknown(type: "invalid-line", raw: .string(text))
    }
  }
}
```

- [ ] **Step 4: Callers**

`AgentSession.handle`: `case .messages(let messages): for message in messages { apply(message) }` → `case .lines(let lines): for line in lines { apply(StreamMessage(line)) }`.
`CapabilityProbe.swift`: wherever it matches `.messages(let batch)`, match `.lines(let batch)` and map `StreamMessage.init`. Read the file first; change only the pattern.

- [ ] **Step 5: Run everything**

Run: `make -C apps/apple test && make -C apps/apple test-app`
Expected: PASS: `AgentProcessTests` unchanged (the invalid line still reads `.unknown(type: "invalid-line", raw: .string("not-json"))`), `CapabilityProbeTests`, goldens.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add -A apps/apple
git commit -m "refactor(apple): the agent process speaks JSON lines, not Claude Code's messages"
```

---

### Task 8: `AgentBackend` and `ClaudeBackend`

**Files:**
- Create: `apps/apple/Drakar/Services/AgentBackend.swift`, `apps/apple/Drakar/Services/ClaudeBackend.swift`
- Modify: `apps/apple/Drakar/Services/AgentSession.swift`
- Test: `apps/apple/DrakarTests/ClaudeBackendTests.swift` (new); existing session tests unchanged

**Interfaces:**
- Consumes: `AgentProcess.Line`, `send(_ json:)` (Task 7), `ClaudeTranslator` (Task 5), `AgentEvent` (Task 4).
- Produces (app target, `MainActor` by default):

```swift
protocol AgentBackend: AnyObject {
  var notFoundMessage: String { get }
  func launch(_ start: AgentStart) -> AgentLaunch
  func started(_ process: AgentProcess, then first: AgentCommand?) throws
  func receive(_ line: AgentProcess.Line, from process: AgentProcess, at time: Date) -> BackendOutput
  @discardableResult func send(_ command: AgentCommand, to process: AgentProcess) throws -> String?
  func locateTarget(sessionID: String, cwd: String, in accounts: [ClaudeAccount]) -> ResumeTarget?
}
struct AgentStart { folder; resuming: ResumeTarget?; environment; executableOverride: URL?;
                    model: String?; mode: PermissionMode?; effort: String?; allowsBypass: Bool; name: String? }
struct AgentLaunch { configuration: AgentProcess.Configuration?; executable: URL?; account: ClaudeAccount? }
enum AgentCommand { prompt(text:context:uuid:attachments:), answer(requestID:decision:),
                    interrupt(cancelQueued:), cancelQueued(uuid:), setMode(String), setModel(String),
                    setEffort(String), rename(title:sessionID:) }
struct BackendOutput { events: [AgentEvent]; signals: [SessionSignal] }
enum SessionSignal { initialized(JSONValue?), commandsChanged(JSONValue), models([ModelOption]),
                     modeAdopted(String), settingsApplied(effort: String?, model: String?),
                     contextReported(ContextUsageReply), rateLimit(JSONValue),
                     changeAnswered(requestID: String, refusal: String?), queueChanged }
AgentSession.init(folder: URL, resuming: ResumeTarget? = nil, backend: AgentBackend = ClaudeBackend())
```

- [ ] **Step 1: Write the failing backend tests**

`ClaudeBackendTests.swift` (read `AgentSessionRepliesTests.swift` first for how the app tests stand a `/bin/sh` script in for `claude`, and reuse its helper):

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@Suite("Claude Code behind the backend")
struct ClaudeBackendTests {
  private func line(_ json: String) throws -> AgentProcess.Line {
    .json(try JSONValue.parse(Data(json.utf8)))
  }

  /// A `cat` stands in for the process: what the backend writes is not read here. Ended when
  /// the suite's process exits; each is a few kilobytes.
  private func process() throws -> AgentProcess {
    let process = AgentProcess(
      .init(
        executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
        currentDirectory: FileManager.default.temporaryDirectory))
    _ = try process.start()
    return process
  }

  @Test func initializeAnswersWithModelsAndTheMode() throws {
    let backend = ClaudeBackend()
    let output = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"models":[],"current_permission_mode":"plan"}}}"#),
      from: try process(), at: .now)
    #expect(output.events.isEmpty)
    #expect(output.signals.contains(.modeAdopted("plan")))
    #expect(output.signals.contains { if case .initialized = $0 { true } else { false } })
  }

  /// Review Focus 5: each refusal names its own request.
  @Test func aRefusalNamesItsRequest() throws {
    let backend = ClaudeBackend()
    let process = try process()
    let first = try backend.send(.setMode("acceptEdits"), to: process)
    let second = try backend.send(.setMode("bypassPermissions"), to: process)
    #expect(first != second)
    let output = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(second!)","error":"Not allowed"}}"#),
      from: process, at: .now)
    #expect(output.signals == [.changeAnswered(requestID: second!, refusal: "Not allowed")])
  }

  @Test func aLifecycleLineSaysTheQueueMoved() throws {
    let output = ClaudeBackend().receive(
      try line(#"{"type":"command_lifecycle","command_uuid":"u","state":"queued"}"#),
      from: try process(), at: .now)
    #expect(output.signals == [.queueChanged])
  }
}
```

`SessionSignal` must be `Equatable` (all payloads are; `ModelOption` and `ContextUsageReply` already are; check).

Run: `make -C apps/apple test-app`
Expected: FAIL to compile: `ClaudeBackend` not found.

- [ ] **Step 2: Write `AgentBackend.swift`**

```swift
import DrakarKit
import Foundation

/// One agent's wire format, behind which `AgentSession` runs it: how to start its CLI, what
/// its lines mean, how a command is written. Claude Code's is `ClaudeBackend`.
///
/// Stateless about the process, which the session owns and passes in; stateful about the
/// stream (its translator, its request ids).
protocol AgentBackend: AnyObject {
  /// Shown when the agent's CLI was not found.
  var notFoundMessage: String { get }
  /// What to run for `start`; no executable when the CLI was not found.
  func launch(_ start: AgentStart) -> AgentLaunch
  /// Everything owed right after the process started, then `first`, the prompt typed before
  /// it existed.
  func started(_ process: AgentProcess, then first: AgentCommand?) throws
  /// One line the process wrote. A reply the agent waits for is written here.
  func receive(_ line: AgentProcess.Line, from process: AgentProcess, at time: Date)
    -> BackendOutput
  /// Writes `command`; the request id, where an answer can come back (mode, model, effort).
  @discardableResult func send(_ command: AgentCommand, to process: AgentProcess) throws
    -> String?
  /// Where a session's own transcript is, once it has an id. Disk-side, Claude-typed until
  /// Codex history (slice 3).
  func locateTarget(sessionID: String, cwd: String, in accounts: [ClaudeAccount]) -> ResumeTarget?
}

/// What a session asks to start with: its folder, what it resumes, and its pills' picks,
/// frozen for this process.
struct AgentStart {
  var folder: URL
  var resuming: ResumeTarget?
  /// The login shell's.
  var environment: [String: String]
  var executableOverride: URL?
  /// Nil or `default`: the agent's own.
  var model: String?
  var mode: PermissionMode?
  var effort: String?
  var allowsBypass: Bool
  /// A name not yet recorded.
  var name: String?
}

struct AgentLaunch {
  /// Nil when the CLI was not found.
  var configuration: AgentProcess.Configuration?
  var executable: URL?
  var account: ClaudeAccount?
}

/// What the person does, in no agent's words.
enum AgentCommand {
  case prompt(text: String, context: [String], uuid: String, attachments: [Attachment])
  case answer(requestID: String, decision: PermissionDecision)
  case interrupt(cancelQueued: Bool)
  case cancelQueued(uuid: String)
  case setMode(String)
  case setModel(String)
  case setEffort(String)
  case rename(title: String, sessionID: String)
}

struct BackendOutput {
  /// What the conversation shows.
  var events: [AgentEvent] = []
  /// What the session learns, never shown as conversation.
  var signals: [SessionSignal] = []
}

enum SessionSignal: Equatable {
  /// The handshake's answer, which lists the skills.
  case initialized(JSONValue?)
  case commandsChanged(JSONValue)
  case models([ModelOption])
  case modeAdopted(String)
  case settingsApplied(effort: String?, model: String?)
  case contextReported(ContextUsageReply)
  case rateLimit(JSONValue)
  /// A mode, model or effort change was answered: `refusal` nil when it took.
  case changeAnswered(requestID: String, refusal: String?)
  /// A queued prompt moved: taken, cancelled, dropped, or only acknowledged.
  case queueChanged
}
```

`PermissionDecision`, `Attachment`, `ModelOption` and `ContextUsageReply` are DrakarKit or app types today; if `ModelOption` lives in the app, this file still compiles (same target).

- [ ] **Step 3: Write `ClaudeBackend.swift`**

Every line below moves from `AgentSession.swift`; nothing is new behaviour.

```swift
import DrakarKit
import Foundation

/// Claude Code over stream-json (docs/claude-stream-json.md): `ClaudeLaunch` and
/// `ClaudeCommand` for the start, `ClaudeTranslator` for what it writes, `ClientMessage` for
/// what it is sent.
final class ClaudeBackend: AgentBackend {
  /// The arguments the next start runs with (a model for a debug launch).
  var command = ClaudeCommand()
  private var translator = ClaudeTranslator()
  private var requestCount = 0

  var notFoundMessage: String { ClaudeLaunch.notFound }

  func launch(_ start: AgentStart) -> AgentLaunch {
    var command = command
    if let model = start.model, model != "default" { command.model = model }
    if let mode = start.mode, mode != .ask { command.permissionMode = mode.rawValue }
    command.effort = start.effort
    command.allowsBypass = start.allowsBypass
    if let resuming = start.resuming {
      command.resumeSessionID = resuming.sessionID
      command.forksSession = resuming.forks == true
    }
    command.name = start.name
    let launch = ClaudeLaunch.make(
      folder: start.folder, resuming: start.resuming, environment: start.environment,
      executableOverride: start.executableOverride)
    return AgentLaunch(
      configuration: launch.executable.map {
        .init(
          executable: $0, arguments: command.arguments, environment: launch.environment,
          currentDirectory: start.folder)
      },
      executable: launch.executable, account: launch.account)
  }

  func started(_ process: AgentProcess, then first: AgentCommand?) throws {
    try process.send(.initialize(requestID: nextRequestID("init")))
    askAppliedSettings(process)
    if let first { try send(first, to: process) }
  }

  @discardableResult func send(_ command: AgentCommand, to process: AgentProcess) throws
    -> String?
  {
    let (message, id) = encode(command)
    try process.send(message)
    return id
  }

  private func encode(_ command: AgentCommand) -> (ClientMessage, String?) {
    switch command {
    case .prompt(let text, let context, let uuid, let attachments):
      return (
        .prompt(text, context: context, uuid: uuid, attachments: attachments.map(\.block)), nil
      )
    case .answer(let id, let decision):
      return (.permission(requestID: id, decision), nil)
    case .interrupt(let cancelQueued):
      return (.interrupt(requestID: nextRequestID("interrupt"), cancelQueued: cancelQueued), nil)
    case .cancelQueued(let uuid):
      return (.cancelQueued(requestID: nextRequestID("cancel"), uuid: uuid), nil)
    case .setMode(let mode):
      let id = nextRequestID("mode")
      return (.setPermissionMode(requestID: id, mode: mode), id)
    case .setModel(let model):
      let id = nextRequestID("model")
      return (.setModel(requestID: id, model: model), id)
    case .setEffort(let level):
      let id = nextRequestID("effort")
      return (.setEffort(requestID: id, level: level), id)
    case .rename(let title, let sessionID):
      return (
        .renameSession(requestID: nextRequestID("rename"), title: title, sessionID: sessionID), nil
      )
    }
  }

  func receive(_ line: AgentProcess.Line, from process: AgentProcess, at time: Date)
    -> BackendOutput
  {
    let message = StreamMessage(line)
    var output = BackendOutput()
    switch message {
    case .rateLimit(let info):
      output.signals.append(.rateLimit(info))
    case .controlResponse(let response) where response.requestID.hasPrefix("init-"):
      if response.isSuccess {
        if let models = ModelOption.list(fromInitialize: response.response) {
          output.signals.append(.models(models))
        }
        if let mode = response.response?["current_permission_mode"]?.stringValue {
          output.signals.append(.modeAdopted(mode))
        }
        output.signals.append(.initialized(response.response))
      }
    case .controlResponse(let response)
    where ["mode-", "model-", "effort-"].contains(where: response.requestID.hasPrefix):
      if response.isSuccess {
        if let mode = response.response?["mode"]?.stringValue {
          output.signals.append(.modeAdopted(mode))
        }
        if !response.requestID.hasPrefix("mode-") { askAppliedSettings(process) }
      }
      output.signals.append(
        .changeAnswered(
          requestID: response.requestID,
          refusal: response.isSuccess
            ? nil : response.error ?? String(localized: "Claude Code refused the change.")))
      return output
    case .controlResponse(let response) where response.requestID.hasPrefix("settings-"):
      if response.isSuccess {
        output.signals.append(
          .settingsApplied(
            effort: EffortLevel.applied(fromSettings: response.response),
            model: ModelName.applied(fromSettings: response.response)))
      }
      return output
    case .controlResponse(let response) where response.requestID.hasPrefix("context-"):
      if response.isSuccess, let reply = ContextUsageReply(response.response) {
        output.signals.append(.contextReported(reply))
      }
      return output
    case .system(.initialized(let info)):
      if let mode = info.permissionMode { output.signals.append(.modeAdopted(mode)) }
    case .system(.status(_, let mode?)):
      output.signals.append(.modeAdopted(mode))
    case .system(.commandsChanged(let commands)):
      output.signals.append(.commandsChanged(commands))
    case .controlRequest(let request):
      // Not `write`: a reply that cannot be written must not mark the session failed.
      if let reply = request.reply { try? process.send(reply) }
    case .commandLifecycle:
      output.signals.append(.queueChanged)
    case .result:
      // Not `write`: a failed context request must not mark the session failed.
      try? process.send(.contextUsage(requestID: nextRequestID("context")))
    default:
      break
    }
    output.events = translator.translate(message, at: time)
    return output
  }

  /// The transcript lands under whichever account the shell selected; look for it in each.
  func locateTarget(sessionID id: String, cwd: String, in accounts: [ClaudeAccount])
    -> ResumeTarget?
  {
    for account in accounts {
      let projects = account.directory.appending(path: "projects")
      let folders =
        (try? FileManager.default.contentsOfDirectory(atPath: projects.path(percentEncoded: false)))
        ?? []
      for name in folders {
        let file = projects.appending(path: "\(name)/\(id).jsonl")
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
          continue
        }
        return ResumeTarget(
          sessionID: id, cwd: cwd, file: file.path(percentEncoded: false),
          accountDirectory: account.directory.path(percentEncoded: false),
          accountIsDefault: account.isDefault)
      }
    }
    return nil
  }

  /// What the process applies now: asked after its start and after each model or effort
  /// change, since a model without effort (Haiku) applies none.
  private func askAppliedSettings(_ process: AgentProcess) {
    try? process.send(.getSettings(requestID: nextRequestID("settings")))
  }

  private func nextRequestID(_ prefix: String) -> String {
    requestCount += 1
    return "\(prefix)-\(requestCount)"
  }
}
```

Two orderings to keep exactly as today, checked by `AgentSessionRepliesTests` and `AgentSessionTests`: the `.result` context request is written *before* the session reacts to the turn's end (today: after `transcript.apply`, before `onTurnEnded`; both are before the next line, so either is fine); the `controlRequest` reply is written before the transcript sees the request (as here). The `ModelOption.list` today records only when `account` is known: the session keeps that condition (Step 4).

- [ ] **Step 4: Slim `AgentSession`**

In `AgentSession.swift`:

1. Class doc comment: "One session in a project window: its history from disk, and its agent's process from its first prompt on. Main-actor state over an `AgentProcess` and an `AgentBackend`: lines are parsed off the main thread, interpreted by the backend, and applied here, which is all the view observes."
2. `init(folder: URL, resuming: ResumeTarget? = nil, backend: AgentBackend = ClaudeBackend())`, storing `@ObservationIgnored let backend: AgentBackend`.
3. Delete: `var command = ClaudeCommand()` (now `ClaudeBackend.command`; grep shows no caller sets it), `requestCount`, `nextRequestID`, `translator` (Task 5), `askAppliedSettings`, `findTarget` (replace calls with `locateTarget()` below), the whole `apply(_ message: StreamMessage)`.
4. `pendingPrompt: ClientMessage?` → `pendingPrompt: AgentCommand?`.
5. `send(_:context:attachments:)`: build `let command = AgentCommand.prompt(text: text, context: context.map(\.promptContext), uuid: uuid, attachments: attachments)` instead of the `ClientMessage`, and `write(command)`.
6. `setMode`: `guard let process else { return }`, `permissionMode = mode.rawValue`, then
   ```swift
       guard let id = try? backend.send(.setMode(mode.rawValue), to: process) else { return }
       revertOnError[id] = { [weak self] in
         self?.modePick = previousPick
         self?.permissionMode = previousMode
       }
   ```
   and likewise `setModel` (`.setModel(value)`) and `setEffort` (`.setEffort(level)`). The revert is registered after the send now; answers arrive on a later main-actor turn, so it is in place first.
7. `spawn`: replace the block from `var command = command` to the `AgentProcess(...)` construction with:
   ```swift
       // The pills' picks, frozen for this process: the session's own, else Settings'.
       modelPick = pickedModel
       modePick = startingMode
       let environment = await Self.environment.value
       guard stillWanted(since: stops) else { return }
       guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
         return fail(String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
       }
       let start = AgentStart(
         folder: folder, resuming: resuming, environment: environment,
         executableOverride: executableOverride, model: modelPick, mode: modePick,
         effort: effortPick ?? ClaudeChoice.defaultEffort, allowsBypass: ClaudeChoice.allowsBypass,
         name: unsentName)
       let launch = backend.launch(start)
       account = launch.account
       guard let configuration = launch.configuration else { return fail(backend.notFoundMessage) }
       executable = launch.executable
       // (the existing isLiveElsewhere block, as it is)
       let process = AgentProcess(configuration)
       do {
         let stream = try process.start()
         self.process = process
         launchedWithBypass = start.allowsBypass
         unsentName = nil
         try backend.started(process, then: pendingPrompt)
         pendingPrompt = nil
         phase = .ready
         …events task unchanged…
   ```
8. `answer`: `write(.answer(requestID: pending.requestID, decision: decision))`.
9. `sendUnsentName`: `try? backend.send(.rename(title: title, sessionID: id), to: process!)` with `guard let process` in the existing guard.
10. `interrupt`: `write(.interrupt(cancelQueued: true))`; `cancelQueued`: `if let process { try? backend.send(.cancelQueued(uuid: prompt.uuid), to: process) }`.
11. `write(_ command: AgentCommand)`:
    ```swift
      private func write(_ command: AgentCommand) {
        guard let process else { return }
        do {
          try backend.send(command, to: process)
        } catch {
          phase = .failed(error.localizedDescription)
        }
      }
    ```
12. `locateTarget()`:
    ```swift
      /// The transcript lands under whichever account the shell selected; look for it in each.
      /// It exists from the first prompt on, which is when the session gave its id.
      private func locateTarget() -> ResumeTarget? {
        guard let id = sessionID else { return nil }
        return backend.locateTarget(
          sessionID: id, cwd: transcript.session?.cwd ?? folder.path(percentEncoded: false),
          in: accounts())
      }
    ```
13. `handle(_ event:)`: `case .lines(let lines): for line in lines { receive(line) }` and:
    ```swift
      private func receive(_ line: AgentProcess.Line) {
        guard let process else { return }
        let output = backend.receive(line, from: process, at: .now)
        for signal in output.signals { handle(signal) }
        let waiting = transcript.pendingPermissions.count
        var turnEnded = false
        for event in output.events {
          transcript.apply(event)
          if case .turnEnded = event { turnEnded = true }
        }
        if unsentName != nil { sendUnsentName() }
        if transcript.pendingPermissions.count > waiting,
          let pending = transcript.pendingPermissions.last
        {
          onPermissionRequested?(pending)
        }
        permissionsMayHaveChanged(from: waiting)
        if turnEndDeferred, output.signals.contains(.queueChanged) {
          if transcript.isRunning {
            turnEndDeferred = false
          } else if transcript.queuedPrompts.isEmpty {
            turnEndDeferred = false
            onTurnEnded?()
          }
        }
        if turnEnded {
          if savedTarget == nil { savedTarget = locateTarget() }
          // Not while a queued prompt is about to start the next one: said once the queue
          // empties without a turn, should it be cancelled or refused instead.
          if transcript.queuedPrompts.isEmpty { onTurnEnded?() } else { turnEndDeferred = true }
        }
      }

      private func handle(_ signal: SessionSignal) {
        switch signal {
        case .rateLimit(let info):
          if let account { accountStore.record(info, for: account) }
        case .models(let models):
          if let account { catalog.record(models, for: account) }
        case .modeAdopted(let mode):
          adopt(mode: mode)
        case .initialized(let reply):
          onInitialized?(reply)
        case .commandsChanged(let commands):
          onCommandsChanged?(commands)
        case .settingsApplied(let effort, let model):
          appliedEffort = effort
          appliedModel = model
        case .contextReported(let reply):
          reportedContext = reply
        case .changeAnswered(let id, let refusal):
          let revert = revertOnError.removeValue(forKey: id)
          if let refusal {
            revert?()
            pillNote = refusal
          }
        case .queueChanged:
          break
        }
      }
    ```
    Today a mode/model/effort/settings/context response returned before `sendUnsentName()` and the permission bookkeeping; running them on those lines now changes nothing observable (no events, so no permission change; the name is sent at most once, as soon as an id is known).
14. `ownTarget()` and `spawn()`'s two `findTarget()` calls → `locateTarget()`.

Then: `grep -n 'ClientMessage\|StreamMessage\|ClaudeCommand\|nextRequestID' apps/apple/Drakar/Services/AgentSession.swift` must print nothing.

- [ ] **Step 5: Run everything**

Run: `make -C apps/apple test-app && make -C apps/apple test`
Expected: PASS: `ClaudeBackendTests` (3), every `AgentSession*Tests` unchanged, `PlanApprovalSessionTests`, `SessionPillsTests`, `AccountStoreTests`, the goldens.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add -A apps/apple
git commit -m "refactor(apple): AgentSession runs its agent through an AgentBackend; Claude Code's is ClaudeBackend"
```

---

### Task 9: The Codex fit check

A translator for what `docs/codex-app-server.md` verified, tested on scrubbed captures, used by nothing.

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexTranslator.swift`
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/codex-turn.jsonl`
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexTranslatorTests.swift`
- Modify: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift` (a case), `StreamMessage.swift` (`PermissionRequest` memberwise init)

**Interfaces:**
- Consumes: `AgentEvent`, `ToolKind`, `FileEdit`, `PatchText` (Tasks 3–4), `TokenUsage`, `SessionInfo.init` (Task 4).
- Produces: `public struct CodexTranslator: Sendable { public init(); public mutating func translate(_ message: JSONValue, at time: Date?) -> [AgentEvent] }`.

- [ ] **Step 1: The fixture**

`Fixtures/codex-turn.jsonl`: server-to-client lines from the 2026-10-06 captures (`probe.log`, `b-approvals.log`, `e-reasoning.log`; codex-cli 0.160.1), ids shortened, paths under `/Users/me/project`, account and installation ids dropped, MCP startup lines dropped. Exactly these 17 lines:

```jsonl
{"method":"thread/started","params":{"thread":{"id":"thread-1","sessionId":"thread-1","cwd":"/Users/me/project","model":"gpt-6-astra","reasoningEffort":"low","cliVersion":"0.160.1","status":{"type":"idle"}}}}
{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}
{"method":"item/started","params":{"item":{"type":"userMessage","id":"user-1","clientId":null,"content":[{"type":"text","text":"Create hello.txt with hi, then run touch from-shell.txt.","text_elements":[]}]},"threadId":"thread-1","turnId":"turn-1"}}
{"method":"item/started","params":{"item":{"type":"reasoning","id":"rs-1","summary":[],"content":[]},"threadId":"thread-1","turnId":"turn-1"}}
{"method":"item/reasoning/summaryPartAdded","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"rs-1","summaryIndex":0}}
{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"rs-1","delta":"**Planning the file**","summaryIndex":0}}
{"method":"item/completed","params":{"item":{"type":"reasoning","id":"rs-1","summary":["**Planning the file**"],"content":[]},"threadId":"thread-1","turnId":"turn-1"}}
{"method":"item/started","params":{"item":{"type":"fileChange","id":"patch-1","changes":[{"path":"/Users/me/project/hello.txt","kind":{"type":"add"},"diff":"hi\n"}],"status":"inProgress"},"threadId":"thread-1","turnId":"turn-1"}}
{"method":"item/fileChange/requestApproval","id":0,"params":{"threadId":"thread-1","turnId":"turn-1","itemId":"patch-1","reason":null,"grantRoot":null}}
{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":0}}
{"method":"item/completed","params":{"item":{"type":"fileChange","id":"patch-1","changes":[{"path":"/Users/me/project/hello.txt","kind":{"type":"add"},"diff":"hi\n"}],"status":"completed"},"threadId":"thread-1","turnId":"turn-1"}}
{"method":"item/commandExecution/requestApproval","id":1,"params":{"kind":"command","threadId":"thread-1","turnId":"turn-1","itemId":"exec-1","command":"/bin/zsh -lc 'touch from-shell.txt'","cwd":"/Users/me/project","commandActions":[{"type":"unknown","command":"touch from-shell.txt"}],"availableDecisions":["accept","cancel"]}}
{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":1}}
{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg-1","text":"","phase":"final_answer"},"threadId":"thread-1","turnId":"turn-1"}}
{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"msg-1","delta":"Created hello.txt containing `hi`; the shell command was rejected."}}
{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-1","turnId":"turn-1","tokenUsage":{"total":{"totalTokens":42676,"inputTokens":42628,"cachedInputTokens":28288,"cacheWriteInputTokens":0,"outputTokens":48,"reasoningOutputTokens":0},"last":{"totalTokens":21369,"inputTokens":21364,"cachedInputTokens":21120,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}}}
{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"completed","error":null,"durationMs":21426}}}
```

(`item/completed` for `msg-1` is left out on purpose: the delta alone must make the text.) In `Fixture.swift` add:

```swift
  /// A Codex turn (codex-cli 0.160.1, 2026-10-06, docs/codex-app-server.md): reasoning, a
  /// file created after an approval, a command declined, the answer streamed, usage with the
  /// window, the end. Server lines only; ids shortened, paths and account scrubbed. Not
  /// stream-json: read with `CodexTranslator`.
  case codexTurn = "codex-turn"
```

- [ ] **Step 2: Write the failing tests**

`CodexTranslatorTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

/// Codex's app-server through the same transcript: the check that `AgentEvent` is no
/// agent's in particular (docs/superpowers/specs/2026-10-06-agent-backend-design.md).
@Suite("A Codex turn as agent events")
struct CodexTranslatorTests {
  private func fold(until stop: Int? = nil) throws -> Transcript {
    var translator = CodexTranslator()
    var transcript = Transcript()
    transcript.addPrompt("Create hello.txt with hi, then run touch from-shell.txt.")
    let lines = try Fixture.codexTurn.lines
    for line in lines.prefix(stop ?? lines.count) {
      for event in translator.translate(try JSONValue.parse(line), at: nil) {
        transcript.apply(event)
      }
    }
    return transcript
  }

  @Test func foldsTheTurn() throws {
    let t = try fold()
    #expect(t.session?.sessionID == "thread-1")
    #expect(t.session?.model == "gpt-6-astra")
    let kinds = t.entries.map(\.kind)
    #expect(kinds.count == 4)
    #expect(kinds.first == .prompt("Create hello.txt with hi, then run touch from-shell.txt."))
    #expect(kinds[1] == .thinking("**Planning the file**"))
    guard case .tool(let patch) = kinds[2] else {
      Issue.record("\(kinds)")
      return
    }
    #expect(
      patch.kind
        == .fileChange(
          path: "/Users/me/project/hello.txt",
          edits: [FileEdit(path: "/Users/me/project/hello.txt", change: .patch("hi\n"))]))
    #expect(patch.result?.isError == false)
    #expect(kinds[3] == .text("Created hello.txt containing `hi`; the shell command was rejected."))
    #expect(t.turnEnd == .completed)
    #expect(!t.isRunning)
    #expect(t.contextWindow == 258_400)
    #expect(t.contextUsage == TokenUsage(input: 244, cacheCreation: 0, cacheRead: 21120, output: 5))
  }

  @Test func asksAndWithdrawsApprovals() throws {
    let asking = try fold(until: 9)
    #expect(asking.pendingPermissions.map(\.requestID) == ["0"])
    #expect(asking.pendingPermissions.first?.request.toolUseID == "patch-1")
    if case .fileChange? = asking.pendingPermissions.first?.request.kind {} else {
      Issue.record("not a file change: \(String(describing: asking.pendingPermissions.first))")
    }
    let answered = try fold(until: 10)
    #expect(answered.pendingPermissions.isEmpty)
    let command = try fold(until: 12)
    #expect(command.pendingPermissions.first?.request.kind == .shell(command: "touch from-shell.txt"))
  }

  @Test func aFileChangeDrawsAsADiff() throws {
    let t = try fold()
    guard case .tool(let call) = t.entries[2].kind,
      case .fileChange(let path, let edits) = call.kind,
      let change = FileChange(path: path, edits: edits)
    else {
      Issue.record("no diff")
      return
    }
    #expect(change.isNewFile)
    #expect(change.addedCount == 1)
  }
}
```

Run: `cd apps/apple && swift test --package-path Packages/DrakarKit --filter CodexTranslatorTests`
Expected: FAIL to compile: `CodexTranslator` not found.

- [ ] **Step 3: `PermissionRequest` memberwise init**

In `StreamMessage.swift`, `PermissionRequest` gains (keep the JSON `init?`):

```swift
  public init(
    toolName: String, displayName: String? = nil, input: JSONValue, description: String? = nil,
    toolUseID: String?, kind: ToolKind
  ) {
    self.toolName = toolName
    self.displayName = displayName
    self.input = input
    self.description = description
    suggestions = []
    blockedPath = nil
    requiresUserInteraction = false
    self.toolUseID = toolUseID
    self.kind = kind
  }
```

- [ ] **Step 4: Write `Codex/CodexTranslator.swift`**

```swift
import Foundation

/// Codex's app-server (docs/codex-app-server.md) as agent events: only what was verified
/// against codex-cli 0.160.1 on 2026-10-06. The fit check of slice 1: nothing in the app
/// uses it yet; slice 2 starts from it.
///
/// Codex is item-based: `item/started`, deltas by item id, `item/completed`. A tool's result
/// is its own item's completion. Approvals are JSON-RPC requests whose id answers them.
public struct CodexTranslator: Sendable {
  /// File changes by item id, which an approval request names without describing.
  private var fileChanges: [String: ToolKind] = [:]

  public init() {}

  public mutating func translate(_ message: JSONValue, at time: Date?) -> [AgentEvent] {
    guard let method = message["method"]?.stringValue else { return [] }
    let params = message["params"] ?? .null
    switch method {
    case "thread/started":
      guard let thread = params["thread"], let id = thread["id"]?.stringValue else { return [] }
      return [
        .sessionStarted(
          SessionInfo(
            sessionID: id, cwd: thread["cwd"]?.stringValue, model: thread["model"]?.stringValue,
            agentVersion: thread["cliVersion"]?.stringValue))
      ]
    case "item/started":
      return item(params["item"], completed: false)
    case "item/completed":
      return item(params["item"], completed: true)
    case "item/agentMessage/delta":
      guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue
      else { return [] }
      return [.itemDelta(id: id, .text(delta))]
    case "item/reasoning/summaryPartAdded":
      guard let id = params["itemId"]?.stringValue, let index = params["summaryIndex"]?.intValue,
        index > 0
      else { return [] }
      return [.itemDelta(id: id, .thinking("\n\n"))]
    case "item/reasoning/summaryTextDelta":
      guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue
      else { return [] }
      return [.itemDelta(id: id, .thinking(delta))]
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      return approval(method: method, id: message["id"], params: params)
    case "serverRequest/resolved":
      guard let id = params["requestId"].flatMap(Self.requestID) else { return [] }
      return [.permissionWithdrawn(requestID: id)]
    case "thread/tokenUsage/updated":
      guard let usage = params["tokenUsage"], let last = usage["last"],
        let input = last["inputTokens"]?.intValue, let output = last["outputTokens"]?.intValue
      else { return [] }
      let cached = last["cachedInputTokens"]?.intValue ?? 0
      return [
        .usage(
          .init(
            messageID: params["turnId"]?.stringValue ?? "",
            usage: TokenUsage(
              input: input - cached, cacheCreation: last["cacheWriteInputTokens"]?.intValue ?? 0,
              cacheRead: cached, output: output),
            model: nil, window: usage["modelContextWindow"]?.intValue, at: nil))
      ]
    case "turn/completed":
      let turn = params["turn"] ?? .null
      let outcome: Transcript.TurnEnd =
        switch turn["status"]?.stringValue {
        case "interrupted": .interrupted
        case "failed": .failed
        default: .completed
        }
      return [
        .turnEnded(
          TurnSummary(
            outcome: outcome, failureText: turn["error"]?["message"]?.stringValue,
            durationMS: turn["durationMs"]?.intValue))
      ]
    default:
      return []
    }
  }

  private mutating func item(_ item: JSONValue?, completed: Bool) -> [AgentEvent] {
    guard let item, let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else {
      return []
    }
    func placed(_ kind: Transcript.Kind) -> AgentEvent {
      let item = AgentEvent.Item(id: id, parent: nil, kind: kind)
      return completed ? .itemCompleted(item) : .itemStarted(item)
    }
    switch type {
    case "agentMessage":
      return [placed(.text(item["text"]?.stringValue ?? ""))]
    case "reasoning":
      let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue)
      return [placed(.thinking(summary.joined(separator: "\n\n")))]
    case "commandExecution":
      let command = item["command"]?.stringValue ?? ""
      let kind = Self.kind(command: command, actions: item["commandActions"]?.arrayValue ?? [])
      var events = [
        placed(
          .tool(
            .init(id: id, name: "Shell", input: .object(["command": .string(command)]), kind: kind)))
      ]
      if completed {
        let status = item["status"]?.stringValue
        events.append(
          .toolResult(
            callID: id,
            .init(
              content: item["aggregatedOutput"]?.stringValue ?? status ?? "",
              isError: status != "completed" || (item["exitCode"]?.intValue ?? 0) != 0)))
      }
      return events
    case "fileChange":
      let changes = item["changes"]?.arrayValue ?? []
      let edits = changes.compactMap { change -> FileEdit? in
        guard let path = change["path"]?.stringValue, let diff = change["diff"]?.stringValue
        else { return nil }
        return FileEdit(path: path, change: .patch(diff))
      }
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
      // `userMessage` is the session's own prompt, already shown; the rest is unverified.
      return []
    }
  }

  private func approval(method: String, id: JSONValue?, params: JSONValue) -> [AgentEvent] {
    guard let requestID = id.flatMap(Self.requestID) else { return [] }
    let itemID = params["itemId"]?.stringValue
    let request: PermissionRequest
    if method == "item/fileChange/requestApproval" {
      request = PermissionRequest(
        toolName: "Edit", input: .object([:]), description: params["reason"]?.stringValue,
        toolUseID: itemID, kind: itemID.flatMap { fileChanges[$0] } ?? .other)
    } else {
      let command = params["command"]?.stringValue ?? ""
      let kind = Self.kind(command: command, actions: params["commandActions"]?.arrayValue ?? [])
      request = PermissionRequest(
        toolName: "Shell", input: .object(["command": .string(command)]),
        description: params["reason"]?.stringValue, toolUseID: itemID, kind: kind)
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
        if let query = (action["query"] ?? action["path"])?.stringValue {
          return .search(pattern: query)
        }
      default: break
      }
      if let asked = action["command"]?.stringValue { return .shell(command: asked) }
    }
    return .shell(command: command)
  }

  /// A JSON-RPC id, which may be a number or a string.
  static func requestID(_ id: JSONValue) -> String? {
    id.intValue.map(String.init) ?? id.stringValue
  }
}
```

`SessionInfo(sessionID:cwd:model:agentVersion:)` is the Task 4 init after the Task 6 rename.

- [ ] **Step 5: Run everything**

Run: `make -C apps/apple test && make -C apps/apple test-app`
Expected: PASS: `CodexTranslatorTests` (3), all earlier suites, goldens.

If a test fails because the vocabulary cannot say something Codex says, that is the finding this task exists for: stop, write the gap down in the spec's "What Codex taught the design", and ask before changing `AgentEvent`.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add -A apps/apple
git commit -m "test(apple): a Codex turn folds through the same transcript (slice 1's fit check)"
```

---

### Task 10: Land

- [ ] **Step 1: Bring in main**

```bash
cd /Users/olivier/Projects/apps/drakar-agent-backend
git fetch . 2>/dev/null; git merge main
```

Conflicts in `Transcript.swift`, `AgentSession.swift` (main's `ClaudeSession.swift`), `History.swift` or a test file mean main changed what this branch moved: re-apply main's change in its new home (translator, backend or reducer), then run the goldens. If main changed the transcript's behaviour, the goldens legitimately change: re-record only the scenarios main's change explains, and say so in the merge commit.

- [ ] **Step 2: Every suite and the formatter**

Run: `make -C apps/apple test && make -C apps/apple test-app && make -C apps/apple format-swift-check`
Expected: all PASS.

- [ ] **Step 3: Ask before landing**

Tell the person the branch is ready, the test counts, and that checking it in the running app means `make run`, which quits their Drakar. The check: open a long history; one live turn with a tool call and a permission; plan mode; a queued prompt; an attachment. Land when they say so:

```bash
cd /Users/olivier/Projects/apps/drakar
git status --short   # must not show uncommitted edits in files the branch touches; if it does, stop and ask
git merge --ff-only feat/agent-backend
```
