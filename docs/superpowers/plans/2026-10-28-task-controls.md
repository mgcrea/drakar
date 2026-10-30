# Subagent and Task Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the cards where they already show, a running subagent or long command can be
stopped and moved to the background. A background command's output can be read as it
grows, and a subagent's whole conversation shows from its file, after a reload too.

**Architecture:** DrakarKit encodes three control requests (`stop_task`, `background_tasks`,
`get_task_output`) and parses their replies. It carries each task's ID and type on
`AgentTask`, and reads a subagent's `agent-<id>.jsonl` through the history path with
sidechain lines kept. The app sends the requests through new `AgentCommand`s, without
session notes, and routes the replies to an `@Observable TaskControls` per session that the
cards read from the environment. `AgentCallView` and `ToolCallView` draw the controls.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI/AppKit, swift-testing, the
DrakarKit SPM package. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-28-task-controls-design.md`

## Global Constraints

- Work in a worktree under `.claude/worktrees/task-controls` (never `../`). Merge `main` in,
  run `make -C apps/apple test test-app` before landing, and land with `git merge --ff-only`
  in the main checkout. If main has uncommitted edits in files this branch touches, stop and
  ask.
- Never `make run` or `make quit`: they quit the person's running Drakar and its sessions.
  Ask the person to relaunch for the live checks.
- Check the UI through the accessibility tree (cupertino-desktop, by identifier).
- The extension's words, verbatim, for every outcome it names:
  - "The agent could not be stopped. It may have finished already."
  - "Could not move this to the background. It may have just finished or already be running in the background."
  - "Moving to the background is turned off for this session."
  - "Could not move this to the background. Try again."
  - "No output yet."
  - "Showing the end of …"
- Drakar's own copy is only "Stop", "Stopping…", "Stopped", "Run in background", "Running in
  the background" (already in `ToolCards.swift`) and "Output". Every string goes through
  `String(localized:)`. No em dashes in UI copy.
- The disabled marker is the CLI's error text "Background tasks are disabled in this
  session." (extension 2.1.312, `an1`).
- No control request on a session Drakar does not drive (read-only, moving, reconnecting,
  waiting for the host, out of reach, no process). Reading a subagent file is allowed
  anywhere.
- Output polls every 1 s, only while its section is open, its window is visible and the task
  runs, plus one fetch when the task ends. A request with no reply re-enables its button
  after 10 s.
- Task-control requests are written without a `SessionNote`, so a replay never sends one
  again. Their request IDs are `<prefix>-<UUID>`, outside the counter that replay rebuilds.
  (Corrected after landing: skipping the note does not keep them out of the session host's
  log, which records every stdin write and stdout line; that is why Output reads the task's
  file instead of polling `get_task_output`.)
- Codex: `AgentFeatures.controlsTasks` is false and nothing shows.
- Deployment target macOS 26.0. Format with `make -C apps/apple format-swift` before each
  commit.

## Review Focus

1. **The process exits, or the host connection drops, while a Stop or Run in background
   waits.** The button should come back, not stay on "Stopping…". Pinned by
   `TaskControlsTests.anExitClearsWhatWaits` (Task 6).
2. **Two cards acted on at once.** Each reply should land on its own card. Pinned by
   `ClaudeBackendTests.eachTaskReplyNamesItsOwnTask` (Task 6).
3. **A truncated tail that starts mid-line or mid-character, or carries ANSI colour codes or
   `\r\n`.** Drop the partial first line, strip leading U+FFFD, strip escapes and `\r`, as
   the extension's `Vb5` does. Pinned by `TaskControlTests.aTruncatedTailStartsOnALine` and
   `.escapesAndReturnsAreStripped` (Task 4).
4. **An agent ID that isn't a plain name** (`../x`, empty, 200 characters). Never look
   outside the project folder; fall back to the streamed calls. Pinned by
   `SubagentTranscriptTests.refusesAnIDThatIsNotAName` (Task 5).
5. **A fork, whose subagent files sit under the original session.** The sibling folder is
   found. Pinned by `SubagentTranscriptTests.findsAForksAgentBesideIt` (Task 5).

---

### Task 1: Capture the task controls from Claude Code 2.1.312

The spec's shapes were read from extension 2.1.312's bundled SDK. This task captures them
for real. Its fixtures are what every later kit test quotes.

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/task-controls.jsonl`
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/subagent-file.jsonl`
- Modify: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift` (two cases)
- Modify: `docs/claude-stream-json.md` (a "Task controls (verified 2026-10-28, 2.1.312)"
  section after "Plans, todos and subagents")

**Interfaces:**
- Produces: `Fixture.taskControls` (`"task-controls"`) and `Fixture.subagentFile`
  (`"subagent-file"`). Each case's doc comment lists, in order, which scenario its lines
  come from, as the existing cases do.

- [ ] **Step 1: Drive the scenarios.** Use a throwaway driver in the scratchpad (not
  committed), following `docs/claude-stream-json.md` "Checking a new release": a scratch
  folder, `ClaudeCommand`'s arguments plus `--model claude-haiku-4-5-20251001
  --setting-sources project`, on `~/.local/share/claude/versions/2.1.312`.
  1. A foreground `python3 -c 'import time; time.sleep(30)'` through Bash. Wait for its
     `task_started` (`is_backgrounded: false`), then send `background_tasks` with its
     `tool_use_id`.
  2. Once it's in the background, send `get_task_output` with its `task_id` twice: once
     while it runs, once after its `task_notification`.
  3. A second foreground sleep. Send `stop_task` for its task.
  4. A foreground `general-purpose` `Agent` that runs a long sleep. Send `stop_task` for it.
  5. `stop_task` with an unknown ID, and `background_tasks` with a call that already
     finished.
  6. A fresh process with `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` in its environment, and
     `background_tasks` on a running foreground call.
- [ ] **Step 2: Record five answers in the new doc section.**
  - Each request's reply.
  - How long a foreground Bash runs before its `task_started` arrives.
  - The status a stopped task reports (`stopped` or `killed`), and on which line.
  - Whether a backgrounded Bash's `tool_result` arrives at once, and what it says.
  - The refusals' exact `error` strings.

  If a reply differs from the spec's table, stop and bring it back: Tasks 4 and 6 depend on
  it.
- [ ] **Step 3: Trim.** Write `task-controls.jsonl` from scenarios 1–6, keeping `task_*`
  lines, tool calls, results and every `control_response`. Write `subagent-file.jsonl` from
  scenario 4's `subagents/agent-<id>.jsonl`. Drop stream events and thinking, cut paths and
  ids as the other fixtures do. Delete the scratch transcripts, and any plan left in
  `~/.claude/plans/`.
- [ ] **Step 4: Commit**

```bash
git add apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/task-controls.jsonl apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/subagent-file.jsonl apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift docs/claude-stream-json.md
git commit -m "test(kit): capture task controls from claude 2.1.312"
```

### Task 2: Raise `ClaudeVersion.tested` to 2.1.312

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ClaudeVersion.swift:33`
- Modify: `docs/claude-stream-json.md` (a "2.1.312 (checked 2026-10-28)" section after
  "2.1.308", and the closing "done for" sentence)

- [ ] **Step 1: Run the pass.** Run the 2.1.308 section's scenarios on 2.1.308 and 2.1.312
  with the procedure at the end of `docs/claude-stream-json.md`, including the binary
  literal diff. Feed the lines through `StreamMessage` and `ClaudeTranslator` in a
  throwaway test, and list anything that lands as `.unknown` or `.other`.
- [ ] **Step 2: Write the section.** Say what decoded alike, what changed, and what Drakar
  ignores, in the 2.1.308 section's form. If anything Drakar reads changed, stop and bring
  it back.
- [ ] **Step 3: Set `tested` to `ClaudeVersion("2.1.284")!...ClaudeVersion("2.1.312")!`**
  and run `make -C apps/apple test`. Expected: PASS.
- [ ] **Step 4: Commit** with `chore(kit): Claude Code 2.1.312 is tested`.

### Task 3: A task's ID, type and stopped state

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/AgentTask.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/AgentEvent.swift:214`
  (`AgentTaskUpdate`)
- Modify: `apps/apple/Drakar/Views/ToolCards.swift:31-43,110-116` (the stopped state)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/AgentTaskTests.swift`

**Interfaces:**
- Produces:

```swift
// AgentTaskUpdate, AgentTask
public var taskID: String?     // the stream's task_id, which is the subagent's agentId
public var taskType: String?   // "local_agent", "local_bash", as the CLI writes it
// AgentTask.Status
case stopped                   // "stopped" or "killed"
// AgentReport
public var agentID: String?    // the structured result's agentId
```

- [ ] **Step 1: Write the failing tests** in `AgentTaskTests`:
  - `aTaskKeepsItsIDAndType`: folding `Fixture.taskControls` gives the Bash call's task
    `taskID` equal to its `task_started` `task_id`, and `taskType == "local_bash"`.
  - `aStoppedTaskIsStopped`: the task stopped in scenario 3 has `status == .stopped`, with
    the status string Task 1 recorded. `AgentTask.Status("killed") == .stopped`.
  - `aReportKeepsItsAgentID`: `Fixture.subagentAndTodos`'s `Agent` result has
    `agentReport?.agentID == "a408679160ffa9e01"`.
- [ ] **Step 2: Run `make -C apps/apple test`.** Expected: FAIL, the members don't exist.
- [ ] **Step 3: Implement.**
  - `TaskEvent.update` fills `taskID`, and `taskType` from `task_type`.
  - `AgentTask.apply` keeps the first non-nil of each.
  - `Status.init` maps `stopped` and `killed` to `.stopped`.
  - `AgentReport` reads `agentId`.
  - In `AgentCallView`, `.stopped` gets its own state: `Image(systemName: "stop.circle")`
    in `.secondary`, with "Stopped" as the detail line.
- [ ] **Step 4: Run `make -C apps/apple test`.** Expected: PASS. If a transcript golden
  differs only by `ended("stopped")` becoming `stopped`, or by the new fields, re-record
  with `DRAKAR_RECORD_GOLDENS=1`, then run again to compare.
- [ ] **Step 5: Commit** with `feat(kit): a task keeps its id and type, and a stop reads as one`.

### Task 4: The three requests and their replies

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ClientMessage.swift`
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/TaskControl.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ClientMessageTests.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TaskControlTests.swift`

**Interfaces:**
- Produces:

```swift
// ClientMessage
case stopTask(requestID: String, taskID: String)          // {subtype: "stop_task", task_id}
case backgroundCall(requestID: String, toolUseID: String) // {subtype: "background_tasks", tool_use_id}
case taskOutput(requestID: String, taskID: String)        // {subtype: "get_task_output", task_id}

// TaskControl.swift
public enum BackgroundOutcome: Sendable, Equatable {
  case moved, notFound, disabled, failed
  /// From the reply: success with `backgrounded` true or missing is moved, false is notFound;
  /// an error containing TaskControl.disabledMarker is disabled; any other error is failed.
  public init(isSuccess: Bool, response: JSONValue?, error: String?)
  public var message: String?   // nil for .moved; the extension's sentence otherwise
}
public struct TaskOutput: Sendable, Equatable {
  public var text: String       // as the reply has it
  public var totalBytes: Int
  public var isTruncated: Bool
  public init?(_ response: JSONValue?)   // nil without output, total_bytes and truncated
  public var displayText: String         // see Step 3
  public var note: String?               // "Showing the end of 12 KB" when truncated, else nil
}
public enum TaskControl {
  public static let disabledMarker = "Background tasks are disabled in this session."
  public static let stopFailure: String  // the extension's Stop sentence, localized
  public static let noOutput: String     // "No output yet."
}
```

- [ ] **Step 1: Write the failing tests.**
  - `ClientMessageTests.taskControlsEncode`: each case's `json` equals the
    `control_request` with exactly the keys above.
  - In `TaskControlTests`, from `Fixture.taskControls`'s replies:
    - `aMovedCallIsMoved` (scenario 1 → `.moved`).
    - `aFinishedCallIsNotFound` (scenario 5 → `.notFound`).
    - `aDisabledSessionSaysSo` (scenario 6 → `.disabled`, whose `message` is "Moving to the
      background is turned off for this session.").
    - `anyOtherErrorFails` (`error: "boom"` → `.failed`).
    - `outputDecodes` (scenario 2's two replies).
    - `aTruncatedTailStartsOnALine` (`"tial\nline two"`, truncated → `"line two"`;
      `"\u{FFFD}\u{FFFD}abc"` with no newline, truncated → `"abc"`).
    - `escapesAndReturnsAreStripped` (`"\u{1B}[31mred\u{1B}[0m\r\nok"` → `"red\nok"`).
    - `theNoteSaysHowMuch` (`totalBytes: 12288, isTruncated: true` → `"Showing the end of
      12 KB"`; not truncated → nil).
- [ ] **Step 2: Run `make -C apps/apple test`.** Expected: FAIL, nothing defined.
- [ ] **Step 3: Implement.**
  - `displayText`: when truncated, drop up to and including the first newline if there is
    one before the end; with no newline, drop leading U+FFFD. Then remove CSI escape
    sequences (`ESC [` … final byte `@`–`~`) and `\r` before `\n`.
  - The note's size is `totalBytes.formatted(.byteCount(style: .file))`.
- [ ] **Step 4: Run `make -C apps/apple test`.** Expected: PASS.
- [ ] **Step 5: Commit** with `feat(kit): stop, background and read a task`.

### Task 5: A subagent's transcript file

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Claude/ClaudeTranslator.swift:214-217`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/TranscriptFollower.swift`
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/SubagentTranscript.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/SubagentTranscriptTests.swift`

**Interfaces:**
- Produces:

```swift
// ClaudeTranslator
public init(includesSidechains: Bool = false)   // history(_:) keeps isSidechain lines when true
// TranscriptFollower
public init(file: URL, includesSidechains: Bool = false)
// SubagentTranscript.swift
public enum SubagentTranscript {
  /// `<transcript minus .jsonl>/subagents/agent-<agentID>.jsonl` if it exists, else the same
  /// name under any other session folder beside it; nil when agentID isn't
  /// ^[A-Za-z0-9_-]{1,128}$ or nothing exists.
  public static func file(agentID: String, transcriptFile: URL) -> URL?
}
```

- [ ] **Step 1: Write the failing tests** in `SubagentTranscriptTests`:
  - `foldsTheWholeConversation`: a `TranscriptFollower(file:includesSidechains: true)` over
    `Fixture.subagentFile` gives, in order: a prompt entry with the agent's prompt, then its
    tool call with a result, then its closing text.
  - `historyStillDropsSidechains`: `Transcript.history(lines:)` over the same lines has no
    entries.
  - In a temporary projects folder:
    - `findsItsOwnAgent`.
    - `findsAForksAgentBesideIt`: `a.jsonl` with no `a/subagents/`, and
      `b/subagents/agent-x.jsonl` → found from `a.jsonl`.
    - `refusesAnIDThatIsNotAName`: `../b/subagents/agent-x`, `""` and 129 × `a` → nil, even
      with a matching file planted.
    - `nothingIsNil`.
- [ ] **Step 2: Run `make -C apps/apple test`.** Expected: FAIL.
- [ ] **Step 3: Implement.** The guard in `history(_:)` reads the new flag. The follower
  passes it to its translator, including after a rewrite resets it. The sibling scan lists
  the transcript's folder once and stats `<folder>/<name>/subagents/agent-<id>.jsonl` for
  each directory.
- [ ] **Step 4: Run `make -C apps/apple test`.** Expected: PASS.
- [ ] **Step 5: Commit** with `feat(kit): read a subagent's own transcript`.

### Task 6: Send the requests and route the replies

**Files:**
- Modify: `apps/apple/Drakar/Services/AgentBackend.swift:57-110` (`AgentCommand`,
  `SessionSignal`)
- Modify: `apps/apple/Drakar/Services/ClaudeBackend.swift`
- Modify: `apps/apple/Drakar/Services/CodexBackend.swift:94-` (the three commands map to nil)
- Modify: `apps/apple/Drakar/Services/AgentFeatures.swift` (`controlsTasks`)
- Create: `apps/apple/Drakar/Services/TaskControls.swift`
- Modify: `apps/apple/Drakar/Services/AgentSession.swift` (own one, feed it, send unnoted)
- Test: `apps/apple/DrakarTests/ClaudeBackendTests.swift`
- Test: `apps/apple/DrakarTests/TaskControlsTests.swift`

**Interfaces:**
- Consumes: Task 4's `ClientMessage` cases, `BackgroundOutcome`, `TaskOutput`.
- Produces:

```swift
// AgentCommand
case stopTask(taskID: String)
case backgroundCall(toolUseID: String)
case taskOutput(taskID: String)
// SessionSignal
case taskStopAnswered(taskID: String, error: String?)
case backgroundAnswered(toolUseID: String, BackgroundOutcome)
case taskOutputAnswered(taskID: String, TaskOutput?)
// AgentFeatures
var controlsTasks: Bool          // .claude true, .codex false

@Observable final class TaskControls {
  /// The session is driven and its agent controls tasks. Read through `availability`, so a
  /// view reading it observes the session's own properties.
  var isAvailable: Bool { availability() }
  /// The session's transcript, for subagent files; set for every session, driven or not.
  var transcriptFile: URL?
  private(set) var stopping: Set<String> = []                // task ids
  private(set) var stopFailures: [String: String] = [:]      // task id → the CLI's error
  private(set) var moving: Set<String> = []                  // tool use ids
  private(set) var backgroundOutcomes: [String: BackgroundOutcome] = [:]
  private(set) var backgroundDisabled = false
  private(set) var outputs: [String: TaskOutput] = [:]
  init(
    timeout: Duration = .seconds(10), availability: @escaping () -> Bool = { false },
    send: @escaping (AgentCommand) -> Void = { _ in })
  func stop(taskID: String)
  func runInBackground(toolUseID: String)
  func fetchOutput(taskID: String)
  func answered(_ signal: SessionSignal)   // ignores every other signal
  func processEnded()                      // clears stopping and moving
}
```

- [ ] **Step 1: Write the failing tests.**
  - `ClaudeBackendTests.taskControlsEncodeWithTheirOwnIDs`: `send(.stopTask(taskID: "t"))`
    returns an ID starting `stop-` with a UUID after it.
  - `ClaudeBackendTests.eachTaskReplyNamesItsOwnTask`: two `stopTask`s and a
    `backgroundCall`, replies fed back out of order → each signal names its own ID. The
    disabled reply from `Fixture.taskControls` gives `.backgroundAnswered(_, .disabled)`.
  - In `TaskControlsTests`:
    - `stopWaitsThenClears`: `stop` → `stopping` holds it and `send` got `.stopTask`; a
      success clears it.
    - `aRefusedStopKeepsTheError`: the error is in `stopFailures`.
    - `aStopIsRetriedOnlyAfterItClears`: a second `stop` while waiting sends nothing.
    - `noReplyClearsAfterTheTimeout`, with `timeout: .milliseconds(50)`.
    - `disabledHidesForTheSession`.
    - `anExitClearsWhatWaits`.
    - `unavailableSendsNothing`.
- [ ] **Step 2: Run `make -C apps/apple test-app`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `ClaudeBackend.encode` gives the three commands `"stop-"`, `"background-"` and
    `"output-"` + `UUID().uuidString`, and remembers each in
    `taskRequests: [String: String]` (request ID → task or call ID).
  - `receive` routes those prefixes to the three signals and returns, as the `"settings-"`
    case does. For Stop, a refusal's `error` is `response.error ?? ""`.
  - `AgentSession` owns `let tasks = TaskControls(send:)`, whose `send` calls
    `backend.send` directly on `process`: no `sendNoted`, and a failure is ignored.
  - `handle(_:)` forwards the three signals to `tasks.answered`.
  - `availability` is a closure over the session (weakly held) returning
    `features.controlsTasks && !isReadOnly && !isMoving && !isReconnecting &&
    !waitsForHost && !isOutOfReach && process != nil`, the same properties `canQueue` reads.
  - `transcriptFile` is set from the session's target, and `processEnded()` is called
    where the process goes.
- [ ] **Step 4: Run `make -C apps/apple test-app`.** Expected: PASS. Known flakes
  (CapabilityProbe, AgentSession opened-elsewhere, SessionMoves): rerun one alone before
  calling it a regression.
- [ ] **Step 5: Commit** with `feat(apple): send task controls and route their replies`.

### Task 7: The controls on the cards

**Files:**
- Modify: `apps/apple/Drakar/Views/ToolCards.swift` (`AgentCallView`)
- Modify: `apps/apple/Drakar/Views/TranscriptView.swift:264-310,377-` (`EntryView`
  passes `task` to every tool call; `ToolCallView` takes it)
- Modify: `apps/apple/Drakar/Views/SessionView.swift:26-30` (the environment)
- Create: `apps/apple/Drakar/Views/TaskControlViews.swift`
- Test: `apps/apple/DrakarTests/TaskControlViewsTests.swift`

**Interfaces:**
- Consumes: Task 3's `AgentTask.taskID`/`taskType`/`.stopped`, Task 4's `TaskOutput`,
  Task 6's `TaskControls`.
- Produces:

```swift
extension EnvironmentValues { @Entry var taskControls: TaskControls? = nil }
/// What a card offers for its task, decided from the call, the task and the controls.
struct TaskOffer: Equatable {
  var stop: Bool
  var runInBackground: Bool
  var output: Bool
  static func of(call: Transcript.ToolCall, task: AgentTask?, controls: TaskControls?) -> TaskOffer
}
struct StopTaskButton: View { let taskID: String }      // id "task.stop.<taskID>"
struct RunInBackgroundLine: View { let toolUseID: String }  // id "task.background.<toolUseID>"
struct TaskOutputSection: View { let taskID: String; let isRunning: Bool }  // id "task.output.<taskID>"
```

- [ ] **Step 1: Write the failing tests** for `TaskOffer.of` in `TaskControlViewsTests`:
  - `stopNeedsARunningTaskWithAnID`.
  - `runInBackgroundNeedsAForegroundTaskAndNoResult`, for `Bash`, `PowerShell`, `Agent`
    and `Task` only.
  - `nothingWhenUnavailable`.
  - `nothingOnceDisabled` (Run in background only).
  - `outputForABackgroundBashTask`.
  - `noOutputForAnAgent`.
- [ ] **Step 2: Run `make -C apps/apple test-app`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `SessionView` sets `.environment(\.taskControls, session.tasks)`.
  - Both cards put `StopTaskButton` at the trailing end of their header. While its ID is in
    `stopping` it reads "Stopping…" and is disabled. A failure shows
    `TaskControl.stopFailure` under the header, with the CLI's error as `.help`.
  - `RunInBackgroundLine` sits under the header. It shows the outcome's `message` after a
    reply, and the button again after `.failed`.
  - `ToolCallView` with a running background task shows `ProgressView` and "Running in the
    background", as `AgentCallView` does, instead of the result's icon.
  - `TaskOutputSection` is a `DisclosureGroup("Output")`. While it's expanded, a
    `.task(id:)` loop calls `fetchOutput` every second as long as `isRunning` and the
    window's `occlusionState` contains `.visible`, then fetches once more when `isRunning`
    turns false. It shows `displayText` in `CodeBlock`, `TaskControl.noOutput` when empty,
    and `note` under it.
- [ ] **Step 4: Run `make -C apps/apple test-app`.** Expected: PASS. Then
  `make -C apps/apple build`.
- [ ] **Step 5: Commit** with `feat(apple): stop a task, background a call, read its output`.

### Task 8: The subagent card reads its file

**Files:**
- Modify: `apps/apple/Drakar/Views/ToolCards.swift` (`AgentCallView`)
- Create: `apps/apple/Drakar/Services/SubagentFeed.swift`
- Test: `apps/apple/DrakarTests/SubagentFeedTests.swift`

**Interfaces:**
- Consumes: Task 3's `AgentTask.taskID` and `AgentReport.agentID`, Task 5's
  `SubagentTranscript.file` and the follower, Task 6's `TaskControls.transcriptFile`.
- Produces:

```swift
/// A subagent's file, followed while the card is open.
@Observable final class SubagentFeed {
  private(set) var transcript: Transcript?   // nil: no file, so the card keeps its streamed children
  init(agentID: String, transcriptFile: URL)
  func refresh()                             // catches up; a read error leaves transcript as it was
}
```

- [ ] **Step 1: Write the failing tests** in `SubagentFeedTests`, in a temporary folder
  holding a copy of `Fixture.subagentFile`'s lines as `s/subagents/agent-x.jsonl`:
  - `readsTheFile`.
  - `followsAppendedLines` (append the last line after the first `refresh`).
  - `noFileIsNil`.
- [ ] **Step 2: Run `make -C apps/apple test-app`.** Expected: FAIL.
- [ ] **Step 3: Implement.** On expand, `AgentCallView` makes a feed from
  `task?.taskID ?? report?.agentID` and the environment's `transcriptFile`. It refreshes
  once, then every second while the task runs. When the feed has a transcript, the card
  draws its `grouped().top` entries with `EntryView` in place of `children`.
- [ ] **Step 4: Run `make -C apps/apple test-app`.** Expected: PASS.
- [ ] **Step 5: Commit** with `feat(apple): a subagent's card shows its whole conversation`.

### Task 9: Ledger, live checks, landing

**Files:**
- Modify: `docs/extension-parity.md` (`stop_subagent`, `run_in_background`,
  `get_task_output` and `get_subagent_transcript` move to `has` with evidence;
  `stop_task`, `background_tasks` and `get_task_output` in the CLI section move to `sends`)

- [ ] **Step 1: Update the rows.** Each `has` gets one file:line from Tasks 6–8, and its
  decision cell keeps `adopt`. Run `make extension-diff`. Expected: no "no row" lines. The
  2.1.312 settings diff is a separate review, so don't `extension-accept` here.
- [ ] **Step 2: Ask the person to relaunch Drakar from the branch's build,** then walk the
  spec's five live checks through the accessibility tree by the identifiers above. Record
  each result in the commit message. A failed check goes back to its task.
- [ ] **Step 3: Land.** Merge `main` into the branch, run `make -C apps/apple test test-app`,
  then `git merge --ff-only` in the main checkout.
- [ ] **Step 4: Commit** with `docs: the task controls are in the ledger`.
