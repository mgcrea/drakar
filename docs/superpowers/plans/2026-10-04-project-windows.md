# Project Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Drakar window becomes one project: its sessions listed above the file tree with
their state and context, switching in place, each `claude` spawned on its first prompt.

**Architecture:** DrakarKit gains the readers (context from transcript tails and from the
stream, window sizes, registry fields, project containment, incremental transcript
following) ported from Armada and tested against captures. The app replaces "one window,
one `ClaudeSession`" with a per-window `Project` that owns `ProjectSession`s, an app-wide
`SessionMonitor` over FSEvents for sessions elsewhere, and an attention layer (unread
marks, Dock badge, local notifications).

**Tech Stack:** Swift 6, SwiftUI + AppKit on macOS 26, Swift Testing, FSEvents,
`UserNotifications`. DrakarKit stays Foundation-only.

**Spec:** `docs/superpowers/specs/2026-10-04-project-windows-design.md`

**One deviation from the spec, decided here:** the window's value is
`WindowRoute { .project(folder:) | .picker(token:) }` rather than `ProjectRoute { folder }`.
SwiftUI cannot open an empty window of a value-typed `WindowGroup` from a custom command,
and ⇧⌘N has to open the session picker. A picker window that picks a session turns into
that project's window, or hands it to the one already open.

## Global Constraints

- DrakarKit has zero dependencies and imports nothing above Foundation (Darwin for
  `sysctl`/`kill` is fine). `make test` resolves nothing, runs offline, in well under a second.
- Protocol shapes are tested against captured output, never against lines written from a
  reading of the SDK. Synthetic minimal lines are fine for shapes already captured.
- The app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; kit code is
  nonisolated by default.
- Drakar opens no connection. `make audit` (repo root) must still pass. `UserNotifications`
  is local.
- Drakar never writes the person's Claude Code settings (`settings.json`, hooks, `statusLine`).
- Commits: `feat(kit): …`, `feat(apple): …`, `docs: …`, a lowercase sentence; a prose body
  when the why is not obvious. No trailers (the history has none).
- Before each commit: `make -C apps/apple format-swift`.
- Two writers on one transcript must never happen: a session open in another process is
  read-only or forked; a session open in another Drakar window is brought forward.
- Copy: "Waiting for you", "Working", "Running a tool" (marked as a guess), "Idle",
  "Not started", "Stopped". Gauge amber at 75 %, red at 90 %.

## Review Focus

1. **A transcript rewritten under a follower** (the file shrank, or was replaced): the
   follower must start over, not append the new file's lines after the old. Pinned in Task 5.
2. **A restored window whose session's transcript is gone** (deleted, or its account folder
   removed): the row shows "Stopped" with the reason, the window still opens. Pinned in Task 6.
3. **A project folder reached through a symbolic link** (`/tmp/x` vs `/private/tmp/x`,
   `~/Projects` linked elsewhere): Claude Code records the resolved `cwd`, and the project
   must still own its sessions. Pinned in Task 3.
4. **Subagent turns** (`parent_tool_use_id`, `isSidechain`) carry their own `usage`: they must
   not move the session's gauge. Pinned in Tasks 1 and 4.
5. **One session id under two accounts** (resumed after switching `CLAUDE_CONFIG_DIR`): one
   row, not two, so there are never two Resume targets for one conversation. Pinned in Task 5.

---

### Task 0: Spike `get_context_usage` against a real `claude`

Not code that is kept: a capture and a paragraph. Everything after it uses the capture.

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/context-usage.jsonl`
- Modify: `docs/claude-stream-json.md` (a new section before "Raw captures")

- [ ] **Step 1: Write the driver in the scratchpad**

```python
# $SCRATCH/context_spike.py — throwaway
import json, subprocess, sys, threading, time

args = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--include-partial-messages", "--model", "haiku", "--debug"]
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=open(sys.argv[1] + ".stderr", "w"), text=True, cwd=sys.argv[2])
out = open(sys.argv[1], "w")
sent = {}

def send(obj):
    p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()

def ask(tag):
    rid = f"ctx-{tag}"
    sent[rid] = time.monotonic()
    send({"type": "control_request", "request_id": rid,
          "request": {"subtype": "get_context_usage", "detail": "summary"}})

def reader():
    for line in p.stdout:
        out.write(line); out.flush()
        msg = json.loads(line)
        if msg.get("type") == "control_response":
            rid = msg["response"].get("request_id", "")
            if rid in sent:
                print(rid, "answered in", round((time.monotonic() - sent[rid]) * 1000), "ms")

threading.Thread(target=reader, daemon=True).start()
send({"type": "control_request", "request_id": "init", "request": {"subtype": "initialize", "hooks": None}})
send({"type": "user", "session_id": "", "parent_tool_use_id": None,
      "message": {"role": "user", "content": "Count slowly from 1 to 40, one number per line."}})
time.sleep(2.5); ask("mid-turn")
time.sleep(25); ask("between-turns")
time.sleep(5); p.stdin.close(); p.wait()
```

- [ ] **Step 2: Run it in a scratch folder**

Run: `python3 $SCRATCH/context_spike.py $SCRATCH/ctx.jsonl $SCRATCH`
Expected: two lines `ctx-… answered in N ms`. Note for each whether it came back before the
turn's `result` line (mid-turn) and how long it took.

- [ ] **Step 3: Check it stayed local**

Run: `grep -i -c 'count_tokens' $SCRATCH/ctx.jsonl.stderr`
Expected: `0`. If `--debug` logs no HTTP calls at all in this build, record that instead and
rely on the timing: a local answer is single-digit milliseconds, a `count_tokens` round trip
is hundreds.

- [ ] **Step 4: Trim the capture into the fixture**

Keep, in order: the `system/init` line, one `assistant` line carrying `message.usage`, the
`result` line, and both `control_response` lines for `ctx-*`. Scrub nothing else (no paths
in these lines beyond `cwd`; replace the scratch path in `cwd` with `/tmp/drakar-probe`).
Write them to `Fixtures/context-usage.jsonl`.

- [ ] **Step 5: Record the findings**

Add to `docs/claude-stream-json.md`, before "Raw captures":

```markdown
## Context usage (measured 2026-10-04, Claude Code <version from init>)

`{"type":"control_request","request_id":…,"request":{"subtype":"get_context_usage","detail":"summary"}}`
is answered by the process that owns stdin, with `totalTokens`, `maxTokens` (the window,
`[1m]` included) and `categories` (`name`, `tokens`, `isDeferred`). Mid-turn: <answered in
N ms | answered only after the result>. Between turns: N ms. `summary` made <no |
N> `count_tokens` calls. Drakar asks after every `result`. Capture:
`Fixtures/context-usage.jsonl`.
```

- [ ] **Step 6: Commit**

```bash
git add docs/claude-stream-json.md apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/context-usage.jsonl
git commit -m "docs: get_context_usage, answered by the process that owns stdin"
```

If the reply has no `maxTokens`, stop and report it: Task 4's reply type and Task 2's
`.reported` source change shape.

---

### Task 1: Reading context out of a transcript's tail

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/JSONLines.swift`
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ContextUsage.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ContextUsageTests.swift`

**Interfaces:**
- Produces: `TokenUsage(input:cacheCreation:cacheRead:output:)`, `TokenUsage.init?(_ json: JSONValue?)`,
  `.total`; `ContextReading { usage, modelID, at, total }`;
  `TranscriptTail { data, dropsFirstLine }`, `TranscriptTail.read(_ url: URL) -> TranscriptTail?`,
  `TranscriptTail(suffixOf: Data)`, `.newestReading`, `.newestModelID`, `.isAwaitingToolResult`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Context in a transcript")
struct ContextUsageTests {

  private func tail(_ lines: [String], dropsFirstLine: Bool = false) -> TranscriptTail {
    TranscriptTail(data: Data(lines.joined(separator: "\n").utf8), dropsFirstLine: dropsFirstLine)
  }

  private let warmTurn =
    #"{"type":"assistant","timestamp":"2026-10-03T21:40:11.123Z","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":13456,"cache_read_input_tokens":86823,"output_tokens":386}}}"#

  /// All three input figures, always: `input_tokens` alone is 2 on a 100k prompt.
  @Test func readsTheWholePromptFromTheNewestTurn() throws {
    let reading = try #require(
      tail([
        #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":1}}}"#,
        warmTurn,
        #"{"type":"user","message":{"role":"user","content":"next"}}"#,
      ]).newestReading)
    #expect(reading.total == 100_281)
    #expect(reading.usage.output == 386)
    #expect(reading.modelID == "claude-opus-5-5")
    #expect(reading.at == Date(timeIntervalSince1970: 1_791_062_411.123))
  }

  /// A subagent's turn has its own context; it must not stand for the session's.
  @Test func skipsSidechainTurns() throws {
    let reading = try #require(
      tail([
        warmTurn,
        #"{"type":"assistant","isSidechain":true,"message":{"id":"s1","usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":1}}}"#,
      ]).newestReading)
    #expect(reading.total == 100_281)
  }

  /// A shape change that drops a key reads as nothing, not as an empty session.
  @Test func refusesAUsageMissingAnInputFigure() {
    #expect(
      tail([#"{"type":"assistant","message":{"id":"m","usage":{"input_tokens":3,"output_tokens":1}}}"#])
        .newestReading == nil)
  }

  /// A tail read starts mid-line; that fragment is not JSON and is never parsed.
  @Test func dropsTheFragmentAtTheStartOfATail() {
    let reading = tail([#"_tokens":9,"cache_read_input_tokens":9}}}"#, warmTurn], dropsFirstLine: true)
      .newestReading
    #expect(reading?.total == 100_281)
  }

  @Test func readsTheModelAttachmentWithItsVariant() {
    let model = tail([
      #"{"type":"attachment","attachment":{"type":"model","identity":{"modelId":"claude-opus-5[1m]"}}}"#,
      warmTurn,
    ]).newestModelID
    #expect(model == "claude-opus-5[1m]")
  }

  @Test func seesAnUnansweredToolCall() {
    let calling =
      #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#
    let answered =
      #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#
    #expect(tail([calling]).isAwaitingToolResult)
    #expect(!tail([calling, answered]).isAwaitingToolResult)
    #expect(!tail([warmTurn]).isAwaitingToolResult)
  }

  /// `suffixOf` takes the last 64KB of a mapped file and knows whether it cut a line.
  @Test func takesTheEndOfALongFile() throws {
    let filler = String(repeating: "x", count: 70_000)
    let data = Data((#"{"type":"user","message":{"content":"\#(filler)"}}"# + "\n" + warmTurn).utf8)
    let tail = TranscriptTail(suffixOf: data)
    #expect(tail.dropsFirstLine)
    #expect(tail.data.count == TranscriptTail.bytes)
    #expect(tail.newestReading?.total == 100_281)
  }

  @Test func readsTheEndOfAFile() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID()).jsonl")
    try Data(warmTurn.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let tail = try #require(TranscriptTail.read(file))
    #expect(!tail.dropsFirstLine)
    #expect(tail.newestReading?.total == 100_281)
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter ContextUsageTests`
Expected: FAIL to compile, `cannot find 'TranscriptTail' in scope`.

- [ ] **Step 3: Port `JSONLines`**

Copy `~/Projects/apps/armada/apps/apple/Armada/JSONLines.swift` to
`apps/apple/Packages/DrakarKit/Sources/DrakarKit/JSONLines.swift`, then: remove every
`nonisolated` (the kit has no default isolation), keep the type `internal`, and replace the
first paragraph of its doc comment with:

```swift
/// The lines of a newline-delimited JSON buffer, walked one at a time without copying the
/// buffer, newest or oldest first. Ported from Armada, where it replaced six copies of a
/// split-everything-first loop that held 50MB transcripts several times over.
```

- [ ] **Step 4: Write `ContextUsage.swift`**

```swift
import Foundation

/// The tokens one API request reported, from an `assistant` entry's `message.usage`.
public struct TokenUsage: Sendable, Equatable {
  public var input: Int
  public var cacheCreation: Int
  public var cacheRead: Int
  public var output: Int

  public init(input: Int, cacheCreation: Int, cacheRead: Int, output: Int) {
    self.input = input
    self.cacheCreation = cacheCreation
    self.cacheRead = cacheRead
    self.output = output
  }

  /// Nil unless all three input figures are there: a shape change that dropped one would
  /// otherwise read as a session with an empty context.
  public init?(_ json: JSONValue?) {
    guard let json, let input = json["input_tokens"]?.intValue,
      let creation = json["cache_creation_input_tokens"]?.intValue,
      let read = json["cache_read_input_tokens"]?.intValue
    else { return nil }
    self.init(
      input: input, cacheCreation: creation, cacheRead: read,
      output: json["output_tokens"]?.intValue ?? 0)
  }

  /// The whole prompt, which is the context: fresh input, plus what this request wrote to
  /// the cache, plus what it read back. `input` alone is near zero on a warm turn.
  public var total: Int { input + cacheCreation + cacheRead }
}

/// How full a session's context was at its newest main-thread turn.
public struct ContextReading: Sendable, Equatable {
  public var usage: TokenUsage
  /// `message.model`. Never carries `[1m]`, so it cannot say the window size on its own.
  public var modelID: String?
  public var at: Date?

  public init(usage: TokenUsage, modelID: String?, at: Date?) {
    self.usage = usage
    self.modelID = modelID
    self.at = at
  }

  public var total: Int { usage.total }
}

/// The end of a transcript file, where everything a session list wants sits: the newest
/// turn's usage, the model attachment, whether a tool call is unanswered. One read serves
/// all three (Armada's `TranscriptTitle.tail`).
public struct TranscriptTail: Sendable {
  /// The newest title sits a median 15KB from the end; 64KB finds it in 96 % of
  /// transcripts (Armada's measurement), and the newest usage is nearer still.
  public static let bytes = 64 * 1024

  public var data: Data
  /// True when the read did not start at byte zero, so its first line is a fragment.
  public var dropsFirstLine: Bool

  public init(data: Data, dropsFirstLine: Bool) {
    self.data = data
    self.dropsFirstLine = dropsFirstLine
  }

  /// The last `bytes` of a buffer already in memory (a mapped file).
  public init(suffixOf data: Data) {
    let start = max(data.startIndex, data.endIndex - Self.bytes)
    self.init(data: Data(data[start...]), dropsFirstLine: start > data.startIndex)
  }

  public static func read(_ url: URL) -> TranscriptTail? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return nil }
    return TranscriptTail(data: data, dropsFirstLine: start > 0)
  }

  private var newestFirst: JSONLines.NewestFirst {
    JSONLines.newestFirst(data, droppingFirstLine: dropsFirstLine)
  }

  public var newestReading: ContextReading? {
    for line in newestFirst {
      if let reading = Self.reading(line) { return reading }
    }
    return nil
  }

  /// The session's own `attachment`/`model` entry, the one place `[1m]` is written. Present
  /// in a minority of transcripts; absent is normal.
  public var newestModelID: String? {
    for line in newestFirst where line.range(of: Data(#""modelId""#.utf8)) != nil {
      guard let json = try? JSONValue.parse(line), json["type"]?.stringValue == "attachment",
        let attachment = json["attachment"], attachment["type"]?.stringValue == "model",
        let id = attachment["identity"]?["modelId"]?.stringValue, !id.isEmpty
      else { continue }
      return id
    }
    return nil
  }

  /// Whether the newest turn is an assistant's `tool_use` nobody answered: a long command,
  /// or a prompt nobody has answered. A guess, and the UI says so.
  public var isAwaitingToolResult: Bool {
    for line in newestFirst {
      guard let json = try? JSONValue.parse(line), json["isSidechain"]?.boolValue != true
      else { continue }
      switch json["type"]?.stringValue {
      case "assistant":
        return json["message"]?["content"]?.arrayValue?.contains {
          $0["type"]?.stringValue == "tool_use"
        } ?? false
      case "user": return false
      default: continue
      }
    }
    return false
  }

  static func reading(_ line: Data) -> ContextReading? {
    // Cheap reject first: most lines are not assistant turns.
    guard line.range(of: Data(#""usage""#.utf8)) != nil, let json = try? JSONValue.parse(line),
      json["type"]?.stringValue == "assistant", json["isSidechain"]?.boolValue != true,
      let message = json["message"], let usage = TokenUsage(message["usage"])
    else { return nil }
    return ContextReading(
      usage: usage, modelID: message["model"]?.stringValue,
      at: json["timestamp"]?.stringValue.flatMap {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0)
      })
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter ContextUsageTests`
Expected: PASS, 8 tests.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): read a session's context from the end of its transcript"
```

---

### Task 2: The context window, and how sure we are of it

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ContextWindow.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ContextWindowTests.swift`

**Interfaces:**
- Consumes: `TokenUsage` (Task 1), `ClaudeAccount` (existing).
- Produces: `ContextWindow { limit, source }`, `ContextWindow.Source` (`reported`,
  `sessionModel(String)`, `accountDefault(String)`, `assumed(String)`, `unknown`, `observed`)
  with `.explanation`; `ContextWindow.resolve(sessionModelID:accountModelID:messageModelID:observedTotal:)`;
  `ContextWindow.accountModelID(_ account: ClaudeAccount) -> String?`;
  `ContextGauge { used, window, fraction, level }`, `ContextGauge.Level { normal, high, critical }`;
  `ContextGauge.make(usage:reportedLimit:initModelID:attachmentModelID:accountModelID:messageModelID:) -> ContextGauge?`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Context window")
struct ContextWindowTests {

  @Test func prefersTheSessionsOwnModel() {
    let window = ContextWindow.resolve(
      sessionModelID: "claude-opus-5[1m]", accountModelID: "sonnet",
      messageModelID: "claude-opus-5", observedTotal: 10)
    #expect(window == ContextWindow(limit: 1_000_000, source: .sessionModel("claude-opus-5[1m]")))
  }

  @Test func fallsBackToTheAccountThenTheMessage() {
    #expect(
      ContextWindow.resolve(
        sessionModelID: nil, accountModelID: "opus[1m]", messageModelID: "claude-opus-5",
        observedTotal: 0).source == .accountDefault("opus[1m]"))
    #expect(
      ContextWindow.resolve(
        sessionModelID: nil, accountModelID: nil, messageModelID: "claude-opus-5",
        observedTotal: 0) == ContextWindow(limit: 200_000, source: .assumed("claude-opus-5")))
    #expect(
      ContextWindow.resolve(
        sessionModelID: nil, accountModelID: nil, messageModelID: nil, observedTotal: 0)
        == ContextWindow(limit: 200_000, source: .unknown))
  }

  /// A 1M session with no attachment reads 389k against an assumed 200k: the measurement
  /// wins, so the gauge never passes full.
  @Test func usageAboveTheWindowMeansAWiderWindow() {
    let window = ContextWindow.resolve(
      sessionModelID: nil, accountModelID: nil, messageModelID: "claude-opus-5",
      observedTotal: 389_013)
    #expect(window == ContextWindow(limit: 1_000_000, source: .observed))
  }

  @Test func aReportedLimitIsTakenAsItIs() throws {
    let gauge = try #require(
      ContextGauge.make(
        usage: TokenUsage(input: 1, cacheCreation: 0, cacheRead: 149_999, output: 0),
        reportedLimit: 200_000, initModelID: "claude-opus-5[1m]", attachmentModelID: nil,
        accountModelID: nil, messageModelID: nil))
    #expect(gauge.window == ContextWindow(limit: 200_000, source: .reported))
    #expect(gauge.fraction == 0.75)
    #expect(gauge.level == .high)
  }

  @Test func theInitModelStandsForTheSession() throws {
    let gauge = try #require(
      ContextGauge.make(
        usage: TokenUsage(input: 0, cacheCreation: 0, cacheRead: 950_000, output: 0),
        reportedLimit: nil, initModelID: "claude-opus-5[1m]", attachmentModelID: nil,
        accountModelID: nil, messageModelID: "claude-opus-5"))
    #expect(gauge.window.limit == 1_000_000)
    #expect(gauge.level == .critical)
  }

  @Test func noUsageIsNoGauge() {
    #expect(
      ContextGauge.make(
        usage: nil, reportedLimit: 200_000, initModelID: nil, attachmentModelID: nil,
        accountModelID: nil, messageModelID: nil) == nil)
  }

  @Test func readsTheAccountsConfiguredModel() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "account-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(#"{"model":"opus[1m]","theme":"dark"}"#.utf8)
      .write(to: folder.appending(path: "settings.json"))
    #expect(
      ContextWindow.accountModelID(ClaudeAccount(directory: folder, isDefault: false)) == "opus[1m]")
    #expect(
      ContextWindow.accountModelID(
        ClaudeAccount(directory: folder.appending(path: "none"), isDefault: false)) == nil)
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter ContextWindowTests`
Expected: FAIL to compile, `cannot find 'ContextWindow' in scope`.

- [ ] **Step 3: Write `ContextWindow.swift`**

```swift
import Foundation

/// How big a session's context window is, and where that answer came from.
///
/// Nothing on disk states it, and `message.model` reads `claude-opus-5` for a 200k session
/// and a 1M one alike (Armada, `docs/claude-code-sessions.md`). A process Drakar owns says
/// it exactly (`get_context_usage`); for the rest, the best source available answers and
/// carries its provenance for the tooltip.
public struct ContextWindow: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    /// `maxTokens` from the process's own `get_context_usage`. Exact.
    case reported
    /// The session's `system/init` model or its `attachment`/`model` entry. Exact.
    case sessionModel(String)
    /// The account's configured model: right until the session runs `/model`.
    case accountDefault(String)
    /// `message.model`, which never carries the variant.
    case assumed(String)
    case unknown
    /// The session already used more than the other sources allowed.
    case observed

    public var explanation: String {
      switch self {
      case .reported: String(localized: "Reported by the session.")
      case .sessionModel(let id): String(localized: "This session runs \(id).")
      case .accountDefault(let id):
        String(
          localized:
            "Assumed from this account's model, \(id). A session that changed model with /model may have another window."
        )
      case .assumed(let id):
        String(
          localized:
            "Assumed from \(id). Claude Code does not record the window size, and the model it records does not tell a 1M session from a 200k one."
        )
      case .unknown: String(localized: "No model recorded; the usual window size.")
      case .observed:
        String(localized: "This session has used more than its model's usual window, so its window is larger.")
      }
    }
  }

  public var limit: Int
  public var source: Source

  public init(limit: Int, source: Source) {
    self.limit = limit
    self.source = source
  }

  public static let standardLimit = 200_000
  public static let extendedLimit = 1_000_000

  /// `[1m]` is the only thing in an id that changes the answer today; this fails open to
  /// the common case rather than keeping a table of ids.
  public static func limit(forModelID id: String) -> Int {
    id.contains("[1m]") ? extendedLimit : standardLimit
  }

  public static func resolve(
    sessionModelID: String?, accountModelID: String?, messageModelID: String?, observedTotal: Int
  ) -> ContextWindow {
    let window: ContextWindow =
      if let id = sessionModelID {
        ContextWindow(limit: limit(forModelID: id), source: .sessionModel(id))
      } else if let id = accountModelID {
        ContextWindow(limit: limit(forModelID: id), source: .accountDefault(id))
      } else if let id = messageModelID {
        ContextWindow(limit: limit(forModelID: id), source: .assumed(id))
      } else {
        ContextWindow(limit: standardLimit, source: .unknown)
      }
    guard observedTotal > window.limit else { return window }
    return ContextWindow(limit: max(extendedLimit, observedTotal), source: .observed)
  }

  /// The `model` in an account's `settings.json` (`opus[1m]`), or nil.
  public static func accountModelID(_ account: ClaudeAccount) -> String? {
    let file = account.directory.appending(path: "settings.json")
    guard let data = try? Data(contentsOf: file), let json = try? JSONValue.parse(data),
      let model = json["model"]?.stringValue, !model.isEmpty
    else { return nil }
    return model
  }
}

/// What the sidebar's gauge draws: how much of the window a session's context fills.
public struct ContextGauge: Sendable, Equatable {
  public enum Level: Sendable, Equatable {
    case normal
    /// From 75 %.
    case high
    /// From 90 %.
    case critical
  }

  public var used: Int
  public var window: ContextWindow

  public init(used: Int, window: ContextWindow) {
    self.used = used
    self.window = window
  }

  public var fraction: Double { min(Double(used) / Double(max(window.limit, 1)), 1) }

  public var level: Level {
    fraction >= 0.9 ? .critical : fraction >= 0.75 ? .high : .normal
  }

  /// A gauge from whatever is known, best source first: a reported limit, the session's own
  /// model (`system/init`, then its attachment), the account's, the message's.
  public static func make(
    usage: TokenUsage?, reportedLimit: Int?, initModelID: String?, attachmentModelID: String?,
    accountModelID: String?, messageModelID: String?
  ) -> ContextGauge? {
    guard let usage else { return nil }
    let window =
      reportedLimit.map { ContextWindow(limit: $0, source: .reported) }
      ?? ContextWindow.resolve(
        sessionModelID: initModelID ?? attachmentModelID, accountModelID: accountModelID,
        messageModelID: messageModelID, observedTotal: usage.total)
    return ContextGauge(used: usage.total, window: window)
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter ContextWindowTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): the context window, from the best source there is, and the gauge"
```

---

### Task 3: Projects own folders, and the registry says more

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ProjectPath.swift`
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ProcessAncestry.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/SessionIndex.swift` (`LiveSession`, from line ~205 to the end)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ProjectPathTests.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift`

**Interfaces:**
- Produces: `ProjectPath.normalize(_:)`, `.contains(_ root:, _ path:)`, `.resolved(_:)`,
  `.owner(of cwd: String, among folders: [String]) -> String?`,
  `.encodedPrefixes(for folder: String) -> [String]`; `ProcessAncestry.parent(of: Int32) -> Int32?`;
  `LiveSession` gains `cwd: String?`, `waitingFor: String?`, `updatedAt: Date?`, a public
  memberwise `init`, and `read(account:isAlive:parentOf:ownPID:temporaryDirectories:)`.

- [ ] **Step 1: Write the failing tests**

`ProjectPathTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Which project a folder is in")
struct ProjectPathTests {

  @Test func containsOnWholeComponents() {
    #expect(ProjectPath.contains("/work/drakar", "/work/drakar"))
    #expect(ProjectPath.contains("/work/drakar/", "/work/drakar/apps/apple"))
    #expect(!ProjectPath.contains("/work/drakar", "/work/drakar-old"))
    #expect(!ProjectPath.contains("/work/drakar", "/work"))
  }

  @Test func theDeepestOpenFolderOwnsASession() {
    let folders = ["/work/drakar", "/work/drakar/apps/apple"]
    #expect(ProjectPath.owner(of: "/work/drakar/apps/apple/Drakar", among: folders) == "/work/drakar/apps/apple")
    #expect(ProjectPath.owner(of: "/work/drakar/.claude/worktrees/x", among: folders) == "/work/drakar")
    #expect(ProjectPath.owner(of: "/work/other", among: folders) == nil)
  }

  /// Claude Code records the resolved cwd; a folder opened through a link still owns it.
  @Test func aFolderOpenedThroughALinkOwnsItsResolvedSessions() throws {
    let real = FileManager.default.temporaryDirectory.appending(path: "real-\(UUID())")
    let link = FileManager.default.temporaryDirectory.appending(path: "link-\(UUID())")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.removeItem(at: real)
    }
    let cwd = ProjectPath.resolved(real.path(percentEncoded: false)) + "/sub"
    let folder = link.path(percentEncoded: false)
    #expect(ProjectPath.owner(of: cwd, among: [folder]) == ProjectPath.normalize(folder))
  }

  @Test func transcriptFoldersBeginWithTheFoldersEncoding() {
    #expect(ProjectPath.encodedPrefixes(for: "/Users/me/my.app") == ["-Users-me-my.app", "-Users-me-my-app"])
    #expect(ProjectPath.encodedPrefixes(for: "/Users/me/app") == ["-Users-me-app"])
  }
}
```

`LiveSessionTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@Suite("The live session registry")
struct LiveSessionTests {

  private let account: ClaudeAccount
  private var sessions: URL { account.directory.appending(path: "sessions") }

  init() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "registry-\(UUID())")
    account = ClaudeAccount(directory: folder, isDefault: false)
    try FileManager.default.createDirectory(
      at: folder.appending(path: "sessions"), withIntermediateDirectories: true)
  }

  private func write(_ pid: Int32, _ json: String) throws {
    try Data(json.utf8).write(to: sessions.appending(path: "\(pid).json"))
    // The key file beside each registry entry is not JSON and must be skipped.
    try Data("secret".utf8).write(to: sessions.appending(path: "\(pid).abc.key"))
  }

  /// Captured from 2.1.288 (this Mac, 2026-10-03), pid and paths changed.
  @Test func readsWhatTheSessionSaysAboutItself() throws {
    try write(
      41,
      #"{"pid":41,"sessionId":"s1","cwd":"/work/drakar","startedAt":1791063576511,"version":"2.1.288","kind":"interactive","entrypoint":"claude-vscode","status":"waiting","waitingFor":"permission prompt","updatedAt":1791063683948}"#
    )
    let live = LiveSession.read(
      account: account, isAlive: { _ in true }, parentOf: { _ in 1 }, ownPID: 99,
      temporaryDirectories: [])
    #expect(live.count == 1)
    #expect(live.first?.cwd == "/work/drakar")
    #expect(live.first?.status == "waiting")
    #expect(live.first?.waitingFor == "permission prompt")
    #expect(live.first?.updatedAt == Date(timeIntervalSince1970: 1_791_063_683.948))
  }

  /// Drakar's own processes register too; they are read from memory, never from here.
  @Test func skipsDrakarsOwnChildrenAndTemporarySpawns() throws {
    try write(41, #"{"pid":41,"sessionId":"mine","cwd":"/work/drakar"}"#)
    try write(42, #"{"pid":42,"sessionId":"summarizer","cwd":"/private/var/folders/x/T"}"#)
    try write(43, #"{"pid":43,"sessionId":"theirs","cwd":"/work/drakar"}"#)
    let live = LiveSession.read(
      account: account, isAlive: { _ in true }, parentOf: { $0 == 41 ? 99 : 1 }, ownPID: 99,
      temporaryDirectories: ["/private/var/folders/x/T"])
    #expect(live.map(\.sessionID) == ["theirs"])
  }

  @Test func skipsAProcessThatIsGone() throws {
    try write(41, #"{"pid":41,"sessionId":"s1","cwd":"/w"}"#)
    #expect(
      LiveSession.read(
        account: account, isAlive: { _ in false }, parentOf: { _ in 1 }, ownPID: 99,
        temporaryDirectories: []
      ).isEmpty)
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter 'ProjectPathTests|LiveSessionTests'`
Expected: FAIL to compile, `cannot find 'ProjectPath' in scope`.

- [ ] **Step 3: Write `ProjectPath.swift`**

```swift
import Foundation

/// Folders as projects compare them: normalised, matched on whole path components, the
/// deepest open project owning a session. Ported from Armada's `ProjectPath`, where a raw
/// prefix once counted `armada-old`'s sessions as `armada`'s.
public enum ProjectPath {
  /// No trailing slash (except the root's), `.` and `..` resolved on the string.
  public static func normalize(_ raw: String) -> String {
    var path = raw
    if path.contains("/.") || path.contains("//") {
      path = URL(filePath: path, directoryHint: .inferFromPath).standardized
        .path(percentEncoded: false)
    }
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  /// Whether `path` is `root` or below it.
  public static func contains(_ root: String, _ path: String) -> Bool {
    let root = normalize(root)
    let path = normalize(path)
    guard !root.isEmpty, !path.isEmpty else { return false }
    if root == "/" { return path.hasPrefix("/") }
    return path == root || path.hasPrefix(root + "/")
  }

  /// The path with its symbolic links resolved, as Claude Code records a `cwd`: a folder
  /// under `/tmp` is `/private/tmp/…` there. `realpath`, because `URL` leaves `/var` alone.
  public static func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return normalize(path) }
    defer { free(real) }
    return normalize(String(cString: real))
  }

  /// The folder among `folders` that owns `cwd`: the deepest containing it, by its own
  /// spelling or its resolved one. Returned as `normalize` writes it.
  public static func owner(of cwd: String, among folders: [String]) -> String? {
    var best: (folder: String, length: Int)?
    for folder in folders {
      let normalized = normalize(folder)
      for key in Set([normalized, resolved(normalized)]) where contains(key, cwd) {
        if let current = best, key.count <= current.length { continue }
        best = (normalized, key.count)
      }
    }
    return best?.folder
  }

  /// How Claude Code names the transcript folder of `folder`, in the two encodings seen:
  /// every `/` a `-`, or every character but letters and digits a `-`. A subfolder's name
  /// starts with its parent's, so these are prefixes to list, then confirm by `cwd`.
  public static func encodedPrefixes(for folder: String) -> [String] {
    let path = normalize(folder)
    let slashes = path.replacingOccurrences(of: "/", with: "-")
    let alphanumeric = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    return slashes == alphanumeric ? [slashes] : [slashes, alphanumeric]
  }
}
```

- [ ] **Step 4: Write `ProcessAncestry.swift`**

```swift
import Darwin

/// What the kernel says about a process's parent. Ported, cut down, from Armada.
public enum ProcessAncestry {
  /// The parent pid, or nil if the process is gone. `sysctl` returns 0 and writes nothing
  /// for a pid that does not exist, so the size and pid are checked, not just the result.
  public static func parent(of pid: Int32) -> Int32? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0,
      info.kp_proc.p_pid == pid, info.kp_eproc.e_ppid > 0
    else { return nil }
    return info.kp_eproc.e_ppid
  }
}
```

- [ ] **Step 5: Extend `LiveSession`**

In `SessionIndex.swift`, replace the stored properties and `read` of `LiveSession` with:

```swift
public struct LiveSession: Sendable, Hashable {
  public var pid: Int32
  public var sessionID: String
  /// `claude-vscode`, `cli`, or `sdk-cli` for a headless one.
  public var entrypoint: String?
  /// `busy`, `waiting` or `idle`: reported by the CLI, the authority for coarse state.
  public var status: String?
  public var cwd: String?
  /// Why it waits ("permission prompt", "dialog open"). Display text: never branched on.
  public var waitingFor: String?
  /// When the CLI last rewrote the file. Better than the transcript's date: a session
  /// parked on a prompt writes no transcript, but moves this.
  public var updatedAt: Date?

  public init(
    pid: Int32, sessionID: String, entrypoint: String? = nil, status: String? = nil,
    cwd: String? = nil, waitingFor: String? = nil, updatedAt: Date? = nil
  ) {
    self.pid = pid
    self.sessionID = sessionID
    self.entrypoint = entrypoint
    self.status = status
    self.cwd = cwd
    self.waitingFor = waitingFor
    self.updatedAt = updatedAt
  }

  /// The per-user temporary folder both ways it is spelled: where plugins run headless
  /// summarizers (the remember plugin's `t-XX` rows), which are not sessions.
  public static let defaultTemporaryDirectories: Set<String> = {
    let spelled = ProjectPath.normalize(NSTemporaryDirectory())
    return [spelled, ProjectPath.resolved(spelled)]
  }()

  /// Every live session in `account`'s registry, except Drakar's own children (a window
  /// reads those from memory) and spawns in the temporary folder.
  public static func read(
    account: ClaudeAccount, isAlive: (Int32) -> Bool = isAlive,
    parentOf: (Int32) -> Int32? = ProcessAncestry.parent,
    ownPID: Int32 = getpid(),
    temporaryDirectories: Set<String> = defaultTemporaryDirectories
  ) -> [LiveSession] {
    let folder = account.directory.appending(path: "sessions", directoryHint: .isDirectory)
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { file in
      guard let data = try? Data(contentsOf: file), let json = try? JSONValue.parse(data),
        let pid = json["pid"]?.intValue.flatMap(Int32.init(exactly:)),
        let id = json["sessionId"]?.stringValue, isAlive(pid), parentOf(pid) != ownPID
      else { return nil }
      let cwd = json["cwd"]?.stringValue
      if let cwd, temporaryDirectories.contains(ProjectPath.normalize(cwd)) { return nil }
      return LiveSession(
        pid: pid, sessionID: id, entrypoint: json["entrypoint"]?.stringValue,
        status: json["status"]?.stringValue, cwd: cwd,
        waitingFor: json["waitingFor"]?.stringValue,
        updatedAt: json["updatedAt"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) })
    }
    .sorted { $0.pid < $1.pid }
  }
```

Keep `isAlive(_:)` as it is. `SessionIndex.list` calls `LiveSession.read(account:isAlive:)`,
which still compiles against the defaults.

- [ ] **Step 6: Run the kit tests**

Run: `make -C apps/apple test`
Expected: PASS, every suite (the existing `SessionIndex` callers still compile).

- [ ] **Step 7: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): which project owns a folder, and what the registry says about a session"
```

---

### Task 4: Context from the stream, and asking the process for its window

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/StreamMessage.swift` (`AssistantMessage`, ~line 99)
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Transcript.swift` (stored state ~line 60, `apply` ~line 122)
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ClientMessage.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ContextUsage.swift` (append `ContextUsageReply`)
- Modify: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift` (new case)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ContextUsageTests.swift` (append)

**Interfaces:**
- Consumes: `TokenUsage` (Task 1); the capture from Task 0.
- Produces: `AssistantMessage.usage: TokenUsage?`; `Transcript.contextUsage: TokenUsage?`,
  `Transcript.contextModelID: String?`; `ClientMessage.contextUsage(requestID: String)`;
  `ContextUsageReply { totalTokens, maxTokens, categories: [Category] }`,
  `ContextUsageReply.init?(_ response: JSONValue?)`, `ContextUsageReply.Category { name, tokens }`.

- [ ] **Step 1: Add the fixture case**

In `Fixture.swift`, after `ideRequests`:

```swift
  /// A `haiku` turn under `--include-partial-messages` (2026-10-04, Task 0 of the project
  /// windows plan): init, an assistant line with usage, the result, and the replies to
  /// `get_context_usage` sent mid-turn and between turns.
  case contextUsage = "context-usage"
```

- [ ] **Step 2: Write the failing tests**

Append to `ContextUsageTests`:

```swift
  @Test func theStreamCarriesUsageIntoTheTranscript() throws {
    var transcript = Transcript()
    for message in try Fixture.contextUsage.messages { transcript.apply(message) }
    let usage = try #require(transcript.contextUsage)
    #expect(usage.total > 0)
    #expect(transcript.contextModelID != nil)
  }

  /// A subagent's request has its own context, which is not the session's.
  @Test func aSubagentsUsageLeavesTheSessionsAlone() throws {
    var transcript = Transcript()
    transcript.apply(
      try StreamMessage(
        line: Data(
          #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":99,"output_tokens":1}}}"#
            .utf8)))
    transcript.apply(
      try StreamMessage(
        line: Data(
          #"{"type":"assistant","parent_tool_use_id":"task1","message":{"id":"s1","content":[{"type":"text","text":"sub"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":5,"output_tokens":1}}}"#
            .utf8)))
    #expect(transcript.contextUsage?.total == 100)
  }

  /// History replays the same messages, so a resumed session has its gauge before it runs.
  @Test func historyCarriesTheNewestUsage() throws {
    let transcript = Transcript.history(lines: try Fixture.historyWithTool.lines)
    #expect(transcript.contextUsage != nil)
  }

  @Test func asksForTheContextInSummary() throws {
    let json = ClientMessage.contextUsage(requestID: "context-1").json
    #expect(json["type"]?.stringValue == "control_request")
    #expect(json["request_id"]?.stringValue == "context-1")
    #expect(json["request"]?["subtype"]?.stringValue == "get_context_usage")
    #expect(json["request"]?["detail"]?.stringValue == "summary")
  }

  @Test func readsTheCapturedReply() throws {
    let responses = try Fixture.contextUsage.messages.compactMap { message -> ControlResponse? in
      if case .controlResponse(let response) = message, response.requestID.hasPrefix("ctx-") {
        return response
      }
      return nil
    }
    let reply = try #require(responses.last.flatMap { ContextUsageReply($0.response) })
    #expect(reply.maxTokens >= 200_000)
    #expect(reply.totalTokens > 0)
    #expect(!reply.categories.isEmpty)
    #expect(!reply.categories.contains { $0.name == "Free space" || $0.tokens == 0 })
  }
```

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter ContextUsageTests`
Expected: FAIL to compile, `value of type 'Transcript' has no member 'contextUsage'`.

- [ ] **Step 4: Decode usage on assistant messages**

In `AssistantMessage`, add the property and set it in `init?`:

```swift
  /// The request's tokens. Every block of one message repeats the same object.
  public var usage: TokenUsage?
```

```swift
    usage = TokenUsage(message["usage"])
```

- [ ] **Step 5: Keep the newest main-thread usage in the transcript**

In `Transcript`, beside `lastResult`:

```swift
  /// The newest main-thread request's tokens: the session's context. Subagents' are theirs.
  public private(set) var contextUsage: TokenUsage?
  /// `message.model` of that request.
  public private(set) var contextModelID: String?
```

At the top of `case .assistant(let assistant):` in `apply(_ message:)`:

```swift
      if assistant.parentToolUseID == nil, let usage = assistant.usage {
        contextUsage = usage
        contextModelID = assistant.model ?? contextModelID
      }
```

- [ ] **Step 6: Encode the request**

In `ClientMessage`, add the case and its encoding:

```swift
  /// The process's own account of its context: the window size, exact, and its breakdown.
  case contextUsage(requestID: String)
```

```swift
    case .contextUsage(let id):
      // `summary`, not `full`: `full` counts each category through `count_tokens`.
      Self.controlRequest(
        id, ["subtype": .string("get_context_usage"), "detail": .string("summary")])
```

- [ ] **Step 7: Decode the reply**

Append to `ContextUsage.swift`:

```swift
/// The answer to `get_context_usage`: the window the process runs with, and what fills it.
public struct ContextUsageReply: Sendable, Equatable {
  public struct Category: Sendable, Equatable {
    public var name: String
    public var tokens: Int
  }

  public var totalTokens: Int
  public var maxTokens: Int
  /// The categories that occupy the window, largest first: the remainder, the reserve and
  /// the deferred tools are left out, as Claude Code leaves them out of its own total.
  public var categories: [Category]

  static let excluded: Set<String> = ["Free space", "Autocompact buffer", "Compact buffer"]

  public init?(_ response: JSONValue?) {
    guard let response, let total = response["totalTokens"]?.intValue,
      let max = response["maxTokens"]?.intValue, max > 0
    else { return nil }
    totalTokens = total
    maxTokens = max
    categories = (response["categories"]?.arrayValue ?? []).compactMap { entry in
      guard let name = entry["name"]?.stringValue, let tokens = entry["tokens"]?.intValue,
        tokens > 0, !Self.excluded.contains(name), entry["isDeferred"]?.boolValue != true
      else { return nil }
      return Category(name: name, tokens: tokens)
    }
    .sorted { $0.tokens > $1.tokens }
  }
}
```

If the Task 0 capture names the fields differently, follow the capture and say so in the
commit body.

- [ ] **Step 8: Run the kit tests**

Run: `make -C apps/apple test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): context from the stream, and the process's own account of its window"
```

---

### Task 5: Following a transcript, and a project's sessions on disk

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/TranscriptFollower.swift`
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ProjectSessions.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/SessionIndex.swift` (`SessionSummary`, `list`, `summarize`)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptFollowerTests.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ProjectSessionsTests.swift`

**Interfaces:**
- Consumes: `TranscriptTail` (Task 1), `ProjectPath` (Task 3), `LiveSession` (Task 3).
- Produces: `TranscriptFollower(file:)`, `.catchUp(_ transcript: inout Transcript) throws`,
  `.offset`; `SessionSummary.context: ContextReading?`, `SessionSummary.modelID: String?`;
  `SessionIndex.list(accounts:limit:under:isAlive:)`, `SessionIndex.summary(of:account:) -> SessionSummary?`;
  `ProjectGroups { elsewhere, ended }`,
  `ProjectSessions.group(_:folder:otherFolders:attached:inOtherWindows:) -> ProjectGroups`.

- [ ] **Step 1: Write the failing follower tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Following a transcript as it is written")
struct TranscriptFollowerTests {

  private let file = FileManager.default.temporaryDirectory.appending(path: "follow-\(UUID()).jsonl")

  private func append(_ data: Data) throws {
    if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
      FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
    }
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()
  }

  private func joined(_ lines: [Data]) -> Data {
    Data(lines.map { $0 + Data("\n".utf8) }.joined())
  }

  /// Read in pieces, cut mid-line, it folds to the same thing as one read of the whole.
  @Test func piecesFoldToTheWhole() throws {
    let whole = joined(try Fixture.historyWithTool.lines)
    let cut = whole.count / 2 + 7
    var follower = TranscriptFollower(file: file)
    var transcript = Transcript()
    try append(whole.prefix(cut))
    try follower.catchUp(&transcript)
    try append(whole.dropFirst(cut))
    try follower.catchUp(&transcript)
    let once = try Transcript.history(contentsOf: file)
    #expect(transcript.entries == once.entries)
    #expect(transcript.title == once.title)
    #expect(follower.offset == UInt64(whole.count))
  }

  /// A file that got shorter was rewritten: start over, never append the new to the old.
  @Test func startsOverWhenTheFileShrinks() throws {
    var follower = TranscriptFollower(file: file)
    var transcript = Transcript()
    try append(joined(try Fixture.historyWithTool.lines))
    try follower.catchUp(&transcript)
    let prompt = #"{"type":"user","message":{"role":"user","content":"only this"}}"#
    try Data((prompt + "\n").utf8).write(to: file)
    try follower.catchUp(&transcript)
    #expect(transcript.entries.map(\.kind) == [.prompt("only this")])
  }

  @Test func aMissingFileThrows() {
    var follower = TranscriptFollower(file: file.appending(path: "nope"))
    var transcript = Transcript()
    #expect(throws: (any Error).self) { try follower.catchUp(&transcript) }
  }
}
```

- [ ] **Step 2: Write the failing grouping and index tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("A project's sessions")
struct ProjectSessionsTests {

  private let account = ClaudeAccount(directory: URL(filePath: "/a/.claude"), isDefault: true)
  private let other = ClaudeAccount(directory: URL(filePath: "/a/.claude-work"), isDefault: false)

  private func summary(
    _ id: String, cwd: String, minutesAgo: Double, live: Bool = false,
    account: ClaudeAccount? = nil
  ) -> SessionSummary {
    let account = account ?? self.account
    var summary = SessionSummary(
      sessionID: id, account: account,
      file: account.directory.appending(path: "projects/x/\(id).jsonl"),
      modified: Date(timeIntervalSinceNow: -minutesAgo * 60), size: 1)
    summary.cwd = cwd
    summary.live = live ? LiveSession(pid: 7, sessionID: id, status: "busy") : nil
    return summary
  }

  @Test func splitsLiveFromEndedAndLeavesTheAttachedOut() {
    let groups = ProjectSessions.group(
      [
        summary("old", cwd: "/w/drakar", minutesAgo: 90),
        summary("live", cwd: "/w/drakar/apps", minutesAgo: 5, live: true),
        summary("here", cwd: "/w/drakar", minutesAgo: 1),
        summary("new", cwd: "/w/drakar", minutesAgo: 2),
        summary("elsewhere", cwd: "/w/other", minutesAgo: 1),
      ],
      folder: "/w/drakar", otherFolders: [], attached: ["here"], inOtherWindows: [])
    #expect(groups.elsewhere.map(\.sessionID) == ["live"])
    #expect(groups.ended.map(\.sessionID) == ["new", "old"])
  }

  @Test func aDeeperWindowTakesItsSessions() {
    let groups = ProjectSessions.group(
      [summary("deep", cwd: "/w/drakar/apps/apple", minutesAgo: 1)],
      folder: "/w/drakar", otherFolders: ["/w/drakar/apps/apple"], attached: [],
      inOtherWindows: [])
    #expect(groups.ended.isEmpty && groups.elsewhere.isEmpty)
  }

  /// Open in another Drakar window: Drakar's children are not in the registry, so the
  /// window index says it is live.
  @Test func anotherDrakarWindowCountsAsElsewhere() {
    let groups = ProjectSessions.group(
      [summary("theirs", cwd: "/w/drakar", minutesAgo: 30)], folder: "/w/drakar",
      otherFolders: [], attached: [], inOtherWindows: ["theirs"])
    #expect(groups.elsewhere.map(\.sessionID) == ["theirs"])
  }

  /// One id under two accounts is one conversation: one row, the newer transcript.
  @Test func oneRowPerSessionID() {
    let groups = ProjectSessions.group(
      [
        summary("s", cwd: "/w/drakar", minutesAgo: 10),
        summary("s", cwd: "/w/drakar", minutesAgo: 3, account: other),
      ],
      folder: "/w/drakar", otherFolders: [], attached: [], inOtherWindows: [])
    #expect(groups.ended.count == 1)
    #expect(groups.ended.first?.account == other)
  }

  /// The index lists only folders encoded under the project, confirms by cwd, and reads
  /// each one's context from the same mapped file.
  @Test func listsAFoldersSessionsWithTheirContext() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "index-\(UUID())")
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    defer { try? FileManager.default.removeItem(at: home) }
    func write(_ folder: String, _ id: String, cwd: String) throws {
      let dir = account.directory.appending(path: "projects/\(folder)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let lines = [
        #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user","content":"go"}}"#,
        #"{"type":"assistant","cwd":"\#(cwd)","message":{"id":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}"#,
      ]
      try Data(lines.joined(separator: "\n").utf8).write(to: dir.appending(path: "\(id).jsonl"))
    }
    try write("-w-drakar", "a", cwd: "/w/drakar")
    try write("-w-drakar-apps", "b", cwd: "/w/drakar/apps")
    try write("-w-drakar-old", "c", cwd: "/w/drakar-old")
    try write("-w-other", "d", cwd: "/w/other")
    let listed = SessionIndex.list(accounts: [account], under: "/w/drakar", isAlive: { _ in false })
    #expect(Set(listed.map(\.sessionID)) == ["a", "b"])
    #expect(listed.first?.context?.total == 6)
  }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter 'TranscriptFollowerTests|ProjectSessionsTests'`
Expected: FAIL to compile, `cannot find 'TranscriptFollower' in scope`.

- [ ] **Step 4: Write `TranscriptFollower.swift`**

```swift
import Foundation

/// A transcript file read as it grows, for a session another process is writing: each
/// catch-up folds in only the lines appended since the last one.
public struct TranscriptFollower: Sendable {
  public let file: URL
  /// Bytes read so far.
  public private(set) var offset: UInt64 = 0
  private var buffer = LineBuffer()

  public init(file: URL) {
    self.file = file
  }

  /// Folds what was appended since the last call into `transcript`. A line still being
  /// written waits for its newline. A file that got shorter was rewritten, and is read
  /// again from the start into a fresh transcript.
  public mutating func catchUp(_ transcript: inout Transcript) throws {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    if size < offset {
      offset = 0
      buffer = LineBuffer()
      transcript = Transcript()
    }
    guard size > offset else { return }
    try handle.seek(toOffset: offset)
    let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
    offset += UInt64(data.count)
    for line in buffer.append(data) {
      if let json = try? JSONValue.parse(line) { transcript.applyHistory(json) }
    }
    transcript.processExited()
  }
}
```

- [ ] **Step 5: Give summaries their context, and list one folder's**

In `SessionSummary`, after `live`:

```swift
  /// The newest main-thread turn's context, from the end of the transcript.
  public var context: ContextReading?
  /// The session's own model attachment (`claude-opus-5[1m]`), when it wrote one.
  public var modelID: String?
```

In `SessionIndex`, change `list` to take an optional folder. Replace its signature and the
inner `for folder in folders` loop head, and filter after summarizing:

```swift
  /// The `limit` most recently written sessions across `accounts`, newest first; with
  /// `folder`, only sessions whose `cwd` is that folder or below it.
  public static func list(
    accounts: [ClaudeAccount], limit: Int = 200, under folder: String? = nil,
    isAlive: (Int32) -> Bool = LiveSession.isAlive
  ) -> [SessionSummary] {
```

```swift
    let prefixes = folder.map { folder in
      Set(
        ProjectPath.encodedPrefixes(for: folder)
          + ProjectPath.encodedPrefixes(for: ProjectPath.resolved(folder)))
    }
```

(placed before the `for account in accounts` that walks `projects`), then:

```swift
      for projectFolder in folders
      where prefixes?.contains(where: projectFolder.lastPathComponent.hasPrefix) ?? true {
```

renaming the loop variable from `folder` to `projectFolder` in that loop's body. Then make
the final `return` filter:

```swift
    return found.sorted { $0.2 > $1.2 }.prefix(limit).compactMap { file, account, modified, size in
      var summary = summarize(file: file, account: account, modified: modified, size: size)
      if let folder {
        guard let cwd = summary.cwd, ProjectPath.owner(of: cwd, among: [folder]) != nil else {
          return nil
        }
      }
      summary.live = live[account]?[summary.sessionID]
      return summary
    }
```

Add a single-file entry point after `list`:

```swift
  /// One transcript, summarized: what the monitor re-reads when a file changes.
  public static func summary(of file: URL, account: ClaudeAccount) -> SessionSummary? {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
    guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
    return summarize(
      file: file, account: account, modified: values.contentModificationDate ?? .distantPast,
      size: values.fileSize ?? 0)
  }
```

In `summarize`, after `summary.cwd = …`:

```swift
    let tail = TranscriptTail(suffixOf: data)
    summary.context = tail.newestReading
    summary.modelID = tail.newestModelID
```

- [ ] **Step 6: Write `ProjectSessions.swift`**

```swift
import Foundation

/// A project window's sidebar, below the sessions it holds: those live elsewhere, and
/// those that ended.
public struct ProjectGroups: Sendable, Equatable {
  /// Live in a terminal, VS Code or another Drakar window: newest activity first.
  public var elsewhere: [SessionSummary]
  /// Newest first.
  public var ended: [SessionSummary]
}

public enum ProjectSessions {
  /// `summaries` sorted into a project's groups.
  ///
  /// A session belongs to the deepest open project containing its `cwd`, so a deeper window
  /// (`otherFolders`) takes its own. `attached` ids are the window's own rows and are left
  /// out. `inOtherWindows` ids are open in another Drakar window, which the registry does
  /// not say: Drakar's own children are not read from it. One id under two accounts is one
  /// conversation, and keeps its newer transcript.
  public static func group(
    _ summaries: [SessionSummary], folder: String, otherFolders: [String],
    attached: Set<String>, inOtherWindows: Set<String>
  ) -> ProjectGroups {
    let folders = [folder] + otherFolders
    let own = ProjectPath.normalize(folder)
    var newest: [String: SessionSummary] = [:]
    for summary in summaries where !attached.contains(summary.sessionID) {
      guard let cwd = summary.cwd, ProjectPath.owner(of: cwd, among: folders) == own else {
        continue
      }
      if let kept = newest[summary.sessionID], kept.modified >= summary.modified { continue }
      newest[summary.sessionID] = summary
    }
    let isElsewhere = { (summary: SessionSummary) in
      summary.live != nil || inOtherWindows.contains(summary.sessionID)
    }
    let activity = { (summary: SessionSummary) in summary.live?.updatedAt ?? summary.modified }
    return ProjectGroups(
      elsewhere: newest.values.filter(isElsewhere).sorted { activity($0) > activity($1) },
      ended: newest.values.filter { !isElsewhere($0) }.sorted { $0.modified > $1.modified })
  }
}
```

- [ ] **Step 7: Run the kit tests**

Run: `make -C apps/apple test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): follow a transcript as it grows, and sort a project's sessions"
```

---

### Task 6: A session that starts on its first prompt

**Files:**
- Modify: `apps/apple/Drakar/Services/ClaudeSession.swift` (whole file)
- Test: `apps/apple/DrakarTests/ClaudeSessionTests.swift`

**Interfaces:**
- Consumes: `TranscriptFollower` (Task 5), `ClientMessage.contextUsage`, `ContextUsageReply`
  (Task 4), `ResumeTarget` (existing, `Services/SessionRoute.swift`).
- Produces, on `ClaudeSession`: `init(folder:resuming:)` (unchanged); `resuming` becomes
  `private(set) var`; `var command: ClaudeCommand`; `var isReadOnly: Bool`;
  `private(set) var reportedContext: ContextUsageReply?`; `private(set) var savedTarget: ResumeTarget?`;
  `func loadHistory() async`; `func spawn() async`;
  `func send(_:context:)` (spawns when needed); `func catchUp()`; `func stop()`;
  callbacks `onTurnEnded: (() -> Void)?`, `onPermissionRequested: ((Transcript.PendingPermission) -> Void)?`,
  `onStopped: (() -> Void)?`; `var canSend: Bool`; `var isProcessRunning: Bool`;
  `var executableOverride: URL?` (tests only); `private(set) var account: ClaudeAccount?`
  (kept from 6ffe135, the footer reads it). The spawn keeps 6ffe135's Settings choices
  (`ClaudeChoice.executable`, `ClaudeChoice.newSessionAccount`), or both Settings › General
  pickers stop doing anything without a test failing.
  `start(command:)` is removed: callers use `send`, or `spawn` directly.

- [ ] **Step 1: Write the failing hosted tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A session against a stand-in `claude`: a script that writes whatever it is sent to a
/// file beside itself, so the order of the lines can be read back.
@MainActor
@Suite("A session started on demand")
struct ClaudeSessionTests {

  private let folder: URL
  private let fake: URL
  private var received: URL { fake.appendingPathExtension("stdin") }

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fake = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat > \"$0.stdin\"\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  private func lines(count: Int) async throws -> [String] {
    for _ in 0..<50 {
      let text = (try? String(contentsOf: received, encoding: .utf8)) ?? ""
      let lines = text.split(separator: "\n").map(String.init)
      if lines.count >= count { return lines }
      try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("the stand-in received fewer than \(count) lines")
    return []
  }

  @Test func nothingRunsUntilTheFirstPrompt() {
    let session = ClaudeSession(folder: folder)
    #expect(session.phase == .idle)
    #expect(session.canSend)
    #expect(!session.isProcessRunning)
  }

  /// The prompt typed before the process exists goes out after `initialize`, never before.
  @Test func theFirstPromptFollowsInitialize() async throws {
    let session = ClaudeSession(folder: folder)
    session.executableOverride = fake
    session.send("hello")
    #expect(session.transcript.isRunning)
    let lines = try await lines(count: 2)
    session.stop()
    #expect(lines.first?.contains(#""subtype":"initialize""#) == true)
    #expect(lines.last?.contains(#""type":"user""#) == true)
    #expect(lines.last?.contains("hello") == true)
  }

  /// A restored window whose transcript is gone still opens, and says why it cannot resume.
  @Test func aMissingTranscriptStopsWithAReason() async {
    let target = ResumeTarget(
      sessionID: "gone", cwd: folder.path(percentEncoded: false),
      file: folder.appending(path: "gone.jsonl").path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
    let session = ClaudeSession(folder: folder, resuming: target)
    await session.loadHistory()
    guard case .failed(let reason) = session.phase else {
      Issue.record("phase is \(session.phase)")
      return
    }
    #expect(reason.contains("transcript"))
  }

  @Test func historyLoadsWithoutAProcess() async throws {
    let file = folder.appending(path: "s1.jsonl")
    try Data(
      [
        #"{"type":"user","message":{"role":"user","content":"Make it so"}}"#,
        #"{"type":"ai-title","aiTitle":"Make it so"}"#,
      ].joined(separator: "\n").utf8
    ).write(to: file)
    let target = ResumeTarget(
      sessionID: "s1", cwd: folder.path(percentEncoded: false),
      file: file.path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
    let session = ClaudeSession(folder: folder, resuming: target)
    await session.loadHistory()
    #expect(session.title == "Make it so")
    #expect(session.phase == .idle)
    #expect(session.savedTarget == target)
  }

  @Test func aReadOnlySessionSendsNothing() {
    let session = ClaudeSession(folder: folder)
    session.isReadOnly = true
    #expect(!session.canSend)
    session.send("hello")
    #expect(session.transcript.entries.isEmpty)
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/ClaudeSessionTests`
Expected: FAIL to compile, `value of type 'ClaudeSession' has no member 'spawn'`.

- [ ] **Step 3: Rewrite `ClaudeSession.swift`**

```swift
import DrakarKit
import Foundation
import Observation

/// One session in a project window: its history from disk, and a `claude` process from its
/// first prompt on.
///
/// Main-actor state over an `AgentProcess`: events are decoded off the main thread and
/// applied here in batches, which is all the view observes.
@Observable
final class ClaudeSession {
  enum Phase: Equatable {
    /// No process: never started, or a history shown until the first prompt.
    case idle
    case starting
    case ready
    case failed(String)
    case exited(status: Int32)
  }

  let folder: URL
  /// What this session continues; nil for a new one. Becomes the session's own target
  /// once it has one, so that a prompt after the process ended resumes it.
  private(set) var resuming: ResumeTarget?
  private(set) var transcript = Transcript()
  private(set) var phase: Phase = .idle
  /// The binary this session runs, for the footer and for bug reports.
  private(set) var executable: URL?
  /// The account it runs under, picked or the shell's; nil until it starts.
  private(set) var account: ClaudeAccount?
  /// The end of the CLI's stderr, shown when the process fails.
  private(set) var diagnostics = ""
  /// The process's answer to `get_context_usage` after its last turn: the exact window.
  private(set) var reportedContext: ContextUsageReply?
  /// What reopening the window resumes: known from the start for a resumed session, and
  /// from its first finished turn for a new one or a fork, once its transcript exists.
  private(set) var savedTarget: ResumeTarget?
  /// The arguments the next spawn runs with (a model for a debug launch).
  var command = ClaudeCommand()
  /// Open in another process: the transcript follows its file and nothing is sent.
  var isReadOnly = false
  /// Stands in for the located binary, in tests.
  @ObservationIgnored var executableOverride: URL?

  /// For the window's attention: a turn ended, a permission request arrived, the process
  /// stopped on its own.
  @ObservationIgnored var onTurnEnded: (() -> Void)?
  @ObservationIgnored var onPermissionRequested: ((Transcript.PendingPermission) -> Void)?
  @ObservationIgnored var onStopped: (() -> Void)?

  @ObservationIgnored private var process: AgentProcess?
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var requestCount = 0
  @ObservationIgnored private var hasHistory = false
  @ObservationIgnored private var follower: TranscriptFollower?
  /// A prompt sent before the process existed, written right after `initialize`.
  @ObservationIgnored private var pendingPrompt: ClientMessage?

  init(folder: URL, resuming: ResumeTarget? = nil) {
    self.folder = folder
    self.resuming = resuming
    savedTarget = resuming?.forks == true ? nil : resuming
  }

  /// The session's id once known: the resumed one at once, a new one or a fork's from
  /// `system/init`. A fork never answers with the original's id, which another process owns.
  var sessionID: String? {
    transcript.session?.sessionID ?? (resuming?.forks == true ? nil : resuming?.sessionID)
  }

  /// The title Claude Code gave the session, from its history.
  var title: String? { transcript.title }

  var isProcessRunning: Bool { process != nil }

  var canSend: Bool { !isReadOnly && !transcript.isRunning && phase != .starting }

  /// The history from the transcript file, once: `--resume` continues a session but does
  /// not replay it, and transcripts run to megabytes, so it is read off the main thread.
  func loadHistory() async {
    guard !hasHistory, let file = resuming?.transcriptFile else { return }
    hasHistory = true
    let loaded = await Task.detached { () -> (Transcript, TranscriptFollower)? in
      var follower = TranscriptFollower(file: file)
      var transcript = Transcript()
      guard (try? follower.catchUp(&transcript)) != nil else { return nil }
      return (transcript, follower)
    }.value
    guard let (transcript, follower) = loaded else {
      phase = .failed(
        String(
          localized:
            "The transcript of this session is missing. It may have been deleted, or its account removed."
        ))
      return
    }
    self.transcript = transcript
    self.follower = follower
  }

  /// What another process appended, for a read-only session.
  func catchUp() {
    guard isReadOnly, var follower else { return }
    try? follower.catchUp(&transcript)
    self.follower = follower
  }

  /// `context` is the editor's open file or selections, sent ahead of the text as the
  /// extension's chat sends it. Starts the process when there is none.
  func send(_ prompt: String, context: [EditorSelection] = []) {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend, !text.isEmpty else { return }
    transcript.addPrompt(
      text, context: context.isEmpty ? nil : context.map(\.label).joined(separator: ", "))
    let message = ClientMessage.prompt(text, context: context.map(\.promptContext))
    if process == nil {
      pendingPrompt = message
      Task { await spawn() }
    } else {
      write(message)
    }
  }

  /// Starts `claude`, resuming this session if it has a transcript.
  func spawn() async {
    guard process == nil, phase != .starting else { return }
    // A session whose process ended goes on under its own id, never as a fork again.
    if let saved = savedTarget, resuming?.forks == true || resuming == nil { resuming = saved }
    phase = .starting
    await loadHistory()
    if case .failed = phase { return fail(nil) }
    var command = command
    var environment = await Self.environment.value
    guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
      return fail(String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
    }
    if let resuming {
      command.resumeSessionID = resuming.sessionID
      command.forksSession = resuming.forks == true
    }
    // A resume under the account that wrote it; a new session under the one picked in
    // Settings, else left to the shell.
    let chosen = resuming?.account ?? ClaudeChoice.newSessionAccount
    if let chosen { environment = chosen.environment(environment) }
    account =
      chosen ?? ClaudeChoice.account(
        at: environment["CLAUDE_CONFIG_DIR"]
          ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
          .path(percentEncoded: false))
    guard
      let claude = executableOverride
        ?? ClaudeLocator.locate(preferred: ClaudeChoice.executable, path: environment["PATH"])
    else {
      return fail(
        String(localized: "Claude Code was not found. Install it, then open the folder again."))
    }
    executable = claude
    let process = AgentProcess(
      .init(
        executable: claude, arguments: command.arguments, environment: environment,
        currentDirectory: folder))
    do {
      let stream = try process.start()
      self.process = process
      try process.send(.initialize(requestID: nextRequestID("init")))
      if let pendingPrompt {
        try process.send(pendingPrompt)
        self.pendingPrompt = nil
      }
      phase = .ready
      events = Task { [weak self] in
        for await event in stream { self?.handle(event) }
      }
    } catch {
      fail(error.localizedDescription)
    }
  }

  func answer(_ pending: Transcript.PendingPermission, _ decision: PermissionDecision) {
    write(.permission(requestID: pending.requestID, decision))
    transcript.resolvePermission(requestID: pending.requestID)
  }

  func interrupt() {
    guard transcript.isRunning else { return }
    write(.interrupt(requestID: nextRequestID("interrupt")))
  }

  /// Ends the process: input closed so it can finish cleanly, then terminated, because a
  /// window that closed mid-turn must not leave a `claude` working on nobody's behalf.
  func stop() {
    process?.closeInput()
    process?.terminate()
    events?.cancel()
  }

  /// `message` nil keeps the reason already in `phase`.
  private func fail(_ message: String?) {
    if let message { phase = .failed(message) }
    pendingPrompt = nil
    transcript.processExited()
  }

  private func handle(_ event: AgentProcess.Event) {
    switch event {
    case .messages(let messages):
      for message in messages { apply(message) }
    case .stderr(let text):
      diagnostics = String((diagnostics + text).suffix(4000))
    case .exited(let status, _):
      transcript.processExited()
      process = nil
      if case .failed = phase { return }
      phase = .exited(status: status)
      onStopped?()
    }
  }

  private func apply(_ message: StreamMessage) {
    if case .controlResponse(let response) = message, response.requestID.hasPrefix("context-") {
      if response.isSuccess, let reply = ContextUsageReply(response.response) {
        reportedContext = reply
      }
      return
    }
    let waiting = transcript.pendingPermissions.count
    transcript.apply(message)
    if transcript.pendingPermissions.count > waiting, let pending = transcript.pendingPermissions.last {
      onPermissionRequested?(pending)
    }
    if case .result = message {
      if savedTarget == nil { savedTarget = findTarget() }
      // Not `write`: a failed context request must not mark the session failed.
      try? process?.send(.contextUsage(requestID: nextRequestID("context")))
      onTurnEnded?()
    }
  }

  /// The transcript lands under whichever account the shell selected; look for it in each.
  /// It exists from the first prompt on, which is when `system/init` gave the id.
  private func findTarget() -> ResumeTarget? {
    guard let id = sessionID else { return nil }
    for account in ClaudeAccount.discover() {
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
          sessionID: id, cwd: transcript.session?.cwd ?? folder.path(percentEncoded: false),
          file: file.path(percentEncoded: false),
          accountDirectory: account.directory.path(percentEncoded: false),
          accountIsDefault: account.isDefault)
      }
    }
    return nil
  }

  private func write(_ message: ClientMessage) {
    do {
      try process?.send(message)
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private func nextRequestID(_ prefix: String) -> String {
    requestCount += 1
    return "\(prefix)-\(requestCount)"
  }

  /// The login shell's environment, read once per launch and shared by every window: a
  /// terminal `claude` sees the user's PATH, and so must this one and the tools it runs.
  /// Without it, launchd's PATH plus the usual install directories.
  static let environment = Task<[String: String], Never> {
    if let environment = await ShellEnvironment.read() { return environment }
    var environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    environment["PATH"] = [
      "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "",
    ].joined(separator: ":")
    return environment
  }
}
```

`ContentView` still calls `start(command:)`, so the app stops compiling here. Make it compile
with the smallest change: in `ContentView.start(_:command:)`, replace
`Task { await session.start(command: command) }` with:

```swift
    session.command = command
    Task { await session.spawn() }
```

Task 8 replaces that code.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/ClaudeSessionTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar/Services/ClaudeSession.swift apps/apple/Drakar/ContentView.swift apps/apple/DrakarTests/ClaudeSessionTests.swift
git commit -m "feat(apple): a session shows its history at once and starts claude on its first prompt"
```

Stage `ContentView.swift` with `git add -p` and take only the `start` hunk: the keep-on-top
change in the same file is the person's uncommitted work and stays out of this commit.

---

### Task 7: The project a window holds

**Files:**
- Modify: `apps/apple/Drakar/Services/SessionRoute.swift` (whole file; keep its name)
- Create: `apps/apple/Drakar/Services/Project.swift`
- Test: `apps/apple/DrakarTests/ProjectTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession` (Task 6), `ProjectPath` (Task 3).
- Produces: `WindowRoute` (`.project(folder:)`, `.picker(token:)`, `static func project(_ url: URL)`,
  `static func picker()`, `var folder: URL?`); `ResumeTarget.init?(_ summary: SessionSummary, forking: Bool = false)`;
  `ProjectSession` (`id`, `session`, `draft`, `isUnread`, `scrollAnchor`, `sessionID`,
  `displayTitle`, `waitingFor: String?`, `hasStopped`);
  `Project` (`folder`, `workspace`, `sessions`, `selectedID`, `selected`,
  `init(folder:restoring:)`, `newSession()`, `attach(_:readOnly:)`, `fork(_:)`, `select(_:)`,
  `end(_:)`, `remove(_:)`, `stopAll()`, `stored`, `session(withID:)`, `runningCount`);
  `StoredProject { sessions: [ResumeTarget], selected: String? }`;
  `OpenSessions.shared` (`register(_:window:)`, `unregister(window:)`, `folders`,
  `projects`, `locate(_ sessionID:) -> (Project, ProjectSession)?`, `ownerFolder(forCwd:)`,
  `requestAttach(_:in:)`, `takePending(for:)`, `transcriptWritten(_:)`, `liveChanged(_:)`,
  `runningCount`).

- [ ] **Step 1: Write the failing hosted tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A project window's sessions")
struct ProjectTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-project-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func target(_ id: String, cwd: String? = nil) -> ResumeTarget {
    ResumeTarget(
      sessionID: id, cwd: cwd ?? folder.path(percentEncoded: false),
      file: folder.appending(path: "\(id).jsonl").path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
  }

  @Test func attachingPutsTheSessionOnTopAndSelectsIt() {
    let project = Project(folder: folder)
    let first = project.attach(target("a"))
    let second = project.attach(target("b"))
    #expect(project.sessions.map(\.id) == [second.id, first.id])
    #expect(project.selectedID == second.id)
  }

  /// One writer per transcript: attaching what is already here selects it.
  @Test func attachingTwiceSelectsTheOneAlreadyHere() {
    let project = Project(folder: folder)
    let first = project.attach(target("a"))
    _ = project.attach(target("b"))
    let again = project.attach(target("a"))
    #expect(again.id == first.id)
    #expect(project.sessions.count == 2)
    #expect(project.selectedID == first.id)
  }

  @Test func theAttachedListSurvivesARelaunch() throws {
    let project = Project(folder: folder)
    _ = project.attach(target("a"))
    _ = project.attach(target("b"))
    _ = project.newSession()  // no id yet: not restorable, and not stored
    project.select(project.sessions[1])  // b
    let stored = try JSONDecoder().decode(
      StoredProject.self, from: JSONEncoder().encode(project.stored))
    let restored = Project(folder: folder, restoring: stored)
    #expect(restored.sessions.map(\.sessionID) == ["b", "a"])
    #expect(restored.selected?.sessionID == "b")
    #expect(restored.sessions.allSatisfy { !$0.session.isProcessRunning })
  }

  @Test func aForkIsANewRowBesideTheOriginal() {
    let project = Project(folder: folder)
    let original = project.attach(target("a"), readOnly: true)
    let fork = project.fork(original)
    #expect(project.sessions.count == 2)
    #expect(fork.session.resuming?.forks == true)
    #expect(!fork.session.isReadOnly)
    #expect(original.session.isReadOnly)
  }

  @Test func theWindowIndexFindsASessionAndItsOwner() {
    let project = Project(folder: folder)
    let attached = project.attach(target("a"))
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    #expect(OpenSessions.shared.locate("a")?.1.id == attached.id)
    let sub = folder.appending(path: "sub").path(percentEncoded: false)
    #expect(OpenSessions.shared.ownerFolder(forCwd: sub) == ProjectPath.normalize(folder.path(percentEncoded: false)))
    #expect(OpenSessions.shared.ownerFolder(forCwd: "/elsewhere/x") == "/elsewhere/x")
  }

  @Test func pendingAttachmentsWaitForTheirWindow() {
    let path = ProjectPath.normalize(folder.path(percentEncoded: false))
    OpenSessions.shared.requestAttach(target("a"), in: path)
    #expect(OpenSessions.shared.takePending(for: path).map(\.sessionID) == ["a"])
    #expect(OpenSessions.shared.takePending(for: path).isEmpty)
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/ProjectTests`
Expected: FAIL to compile, `cannot find 'Project' in scope`.

- [ ] **Step 3: Rewrite `SessionRoute.swift`**

```swift
import DrakarKit
import Foundation
import Observation

/// What a window shows: a project, or the session picker until one is chosen.
///
/// A window's value, so SwiftUI restores it at launch and `openWindow(value:)` brings
/// forward the window already showing a project instead of opening a second: two windows
/// on one folder would be two editors, and could be two writers on one transcript.
enum WindowRoute: Codable, Hashable {
  case project(folder: String)
  /// `token` keeps two picker windows apart.
  case picker(token: UUID)

  static func project(_ url: URL) -> WindowRoute {
    .project(folder: ProjectPath.normalize(url.path(percentEncoded: false)))
  }

  static func picker() -> WindowRoute { .picker(token: UUID()) }

  var folder: URL? {
    if case .project(let folder) = self { return URL(filePath: folder, directoryHint: .isDirectory) }
    return nil
  }
}

struct ResumeTarget: Codable, Hashable {
  var sessionID: String
  var cwd: String
  var file: String
  var accountDirectory: String
  var accountIsDefault: Bool
  /// Continue a copy under a new id: the session is open in another process. Optional so
  /// that a target stored before the field existed still decodes.
  var forks: Bool?

  init(
    sessionID: String, cwd: String, file: String, accountDirectory: String,
    accountIsDefault: Bool, forks: Bool? = nil
  ) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.file = file
    self.accountDirectory = accountDirectory
    self.accountIsDefault = accountIsDefault
    self.forks = forks
  }

  init?(_ summary: SessionSummary, forking: Bool = false) {
    guard let cwd = summary.cwd else { return nil }
    self.init(
      sessionID: summary.sessionID, cwd: cwd, file: summary.file.path(percentEncoded: false),
      accountDirectory: summary.account.directory.path(percentEncoded: false),
      accountIsDefault: summary.account.isDefault, forks: forking ? true : nil)
  }

  var account: ClaudeAccount {
    ClaudeAccount(
      directory: URL(filePath: accountDirectory, directoryHint: .isDirectory),
      isDefault: accountIsDefault)
  }

  var transcriptFile: URL { URL(filePath: file) }
}

/// Every project window Drakar has open, and through them every session it holds: so a
/// window knows a session is open in another, the global list knows where to send a pick,
/// and the bridge knows which folders to claim.
@Observable
final class OpenSessions {
  static let shared = OpenSessions()

  private(set) var projects: [UUID: Project] = [:]
  /// Sessions picked before their project's window existed, by folder.
  @ObservationIgnored private var pending: [String: [ResumeTarget]] = [:]

  func register(_ project: Project, window: UUID) {
    projects[window] = project
    IDEBridge.shared.refreshFolders()
  }

  func unregister(window: UUID) {
    projects[window] = nil
    IDEBridge.shared.refreshFolders()
  }

  /// The open projects' folders, which Drakar is the editor for by default. As the lock
  /// file lists them: no trailing slash.
  var folders: [String] {
    projects.values.map { ProjectPath.normalize($0.folder.path(percentEncoded: false)) }
  }

  func locate(_ sessionID: String) -> (Project, ProjectSession)? {
    for project in projects.values {
      if let session = project.session(withID: sessionID) { return (project, session) }
    }
    return nil
  }

  /// The open project that would own `cwd`, or `cwd` itself for a new window.
  func ownerFolder(forCwd cwd: String) -> String {
    ProjectPath.owner(of: cwd, among: folders) ?? ProjectPath.normalize(cwd)
  }

  func requestAttach(_ target: ResumeTarget, in folder: String) {
    pending[ProjectPath.normalize(folder), default: []].append(target)
  }

  func takePending(for folder: String) -> [ResumeTarget] {
    pending.removeValue(forKey: ProjectPath.normalize(folder)) ?? []
  }

  /// A transcript changed on disk: a read-only session following it catches up.
  func transcriptWritten(_ sessionID: String) {
    locate(sessionID)?.1.session.catchUp()
  }

  /// The ids live in other processes now. A read-only session whose process went away can
  /// be resumed where it is.
  func liveChanged(_ live: Set<String>) {
    for project in projects.values {
      for item in project.sessions where item.session.isReadOnly {
        guard let id = item.sessionID, !live.contains(id) else { continue }
        item.session.catchUp()
        item.session.isReadOnly = false
      }
    }
  }

  /// Sessions mid-turn across every window, for the quit question.
  var runningCount: Int { projects.values.reduce(0) { $0 + $1.runningCount } }

  // MARK: - Until Task 8: the one-session windows still use these

  private(set) var routes: [String: SessionRoute] = [:]
  private(set) var windowFolders: [UUID: String] = [:]

  func register(_ route: SessionRoute, for sessionID: String) { routes[sessionID] = route }

  func unregister(_ sessionID: String) { routes[sessionID] = nil }

  func setFolder(_ folder: URL?, forWindow window: UUID) {
    windowFolders[window] = folder.map { ProjectPath.normalize($0.path(percentEncoded: false)) }
    IDEBridge.shared.refreshFolders()
  }
}

/// Until Task 8: the window value of a one-session window.
enum SessionRoute: Codable, Hashable {
  case new(folder: String, token: UUID)
  case resume(ResumeTarget)

  static func new(folder: URL) -> SessionRoute {
    .new(folder: folder.path(percentEncoded: false), token: UUID())
  }

  static func resume(_ summary: SessionSummary, forking: Bool = false) -> SessionRoute? {
    ResumeTarget(summary, forking: forking).map(SessionRoute.resume)
  }

  var folder: URL {
    switch self {
    case .new(let folder, _): URL(filePath: folder, directoryHint: .isDirectory)
    case .resume(let target): URL(filePath: target.cwd, directoryHint: .isDirectory)
    }
  }

  var sessionID: String? {
    if case .resume(let target) = self { return target.sessionID }
    return nil
  }
}
```

While both kinds of window exist, `folders` must cover both: replace its body with
`Array(Set(projects.values.map { ProjectPath.normalize($0.folder.path(percentEncoded: false)) } + windowFolders.values))`.

- [ ] **Step 4: Write `Project.swift`**

```swift
import DrakarKit
import Foundation
import Observation

/// One session as a project window holds it: the session, and what the window keeps for it
/// while another is shown.
@Observable
final class ProjectSession: Identifiable {
  let id = UUID()
  let session: ClaudeSession
  /// The composer's text, kept across switches.
  var draft = ""
  /// A turn ended, or the process stopped, while another session was shown.
  var isUnread = false
  /// The entry at the top of the transcript when it was last shown; nil while it followed
  /// the bottom.
  var scrollAnchor: String?

  init(session: ClaudeSession) {
    self.session = session
  }

  var sessionID: String? { session.sessionID }

  var displayTitle: String {
    if let title = session.title { return title }
    for entry in session.transcript.entries {
      if case .prompt(let text) = entry.kind { return String(text.prefix(80)) }
    }
    return String(localized: "New session")
  }

  /// What the first waiting permission request wants: "Bash: make test".
  var waitingFor: String? {
    guard let pending = session.transcript.pendingPermissions.first else { return nil }
    let name = pending.request.displayName ?? pending.request.toolName
    let summary = pending.request.summary
    return summary.isEmpty ? name : "\(name): \(summary)"
  }

  var hasStopped: Bool {
    switch session.phase {
    case .failed: true
    case .exited(let status): status != 0
    case .idle, .starting, .ready: false
    }
  }
}

/// What a project window keeps between launches: the sessions it held, and the one shown.
struct StoredProject: Codable, Equatable {
  var sessions: [ResumeTarget] = []
  var selected: String?
}

/// A project window: a folder, its editor, and the sessions attached to it.
@Observable
final class Project {
  let folder: URL
  let workspace: Workspace
  private(set) var sessions: [ProjectSession] = []
  var selectedID: ProjectSession.ID?

  init(folder: URL, restoring stored: StoredProject? = nil) {
    self.folder = folder
    workspace = Workspace(folder: folder)
    for target in stored?.sessions ?? [] {
      sessions.append(make(ClaudeSession(folder: URL(filePath: target.cwd), resuming: target)))
    }
    selectedID =
      sessions.first { $0.sessionID == stored?.selected }?.id ?? sessions.first?.id
    if let selected { load(selected) }
  }

  var selected: ProjectSession? { sessions.first { $0.id == selectedID } }

  func session(withID sessionID: String) -> ProjectSession? {
    sessions.first { $0.sessionID == sessionID }
  }

  /// A new session in the project's folder, on top and shown. No process until it is
  /// prompted.
  @discardableResult func newSession() -> ProjectSession {
    let item = make(ClaudeSession(folder: folder))
    sessions.insert(item, at: 0)
    select(item)
    return item
  }

  /// `target` on top and shown, or the row already holding it. `readOnly` while another
  /// process has it open.
  @discardableResult func attach(_ target: ResumeTarget, readOnly: Bool = false) -> ProjectSession {
    if target.forks != true, let existing = session(withID: target.sessionID) {
      select(existing)
      return existing
    }
    let session = ClaudeSession(folder: URL(filePath: target.cwd, directoryHint: .isDirectory), resuming: target)
    session.isReadOnly = readOnly
    let item = make(session)
    sessions.insert(item, at: 0)
    select(item)
    return item
  }

  /// A copy of a session open elsewhere, continued under a new id beside it.
  @discardableResult func fork(_ item: ProjectSession) -> ProjectSession {
    guard var target = item.session.resuming ?? item.session.savedTarget else { return item }
    target.forks = true
    return attach(target)
  }

  func select(_ item: ProjectSession) {
    selectedID = item.id
    item.isUnread = false
    load(item)
  }

  /// Stops the process; the row stays, and its next prompt resumes it.
  func end(_ item: ProjectSession) {
    item.session.stop()
  }

  func remove(_ item: ProjectSession) {
    item.session.stop()
    sessions.removeAll { $0.id == item.id }
    if selectedID == item.id { selectedID = sessions.first?.id }
    if let selected { load(selected) }
  }

  func stopAll() {
    for item in sessions { item.session.stop() }
  }

  /// Sessions mid-turn: what closing the window would interrupt.
  var runningCount: Int { sessions.count { $0.session.transcript.isRunning } }

  var stored: StoredProject {
    StoredProject(
      sessions: sessions.compactMap(\.session.savedTarget),
      selected: selected?.session.savedTarget?.sessionID)
  }

  private func make(_ session: ClaudeSession) -> ProjectSession {
    let item = ProjectSession(session: session)
    session.onTurnEnded = { [weak self, weak item] in
      guard let self, let item, item.id != self.selectedID else { return }
      item.isUnread = true
    }
    session.onStopped = { [weak self, weak item] in
      guard let self, let item, item.id != self.selectedID, item.hasStopped else { return }
      item.isUnread = true
    }
    return item
  }

  private func load(_ item: ProjectSession) {
    Task { await item.session.loadHistory() }
  }
}
```

- [ ] **Step 5: Build the app**

Run: `make -C apps/apple build`
Expected: success. Nothing uses `Project` yet; the one-session windows run on the legacy
members kept at the bottom of `SessionRoute.swift`.

- [ ] **Step 6: Run the tests**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/ProjectTests`
Expected: PASS, 6 tests.

- [ ] **Step 7: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar/Services/SessionRoute.swift apps/apple/Drakar/Services/Project.swift apps/apple/DrakarTests/ProjectTests.swift
git commit -m "feat(apple): a window holds a project, and the project holds its sessions"
```

---

### Task 8: The project window

**Files:**
- Modify: `apps/apple/Drakar/ContentView.swift` (body, route handling, debug launch; keep
  `WindowLevel`, `WindowReader`, `shortened`, `abbreviated` and the keep-on-top toolbar)
- Create: `apps/apple/Drakar/Views/ProjectSidebar.swift`
- Create: `apps/apple/Drakar/Views/VerticalSplit.swift`
- Modify: `apps/apple/Drakar/Views/SessionView.swift` (takes a `ProjectSession`, read-only banner)
- Modify: `apps/apple/Drakar/Views/ComposerView.swift` (`text` becomes a binding)
- Modify: `apps/apple/Drakar/Views/TranscriptView.swift` (scroll anchor)
- Modify: `apps/apple/Drakar/Views/SessionsView.swift` (picks hand over a target)
- Modify: `apps/apple/Drakar/DrakarApp.swift` (window group, Session menu)
- Modify: `apps/apple/Drakar/Services/SessionRoute.swift` (delete the legacy members)

**Interfaces:**
- Consumes: `Project`, `ProjectSession`, `WindowRoute`, `OpenSessions` (Task 7).
- Produces: `ProjectSidebar(project:)`; `SessionListView(project:)` with a "This window"
  section (Task 9 adds the other two); `SessionRow(item:isSelected:)`;
  `FocusedValues.project`; `SessionView(item:project:)`.

- [ ] **Step 1: `VerticalSplit.swift`**

```swift
import SwiftUI

/// Two panes stacked with a divider to drag between them: the sidebar's sessions over its
/// files. `SplitPanes` turned on its side, for the same reason it is not `HSplitView`.
struct VerticalSplit<Top: View, Bottom: View>: View {
  /// The top pane's share of the height.
  @Binding var fraction: Double
  var minimum: CGFloat = 90
  @ViewBuilder let top: Top
  @ViewBuilder let bottom: Bottom

  @State private var dragStart: Double?

  var body: some View {
    GeometryReader { geometry in
      let total = max(geometry.size.height - 1, 1)
      VStack(spacing: 0) {
        top.frame(height: height(total))
        Divider()
          .overlay {
            Color.clear
              .frame(height: 9)
              .contentShape(Rectangle())
              .pointerStyle(.rowResize)
              .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                  .onChanged { drag in
                    let start = dragStart ?? Double(height(total) / total)
                    dragStart = start
                    fraction = Double(
                      clamp(CGFloat(start) * total + drag.translation.height, total) / total)
                  }
                  .onEnded { _ in dragStart = nil })
          }
        bottom.frame(maxHeight: .infinity)
      }
    }
  }

  private func height(_ total: CGFloat) -> CGFloat { clamp(total * CGFloat(fraction), total) }

  private func clamp(_ height: CGFloat, _ total: CGFloat) -> CGFloat {
    max(min(height, total - minimum), min(minimum, total / 2))
  }
}
```

- [ ] **Step 2: `ProjectSidebar.swift`**

```swift
import AppKit
import DrakarKit
import SwiftUI

/// The project's sessions over its files, the split kept per window.
struct ProjectSidebar: View {
  let project: Project
  @SceneStorage("drakar.sessionsFraction") private var fraction = 0.38

  var body: some View {
    VerticalSplit(fraction: $fraction) {
      SessionListView(project: project)
    } bottom: {
      FileTreeView(workspace: project.workspace)
    }
  }
}

/// The sessions this window holds. Rows keep their order whatever their state does, so a
/// row never moves under the pointer.
struct SessionListView: View {
  let project: Project

  var body: some View {
    List(selection: selection) {
      Section {
        ForEach(project.sessions) { item in
          SessionRow(item: item, isSelected: item.id == project.selectedID)
            .tag(item.id)
            .contextMenu { menu(for: item) }
            .accessibilityIdentifier("sessions.attached.\(item.sessionID ?? "new")")
        }
      } header: {
        HStack {
          Text("This Window")
          Spacer()
          Button("New Session", systemImage: "plus") { project.newSession() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("New session (⌘N)")
            .accessibilityIdentifier("sessions.new")
        }
      }
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier("sessions")
  }

  private var selection: Binding<ProjectSession.ID?> {
    Binding(
      get: { project.selectedID },
      set: { id in if let item = project.sessions.first(where: { $0.id == id }) { project.select(item) } })
  }

  @ViewBuilder private func menu(for item: ProjectSession) -> some View {
    if item.session.isProcessRunning {
      Button("End Session") { confirmIfRunning(item) { project.end(item) } }
    }
    Button("Remove from Window") { confirmIfRunning(item) { project.remove(item) } }
    if let file = item.session.savedTarget?.transcriptFile {
      Divider()
      Button("Show Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
  }

  /// Mid-turn, stopping loses the turn: ask first.
  private func confirmIfRunning(_ item: ProjectSession, then action: @escaping () -> Void) {
    guard item.session.transcript.isRunning else { return action() }
    let alert = NSAlert()
    alert.messageText = String(localized: "“\(item.displayTitle)” is still working.")
    alert.informativeText = String(localized: "Stopping it now ends the turn part-way.")
    alert.addButton(withTitle: String(localized: "Stop"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    if alert.runModal() == .alertFirstButtonReturn { action() }
  }
}

/// One attached session: what it is doing, and its title.
struct SessionRow: View {
  let item: ProjectSession
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Circle()
        .fill(state.tint)
        .frame(width: 7, height: 7)
        .help(state.label)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(item.displayTitle)
            .lineLimit(1)
            .fontWeight(item.isUnread ? .semibold : .regular)
          if item.isUnread {
            Circle().fill(.blue).frame(width: 5, height: 5).accessibilityLabel("Unread")
          }
        }
        if let detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var state: RowState {
    let session = item.session
    if item.waitingFor != nil { return .waiting }
    if session.transcript.isRunning { return .working }
    if item.hasStopped { return .stopped }
    if session.isReadOnly { return .elsewhere }
    return session.isProcessRunning ? .idle : .notStarted
  }

  private var detail: String? {
    if let waiting = item.waitingFor { return waiting }
    if case .failed(let reason) = item.session.phase { return reason }
    return worktreeName
  }

  /// The worktree's folder name, for a session running below the project root.
  private var worktreeName: String? {
    let path = item.session.folder.path(percentEncoded: false)
    guard let range = path.range(of: "/.claude/worktrees/") else { return nil }
    return String(path[range.upperBound...].prefix { $0 != "/" })
  }
}

/// A row's state, in Claude Code's words and Armada's colours.
enum RowState {
  case working, runningTool, waiting, idle, notStarted, stopped, elsewhere

  var label: String {
    switch self {
    case .working: String(localized: "Working")
    case .runningTool: String(localized: "Probably running a tool")
    case .waiting: String(localized: "Waiting for you")
    case .idle: String(localized: "Idle")
    case .notStarted: String(localized: "Not started")
    case .stopped: String(localized: "Stopped")
    case .elsewhere: String(localized: "Open elsewhere")
    }
  }

  var tint: Color {
    switch self {
    case .working: .green
    case .runningTool: .orange
    case .waiting: .blue
    case .stopped: .red
    case .idle, .notStarted, .elsewhere: .secondary
    }
  }
}
```

- [ ] **Step 3: Bind the composer's text and keep the transcript's place**

`ComposerView`: replace `@State private var text = ""` with `@Binding var text: String`,
and add `text` as the first stored property so callers pass `text: $item.draft`.

`TranscriptView`: add the binding and the anchor handling.

```swift
  let transcript: Transcript
  /// The entry at the top when this session was last shown; nil while following.
  @Binding var anchor: String?
```

Add `.scrollTargetLayout()` as the first modifier of the `LazyVStack`, so the scroll view
knows its rows by their entry ids. After `.scrollPosition($position)`:

```swift
    .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.6) { visible in
      if !isFollowing { anchor = visible.first }
    }
    .onChange(of: isFollowing) { _, following in if following { anchor = nil } }
    .onAppear {
      guard let anchor else { return }
      isFollowing = false
      position.scrollTo(id: anchor, anchor: .top)
    }
```

- [ ] **Step 4: `SessionView` takes a project session**

Replace the struct's head and body (keep `ProblemBanner` and `SessionFooter`):

```swift
/// The transcript, what stopped it if anything did, the composer and the footer.
struct SessionView: View {
  @Bindable var item: ProjectSession
  let project: Project

  private var session: ClaudeSession { item.session }
  private var workspace: Workspace { project.workspace }

  var body: some View {
    VStack(spacing: 0) {
      TranscriptView(transcript: session.transcript, anchor: $item.scrollAnchor)
      if let problem {
        ProblemBanner(message: problem, diagnostics: session.diagnostics)
      }
      Divider()
      if session.isReadOnly {
        ReadOnlyBanner(host: host) { project.fork(item) }
      } else {
        ComposerView(
          text: $item.draft, canSend: session.canSend, isRunning: session.transcript.isRunning,
          context: workspace.selection, pinned: workspace.pinned,
          unpin: { selection in workspace.pinned.removeAll { $0 == selection } },
          send: { text, context in
            session.send(text, context: context)
            workspace.pinned = []
          },
          stop: session.interrupt)
      }
      SessionFooter(session: session)
    }
    .sheet(item: pendingPermission) { pending in
      PermissionSheet(pending: pending) { decision in session.answer(pending, decision) }
    }
    .environment(\.sessionFolder, session.folder)
    .environment(\.openInEditor, OpenInEditorAction(workspace: workspace))
  }

  /// Where the session is open, from the registry, for the banner.
  private var host: String {
    // Task 9 replaces this with the monitor's answer.
    String(localized: "another app")
  }
```

Keep `pendingPermission` and `problem` as they are. In `problem`, `.exited` with status 0
now means "ended, and the next prompt resumes it", so return nil for it:

```swift
    case .exited(let status) where status != 0:
      String(localized: "Claude Code exited with status \(status).")
    case .idle, .starting, .ready, .exited: nil
```

Add below `ProblemBanner`:

```swift
/// In place of the composer while another process has the session open: two writers on one
/// transcript would interleave its history.
private struct ReadOnlyBanner: View {
  let host: String
  let fork: () -> Void

  var body: some View {
    HStack {
      Label("Live in \(host). Its transcript follows here.", systemImage: "eye")
        .foregroundStyle(.secondary)
      Spacer()
      Button("Fork a Copy", action: fork)
        .help("Continue a copy under a new id, leaving the original where it is.")
        .accessibilityIdentifier("session.fork")
    }
    .padding(12)
  }
}
```

In `SessionFooter.status`, `.idle` now means "not started": change its case to

```swift
    case .idle:
      Label("Not started", systemImage: "circle.dotted")
    case .starting:
      Label("Starting…", systemImage: "circle.dotted")
```

- [ ] **Step 5: Rewrite `ContentView`'s window logic**

Replace everything above `WindowLevel` with:

```swift
import AppKit
import DrakarKit
import SwiftUI

/// A window: the session picker until a project is chosen, then the project's sessions
/// over its files in the sidebar, the editor, and the selected session.
struct ContentView: View {
  @Binding var route: WindowRoute?
  @State private var project: Project?
  /// Names this window to `OpenSessions`.
  @State private var windowID = UUID()
  @Environment(\.appearsActive) private var appearsActive
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  /// The editor's share of the window beside the session, kept per window.
  @SceneStorage("drakar.editorFraction") private var editorFraction = 0.5
  /// Whether this window floats above other apps' windows, kept per window.
  @SceneStorage("drakar.keepsOnTop") private var keepsOnTop = false
  /// The attached sessions and the one shown, as JSON (`StoredProject`).
  @SceneStorage("drakar.project") private var storedProject = ""

  var body: some View {
    Group {
      if let project {
        let workspace = project.workspace
        NavigationSplitView {
          ProjectSidebar(project: project)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
          SplitPanes(fraction: $editorFraction, showsLeading: !workspace.documents.isEmpty) {
            EditorView(workspace: workspace)
          } trailing: {
            if let item = project.selected {
              SessionView(item: item, project: project).id(item.id)
            } else {
              ContentUnavailableView {
                Label("No session", systemImage: "bubble.left.and.text.bubble.right")
              } actions: {
                Button("New Session") { project.newSession() }
              }
            }
          }
        }
        .background(
          WindowReader { window in
            workspace.window = window
            WindowCloseGuard.install(on: window, for: workspace)
          }
        )
        .onChange(of: workspace.unsavedDocuments.isEmpty, initial: true) { _, clean in
          workspace.window?.isDocumentEdited = !clean
        }
        .focusedSceneValue(\.workspace, workspace)
        .focusedSceneValue(\.project, project)
        .sheet(isPresented: quickOpenShown(workspace)) { QuickOpenView(workspace: workspace) }
        .sheet(isPresented: searchShown(workspace)) { ProjectSearchView(workspace: workspace) }
        .onChange(of: appearsActive, initial: true) { _, active in
          if active { workspace.becameActive() }
        }
        .onChange(of: project.stored, initial: true) { _, stored in
          storedProject = (try? String(decoding: JSONEncoder().encode(stored), as: UTF8.self)) ?? ""
        }
      } else {
        SessionsView(pick: pick, openFolder: { folder in
          show(.project(folder), attaching: [])
        })
      }
    }
    .frame(minWidth: 680, minHeight: 440)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Toggle(isOn: $keepsOnTop) {
          Label("Keep on Top", systemImage: keepsOnTop ? "pin.fill" : "pin")
        }
        .toggleStyle(.button)
        .help(keepsOnTop ? "Stop keeping this window on top" : "Keep this window on top")
        .accessibilityIdentifier("window.keepOnTop")
      }
    }
    .background(WindowLevel(floats: keepsOnTop))
    .navigationTitle(windowTitle)
    .navigationSubtitle(project?.selected?.displayTitle ?? "")
    .onChange(of: route, initial: true) { open(route) }
    .onDisappear {
      project?.stopAll()
      OpenSessions.shared.unregister(window: windowID)
    }
    .task { openFromLaunchArguments() }
  }

  private var windowTitle: String {
    project.map { Self.shortened($0.folder) } ?? "Drakar"
  }

  private func quickOpenShown(_ workspace: Workspace) -> Binding<Bool> {
    Binding(get: { workspace.isQuickOpenShown }, set: { workspace.isQuickOpenShown = $0 })
  }

  private func searchShown(_ workspace: Workspace) -> Binding<Bool> {
    Binding(get: { workspace.isSearchShown }, set: { workspace.isSearchShown = $0 })
  }

  /// The project for `route`, restored from scene storage the first time.
  private func open(_ route: WindowRoute?) {
    guard let folder = route?.folder else { return }
    if project?.folder.standardizedFileURL != folder.standardizedFileURL {
      let stored = try? JSONDecoder().decode(StoredProject.self, from: Data(storedProject.utf8))
      let project = Project(folder: folder, restoring: stored)
      self.project = project
      OpenSessions.shared.register(project, window: windowID)
    }
    guard let project else { return }
    for target in OpenSessions.shared.takePending(for: folder.path(percentEncoded: false)) {
      project.attach(target)
    }
    if project.sessions.isEmpty { project.newSession() }
  }

  /// A session picked in this picker window: shown where it already is, or in the project
  /// window that owns its folder, this one becoming it when none is open.
  private func pick(_ summary: SessionSummary, forking: Bool) {
    if !forking, let (owner, item) = OpenSessions.shared.locate(summary.sessionID) {
      owner.select(item)
      owner.workspace.window?.makeKeyAndOrderFront(nil)
      return
    }
    guard let cwd = summary.cwd, let target = ResumeTarget(summary, forking: forking) else { return }
    let folder = OpenSessions.shared.ownerFolder(forCwd: cwd)
    show(.project(folder: folder), attaching: [target])
  }

  /// The project window for `next`: the one already open on that folder, brought forward
  /// with the sessions attached (this picker window closing), or this window becoming it.
  private func show(_ next: WindowRoute, attaching targets: [ResumeTarget]) {
    guard case .project(let folder) = next else { return }
    if let owner = OpenSessions.shared.projects.values.first(where: {
      ProjectPath.normalize($0.folder.path(percentEncoded: false)) == folder
    }) {
      for target in targets { owner.attach(target) }
      owner.workspace.window?.makeKeyAndOrderFront(nil)
      if let current = route { dismissWindow(value: current) }
      return
    }
    for target in targets { OpenSessions.shared.requestAttach(target, in: folder) }
    route = next
  }
```

Keep `shortened` and `abbreviated`. Replace `openFromLaunchArguments` and `send` with:

```swift
  /// `make run ARGS='-drakar.debugFolder <path> -drakar.debugPrompt <text>'` opens a
  /// project with a new session and sends it a first prompt with no clicks.
  /// `-drakar.debugResume <session id>` attaches one from the index instead.
  /// `-drakar.debugModel <id>` picks a cheap model for the new session, and
  /// `-drakar.debugSettingSources project` keeps the user's own permission rules and hooks
  /// out of one that needs a permission prompt to appear. `-drakar.debugOpen <path>`,
  /// `-drakar.debugQuickOpen <query>` and `-drakar.debugSearch <query>` drive the editor.
  /// Values, not flags: UserDefaults reads a value starting with `-` as the next key.
  /// Debug builds only.
  private func openFromLaunchArguments() {
    #if DEBUG
      let defaults = UserDefaults.standard
      guard project == nil, route?.folder == nil else { return }
      let prompt = defaults.string(forKey: "drakar.debugPrompt")
      if let id = defaults.string(forKey: "drakar.debugResume") {
        Task {
          let summaries = await Task.detached {
            SessionIndex.list(accounts: ClaudeAccount.discover())
          }.value
          guard let summary = summaries.first(where: { $0.sessionID == id }) else { return }
          pick(summary, forking: false)
          if let prompt { project?.selected?.session.send(prompt) }
        }
        return
      }
      guard let path = defaults.string(forKey: "drakar.debugFolder") else { return }
      route = .project(URL(filePath: path, directoryHint: .isDirectory))
      open(route)  // now, not on the next update: the rest needs the project
      guard let project, let item = project.selected else { return }
      item.session.command = ClaudeCommand(
        model: defaults.string(forKey: "drakar.debugModel"),
        extraArguments: defaults.string(forKey: "drakar.debugSettingSources").map {
          ["--setting-sources", $0]
        } ?? [])
      let workspace = project.workspace
      if let file = defaults.string(forKey: "drakar.debugOpen") {
        workspace.open(URL(filePath: file, relativeTo: project.folder))
      }
      if let query = defaults.string(forKey: "drakar.debugQuickOpen") {
        workspace.showQuickOpen(query: query)
      }
      if let query = defaults.string(forKey: "drakar.debugSearch") {
        workspace.showSearch(query: query)
      }
      if let prompt {
        item.session.send(prompt, context: workspace.active.map { [$0.selection] } ?? [])
      }
    #endif
  }
}
```

Add the focused value next to the existing `workspace` one (search for
`var workspace: Workspace?` in the `FocusedValues` extension, `Drakar/Services/Workspace.swift`
or `EditorView.swift`):

```swift
  @Entry var project: Project?
```

- [ ] **Step 6: The picker hands over summaries**

In `SessionsView`, replace `let open: (SessionRoute) -> Void` with:

```swift
  /// A session picked: `forking` when it is open in another process.
  let pick: (SessionSummary, Bool) -> Void
  let openFolder: (URL) -> Void
```

Then:
- `.fileImporter`: `if case .success(let folder) = result { openFolder(folder) }`.
- The fork dialog's button: `Button("Fork a Copy") { pick(summary, true) }`.
- `menu(for:)`: "Resume" → `resume(summary)`; drop "Resume in New Window"; "Fork a Copy" →
  `pick(summary, true)` under `summary.live != nil && OpenSessions.shared.locate(summary.sessionID) == nil`;
  "New Session in …" → `openFolder(URL(filePath: cwd, directoryHint: .isDirectory))`.
- `resume(_:)`:

```swift
  private func resume(_ summary: SessionSummary) {
    if OpenSessions.shared.locate(summary.sessionID) != nil || summary.live == nil {
      pick(summary, false)
    } else {
      openElsewhere = summary
    }
  }
```

- `SessionRow`'s `isOpenHere`: `OpenSessions.shared.locate(summary.sessionID) != nil`.
- Remove `@Environment(\.openWindow)`, now unused.

- [ ] **Step 7: The window group and the Session menu**

In `DrakarApp.swift`:

```swift
    WindowGroup(for: WindowRoute.self) { $route in
      ContentView(route: $route)
    }
    .commands {
      SupportCommands(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
      CommandGroup(replacing: .newItem) { NewWindowCommand() }
      CommandMenu("Session") { SessionCommands() }
      CommandGroup(replacing: .saveItem) {
        CloseCommands()
        SaveCommand()
      }
      CommandGroup(after: .textEditing) { MentionCommands() }
      CommandGroup(replacing: .printItem) { QuickOpenCommand() }
    }
```

```swift
/// File > New Window (⇧⌘N): a picker window. ⌘N belongs to New Session.
private struct NewWindowCommand: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("New Window") { openWindow(value: WindowRoute.picker()) }
      .keyboardShortcut("n", modifiers: [.command, .shift])
  }
}

/// The Session menu: what acts on the focused project's sessions.
private struct SessionCommands: View {
  @FocusedValue(\.project) private var project

  var body: some View {
    Button("New Session") { project?.newSession() }
      .keyboardShortcut("n")
      .disabled(project == nil)
  }
}
```

- [ ] **Step 8: Delete the legacy members**

In `SessionRoute.swift`, delete the `SessionRoute` enum and the `// MARK: - Until Task 8`
block of `OpenSessions`, and give `folders` back its Task 7 body
(`projects.values.map { ProjectPath.normalize($0.folder.path(percentEncoded: false)) }`).
`grep -rn 'SessionRoute\|windowFolders\|setFolder' apps/apple/Drakar` must print nothing.

- [ ] **Step 9: Build and run the suites**

Run: `make -C apps/apple test-all`
Expected: PASS (kit and app, including `ProjectTests` and `ClaudeSessionTests`).

- [ ] **Step 10: Check it in the running app**

Run: `make -C apps/apple run ARGS='-drakar.debugFolder /tmp/drakar-probe -drakar.debugModel haiku -drakar.debugPrompt "Reply with the single word: one"'`
(create `/tmp/drakar-probe` first). Expected: one window titled `/tmp/drakar-probe`, a row
"Working" then idle, the reply in the transcript. Then ⌘N, type "Reply with: two", send;
switch back to the first row while the second works: the first shows its transcript and
draft as left, the second's row stays green until its turn ends, then gets the unread dot.
Quit and relaunch with `make -C apps/apple run`: the window comes back with both rows,
neither running ("Not started" in the footer).

- [ ] **Step 11: Commit**

```bash
make -C apps/apple format-swift
git add -p apps/apple/Drakar   # leave the keep-on-top hunks of ContentView to the person
git add apps/apple/Drakar/Views/ProjectSidebar.swift apps/apple/Drakar/Views/VerticalSplit.swift
git commit -m "feat(apple): one window per project, its sessions over its files, switching in place"
```

The keep-on-top toolbar and `WindowLevel` are the person's uncommitted change. They are kept
in the rewritten `ContentView`; stage everything else in that file and ask before
committing those hunks.

---

### Task 9: Sessions elsewhere, ended sessions, and the gauge

**Files:**
- Create: `apps/apple/Drakar/Services/SessionMonitor.swift`
- Create: `apps/apple/Drakar/Views/ContextGaugeView.swift`
- Modify: `apps/apple/Drakar/Views/ProjectSidebar.swift` (two sections, gauges)
- Modify: `apps/apple/Drakar/Views/SessionView.swift` (`host`)
- Modify: `apps/apple/Drakar/Views/SessionsView.swift` (reads the monitor)
- Modify: `apps/apple/Drakar/DrakarApp.swift` (`AppDelegate` starts the monitor)
- Test: `apps/apple/DrakarTests/SessionMonitorTests.swift`

**Interfaces:**
- Consumes: `SessionIndex.list(accounts:limit:under:)`, `SessionIndex.summary(of:account:)`,
  `LiveSession.read`, `ProjectSessions.group`, `ContextGauge.make`, `ContextWindow.accountModelID`
  (Tasks 2–5); `OpenSessions.transcriptWritten`, `liveChanged` (Task 7).
- Produces: `SessionMonitor.shared` (`start() async`, `include(folder:) async`,
  `summaries(under:) -> [SessionSummary]`, `all: [SessionSummary]`, `accountModel(for:) -> String?`,
  `host(of:) -> String`, `isLoaded`); `ContextGaugeView(gauge:)`;
  `ProjectSession.gauge(accountModel:) -> ContextGauge?`.

- [ ] **Step 1: Write the failing hosted test**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Watching sessions on disk")
struct SessionMonitorTests {

  @Test func aTranscriptWrittenAppearsUnderItsProject() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "monitor-\(UUID())")
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    let projects = account.directory.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: account.directory.appending(path: "sessions"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    #expect(monitor.summaries(under: "/w/drakar").isEmpty)

    try Data(#"{"type":"user","cwd":"/w/drakar","message":{"role":"user","content":"go"}}"#.utf8)
      .write(to: projects.appending(path: "s1.jsonl"))
    for _ in 0..<40 where monitor.summaries(under: "/w/drakar").isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(monitor.summaries(under: "/w/drakar").map(\.sessionID) == ["s1"])
    monitor.stop()
  }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/SessionMonitorTests`
Expected: FAIL to compile, `cannot find 'SessionMonitor' in scope`.

- [ ] **Step 3: Write `SessionMonitor.swift`**

```swift
import DrakarKit
import Foundation
import Observation

/// Every session on disk, kept current from FSEvents: what a project window lists as
/// elsewhere and ended, and what the picker lists. One for the app, since every window
/// reads the same folders. Armada's `SessionWatcher`, narrowed to what Drakar shows.
@Observable
final class SessionMonitor {
  static let shared = SessionMonitor()

  /// By transcript path (`SessionSummary.id`): one id can have a transcript per account.
  private(set) var byFile: [String: SessionSummary] = [:]
  private(set) var isLoaded = false

  @ObservationIgnored private var accounts: [ClaudeAccount]
  @ObservationIgnored private var accountModels: [URL: String] = [:]
  @ObservationIgnored private var live: [URL: [String: LiveSession]] = [:]
  @ObservationIgnored private var watchers: [FolderWatcher] = []
  @ObservationIgnored private var sweep: Timer?
  @ObservationIgnored private var included: Set<String> = []

  /// `accounts` for tests; the app discovers them, its shell's `CLAUDE_CONFIG_DIR` included.
  init(accounts: [ClaudeAccount] = []) {
    self.accounts = accounts
  }

  var all: [SessionSummary] { byFile.values.sorted { $0.modified > $1.modified } }

  func summaries(under folder: String) -> [SessionSummary] {
    byFile.values.filter { summary in
      summary.cwd.map { ProjectPath.owner(of: $0, among: [folder]) != nil } ?? false
    }
  }

  func accountModel(for account: ClaudeAccount) -> String? { accountModels[account.directory] }

  /// Where a live session runs, in words.
  func host(of summary: SessionSummary) -> String {
    if OpenSessions.shared.locate(summary.sessionID) != nil {
      return String(localized: "another Drakar window")
    }
    return switch summary.live?.entrypoint {
    case "claude-vscode": String(localized: "VS Code")
    case "cli": String(localized: "a terminal")
    case "claude-desktop": String(localized: "the Claude app")
    default: String(localized: "another app")
    }
  }

  func start() async {
    guard watchers.isEmpty else { return }
    if accounts.isEmpty {
      let extra =
        (await ClaudeSession.environment.value)["CLAUDE_CONFIG_DIR"].map {
          [URL(filePath: $0, directoryHint: .isDirectory)]
        } ?? []
      accounts = ClaudeAccount.discover(extra: extra)
    }
    let accounts = self.accounts
    for account in accounts {
      accountModels[account.directory] = ContextWindow.accountModelID(account)
    }
    let listed = await Task.detached { SessionIndex.list(accounts: accounts, limit: 500) }.value
    merge(listed)
    readRegistries()
    isLoaded = true
    for account in accounts {
      for name in ["sessions", "projects"] {
        let folder = account.directory.appending(path: name, directoryHint: .isDirectory)
        if let watcher = FolderWatcher(folder: folder, onChange: { [weak self] paths in
          self?.changed(paths, in: account)
        }) {
          watchers.append(watcher)
        }
      }
    }
    // A crashed session leaves its registry file behind: its pid is checked every second.
    sweep = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.sweepDead() }
    }
  }

  func stop() {
    for watcher in watchers { watcher.stop() }
    watchers = []
    sweep?.invalidate()
    sweep = nil
  }

  /// A project window's own sessions, past the 500 newest the app reads at launch.
  func include(folder: String) async {
    guard included.insert(folder).inserted else { return }
    let accounts = self.accounts
    let listed = await Task.detached {
      SessionIndex.list(accounts: accounts, limit: 200, under: folder)
    }.value
    merge(listed)
  }

  private func merge(_ summaries: [SessionSummary]) {
    for var summary in summaries {
      summary.live = live[summary.account.directory]?[summary.sessionID]
      byFile[summary.id] = summary
    }
  }

  private func changed(_ paths: [String], in account: ClaudeAccount) {
    var registry = false
    var files: Set<String> = []
    for path in paths {
      let url = URL(filePath: path)
      if url.pathExtension == "json", url.deletingLastPathComponent().lastPathComponent == "sessions" {
        registry = true
      } else if url.pathExtension == "jsonl",
        // `<project>/<id>.jsonl` only: a subagent writes under `<project>/<id>/…`.
        url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "projects"
      {
        files.insert(path)
      }
    }
    if registry { readRegistries() }
    for path in files {
      let file = URL(filePath: path)
      Task {
        guard let summary = await Task.detached({ SessionIndex.summary(of: file, account: account) }).value
        else { return }
        merge([summary])
        OpenSessions.shared.transcriptWritten(summary.sessionID)
      }
    }
  }

  private func readRegistries() {
    for account in accounts {
      live[account.directory] = Dictionary(
        LiveSession.read(account: account).map { ($0.sessionID, $0) },
        uniquingKeysWith: { first, _ in first })
    }
    for (key, summary) in byFile {
      let current = live[summary.account.directory]?[summary.sessionID]
      if summary.live != current { byFile[key]?.live = current }
    }
    OpenSessions.shared.liveChanged(Set(live.values.flatMap(\.keys)))
  }

  private func sweepDead() {
    let dead = live.values.contains { sessions in
      sessions.values.contains { !LiveSession.isAlive($0.pid) }
    }
    if dead { readRegistries() }
  }
}
```

The FSEvents paths come back resolved (`/private/…` for `/tmp`, as `FolderWatcher` says):
the checks above look only at names, never at prefixes, so they hold either way.

- [ ] **Step 4: Start it with the app**

In `AppDelegate.applicationDidFinishLaunching`:

```swift
    Task { await SessionMonitor.shared.start() }
```

- [ ] **Step 5: Run the test**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/SessionMonitorTests`
Expected: PASS.

- [ ] **Step 6: The gauge**

`ContextGaugeView.swift`:

```swift
import DrakarKit
import SwiftUI

/// How full a session's context is: a percentage over a thin bar, amber from 75 % and red
/// from 90 %, with the figures and the window's source in the tooltip.
struct ContextGaugeView: View {
  let gauge: ContextGauge

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(gauge.fraction, format: .percent.precision(.fractionLength(0)))
        .font(.caption2.monospacedDigit())
        .foregroundStyle(gauge.level == .normal ? .secondary : tint)
      Capsule()
        .fill(.quaternary)
        .frame(width: 34, height: 3)
        .overlay(alignment: .leading) {
          Capsule().fill(tint).frame(width: 34 * gauge.fraction, height: 3)
        }
    }
    .help(help)
    .accessibilityElement()
    .accessibilityLabel("Context")
    .accessibilityValue(help)
  }

  private var tint: Color {
    switch gauge.level {
    case .normal: .secondary
    case .high: .orange
    case .critical: .red
    }
  }

  private var help: String {
    let used = gauge.used.formatted(.number.notation(.compactName))
    let limit = gauge.window.limit.formatted(.number.notation(.compactName))
    return String(localized: "\(used) of \(limit). \(gauge.window.source.explanation)")
  }
}
```

Add to `ProjectSession` in `Project.swift`:

```swift
  /// The gauge from what this session knows: its process's report, its own model, the
  /// account's, the newest message's.
  func gauge(accountModel: String?) -> ContextGauge? {
    let transcript = session.transcript
    return ContextGauge.make(
      usage: transcript.contextUsage, reportedLimit: session.reportedContext?.maxTokens,
      initModelID: transcript.session?.model, attachmentModelID: nil,
      accountModelID: accountModel, messageModelID: transcript.contextModelID)
  }
```

A session that has not loaded its history yet has no `contextUsage`: the row shows no gauge
until it is first selected, which loads it (cheap, off the main thread).

- [ ] **Step 7: The sidebar's other two groups**

In `SessionListView` (`ProjectSidebar.swift`), add:

```swift
  @State private var showsAllEnded = false
  private var monitor: SessionMonitor { .shared }
  private var groups: ProjectGroups {
    let folder = ProjectPath.normalize(project.folder.path(percentEncoded: false))
    let others = OpenSessions.shared.folders.filter { $0 != folder }
    let attached = Set(project.sessions.compactMap(\.sessionID))
    let inOtherWindows = Set(
      OpenSessions.shared.projects.values.filter { $0 !== project }
        .flatMap { $0.sessions.compactMap(\.sessionID) })
    return ProjectSessions.group(
      monitor.summaries(under: folder), folder: folder, otherFolders: others,
      attached: attached, inOtherWindows: inOtherWindows)
  }
```

After the "This Window" `Section`, inside the `List`:

```swift
      let groups = groups
      if !groups.elsewhere.isEmpty {
        Section("Elsewhere") {
          ForEach(groups.elsewhere) { summary in
            SummaryRow(summary: summary, host: monitor.host(of: summary), monitor: monitor)
              .contentShape(Rectangle())
              .onTapGesture { openElsewhere(summary) }
              .accessibilityAddTraits(.isButton)
              .accessibilityIdentifier("sessions.elsewhere.\(summary.sessionID)")
          }
        }
      }
      if !groups.ended.isEmpty {
        Section(isExpanded: $showsEnded) {
          ForEach(showsAllEnded ? groups.ended : Array(groups.ended.prefix(20))) { summary in
            SummaryRow(summary: summary, host: nil, monitor: monitor)
              .contentShape(Rectangle())
              .onTapGesture { if let target = ResumeTarget(summary) { project.attach(target) } }
              .accessibilityAddTraits(.isButton)
              .accessibilityIdentifier("sessions.ended.\(summary.sessionID)")
          }
          if groups.ended.count > 20, !showsAllEnded {
            Button("Show All \(groups.ended.count)") { showsAllEnded = true }
              .buttonStyle(.link)
          }
        } header: {
          Text("Ended (\(groups.ended.count))")
        }
      }
```

with `@State private var showsEnded = false`, and on the `List`:

```swift
    .task { await monitor.include(folder: project.folder.path(percentEncoded: false)) }
```

and:

```swift
  private func openElsewhere(_ summary: SessionSummary) {
    if let (owner, item) = OpenSessions.shared.locate(summary.sessionID) {
      owner.select(item)
      owner.workspace.window?.makeKeyAndOrderFront(nil)
    } else if let target = ResumeTarget(summary) {
      project.attach(target, readOnly: true)
    }
  }
```

Give `SessionRow` its gauge, at the end of its `HStack`:

```swift
      Spacer(minLength: 4)
      if let gauge = item.gauge(
        accountModel: item.session.resuming.flatMap { SessionMonitor.shared.accountModel(for: $0.account) })
      {
        ContextGaugeView(gauge: gauge)
      }
```

Add the summary row below `SessionRow`:

```swift
/// A session this window does not hold: live elsewhere, or ended.
struct SummaryRow: View {
  let summary: SessionSummary
  /// Where it is live, or nil for an ended one.
  let host: String?
  let monitor: SessionMonitor

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Circle().fill(state.tint).frame(width: 7, height: 7).help(state.label)
      VStack(alignment: .leading, spacing: 2) {
        Text(summary.displayTitle).lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      if let gauge {
        ContextGaugeView(gauge: gauge)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var state: RowState {
    guard host != nil else { return .idle }
    return switch summary.live?.status {
    case "busy":
      TranscriptTail.read(summary.file)?.isAwaitingToolResult == true ? .runningTool : .working
    case "waiting": .waiting
    default: .idle
    }
  }

  private var detail: String {
    let when = (summary.live?.updatedAt ?? summary.modified)
      .formatted(.relative(presentation: .named))
    var parts = [when]
    if let waiting = summary.live?.waitingFor { parts.insert(waiting, at: 0) }
    if let host { parts.append(host) }
    return parts.joined(separator: " · ")
  }

  private var gauge: ContextGauge? {
    ContextGauge.make(
      usage: summary.context?.usage, reportedLimit: nil, initModelID: nil,
      attachmentModelID: summary.modelID, accountModelID: monitor.accountModel(for: summary.account),
      messageModelID: summary.context?.modelID)
  }
}
```

`TranscriptTail.read` in `state` runs per render of a busy row only, a 64KB read; acceptable
for a handful of rows. If it shows in a profile, move the answer into the monitor's
`changed(_:in:)` and keep it on the summary.

- [ ] **Step 8: The read-only banner names the host**

In `SessionView.host`:

```swift
  private var host: String {
    guard let id = item.sessionID,
      let summary = SessionMonitor.shared.all.first(where: { $0.sessionID == id })
    else { return String(localized: "another app") }
    return SessionMonitor.shared.host(of: summary)
  }
```

- [ ] **Step 9: The picker reads the monitor**

In `SessionsView`: delete `@State private var sessions`, `isLoading` and `load()`; read
`SessionMonitor.shared.all` where `sessions` was used and `!SessionMonitor.shared.isLoaded`
where `isLoading` was. The Refresh button and its ⌘R go: the list now follows the disk.
Remove `.task { await load() }`.

- [ ] **Step 10: Run the suites and check it live**

Run: `make -C apps/apple test-all`
Expected: PASS.

Then `make -C apps/apple run ARGS='-drakar.debugFolder <this repo>'`, and in a terminal in
this repo run `claude`, send it one prompt. Expected: an Elsewhere row "Working" then
"Idle · a terminal" with its gauge; past sessions of this repo under Ended with gauges.
Click the terminal's row: read-only, its transcript follows as the terminal session works,
the banner says "Live in a terminal". Quit the terminal `claude`: within a second the
banner is gone and the composer is back. Click an Ended row: its history appears at once,
footer "Not started".

- [ ] **Step 11: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests/SessionMonitorTests.swift
git commit -m "feat(apple): sessions elsewhere and ended under the window's own, each with its context"
```

---

### Task 10: Attention

**Files:**
- Create: `apps/apple/Drakar/Services/Attention.swift`
- Modify: `apps/apple/Drakar/Services/Project.swift` (`make(_:)` hooks, `nextNeedingAttention()`)
- Modify: `apps/apple/Drakar/DrakarApp.swift` (Session menu item, delegate)
- Modify: `apps/apple/Drakar/Views/SettingsView.swift` (one toggle)
- Test: `apps/apple/DrakarTests/AttentionTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.onPermissionRequested`, `onTurnEnded` (Task 6); `OpenSessions` (Task 7).
- Produces: `Attention.shared` (`refresh()`, `permissionRequested(_:in:)`, `turnEnded(_:in:)`,
  `waitingCount: Int`); `Project.nextNeedingAttention() -> ProjectSession?`;
  `PreferenceKey.notifiesTurnEnds`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What needs the person")
struct AttentionTests {

  private func project() throws -> Project {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return Project(folder: folder)
  }

  /// Unread rows after the selected one, wrapping, the selected one never.
  @Test func nextGoesToUnreadRowsInOrder() throws {
    let project = try project()
    let c = project.newSession()
    let b = project.newSession()
    let a = project.newSession()  // rows: a, b, c; a selected
    c.isUnread = true
    #expect(project.nextNeedingAttention()?.id == c.id)
    b.isUnread = true
    #expect(project.nextNeedingAttention()?.id == b.id)
    project.select(b)
    #expect(project.nextNeedingAttention()?.id == c.id)
    c.isUnread = false
    #expect(project.nextNeedingAttention() == nil)
    _ = a
  }

  @Test func theBadgeCountsNothingWhenNothingWaits() throws {
    let project = try project()
    _ = project.newSession()
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    #expect(Attention.shared.waitingCount == 0)
  }
}
```

Waiting rows (pending permissions) cannot be provoked in a hosted test without a process;
they are checked live in Step 7. `nextNeedingAttention` orders them first by the same code
path, which the review checks.

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/AttentionTests`
Expected: FAIL to compile, `value of type 'Project' has no member 'nextNeedingAttention'`.

- [ ] **Step 3: `nextNeedingAttention` and the hooks**

In `Project`:

```swift
  /// The next row after the selected one that wants the person: waiting on a permission
  /// first, then unread, wrapping. Never the selected row.
  func nextNeedingAttention() -> ProjectSession? {
    let start = sessions.firstIndex { $0.id == selectedID } ?? -1
    let ordered = sessions[(start + 1)...] + sessions[..<max(start, 0)]
    return ordered.first { $0.waitingFor != nil } ?? ordered.first { $0.isUnread }
  }
```

In `Project.make(_:)`, extend the two closures and add the permission one:

```swift
    session.onTurnEnded = { [weak self, weak item] in
      guard let self, let item else { return }
      if item.id != self.selectedID { item.isUnread = true }
      Attention.shared.turnEnded(item, in: self)
    }
    session.onPermissionRequested = { [weak self, weak item] _ in
      guard let self, let item else { return }
      Attention.shared.permissionRequested(item, in: self)
    }
```

and in `select(_:)`, after `item.isUnread = false`: `Attention.shared.refresh()`.

In `ClaudeSession.answer(_:_:)`, after `resolvePermission`, the badge must drop: add an
`@ObservationIgnored var onPermissionAnswered: (() -> Void)?` called there, and in
`Project.make(_:)`: `session.onPermissionAnswered = { Attention.shared.refresh() }`.

- [ ] **Step 4: `Attention.swift`**

```swift
import AppKit
import DrakarKit
import UserNotifications

/// What wants the person while they look elsewhere: the Dock badge for permission requests
/// waiting in any window, and a local notification when Drakar is not the active app. Only
/// Drakar's own sessions: Armada notifies for every session on the Mac already.
final class Attention: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Attention()

  private var askedForPermission = false

  var waitingCount: Int {
    OpenSessions.shared.projects.values.reduce(0) { total, project in
      total + project.sessions.reduce(0) { $0 + $1.session.transcript.pendingPermissions.count }
    }
  }

  func refresh() {
    let count = waitingCount
    NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
  }

  func permissionRequested(_ item: ProjectSession, in project: Project) {
    refresh()
    guard !NSApp.isActive, let wants = item.waitingFor else { return }
    post(title: item.displayTitle, body: String(localized: "Wants to use \(wants)"), item: item)
  }

  func turnEnded(_ item: ProjectSession, in project: Project) {
    refresh()
    guard !NSApp.isActive, UserDefaults.standard.bool(forKey: PreferenceKey.notifiesTurnEnds)
    else { return }
    post(title: item.displayTitle, body: String(localized: "Finished its turn."), item: item)
  }

  private func post(title: String, body: String, item: ProjectSession) {
    guard let sessionID = item.sessionID else { return }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    Task {
      if !askedForPermission {
        askedForPermission = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.userInfo = ["sessionID": sessionID]
      try? await center.add(
        UNNotificationRequest(identifier: sessionID, content: content, trigger: nil))
    }
  }

  /// A click brings the session's window forward with its row selected.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let id = response.notification.request.content.userInfo["sessionID"] as? String
    else { return }
    await MainActor.run {
      guard let (project, item) = OpenSessions.shared.locate(id) else { return }
      project.select(item)
      NSApp.activate()
      project.workspace.window?.makeKeyAndOrderFront(nil)
    }
  }
}
```

- [ ] **Step 5: The menu item and the setting**

In `DrakarApp.swift`'s `SessionCommands`, after "New Session":

```swift
    Button("Next Session Needing You") {
      if let project, let next = project.nextNeedingAttention() { project.select(next) }
    }
    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
    .disabled(project?.nextNeedingAttention() == nil)
```

In `SettingsView.swift`, add to `PreferenceKey`:

```swift
  /// Whether a session that finishes its turn while Drakar is in the background says so.
  static let notifiesTurnEnds = "drakar.notifiesTurnEnds"
```

and to `GeneralPane`, a second `Section` after the editor one:

```swift
      Section {
        Toggle("Notify when a session finishes its turn", isOn: $notifiesTurnEnds)
          .accessibilityIdentifier("settings.notifiesTurnEnds")
      } footer: {
        Text("Sessions that need a permission always notify while Drakar is in the background.")
      }
```

with `@AppStorage(PreferenceKey.notifiesTurnEnds) private var notifiesTurnEnds = false`.

- [ ] **Step 6: Run the tests**

Run: `make -C apps/apple test-all`
Expected: PASS.

- [ ] **Step 7: Check it live**

`make -C apps/apple run ARGS='-drakar.debugFolder /tmp/drakar-probe -drakar.debugModel haiku -drakar.debugSettingSources project'`.
Send "Use the Bash tool to run: touch a.txt". ⌘N, select the new row before the permission
arrives. Expected: the first row turns blue, "Bash: touch a.txt"; the Dock shows 1;
⌥⌘↓ selects it and the permission sheet appears; answering clears the badge. Repeat with
another app in front: a notification arrives; clicking it brings Drakar forward on that row.

- [ ] **Step 8: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests/AttentionTests.swift
git commit -m "feat(apple): what a background session wants shows on its row, the Dock and a notification"
```

---

### Task 11: Closing or quitting while sessions work

**Files:**
- Modify: `apps/apple/Drakar/Services/Workspace.swift` (`WindowCloseGuard`, `UnsavedChanges`)
- Modify: `apps/apple/Drakar/ContentView.swift` (install call)
- Modify: `apps/apple/Drakar/DrakarApp.swift` (`applicationShouldTerminate`)
- Test: `apps/apple/DrakarTests/ClosingTests.swift`

**Interfaces:**
- Consumes: `Project.runningCount`, `OpenSessions.runningCount` (Task 7).
- Produces: `RunningSessions.note(count:) -> String`, `RunningSessions.alert(count:) -> NSAlert`;
  `WindowCloseGuard.install(on:for:running:)`.

- [ ] **Step 1: Write the failing test**

```swift
import AppKit
import Testing

@testable import Drakar

@MainActor
@Suite("Closing with sessions at work")
struct ClosingTests {

  @Test func saysHowManyAndWhatClosingDoes() {
    #expect(RunningSessions.note(count: 1) == "A session is still working. Closing stops it.")
    #expect(RunningSessions.note(count: 3) == "3 sessions are still working. Closing stops them.")
  }

  @Test func theAlertOffersCloseThenCancel() {
    let alert = RunningSessions.alert(count: 2)
    #expect(alert.buttons.map(\.title) == ["Close", "Cancel"])
    #expect(alert.informativeText == RunningSessions.note(count: 2))
  }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/ClosingTests`
Expected: FAIL to compile, `cannot find 'RunningSessions' in scope`.

- [ ] **Step 3: `RunningSessions`, beside `UnsavedChanges` in `Workspace.swift`**

```swift
/// The question before a close or a quit stops sessions mid-turn.
enum RunningSessions {
  static func note(count: Int) -> String {
    count == 1
      ? String(localized: "A session is still working. Closing stops it.")
      : String(localized: "\(count) sessions are still working. Closing stops them.")
  }

  static func alert(count: Int) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = String(localized: "Close while sessions are working?")
    alert.informativeText = note(count: count)
    alert.addButton(withTitle: String(localized: "Close"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    return alert
  }
}
```

- [ ] **Step 4: The window's guard asks both questions in one alert**

`WindowCloseGuard`: add `private let running: () -> Int`, pass it through `install` and
`init`:

```swift
  static func install(on window: NSWindow, for workspace: Workspace, running: @escaping () -> Int) {
    guard !(window.delegate is WindowCloseGuard) else { return }
    let closeGuard = WindowCloseGuard(original: window.delegate, workspace: workspace, running: running)
    workspace.closeGuard = closeGuard
    window.delegate = closeGuard
  }
```

and replace `windowShouldClose`:

```swift
  func windowShouldClose(_ window: NSWindow) -> Bool {
    let unsaved = workspace?.unsavedDocuments ?? []
    let running = running()
    guard let workspace, !unsaved.isEmpty || running > 0 else {
      return original?.windowShouldClose?(window) ?? true
    }
    if unsaved.isEmpty {
      RunningSessions.alert(count: running).beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn { window.close() }
      }
      return false
    }
    let alert = UnsavedChanges.alert(for: unsaved)
    if running > 0 { alert.informativeText += "\n\n" + RunningSessions.note(count: running) }
    alert.beginSheetModal(for: window) { response in
      switch UnsavedChanges.choice(response) {
      case .save:
        workspace.saveAll()
        if workspace.unsavedDocuments.isEmpty { window.close() }
      case .discard: window.close()
      case .cancel: break
      }
    }
    return false
  }
```

(keep whatever the existing method returned after starting its sheet; it returns `false`
so the sheet decides.)

In `ContentView`'s `WindowReader`:
`WindowCloseGuard.install(on: window, for: workspace, running: { [weak project] in project?.runningCount ?? 0 })`.

- [ ] **Step 5: Quitting**

In `AppDelegate.applicationShouldTerminate`, replace the first guard:

```swift
    let workspaces = Workspace.all.filter { !$0.unsavedDocuments.isEmpty }
    let running = OpenSessions.shared.runningCount
    if workspaces.isEmpty {
      guard running > 0 else { return .terminateNow }
      return RunningSessions.alert(count: running).runModal() == .alertFirstButtonReturn
        ? .terminateNow : .terminateCancel
    }
    let alert = UnsavedChanges.alert(for: workspaces.flatMap(\.unsavedDocuments))
    if running > 0 { alert.informativeText += "\n\n" + RunningSessions.note(count: running) }
    switch UnsavedChanges.choice(alert.runModal()) {
```

keeping the existing three cases below it.

- [ ] **Step 6: Run the tests**

Run: `make -C apps/apple test-all`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests/ClosingTests.swift
git commit -m "feat(apple): ask before a close or a quit stops sessions mid-turn"
```

---

### Task 12: The bridge knows its terminals, and a worktree knows its copy

**Files:**
- Modify: `apps/apple/Drakar/Services/IDEBridge.swift` (`connectedPIDs`)
- Modify: `apps/apple/Drakar/Views/ProjectSidebar.swift` (`SummaryRow` detail)
- Modify: `apps/apple/Drakar/DrakarApp.swift` (`MentionCommands` label)
- Modify: `apps/apple/Drakar/Views/ComposerView.swift`, `apps/apple/Drakar/Views/SessionView.swift` (chip note)
- Test: `apps/apple/DrakarTests/WorktreeChipTests.swift`

**Interfaces:**
- Consumes: `IDEConnection.claudePID` (existing), `SessionMonitor` (Task 9).
- Produces: `IDEBridge.connectedPIDs: Set<Int32>`; `SessionMonitor.connectedSession(under:) -> SessionSummary?`;
  `ComposerView.selectionNote(_ selection: EditorSelection, sessionFolder: URL, projectFolder: URL) -> String?` (static).

- [ ] **Step 1: Write the failing test**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@Suite("A selection sent to a session in a worktree")
struct WorktreeChipTests {

  private func selection(_ path: String) -> EditorSelection {
    EditorSelection(
      filePath: path, text: "",
      start: TextPosition(line: 0, character: 0), end: TextPosition(line: 0, character: 0))
  }

  @Test func aFileOfTheMainCheckoutIsMarked() {
    let note = ComposerView.selectionNote(
      selection("/w/drakar/README.md"),
      sessionFolder: URL(filePath: "/w/drakar/.claude/worktrees/x"),
      projectFolder: URL(filePath: "/w/drakar"))
    #expect(note == "from the main checkout")
  }

  @Test func aFileOfTheSessionsOwnFolderIsNot() {
    #expect(
      ComposerView.selectionNote(
        selection("/w/drakar/.claude/worktrees/x/README.md"),
        sessionFolder: URL(filePath: "/w/drakar/.claude/worktrees/x"),
        projectFolder: URL(filePath: "/w/drakar")) == nil)
    #expect(
      ComposerView.selectionNote(
        selection("/w/drakar/README.md"), sessionFolder: URL(filePath: "/w/drakar"),
        projectFolder: URL(filePath: "/w/drakar")) == nil)
  }
}
```

If `TextPosition`'s initializer differs, read it in `EditorSelection.swift` and match it.

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/WorktreeChipTests`
Expected: FAIL to compile, `type 'ComposerView' has no member 'selectionNote'`.

- [ ] **Step 3: The chip's note**

In `ComposerView`, add stored properties `let sessionFolder: URL` and `let projectFolder: URL`
(after `pinned`), and:

```swift
  /// "from the main checkout" when the session runs in a folder below the project (a
  /// worktree) and the selection is a file outside it: the session reads another copy.
  static func selectionNote(
    _ selection: EditorSelection, sessionFolder: URL, projectFolder: URL
  ) -> String? {
    let session = ProjectPath.normalize(sessionFolder.path(percentEncoded: false))
    let project = ProjectPath.normalize(projectFolder.path(percentEncoded: false))
    guard session != project, !ProjectPath.contains(session, selection.filePath) else { return nil }
    return String(localized: "from the main checkout")
  }
```

Pass the note into both chips: in `PinnedChip` and `ContextChip`, show
`Label(note.map { "\(label) · \($0)" } ?? label, …)` with a `let note: String?` property,
and build them with
`note: Self.selectionNote(selection, sessionFolder: sessionFolder, projectFolder: projectFolder)`.
In `SessionView`, pass `sessionFolder: session.folder, projectFolder: project.folder`.

- [ ] **Step 4: Which terminals are connected**

In `IDEBridge`, beside the other observed state:

```swift
  /// The pids of the terminal `claude`s connected now, from their `ide_connected`.
  private(set) var connectedPIDs: Set<Int32> = []
```

In `handle(_:from:)`'s `ide_connected` branch, after setting `connection.claudePID`:
`if let pid = connection.claudePID { connectedPIDs.insert(pid) }`. In `closed(_:)`, first
line: `if let pid = connection.claudePID { connectedPIDs.remove(pid) }`.

In `SessionMonitor`:

```swift
  /// The one terminal session of `folder` connected to the bridge, when there is exactly one.
  func connectedSession(under folder: String) -> SessionSummary? {
    let connected = summaries(under: folder).filter { summary in
      summary.live.map { IDEBridge.shared.connectedPIDs.contains($0.pid) } ?? false
    }
    return connected.count == 1 ? connected.first : nil
  }
```

In `SummaryRow.detail`, when `summary.live.map({ IDEBridge.shared.connectedPIDs.contains($0.pid) }) == true`,
append `String(localized: "connected")` to `parts`.

In `MentionCommands` (`DrakarApp.swift`), name the target:

```swift
  private var title: String {
    guard let workspace,
      let summary = SessionMonitor.shared.connectedSession(
        under: workspace.folder.path(percentEncoded: false))
    else { return String(localized: "Mention in Terminal Session") }
    return String(localized: "Mention in “\(summary.displayTitle)”")
  }
```

and use `Button(title) { … }` for the ⌘⌥K item.

- [ ] **Step 5: Run the tests, check it live**

Run: `make -C apps/apple test-all`
Expected: PASS.

Live: with a project window open on this repo, run `claude --ide` in a terminal here. The
Elsewhere row says "connected"; Edit > "Mention in “<its title>”" with a selection in the
editor puts the reference into the terminal prompt.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests/WorktreeChipTests.swift
git commit -m "feat(apple): terminal sessions on the bridge say so, and a worktree's selection names its copy"
```

---

### Task 13: Verify end to end, and say what exists

**Files:**
- Modify: `PLAN.md` (status paragraph, §4 a phase 5 entry)

- [ ] **Step 1: Every suite and the audit**

Run: `make -C apps/apple test-all && make audit && make -C apps/apple format-swift-check`
Expected: all PASS. If `make audit` flags `UserNotifications`, read why: it is local
delivery, and the allowance belongs in `scripts/audit-network.sh` with a comment, after
asking the person.

- [ ] **Step 2: The live checklist from the spec, against the real CLI**

Each one, noting the Claude Code version from a footer:
1. Two sessions working at once in one window; switching keeps each draft and scroll place.
2. A background permission request: blue row, Dock badge, notification with Drakar in the
   background, answered from the sheet after selecting the row.
3. A terminal `claude --ide` shown under Elsewhere as connected; ⌘⌥K names it.
4. Resume an Ended session; fork a live one from its read-only banner; quit and relaunch:
   rows restored, nothing running.
5. A session's gauge: after its first turn the tooltip says "Reported by the session." and
   the limit matches the model (1M for a `[1m]` model).

Any that fails is a bug to fix before Step 3, under superpowers:systematic-debugging.

- [ ] **Step 3: PLAN.md**

In the status paragraph, after "Phase 4 added …", add a sentence: "Phase 5 made a window a
project: its sessions in the sidebar with their state and context, switching in place,
each started on its first prompt." In §4, add after item 4:

```markdown
5. **Project windows.** *Done 2026-10-04*
   (`docs/superpowers/specs/2026-10-04-project-windows-design.md`). A window is a folder
   and every session in it and below: the window's own, those live in a terminal, VS Code
   or another window (read-only, forkable), and those that ended. Each row says what the
   session is doing and how full its context is, exactly for Drakar's own sessions
   (`get_context_usage` after each turn) and from the transcript's tail for the rest.
   `claude` starts on a session's first prompt; a background session's permission request
   shows on its row, the Dock and a notification. Not yet: a context breakdown panel.
```

- [ ] **Step 4: Commit**

```bash
git add PLAN.md
git commit -m "docs: project windows are in"
```
