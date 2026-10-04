# Move Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move a project's sessions (or one session) from one Claude account to another, so they carry on under the same id there.

**Architecture:** `SessionMover` (DrakarKit) relocates one session's files with `FileManager.moveItem`, transcript last. `SessionMoves` (app) lists a folder's candidates, classifies each just before its move (idle held → stop; busy or live elsewhere → skip), runs the moves, relocates held `ClaudeSession`s, and words the summary. The toolbar picker offers a folder move after a pick; session rows get a "Move to" menu.

**Tech Stack:** Swift 6, SwiftUI + AppKit alerts (macOS), Swift Testing, DrakarKit package.

**Spec:** `docs/superpowers/specs/2026-10-04-move-sessions-design.md`

## Global Constraints

- A real move: files leave the source account, the session id stays. Nothing is copied to stay behind, nothing is overwritten, nothing is deleted.
- Moved per session: `projects/<folder name>/<id>.jsonl` (last), `projects/<folder name>/<id>/`, `file-history/<id>`, `session-env/<id>`. Not moved: `history.jsonl`, `sessions/`.
- `<folder name>` is the source transcript's parent folder name, reused exactly; never re-encoded from a path.
- The target already holding `<id>.jsonl`: skipped as "already there", both files untouched. A sidecar already at the target: left where both are.
- Classification per session, immediately before its move: held by a Drakar window and busy (turn running or permission pending) → skip "busy"; held and idle → stop its process if any, move, `relocate(to:)`; not held but live in another process → skip "running in <host>"; otherwise move.
- Accounts are compared by `ClaudeAccount.key`; `CLAUDE_CONFIG_DIR` comes from `ClaudeAccount.environment` (no trailing slash).
- Picker prompt: "Move this folder's N sessions from <source> to <target> too?", N excluding sessions running elsewhere; buttons "Move N Sessions" / "Not Now".
- Summary: "Moved N sessions to <target>." then, when some did not, "Not moved: …".
- `ClaudeChoice.testSuite` (task-local) scopes Settings in tests; never assign a global.
- Commands from `apps/apple`: `make test`, `make test-app`, `make build`. Format only touched files with `xcrun swift-format format --in-place <files>`.

## Review Focus

1. **A session prompted while the move prompt is up** must be skipped as busy, not stopped mid-turn: classification happens per session at move time. Pinned by `SessionMovesRunTests.aBusySessionIsSkipped` (Task 3).
2. **A worktree session's transcript folder** (a different `<folder name>`) must land under that same name on the target. Pinned by `SessionMoverTests.reusesTheFolderNameExactly` (Task 1).
3. **A session this window only watches** (read-only, live in a terminal) is not "held": it must be skipped as running elsewhere. Pinned by `SessionMovesTests.classifies` (row: not held, live) (Task 3).
4. **Relaunch after a move** must reopen the session on its new account: `savedTarget` follows the move. Pinned by `ClaudeSessionRelocateTests.theNextStartResumesUnderTheNewAccount` (Task 2).
5. **The same id listed twice** (a held row and its summary) must be moved once. Pinned by `SessionMovesTests.oneCandidatePerSessionTheWindowsWins` (Task 3).

---

### Task 1: `SessionMover` — one session's files to another account

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/SessionMover.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/SessionMoverTests.swift`

**Interfaces:**
- Consumes: `ClaudeAccount` (`directory`, `isDefault`).
- Produces:
  - `public enum SkipReason: Sendable, Equatable { case alreadyThere, busy, runningElsewhere(String) }`
  - `public enum MoveOutcome: Sendable, Equatable { case moved, skipped(SkipReason), failed(String) }`
  - `public enum SessionMover { static func destination(of transcript: URL, to target: ClaudeAccount) -> URL; static func move(transcript: URL, from source: ClaudeAccount, to target: ClaudeAccount, fileManager: FileManager = .default) -> MoveOutcome }`

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Moving a session's files to another account")
struct SessionMoverTests {

  private let root: URL
  private let source: ClaudeAccount
  private let target: ClaudeAccount
  private let folderName = "-Users-me-Projects-app"
  private let id = "11111111-2222-3333-4444-555555555555"

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-move-\(UUID().uuidString)", directoryHint: .isDirectory)
    source = ClaudeAccount(
      directory: root.appending(path: ".claude-a", directoryHint: .isDirectory), isDefault: false)
    target = ClaudeAccount(
      directory: root.appending(path: ".claude-b", directoryHint: .isDirectory), isDefault: false)
    for account in [source, target] {
      try FileManager.default.createDirectory(at: account.directory, withIntermediateDirectories: true)
    }
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  /// The transcript and, as asked, each sidecar, under `account`.
  @discardableResult
  private func write(
    in account: ClaudeAccount, folder: String? = nil, text: String = "{\"type\":\"user\"}\n",
    subagents: Bool = false, fileHistory: Bool = false, sessionEnv: Bool = false
  ) throws -> URL {
    let projects = account.directory.appending(path: "projects/\(folder ?? folderName)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let transcript = projects.appending(path: "\(id).jsonl")
    try Data(text.utf8).write(to: transcript)
    if subagents {
      let folder = projects.appending(path: "\(id)/subagents", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("{}\n".utf8).write(to: folder.appending(path: "agent-1.jsonl"))
    }
    if fileHistory {
      let folder = account.directory.appending(path: "file-history/\(id)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("v1".utf8).write(to: folder.appending(path: "abc@v1"))
    }
    if sessionEnv {
      let folder = account.directory.appending(path: "session-env", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: folder.appending(path: id, directoryHint: .isDirectory), withIntermediateDirectories: true)
    }
    return transcript
  }

  @Test func movesTheTranscriptAndEverySidecar() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source, subagents: true, fileHistory: true, sessionEnv: true)
    #expect(SessionMover.move(transcript: transcript, from: source, to: target) == .moved)

    let destination = SessionMover.destination(of: transcript, to: target)
    #expect(destination.path(percentEncoded: false).hasSuffix(".claude-b/projects/\(folderName)/\(id).jsonl"))
    #expect(exists(destination))
    #expect(exists(destination.deletingPathExtension().appending(path: "subagents/agent-1.jsonl")))
    #expect(exists(target.directory.appending(path: "file-history/\(id)/abc@v1")))
    #expect(exists(target.directory.appending(path: "session-env/\(id)")))
    #expect(!exists(transcript))
    #expect(!exists(transcript.deletingPathExtension()))
    #expect(!exists(source.directory.appending(path: "file-history/\(id)")))
    #expect(!exists(source.directory.appending(path: "session-env/\(id)")))
  }

  @Test func movesWhicheverSidecarsThereAre() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source, fileHistory: true)
    #expect(SessionMover.move(transcript: transcript, from: source, to: target) == .moved)
    #expect(exists(target.directory.appending(path: "file-history/\(id)")))
    #expect(!exists(target.directory.appending(path: "session-env/\(id)")))
  }

  @Test func neverOverwritesATranscriptAlreadyThere() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source, text: "source\n")
    let existing = try write(in: target, text: "target\n")
    #expect(
      SessionMover.move(transcript: transcript, from: source, to: target) == .skipped(.alreadyThere))
    #expect(try String(contentsOf: transcript, encoding: .utf8) == "source\n")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "target\n")
  }

  /// A worktree's folder name is not what encoding the project path would give.
  @Test func reusesTheFolderNameExactly() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let odd = "-Users-me-Projects-app--claude-worktrees-Feat.X"
    let transcript = try write(in: source, folder: odd)
    #expect(SessionMover.move(transcript: transcript, from: source, to: target) == .moved)
    #expect(exists(target.directory.appending(path: "projects/\(odd)/\(id).jsonl")))
  }

  @Test func refusesWhenTheTargetFolderIsGone() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source)
    try FileManager.default.removeItem(at: target.directory)
    guard case .failed = SessionMover.move(transcript: transcript, from: source, to: target) else {
      Issue.record("moved into a missing account")
      return
    }
    #expect(exists(transcript))
  }

  /// The transcript decides the account: a failure on it leaves the session usable where it
  /// was, and a second move finishes the job.
  @Test func aFailedTranscriptMoveLeavesTheSessionWhereItWas() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source, fileHistory: true)
    guard case .failed = SessionMover.move(
      transcript: transcript, from: source, to: target, fileManager: RefusesTranscripts())
    else {
      Issue.record("the refusing file manager moved the transcript")
      return
    }
    #expect(exists(transcript))
    #expect(exists(target.directory.appending(path: "file-history/\(id)")))
    #expect(SessionMover.move(transcript: transcript, from: source, to: target) == .moved)
    #expect(exists(SessionMover.destination(of: transcript, to: target)))
  }
}

/// Moves everything but a transcript.
private final class RefusesTranscripts: FileManager, @unchecked Sendable {
  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if srcURL.pathExtension == "jsonl" { throw CocoaError(.fileWriteNoPermission) }
    try super.moveItem(at: srcURL, to: dstURL)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/apple && make test`
Expected: build failure, `cannot find 'SessionMover' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Why a session was not moved.
public enum SkipReason: Sendable, Equatable {
  /// The target account already holds a transcript with this id.
  case alreadyThere
  /// A Drakar window is running a turn in it or waiting on a permission.
  case busy
  /// Open in another process: "VS Code", "a terminal", "the Claude app", "another app".
  case runningElsewhere(String)
}

public enum MoveOutcome: Sendable, Equatable {
  case moved
  case skipped(SkipReason)
  case failed(String)
}

/// Moves one session's files from one account's directory to another's
/// (`docs/superpowers/specs/2026-10-04-move-sessions-design.md`). A session belongs to the
/// account whose `projects` holds its transcript, so the transcript goes last: a move cut
/// short leaves the session where it was, and moving it again finishes.
public enum SessionMover {
  /// Where `transcript` lands under `target`: the same `projects/<folder name>/<id>.jsonl`,
  /// the folder name reused as the source has it, never encoded again from a path.
  public static func destination(of transcript: URL, to target: ClaudeAccount) -> URL {
    target.directory.appending(path: "projects", directoryHint: .isDirectory)
      .appending(
        path: transcript.deletingLastPathComponent().lastPathComponent, directoryHint: .isDirectory
      )
      .appending(path: transcript.lastPathComponent)
  }

  /// Nothing is overwritten: a transcript already at the target skips the session, and a
  /// sidecar already there is left beside the source's.
  public static func move(
    transcript: URL, from source: ClaudeAccount, to target: ClaudeAccount,
    fileManager: FileManager = .default
  ) -> MoveOutcome {
    func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path(percentEncoded: false)) }
    guard exists(target.directory) else {
      return .failed(
        String(localized: "\(target.directory.path(percentEncoded: false)) no longer exists."))
    }
    let destination = destination(of: transcript, to: target)
    guard !exists(destination) else { return .skipped(.alreadyThere) }
    let id = transcript.deletingPathExtension().lastPathComponent
    let sidecars = [
      (transcript.deletingPathExtension(), destination.deletingPathExtension()),
      (
        source.directory.appending(path: "file-history").appending(path: id),
        target.directory.appending(path: "file-history").appending(path: id)
      ),
      (
        source.directory.appending(path: "session-env").appending(path: id),
        target.directory.appending(path: "session-env").appending(path: id)
      ),
    ]
    do {
      for (from, to) in sidecars where exists(from) && !exists(to) {
        try fileManager.createDirectory(
          at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: from, to: to)
      }
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.moveItem(at: transcript, to: destination)
      return .moved
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd apps/apple && make test`
Expected: PASS, every `SessionMoverTests` case.

- [ ] **Step 5: Format and commit**

```bash
K=apps/apple/Packages/DrakarKit
xcrun swift-format format --in-place $K/Sources/DrakarKit/SessionMover.swift $K/Tests/DrakarKitTests/SessionMoverTests.swift
git add $K/Sources/DrakarKit/SessionMover.swift $K/Tests/DrakarKitTests/SessionMoverTests.swift
git commit -m "feat(kit): a session's files move to another account, transcript last"
```

---

### Task 2: `ClaudeSession.relocate(to:)`

**Files:**
- Modify: `apps/apple/Drakar/Services/ClaudeSession.swift` (after `stop()`, around line 289)
- Test: `apps/apple/DrakarTests/ClaudeSessionRelocateTests.swift`

**Interfaces:**
- Consumes: `ResumeTarget(sessionID:cwd:file:accountDirectory:accountIsDefault:)`, `ClaudeAccount.key`.
- Produces: `ClaudeSession.relocate(to target: ResumeTarget)`.

- [ ] **Step 1: Write the failing test**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A session whose files moved")
struct ClaudeSessionRelocateTests {

  private let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-relocate-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private func transcript(in account: URL) throws -> URL {
    let folder = account.appending(path: "projects/-p", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "s1.jsonl")
    try Data(
      [
        #"{"type":"user","message":{"role":"user","content":"Make it so"}}"#,
        #"{"type":"ai-title","aiTitle":"Make it so"}"#,
      ].joined(separator: "\n").appending("\n").utf8
    ).write(to: file)
    return file
  }

  private func target(_ file: URL, account: URL) -> ResumeTarget {
    ResumeTarget(
      sessionID: "s1", cwd: root.path(percentEncoded: false), file: file.path(percentEncoded: false),
      accountDirectory: ClaudeAccount(directory: account, isDefault: false).key,
      accountIsDefault: false)
  }

  /// The window's stored project and the next process both follow the move.
  @Test func theNextStartResumesUnderTheNewAccount() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appending(path: ".claude-a", directoryHint: .isDirectory)
    let new = root.appending(path: ".claude-b", directoryHint: .isDirectory)
    let oldFile = try transcript(in: old)
    let newFile = try transcript(in: new)
    let fake = root.appending(path: "claude")
    try Data(
      "#!/bin/sh\nprintf '%s\\n' \"$CLAUDE_CONFIG_DIR\" \"$@\" > \"$0.args\"\ncat > /dev/null\n".utf8
    ).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    let session = ClaudeSession(folder: root, resuming: target(oldFile, account: old))
    session.executableOverride = fake
    let moved = target(newFile, account: new)
    session.relocate(to: moved)
    #expect(session.savedTarget == moved)
    #expect(session.effectiveAccount?.key == ClaudeAccount(directory: new, isDefault: false).key)

    await session.spawn()
    defer { session.stop() }
    let written = fake.appendingPathExtension("args")
    var lines: [String] = []
    for _ in 0..<50 {
      lines = ((try? String(contentsOf: written, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
      if !lines.isEmpty { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(lines.first == ClaudeAccount(directory: new, isDefault: false).key)
    #expect(lines.contains("--resume"))
    #expect(lines.contains("s1"))
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd apps/apple && make test-app`
Expected: build failure, `value of type 'ClaudeSession' has no member 'relocate'`.

- [ ] **Step 3: Implement**

After `stop()` in `ClaudeSession`:

```swift
  /// The session's files moved to another account (`SessionMover`): its next start resumes
  /// `target` there, and the window's stored project names the new file. For a session
  /// with no process; `SessionMoves` stops an idle one first.
  func relocate(to target: ResumeTarget) {
    resuming = target
    savedTarget = target
    // The process that ran under the old account is gone; until the next one starts, the
    // session is on the account its files are under.
    account = nil
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd apps/apple && make test-app`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
A=apps/apple
xcrun swift-format format --in-place $A/Drakar/Services/ClaudeSession.swift $A/DrakarTests/ClaudeSessionRelocateTests.swift
git add $A/Drakar/Services/ClaudeSession.swift $A/DrakarTests/ClaudeSessionRelocateTests.swift
git commit -m "feat(apple): a session whose files moved resumes under its new account"
```

---

### Task 3: `SessionMoves` — candidates, classification, the run, the summary

**Files:**
- Create: `apps/apple/Drakar/Services/SessionMoves.swift`
- Test: `apps/apple/DrakarTests/SessionMovesTests.swift`

**Interfaces:**
- Consumes: `SessionMover.move(transcript:from:to:)`, `SessionMover.destination(of:to:)`, `MoveOutcome`, `SkipReason` (Task 1); `ClaudeSession.relocate(to:)` (Task 2); `ClaudeSession.isProcessRunning`, `.transcript.isRunning`, `.transcript.pendingPermissions`, `.stop()`, `.savedTarget`; `SessionSummary` (`sessionID`, `account`, `file`, `cwd`, `displayTitle`); `ClaudeAccount.key`.
- Produces:
  - `enum SessionMoves` with
    - `struct Candidate: Equatable { sessionID: String; title: String; transcript: URL; account: ClaudeAccount; cwd: String? }`
    - `struct Held: Equatable { hasProcess: Bool; isBusy: Bool }` and `static func held(_ session: ClaudeSession) -> Held`
    - `enum Plan: Equatable { case move(stopping: Bool), skip(SkipReason) }`
    - `struct Report: Equatable { title: String; outcome: MoveOutcome }`
    - `static func candidates(summaries: [SessionSummary], held: [(target: ResumeTarget, title: String)], notOn target: ClaudeAccount) -> [Candidate]`
    - `static func classify(sessionID: String, held: Held?, liveIDs: Set<String>, host: String) -> Plan`
    - `static func run(_ candidates: [Candidate], to target: ClaudeAccount, locate: (String) -> ClaudeSession?, liveIDs: () -> Set<String>, host: (Candidate) -> String) async -> [Report]`
    - `static func summary(_ reports: [Report], to name: String) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Which sessions move, and what came of it")
struct SessionMovesTests {

  private let a = ClaudeAccount(directory: URL(filePath: "/u/.claude-a/", directoryHint: .isDirectory), isDefault: false)
  private let b = ClaudeAccount(directory: URL(filePath: "/u/.claude-b/", directoryHint: .isDirectory), isDefault: false)

  private func summary(_ id: String, on account: ClaudeAccount, title: String? = nil) -> SessionSummary {
    var summary = SessionSummary(
      sessionID: id, account: account,
      file: account.directory.appending(path: "projects/-p/\(id).jsonl"), modified: .now, size: 1)
    summary.title = title
    summary.cwd = "/p"
    return summary
  }

  @Test func onlySessionsOnAnotherAccount() {
    let candidates = SessionMoves.candidates(
      summaries: [summary("s1", on: a), summary("s2", on: b)], held: [], notOn: b)
    #expect(candidates.map(\.sessionID) == ["s1"])
  }

  /// A held row's transcript can be newer than the list; it counts once, as the window has it.
  @Test func oneCandidatePerSessionTheWindowsWins() {
    let target = ResumeTarget(
      sessionID: "s1", cwd: "/p", file: "/u/.claude-a/projects/-p/s1.jsonl",
      accountDirectory: a.key, accountIsDefault: false)
    let candidates = SessionMoves.candidates(
      summaries: [summary("s1", on: a, title: "Listed")],
      held: [(target: target, title: "Held"), (target: ResumeTarget(
        sessionID: "s3", cwd: "/p", file: "/u/.claude-a/projects/-p/s3.jsonl",
        accountDirectory: a.key, accountIsDefault: false), title: "New")],
      notOn: b)
    #expect(candidates.map(\.sessionID).sorted() == ["s1", "s3"])
    #expect(candidates.first { $0.sessionID == "s1" }?.title == "Held")
  }

  @Test func classifies() {
    let idle = SessionMoves.Held(hasProcess: true, isBusy: false)
    let busy = SessionMoves.Held(hasProcess: true, isBusy: true)
    let stopped = SessionMoves.Held(hasProcess: false, isBusy: false)
    #expect(SessionMoves.classify(sessionID: "s", held: nil, liveIDs: [], host: "x") == .move(stopping: false))
    #expect(SessionMoves.classify(sessionID: "s", held: stopped, liveIDs: [], host: "x") == .move(stopping: false))
    #expect(SessionMoves.classify(sessionID: "s", held: idle, liveIDs: ["s"], host: "x") == .move(stopping: true))
    #expect(SessionMoves.classify(sessionID: "s", held: busy, liveIDs: [], host: "x") == .skip(.busy))
    // Watched read-only in a window, open in a terminal: not held.
    #expect(
      SessionMoves.classify(sessionID: "s", held: nil, liveIDs: ["s"], host: "VS Code")
        == .skip(.runningElsewhere("VS Code")))
  }

  @Test func summarises() {
    func report(_ outcome: MoveOutcome, _ title: String = "T") -> SessionMoves.Report {
      SessionMoves.Report(title: title, outcome: outcome)
    }
    #expect(SessionMoves.summary([report(.moved)], to: "Skitrust") == "Moved 1 session to Skitrust.")
    #expect(
      SessionMoves.summary(
        [report(.moved), report(.moved), report(.skipped(.runningElsewhere("VS Code"))),
         report(.skipped(.runningElsewhere("VS Code"))), report(.skipped(.alreadyThere))],
        to: "Skitrust")
        == "Moved 2 sessions to Skitrust. Not moved: 2 running in VS Code, 1 already on Skitrust.")
    #expect(
      SessionMoves.summary([report(.skipped(.busy)), report(.failed("disk full"), "Fix it")], to: "Skitrust")
        == "Moved no session to Skitrust. Not moved: 1 busy. Failed: “Fix it”: disk full.")
  }
}

/// The run against real files and a stand-in `claude`.
@MainActor
@Suite("Moving sessions for real")
struct SessionMovesRunTests {

  private let root: URL
  private let a: ClaudeAccount
  private let b: ClaudeAccount
  private let fake: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-moves-\(UUID().uuidString)", directoryHint: .isDirectory)
    a = ClaudeAccount(directory: root.appending(path: ".claude-a", directoryHint: .isDirectory), isDefault: false)
    b = ClaudeAccount(directory: root.appending(path: ".claude-b", directoryHint: .isDirectory), isDefault: false)
    for account in [a, b] {
      try FileManager.default.createDirectory(at: account.directory, withIntermediateDirectories: true)
    }
    fake = root.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  private func heldSession(_ id: String) throws -> (ClaudeSession, SessionMoves.Candidate) {
    let folder = a.directory.appending(path: "projects/-p", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "\(id).jsonl")
    try Data(#"{"type":"user","message":{"role":"user","content":"hi"}}"#.appending("\n").utf8)
      .write(to: file)
    let target = ResumeTarget(
      sessionID: id, cwd: root.path(percentEncoded: false), file: file.path(percentEncoded: false),
      accountDirectory: a.key, accountIsDefault: false)
    let session = ClaudeSession(folder: root, resuming: target)
    session.executableOverride = fake
    let candidate = SessionMoves.Candidate(
      sessionID: id, title: id, transcript: file, account: a, cwd: target.cwd)
    return (session, candidate)
  }

  @Test func anIdleSessionIsStoppedMovedAndRelocated() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, candidate) = try heldSession("s1")
    await session.spawn()
    #expect(session.isProcessRunning)

    let reports = await SessionMoves.run(
      [candidate], to: b, locate: { $0 == "s1" ? session : nil }, liveIDs: { ["s1"] },
      host: { _ in "x" })
    #expect(reports == [SessionMoves.Report(title: "s1", outcome: .moved)])
    #expect(!session.isProcessRunning)
    #expect(session.savedTarget?.accountDirectory == b.key)
    #expect(session.savedTarget?.file == SessionMover.destination(of: candidate.transcript, to: b).path(percentEncoded: false))
    #expect(!FileManager.default.fileExists(atPath: candidate.transcript.path(percentEncoded: false)))
  }

  /// Prompted between the question and the move: left alone.
  @Test func aBusySessionIsSkipped() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, candidate) = try heldSession("s2")
    session.send("keep going")
    defer { session.stop() }
    #expect(session.transcript.isRunning)

    let reports = await SessionMoves.run(
      [candidate], to: b, locate: { $0 == "s2" ? session : nil }, liveIDs: { [] }, host: { _ in "x" })
    #expect(reports == [SessionMoves.Report(title: "s2", outcome: .skipped(.busy))])
    #expect(FileManager.default.fileExists(atPath: candidate.transcript.path(percentEncoded: false)))
  }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/apple && make test-app`
Expected: build failure, `cannot find 'SessionMoves' in scope`.

- [ ] **Step 3: Implement**

```swift
import DrakarKit
import Foundation

/// Moving a folder's sessions to another account: which ones, in what state, and what came
/// of it (`docs/superpowers/specs/2026-10-04-move-sessions-design.md`). `SessionMover` moves
/// the files; this decides, one session at a time and just before its move, whether it may.
enum SessionMoves {
  /// One session that could move.
  struct Candidate: Equatable {
    var sessionID: String
    var title: String
    var transcript: URL
    var account: ClaudeAccount
    var cwd: String?
  }

  /// A Drakar window holding the session, as the move sees it.
  struct Held: Equatable {
    var hasProcess: Bool
    /// A turn running or a permission waiting: stopping it would lose work.
    var isBusy: Bool
  }

  enum Plan: Equatable {
    case move(stopping: Bool)
    case skip(SkipReason)
  }

  struct Report: Equatable {
    var title: String
    var outcome: MoveOutcome
  }

  static func held(_ session: ClaudeSession) -> Held {
    Held(
      hasProcess: session.isProcessRunning,
      isBusy: session.transcript.isRunning || !session.transcript.pendingPermissions.isEmpty)
  }

  /// The sessions not on `target`: those listed, and the windows' own, whose transcript can
  /// be newer than the list. One per id, the window's when both have it.
  static func candidates(
    summaries: [SessionSummary], held: [(target: ResumeTarget, title: String)],
    notOn target: ClaudeAccount
  ) -> [Candidate] {
    var byID: [String: Candidate] = [:]
    var order: [String] = []
    for summary in summaries where summary.account.key != target.key {
      if byID[summary.sessionID] == nil { order.append(summary.sessionID) }
      byID[summary.sessionID] = Candidate(
        sessionID: summary.sessionID, title: summary.displayTitle, transcript: summary.file,
        account: summary.account, cwd: summary.cwd)
    }
    for (resume, title) in held where resume.account.key != target.key {
      if byID[resume.sessionID] == nil { order.append(resume.sessionID) }
      byID[resume.sessionID] = Candidate(
        sessionID: resume.sessionID, title: title, transcript: resume.transcriptFile,
        account: resume.account, cwd: resume.cwd)
    }
    return order.compactMap { byID[$0] }
  }

  /// A held session is the window's to judge; one no window holds but a process has open is
  /// running elsewhere, even when this window watches it.
  static func classify(sessionID: String, held: Held?, liveIDs: Set<String>, host: String) -> Plan {
    if let held { return held.isBusy ? .skip(.busy) : .move(stopping: held.hasProcess) }
    if liveIDs.contains(sessionID) { return .skip(.runningElsewhere(host)) }
    return .move(stopping: false)
  }

  /// One at a time, each judged just before its move: a terminal may resume one, or the
  /// person prompt one, while the others move.
  static func run(
    _ candidates: [Candidate], to target: ClaudeAccount, locate: (String) -> ClaudeSession?,
    liveIDs: () -> Set<String>, host: (Candidate) -> String
  ) async -> [Report] {
    var reports: [Report] = []
    for candidate in candidates {
      let session = locate(candidate.sessionID)
      let plan = classify(
        sessionID: candidate.sessionID, held: session.map(held), liveIDs: liveIDs(),
        host: host(candidate))
      guard case .move(let stopping) = plan else {
        if case .skip(let reason) = plan {
          reports.append(Report(title: candidate.title, outcome: .skipped(reason)))
        }
        continue
      }
      if stopping { session?.stop() }
      let transcript = candidate.transcript
      let source = candidate.account
      let outcome = await Task.detached {
        SessionMover.move(transcript: transcript, from: source, to: target)
      }.value
      if outcome == .moved, let session {
        session.relocate(
          to: ResumeTarget(
            sessionID: candidate.sessionID,
            cwd: candidate.cwd ?? session.folder.path(percentEncoded: false),
            file: SessionMover.destination(of: transcript, to: target).path(percentEncoded: false),
            accountDirectory: target.key, accountIsDefault: target.isDefault))
      }
      reports.append(Report(title: candidate.title, outcome: outcome))
    }
    return reports
  }

  /// `Moved 12 sessions to Skitrust. Not moved: 2 running in VS Code, 1 already on Skitrust.`
  static func summary(_ reports: [Report], to name: String) -> String {
    let moved = reports.count { $0.outcome == .moved }
    var text =
      switch moved {
      case 0: String(localized: "Moved no session to \(name).")
      case 1: String(localized: "Moved 1 session to \(name).")
      default: String(localized: "Moved \(moved) sessions to \(name).")
      }
    var skipped: [String] = []
    var counts: [String: Int] = [:]
    var failures: [String] = []
    for report in reports {
      let label: String
      switch report.outcome {
      case .moved: continue
      case .failed(let reason):
        failures.append("“\(report.title)”: \(reason)")
        continue
      case .skipped(.busy): label = String(localized: "busy")
      case .skipped(.alreadyThere): label = String(localized: "already on \(name)")
      case .skipped(.runningElsewhere(let host)): label = String(localized: "running in \(host)")
      }
      if counts[label] == nil { skipped.append(label) }
      counts[label, default: 0] += 1
    }
    if !skipped.isEmpty {
      text += " " + String(localized: "Not moved:") + " "
        + skipped.map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: ", ") + "."
    }
    if !failures.isEmpty {
      text += " " + String(localized: "Failed:") + " " + failures.joined(separator: "; ") + "."
    }
    return text
  }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd apps/apple && make test-app`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
A=apps/apple
xcrun swift-format format --in-place $A/Drakar/Services/SessionMoves.swift $A/DrakarTests/SessionMovesTests.swift
git add $A/Drakar/Services/SessionMoves.swift $A/DrakarTests/SessionMovesTests.swift
git commit -m "feat(apple): a folder's sessions move to another account, each judged just before it goes"
```

---

### Task 4: The picker prompt, the row menus, the alerts

**Files:**
- Modify: `apps/apple/Drakar/Services/SessionMoves.swift` (append the AppKit-facing part)
- Modify: `apps/apple/Drakar/Views/AccountToolbarItem.swift` (`AccountPicker`'s row button, around line 83)
- Modify: `apps/apple/Drakar/Views/ProjectSidebar.swift` (`menu(for:)` at line 188; `.contextMenu` on the elsewhere and ended `SummaryRow`s at lines 108 and 120)

**Interfaces:**
- Consumes: Task 3's `SessionMoves` API; `SessionMonitor.shared` (`summaries(under:)`, `liveIDs`, `summary(forFile:)`, `host(of:)`); `OpenSessions.shared` (`projects`, `locate(_:)`); `AccountStore.shared` (`accounts`, `profile(for:)`, `windowAccount(for:)`, `pick(_:for:)`); `ProjectPath.normalize`.
- Produces: `SessionMoves.offer(folder:from:to:)`, `SessionMoves.moveOne(_ candidate:to:)`, `SessionMoves.candidate(for summary:)`, `SessionMoves.candidate(for item:)`.

- [ ] **Step 1: Append the AppKit-facing part to `SessionMoves.swift`**

```swift
import AppKit

extension SessionMoves {
  /// The app's own answers to `run`'s questions.
  private static func runInApp(_ candidates: [Candidate], to target: ClaudeAccount) async -> [Report] {
    let monitor = SessionMonitor.shared
    return await run(
      candidates, to: target, locate: { OpenSessions.shared.locate($0)?.1.session },
      liveIDs: { monitor.liveIDs }, host: { hostName(of: $0) })
  }

  private static func hostName(of candidate: Candidate) -> String {
    let monitor = SessionMonitor.shared
    return monitor.summary(forFile: candidate.transcript).map { monitor.host(of: $0) }
      ?? String(localized: "another app")
  }

  /// After the picker moved `folder` from `source` to `target`: offer to take its sessions
  /// along. Asks nothing when there is nothing to move.
  static func offer(folder: URL, from source: ClaudeAccount, to target: ClaudeAccount) {
    let path = ProjectPath.normalize(folder.path(percentEncoded: false))
    let held = OpenSessions.shared.projects.values
      .filter { ProjectPath.normalize($0.folder.path(percentEncoded: false)) == path }
      .flatMap(\.held)
      .compactMap { item in item.session.savedTarget.map { (target: $0, title: item.displayTitle) } }
    let all = candidates(
      summaries: SessionMonitor.shared.summaries(under: path), held: held, notOn: target)
    let live = SessionMonitor.shared.liveIDs
    let elsewhere = all.filter { OpenSessions.shared.locate($0.sessionID) == nil && live.contains($0.sessionID) }
    let movable = all.count - elsewhere.count
    guard movable > 0 else { return }
    let store = AccountStore.shared
    let from = store.profile(for: source).name
    let to = store.profile(for: target).name
    let alert = NSAlert()
    alert.messageText =
      movable == 1
      ? String(localized: "Move this folder's session from \(from) to \(to) too?")
      : String(localized: "Move this folder's \(movable) sessions from \(from) to \(to) too?")
    if !elsewhere.isEmpty {
      let hosts = Set(elsewhere.map(hostName(of:))).sorted().joined(separator: ", ")
      alert.informativeText = String(
        localized: "\(elsewhere.count) running in \(hosts) will stay on \(from).")
    }
    alert.addButton(
      withTitle: movable == 1
        ? String(localized: "Move Session") : String(localized: "Move \(movable) Sessions"))
    alert.addButton(withTitle: String(localized: "Not Now"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task {
      let reports = await runInApp(all, to: target)
      let summary = NSAlert()
      summary.messageText = Self.summary(reports, to: to)
      summary.runModal()
    }
  }

  /// One session from its row. Says something only when it did not move.
  static func moveOne(_ candidate: Candidate, to target: ClaudeAccount) {
    Task {
      let reports = await runInApp([candidate], to: target)
      guard reports.first?.outcome != .moved else { return }
      let alert = NSAlert()
      alert.messageText = Self.summary(reports, to: AccountStore.shared.profile(for: target).name)
      alert.runModal()
    }
  }

  static func candidate(for summary: SessionSummary) -> Candidate {
    Candidate(
      sessionID: summary.sessionID, title: summary.displayTitle, transcript: summary.file,
      account: summary.account, cwd: summary.cwd)
  }

  /// Nil for a session never prompted: it has no files, and starts on the window's account.
  static func candidate(for item: ProjectSession) -> Candidate? {
    item.session.savedTarget.map {
      Candidate(
        sessionID: $0.sessionID, title: item.displayTitle, transcript: $0.transcriptFile,
        account: $0.account, cwd: $0.cwd)
    }
  }

  /// Every discovered account but `current`, for a "Move to" menu.
  static func destinations(from current: ClaudeAccount) -> [ClaudeAccount] {
    AccountStore.shared.accounts.filter { $0.key != current.key }
  }
}
```

- [ ] **Step 2: Offer the move after a pick**

In `AccountPicker` (`AccountToolbarItem.swift`), the row button's action becomes:

```swift
        Button {
          let previous = store.windowAccount(for: folder)
          store.pick(account, for: folder)
          dismiss()
          if account.key != previous.key {
            // After the popover is gone: a modal over an open popover is lost behind it.
            DispatchQueue.main.async {
              SessionMoves.offer(folder: folder, from: previous, to: account)
            }
          }
        } label: {
```

- [ ] **Step 3: "Move to" in the row menus**

In `SessionListView.menu(for:)` (`ProjectSidebar.swift`), before the `if let file = item.session.savedTarget?.transcriptFile` block:

```swift
    if let candidate = SessionMoves.candidate(for: item) {
      let others = SessionMoves.destinations(from: candidate.account)
      if !others.isEmpty {
        Divider()
        Menu("Move to") {
          ForEach(others, id: \.key) { account in
            Button(AccountStore.shared.profile(for: account).name) {
              SessionMoves.moveOne(candidate, to: account)
            }
          }
        }
      }
    }
```

Add a menu for summary rows in `SessionListView`:

```swift
  /// An elsewhere row running in another process cannot move; the menu says where it runs.
  @ViewBuilder private func moveMenu(for summary: SessionSummary, host: String?) -> some View {
    let others = SessionMoves.destinations(from: summary.account)
    if !others.isEmpty {
      Menu("Move to") {
        ForEach(others, id: \.key) { account in
          Button(AccountStore.shared.profile(for: account).name) {
            SessionMoves.moveOne(SessionMoves.candidate(for: summary), to: account)
          }
          .disabled(host != nil)
        }
        if let host {
          Text("Running in \(host)")
        }
      }
    }
  }
```

and attach it: on the elsewhere `SummaryRow` add `.contextMenu { moveMenu(for: summary, host: monitor.host(of: summary)) }` (an elsewhere row is live by definition), and on the ended `SummaryRow` add `.contextMenu { moveMenu(for: summary, host: nil) }`.

- [ ] **Step 4: Build and run the suites**

Run: `cd apps/apple && make build && make test-app && make test`
Expected: `** BUILD SUCCEEDED **`, then both suites PASS.

- [ ] **Step 5: Format and commit**

```bash
A=apps/apple
xcrun swift-format format --in-place $A/Drakar/Services/SessionMoves.swift $A/Drakar/Views/AccountToolbarItem.swift $A/Drakar/Views/ProjectSidebar.swift
git add $A/Drakar/Services/SessionMoves.swift $A/Drakar/Views/AccountToolbarItem.swift $A/Drakar/Views/ProjectSidebar.swift
git commit -m "feat(apple): picking another account offers to move the folder's sessions, and a row moves one"
```

- [ ] **Step 6: Check it in the running app (only with the person's go-ahead)**

`make run` quits whatever Drakar is running, including one another session launched from the main checkout. Ask first. Then, through cupertino-desktop's accessibility tree (screenshots come out black on this Mac):
- in a scratch folder, start a session on Personal (one short prompt on haiku), let it finish;
- open `window.account`, press `account.row..claude-skitrust`, accept "Move this folder's 1 session…";
- the summary alert reads "Moved 1 session to Skitrust."; `ls ~/.claude-skitrust/projects/<folder name>/` holds the transcript and `~/.claude/projects/<folder name>/` no longer does;
- prompt the session again: it resumes (its transcript keeps growing under `~/.claude-skitrust`);
- move it back with the row's Move to ▸ Personal.
