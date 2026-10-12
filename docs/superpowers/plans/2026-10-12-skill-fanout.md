# Run a Skill in Each Subfolder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From a skill's context menu (or Session › Run Skill in Subfolders…), start one session per immediate subfolder of a parent folder, each running that skill, all at once or at most N at a time.

**Architecture:** Three pure DrakarKit pieces (`SubfolderScan`, `FanOut`, `SkillReach`) carry the logic and are unit-tested offline. The app adds `Project.runInSubfolders` (sessions made up front, prompts sent as the `FanOut` allows, slots freed from the existing `onTurnEnded`/`onStopped` hooks in `Project.make`), an `@Observable` `FanOutDraft` behind a SwiftUI sheet, a banner per running batch, and a subfolder label on session rows.

**Tech Stack:** Swift 6, SwiftUI (macOS), Swift Testing (`import Testing`, `@Test`, `#expect`), DrakarKit SwiftPM package.

**Spec:** `docs/superpowers/specs/2026-10-12-skill-fanout-design.md`

## Global Constraints

- Work in the sibling worktree `~/Projects/apps/drakar-skill-fanout` on `feat/skill-fanout`; never switch branches or stash in `~/Projects/apps/drakar` (other sessions commit there).
- Commands below run from `apps/apple/` inside the worktree.
- DrakarKit tests: `swift test --package-path Packages/DrakarKit --filter <Suite>`. App tests: `xcodebuild test -project Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath .build -only-testing:DrakarTests/<Suite>`.
- Known timing flakes in a full `make test-app`: `CapabilityProbeTests` (two tests) and `AgentSessionTests.aSessionOpenedElsewhereDuringTheStartIsNotWritten`; rerun alone before calling them regressions.
- Code style: 2-space indent, `///` doc comments in the house voice (plain sentences, what it is, not how), `String(localized:)` for UI text, swift-format (`make format-swift-check` must pass).
- Session name: exactly `"/<skill> · <folder name>"` (middle dot U+00B7 with a space each side).
- Prompt: `"/<skill>"`, plus `" " + arguments` when the trimmed arguments are not empty.
- A limit of nil, 0 or less means unlimited. Default in the sheet: empty (unlimited).
- "Git repositories only" is on by default. Hidden folders (name starting with `.`) are never listed.
- Sessions live in the window the batch started from. The batch is not persisted.
- Commit messages: `feat(apple): …` / `test(apple): …` as in `git log`.

## Review Focus

1. **A waiting session the person closes or dismisses before its turn** — the batch must not stall: the slot logic skips a session no longer in `project.sessions` and moves to the next. Test in Task 4 (`aClosedWaitingSessionIsSkipped`).
2. **A session that fails to start (folder gone, CLI exits at once)** — it stops, which must free its slot so the queue moves on. Test in Task 4 (`aSessionThatStopsFreesItsSlot`).
3. **A turn end reported twice for the same session (turn end, then stop)** — must free only one slot. Test in Task 2 (`finishingTwiceFreesOneSlot`).
4. **A skill whose origin Drakar can't place (managed settings, another source)** — must not be marked "Not available here" in every folder; unknown means reachable. Test in Task 3 (`anUnknownSkillIsReachableEverywhere`).
5. **Session rows for sessions in the project folder itself or in a `.claude/worktrees/…` folder** — no subfolder label (the worktree keeps its own). Test in Task 1 (`noChildForTheRootOrAHiddenFolder`).

---

## File Structure

| File | Responsibility |
| --- | --- |
| Create `Packages/DrakarKit/Sources/DrakarKit/SubfolderScan.swift` | List a parent's immediate visible child folders, marking git repositories. |
| Modify `Packages/DrakarKit/Sources/DrakarKit/ProjectPath.swift` | `ProjectPath.child(of:below:)`: the first visible path component of a session folder below a project. |
| Create `Packages/DrakarKit/Sources/DrakarKit/FanOut.swift` | The pure batch state machine: waiting/running/finished/cancelled, limit, summary text. |
| Create `Packages/DrakarKit/Sources/DrakarKit/Skills/SkillReach.swift` | Which subfolders Claude Code would not find a skill in. |
| Modify `Drakar/Services/Project.swift` | `newSession(select:)`, `FanOutBatch`, `fanOuts`, `fanOutRequest`, `runInSubfolders`, `cancelFanOut(_:)`, slot freeing in `make`. |
| Create `Drakar/Services/FanOutDraft.swift` | The sheet's model: rows, ticks, git filter, reach (Claude scan + Codex store), arguments, mode, limit, `start()`. |
| Create `Drakar/Views/SkillFanOutSheet.swift` | The sheet UI, and its skill picker for the Session menu. |
| Modify `Drakar/Views/InspectorView.swift` | "Run in Each Subfolder…" in the skill context menu. |
| Modify `Drakar/DrakarApp.swift` | Session › Run Skill in Subfolders…. |
| Modify `Drakar/ContentView.swift` | Present the sheet from `project.fanOutRequest`. |
| Modify `Drakar/Views/ProjectSidebar.swift` | Banner per batch; subfolder in `SessionRow`'s detail line. |
| Tests | `Packages/DrakarKit/Tests/DrakarKitTests/{SubfolderScanTests,FanOutTests,SkillReachTests}.swift`, `DrakarTests/{ProjectFanOutTests,FanOutDraftTests}.swift`. |

---

### Task 1: SubfolderScan and ProjectPath.child

**Files:**
- Create: `Packages/DrakarKit/Sources/DrakarKit/SubfolderScan.swift`
- Modify: `Packages/DrakarKit/Sources/DrakarKit/ProjectPath.swift` (add one function in the `ProjectPath` enum)
- Test: `Packages/DrakarKit/Tests/DrakarKitTests/SubfolderScanTests.swift`

**Interfaces:**
- Produces:
  - `public struct Subfolder: Sendable, Hashable, Identifiable { public var url: URL; public var name: String; public var isGitRepository: Bool; public var id: URL { url } }`
  - `public enum SubfolderScan { public static func children(of parent: URL) -> [Subfolder] }`
  - `ProjectPath.child(of path: String, below root: String) -> String?`

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("A parent folder's subfolders")
struct SubfolderScanTests {
  private let parent: URL

  init() throws {
    parent = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-subfolders-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  }

  private func folder(_ name: String) throws -> URL {
    let url = parent.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Folders only, hidden ones skipped, in Finder's order (2 before 10).
  @Test func listsVisibleFoldersInFinderOrder() throws {
    _ = try folder("app10")
    _ = try folder("app2")
    _ = try folder(".cache")
    try Data().write(to: parent.appending(path: "README.md"))
    #expect(SubfolderScan.children(of: parent).map(\.name) == ["app2", "app10"])
  }

  /// A `.git` folder, or a `.git` file (a linked worktree), makes a repository.
  @Test func marksGitRepositories() throws {
    try FileManager.default.createDirectory(
      at: try folder("repo").appending(path: ".git"), withIntermediateDirectories: true)
    try Data("gitdir: /elsewhere\n".utf8).write(to: try folder("worktree").appending(path: ".git"))
    _ = try folder("plain")
    let found = Dictionary(
      uniqueKeysWithValues: SubfolderScan.children(of: parent).map { ($0.name, $0.isGitRepository) })
    #expect(found == ["plain": false, "repo": true, "worktree": true])
  }

  /// A link to a folder is a folder; a link to a file, or to nothing, is not.
  @Test func followsLinksToFolders() throws {
    let target = try folder("target")
    try FileManager.default.createSymbolicLink(
      at: parent.appending(path: "linked"), withDestinationURL: target)
    try FileManager.default.createSymbolicLink(
      at: parent.appending(path: "dangling"),
      withDestinationURL: parent.appending(path: "gone"))
    #expect(SubfolderScan.children(of: parent).map(\.name) == ["linked", "target"])
  }

  /// A parent that can't be read has no subfolders.
  @Test func aMissingParentHasNone() {
    #expect(SubfolderScan.children(of: parent.appending(path: "nope")).isEmpty)
  }

  /// The first component below the project, for a session in a subfolder.
  @Test func childOfASessionFolder() {
    #expect(ProjectPath.child(of: "/p/apps/drakar/src", below: "/p/apps") == "drakar")
    #expect(ProjectPath.child(of: "/p/apps/drakar/", below: "/p/apps/") == "drakar")
    #expect(ProjectPath.child(of: "/p/other", below: "/p/apps") == nil)
  }

  /// None for the project itself, nor below a hidden folder (a worktree has its own label).
  @Test func noChildForTheRootOrAHiddenFolder() {
    #expect(ProjectPath.child(of: "/p/apps", below: "/p/apps") == nil)
    #expect(ProjectPath.child(of: "/p/apps/.claude/worktrees/x", below: "/p/apps") == nil)
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path Packages/DrakarKit --filter SubfolderScanTests`
Expected: build failure, `cannot find 'SubfolderScan' in scope`.

- [ ] **Step 3: Implement**

`Packages/DrakarKit/Sources/DrakarKit/SubfolderScan.swift`:

```swift
import Foundation

/// One folder directly inside a parent, as a batch of sessions can start in it.
public struct Subfolder: Sendable, Hashable, Identifiable {
  public var url: URL
  public var name: String
  /// It holds a `.git` folder, or a `.git` file as a linked worktree does.
  public var isGitRepository: Bool

  public var id: URL { url }

  public init(url: URL, name: String, isGitRepository: Bool) {
    self.url = url
    self.name = name
    self.isGitRepository = isGitRepository
  }
}

/// A parent folder's immediate subfolders (docs/superpowers/specs/2026-10-12-skill-fanout-design.md
/// §1): folders and links to folders, hidden ones left out, in Finder's order. Reads the
/// listing and one entry per child, nothing deeper.
public enum SubfolderScan {
  public static func children(of parent: URL) -> [Subfolder] {
    let manager = FileManager.default
    let root = ProjectPath.normalize(parent.path(percentEncoded: false))
    let names = (try? manager.contentsOfDirectory(atPath: root)) ?? []
    return names.filter { !$0.hasPrefix(".") }
      .compactMap { name -> Subfolder? in
        let path = root + "/" + name
        var isFolder: ObjCBool = false
        // `fileExists` follows links: a link to a folder is one, a dangling link is nothing.
        guard manager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue
        else { return nil }
        return Subfolder(
          url: URL(filePath: path, directoryHint: .isDirectory), name: name,
          isGitRepository: manager.fileExists(atPath: path + "/.git"))
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
```

In `ProjectPath.swift`, inside `public enum ProjectPath`, after `contains(_:_:)`:

```swift
  /// The first component of `path` below `root`: the subfolder a session runs in. Nil for
  /// `root` itself, a path outside it, or one below a hidden folder (a worktree in
  /// `.claude/worktrees` is labelled by its own name).
  public static func child(of path: String, below root: String) -> String? {
    let (path, root) = (normalize(path), normalize(root))
    guard path != root, contains(root, path) else { return nil }
    let rest = path.dropFirst(root.count).drop { $0 == "/" }
    guard let first = rest.split(separator: "/").first, !first.hasPrefix(".") else {
      return nil
    }
    return String(first)
  }
```

(Check `normalize` drops a trailing `/` and `contains` is true for `root` itself or a path below it — read lines 6-28 of `ProjectPath.swift` first; if `contains` differs, adjust the guard so the tests pass.)

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --package-path Packages/DrakarKit --filter SubfolderScanTests`
Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Packages/DrakarKit/Sources/DrakarKit/SubfolderScan.swift Packages/DrakarKit/Sources/DrakarKit/ProjectPath.swift Packages/DrakarKit/Tests/DrakarKitTests/SubfolderScanTests.swift
git commit -m "feat(apple): DrakarKit lists a folder's subfolders, and the one a session runs in"
```

---

### Task 2: FanOut, the batch's state

**Files:**
- Create: `Packages/DrakarKit/Sources/DrakarKit/FanOut.swift`
- Test: `Packages/DrakarKit/Tests/DrakarKitTests/FanOutTests.swift`

**Interfaces:**
- Produces:

```swift
public struct FanOut<ID: Hashable & Sendable>: Sendable {
  public enum State: Sendable, Equatable { case waiting, running, finished, cancelled }
  public let ids: [ID]
  public let limit: Int?            // nil: unlimited (0 or less given means nil)
  public init(ids: [ID], limit: Int?)
  public func state(of id: ID) -> State?
  public func count(_ state: State) -> Int
  public var isDone: Bool           // nothing waiting or running
  public var summary: String        // "4 running · 8 waiting · 3 done", zero parts left out
  public mutating func start() -> [ID]
  public mutating func finished(_ id: ID) -> [ID]
  public mutating func cancel() -> [ID]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Testing

@Suite("A skill's batch of sessions")
struct FanOutTests {
  /// Unlimited: every one starts at once.
  @Test func unlimitedStartsAll() {
    var batch = FanOut(ids: [1, 2, 3], limit: nil)
    #expect(batch.start() == [1, 2, 3])
    #expect(batch.count(.running) == 3)
    #expect(!batch.isDone)
  }

  /// 0 or less is unlimited too.
  @Test func aLimitOfZeroIsUnlimited() {
    var batch = FanOut(ids: [1, 2], limit: 0)
    #expect(batch.limit == nil)
    #expect(batch.start() == [1, 2])
  }

  /// With a limit, that many start, then one per finished one, in order.
  @Test func aLimitStartsThatManyThenOneEach() {
    var batch = FanOut(ids: [1, 2, 3, 4], limit: 2)
    #expect(batch.start() == [1, 2])
    #expect(batch.finished(2) == [3])
    #expect(batch.finished(1) == [4])
    #expect(batch.finished(3) == [])
    #expect(batch.finished(4) == [])
    #expect(batch.isDone)
  }

  /// A turn end then a stop for the same session frees one slot, not two.
  @Test func finishingTwiceFreesOneSlot() {
    var batch = FanOut(ids: [1, 2, 3], limit: 1)
    _ = batch.start()
    #expect(batch.finished(1) == [2])
    #expect(batch.finished(1) == [])
    #expect(batch.state(of: 3) == .waiting)
  }

  /// One finished before it was sent (closed while waiting) frees nothing; an unknown id
  /// changes nothing.
  @Test func finishingAWaitingOneFreesNothing() {
    var batch = FanOut(ids: [1, 2, 3], limit: 1)
    _ = batch.start()
    #expect(batch.finished(3) == [])
    #expect(batch.state(of: 3) == .finished)
    #expect(batch.finished(99) == [])
    #expect(batch.finished(1) == [2])
  }

  /// Cancel returns the waiting ones only; the running ones keep running.
  @Test func cancelReturnsTheWaiting() {
    var batch = FanOut(ids: [1, 2, 3], limit: 1)
    _ = batch.start()
    #expect(batch.cancel() == [2, 3])
    #expect(batch.state(of: 1) == .running)
    #expect(!batch.isDone)
    #expect(batch.finished(1) == [])
    #expect(batch.isDone)
  }

  /// The banner's counts, zero ones left out.
  @Test func summary() {
    var batch = FanOut(ids: [1, 2, 3, 4], limit: 2)
    _ = batch.start()
    _ = batch.finished(1)
    #expect(batch.summary == "2 running · 1 waiting · 1 done")
    _ = batch.cancel()
    #expect(batch.summary == "2 running · 1 done")
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path Packages/DrakarKit --filter FanOutTests`
Expected: build failure, `cannot find 'FanOut' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// A skill sent to many sessions, at most `limit` at a time
/// (docs/superpowers/specs/2026-10-12-skill-fanout-design.md §4). Pure: the caller sends the
/// prompts this returns and says when a session is done with its turn.
public struct FanOut<ID: Hashable & Sendable>: Sendable {
  public enum State: Sendable, Equatable { case waiting, running, finished, cancelled }

  /// In the order they start.
  public let ids: [ID]
  /// How many run at once; nil for all.
  public let limit: Int?
  private var states: [ID: State]

  public init(ids: [ID], limit: Int?) {
    self.ids = ids
    self.limit = limit.flatMap { $0 > 0 ? $0 : nil }
    states = Dictionary(ids.map { ($0, State.waiting) }, uniquingKeysWith: { first, _ in first })
  }

  public func state(of id: ID) -> State? { states[id] }

  public func count(_ state: State) -> Int { states.values.count { $0 == state } }

  /// Nothing waits or runs.
  public var isDone: Bool { count(.waiting) == 0 && count(.running) == 0 }

  /// "4 running · 8 waiting · 3 done", the counts that are not zero.
  public var summary: String {
    [
      (count(.running), String(localized: "running")),
      (count(.waiting), String(localized: "waiting")),
      (count(.finished), String(localized: "done")),
    ]
    .filter { $0.0 > 0 }
    .map { "\($0.0) \($0.1)" }
    .joined(separator: " · ")
  }

  /// The ones to send now: all, or the first `limit`.
  public mutating func start() -> [ID] { next() }

  /// `id` is done with its turn, or stopped. Returns the one to send in its place, if it held
  /// a slot and one waits. Again for the same id, or for an unknown one, nothing.
  public mutating func finished(_ id: ID) -> [ID] {
    guard let state = states[id], state == .running || state == .waiting else { return [] }
    states[id] = .finished
    return state == .running ? next() : []
  }

  /// The waiting ones, which will not be sent now. The running ones go on.
  public mutating func cancel() -> [ID] {
    let waiting = ids.filter { states[$0] == .waiting }
    for id in waiting { states[id] = .cancelled }
    return waiting
  }

  private mutating func next() -> [ID] {
    let free = limit.map { max(0, $0 - count(.running)) } ?? ids.count
    let starting = Array(ids.filter { states[$0] == .waiting }.prefix(free))
    for id in starting { states[id] = .running }
    return starting
  }
}
```

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --package-path Packages/DrakarKit --filter FanOutTests`
Expected: 7 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Packages/DrakarKit/Sources/DrakarKit/FanOut.swift Packages/DrakarKit/Tests/DrakarKitTests/FanOutTests.swift
git commit -m "feat(apple): DrakarKit's FanOut sends a skill to many sessions, a few at a time"
```

---

### Task 3: SkillReach, where Claude Code would not find a skill

**Files:**
- Create: `Packages/DrakarKit/Sources/DrakarKit/Skills/SkillReach.swift`
- Test: `Packages/DrakarKit/Tests/DrakarKitTests/SkillReachTests.swift`

**Interfaces:**
- Consumes: `ClaudeSkillScan.scan(account:project:)`, the internal `ClaudeSkillScan.skills(in:origin:)` and `ClaudeSkillScan.commands(in:origin:)` (same module).
- Produces: `public enum SkillReach { public static func claudeMissing(name: String, isBuiltin: Bool, account: URL, parent: URL, folders: [URL]) -> Set<URL> }`

Rule (spec §2): nothing is missing when the skill is the CLI's own, the account's, or a plugin's, or when the parent folder does not hold it as a project skill (its origin is one Drakar cannot place: treat it as reachable). Otherwise a folder is missing it unless its own `.claude/skills` or `.claude/commands` holds that name.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Which subfolders Claude Code finds a skill in")
struct SkillReachTests {
  private let root: URL
  private let account: URL
  private let parent: URL
  private let one: URL
  private let two: URL

  init() throws {
    root = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-reach-\(UUID().uuidString)", directoryHint: .isDirectory)
    account = root.appending(path: ".claude-test", directoryHint: .isDirectory)
    parent = root.appending(path: "apps", directoryHint: .isDirectory)
    one = parent.appending(path: "one", directoryHint: .isDirectory)
    two = parent.appending(path: "two", directoryHint: .isDirectory)
    for folder in [account, one, two] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  private func skill(_ name: String, in folder: URL) throws {
    let dir = folder.appending(path: "skills/\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("---\nname: \(name)\n---\n".utf8).write(to: dir.appending(path: "SKILL.md"))
  }

  private func missing(_ name: String, builtin: Bool = false) -> Set<URL> {
    SkillReach.claudeMissing(
      name: name, isBuiltin: builtin, account: account, parent: parent, folders: [one, two])
  }

  /// The account's skills reach every folder.
  @Test func aUserSkillIsEverywhere() throws {
    try skill("check", in: account)
    #expect(missing("check").isEmpty)
  }

  /// The CLI's own reach every folder.
  @Test func aBuiltinIsEverywhere() {
    #expect(missing("compact", builtin: true).isEmpty)
  }

  /// One from the parent's `.claude/skills` reaches only the folders holding their own.
  @Test func aParentProjectSkillIsMissingWhereNotHeld() throws {
    try skill("deploy", in: parent.appending(path: ".claude"))
    try skill("deploy", in: one.appending(path: ".claude"))
    #expect(missing("deploy") == [two])
  }

  /// A project command counts as held too.
  @Test func aCommandCountsAsHeld() throws {
    try skill("ship", in: parent.appending(path: ".claude"))
    let commands = two.appending(path: ".claude/commands", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
    try Data("Ship it\n".utf8).write(to: commands.appending(path: "ship.md"))
    #expect(missing("ship") == [one])
  }

  /// One Drakar finds nowhere (managed settings, a source it doesn't read) is not marked
  /// missing everywhere: unknown is reachable.
  @Test func anUnknownSkillIsReachableEverywhere() {
    #expect(missing("mystery").isEmpty)
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path Packages/DrakarKit --filter SkillReachTests`
Expected: build failure, `cannot find 'SkillReach' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Where a session would not find a skill (docs/superpowers/specs/2026-10-12-skill-fanout-design.md
/// §2). Claude Code reads the account's skills, its plugins', and the session folder's own
/// `.claude`; not a parent folder's.
public enum SkillReach {
  /// The folders among `folders` whose sessions would not find `name`. None when it is the
  /// CLI's own, the account's or a plugin's, or when `parent` does not hold it either: a
  /// skill from somewhere Drakar doesn't read is taken to be found.
  public static func claudeMissing(
    name: String, isBuiltin: Bool, account: URL, parent: URL, folders: [URL]
  ) -> Set<URL> {
    guard !isBuiltin,
      !ClaudeSkillScan.scan(account: account, project: nil).skills.contains(where: {
        $0.name == name
      }),
      projectNames(parent).contains(name)
    else { return [] }
    return Set(folders.filter { !projectNames($0).contains(name) })
  }

  /// The skills and commands in `folder/.claude`.
  private static func projectNames(_ folder: URL) -> Set<String> {
    let own = folder.appending(path: ".claude", directoryHint: .isDirectory)
    let skills = ClaudeSkillScan.skills(in: own.appending(path: "skills"), origin: .project)
    let commands = ClaudeSkillScan.commands(in: own.appending(path: "commands"), origin: .project)
    return Set((skills + commands).map(\.name))
  }
}
```

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --package-path Packages/DrakarKit --filter SkillReachTests`
Expected: 5 tests passed. Then the whole kit: `swift test --package-path Packages/DrakarKit` — all pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/DrakarKit/Sources/DrakarKit/Skills/SkillReach.swift Packages/DrakarKit/Tests/DrakarKitTests/SkillReachTests.swift
git commit -m "feat(apple): DrakarKit tells which subfolders a parent's project skill doesn't reach"
```

---

### Task 4: Project.runInSubfolders and freeing slots

**Files:**
- Modify: `Drakar/Services/Project.swift` — `newSession` (around line 423), `run(_:in:)` neighbourhood (add after it, ~line 513), `make(_:)` (~line 799)
- Test: `DrakarTests/ProjectFanOutTests.swift`

**Interfaces:**
- Consumes: `FanOut<UUID>` (Task 2).
- Produces (in `Project.swift`):

```swift
/// A skill run in each of several folders: the sessions and what is left to send them.
@Observable final class FanOutBatch: Identifiable {
  let id = UUID()
  let skillName: String
  let prompt: String
  var queue: FanOut<UUID>
}

/// The sheet asked for, on a skill or (from the Session menu) to pick one.
struct FanOutRequest: Identifiable {
  let id = UUID()
  var skill: SkillEntry?
}

// On Project:
private(set) var fanOuts: [FanOutBatch]
var fanOutRequest: FanOutRequest?
@discardableResult func newSession(agent: AgentKind? = nil, folder: URL? = nil, select shows: Bool = true) -> ProjectSession
func runInSubfolders(_ skill: SkillEntry, folders: [URL], arguments: String, mode: PermissionMode?, limit: Int?)
func cancelFanOut(_ batch: FanOutBatch)
```

- [ ] **Step 1: Write the failing tests**

`DrakarTests/ProjectFanOutTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Running a skill in each subfolder")
struct ProjectFanOutTests {
  private let parent: URL
  private let folders: [URL]
  private let check = SkillEntry(name: "check", description: "Fix it")
  private let audit = SkillEntry(name: "audit", argumentHint: "<area>")

  init() throws {
    parent = FileManager.default.temporaryDirectory.appending(
      path: "drakar-fanout-\(UUID().uuidString)", directoryHint: .isDirectory)
    folders = ["alpha", "beta", "gamma"].map {
      parent.appending(path: $0, directoryHint: .isDirectory)
    }
    for folder in folders {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  /// A stand-in CLI that reads forever (`cat`), or one that exits at once.
  private func standIn(exits: Bool = false) throws -> URL {
    let script = parent.appending(path: exits ? "claude-exits" : "claude")
    try Data((exits ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\ncat > /dev/null\n").utf8)
      .write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func prompts(_ item: ProjectSession) -> [String] {
    item.session.transcript.entries.compactMap {
      if case .prompt(let text) = $0.kind { text } else { nil }
    }
  }

  /// One session per folder, named after the skill and the folder, on top in folder order,
  /// the first shown; unlimited, each is sent the skill.
  @Test func oneSessionPerFolder() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: nil)
    #expect(project.sessions.prefix(3).map(\.displayTitle)
      == ["/check · alpha", "/check · beta", "/check · gamma"])
    #expect(project.sessions.prefix(3).map(\.session.folder.lastPathComponent)
      == ["alpha", "beta", "gamma"])
    #expect(project.selected?.id == project.sessions.first?.id)
    for item in project.sessions.prefix(3) { #expect(prompts(item) == ["/check"]) }
    #expect(project.fanOuts.count == 1)
  }

  /// Arguments follow the name; blank ones are left out.
  @Test func argumentsFollowTheName() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(audit, folders: [folders[0]], arguments: "  auth  ", mode: nil, limit: nil)
    #expect(prompts(try #require(project.sessions.first)) == ["/audit auth"])
  }

  /// The mode picked goes to every session.
  @Test func theModeGoesToEach() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: .plan, limit: 1)
    for item in project.sessions.prefix(3) { #expect(item.session.startingMode == .plan) }
  }

  /// With a limit, that many are sent; a turn end sends the next.
  @Test func aLimitSendsTheNextOnATurnEnd() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 2)
    let items = Array(project.sessions.prefix(3))
    #expect(items.map { prompts($0).count } == [1, 1, 0])
    items[0].session.onTurnEnded?()
    #expect(prompts(items[2]) == ["/check"])
  }

  /// A session that stops without a turn end (it could not start) frees its slot too.
  @Test func aSessionThatStopsFreesItsSlot() async throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn(exits: true)
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let last = try #require(project.sessions.dropFirst(2).first)
    // Each stand-in exits at once; the stops walk the queue to the last.
    for _ in 0..<100 where prompts(last).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(prompts(last) == ["/check"])
  }

  /// A waiting session closed before its turn is skipped, not waited for.
  @Test func aClosedWaitingSessionIsSkipped() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.close(items[1])
    items[0].session.onTurnEnded?()
    #expect(prompts(items[2]) == ["/check"])
  }

  /// Cancel leaves the waiting ones unsent; the batch goes once the running one is done.
  @Test func cancelLeavesTheWaitingUnsent() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.cancelFanOut(try #require(project.fanOuts.first))
    items[0].session.onTurnEnded?()
    #expect(prompts(items[1]).isEmpty)
    #expect(prompts(items[2]).isEmpty)
    #expect(project.fanOuts.isEmpty)
  }
}
```

Before running: check how `Project` removes a held session (grep `func close\|func dismiss` in `Project.swift`) and use that method's real name in `aClosedWaitingSessionIsSkipped` in place of `close(_:)`. Check the transcript entry kind for a prompt (`.prompt(String)`, as `SkillRunTests.aCodexSessionRunsOneByName` uses).

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -project Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath .build -only-testing:DrakarTests/ProjectFanOutTests`
Expected: build failure, `value of type 'Project' has no member 'runInSubfolders'`.

- [ ] **Step 3: Implement**

At the top of `Project.swift`, next to `enum SkillTarget`:

```swift
/// A skill run in each of several folders: its sessions, and what is left to send them
/// (docs/superpowers/specs/2026-10-12-skill-fanout-design.md).
@Observable
final class FanOutBatch: Identifiable {
  let id = UUID()
  let skillName: String
  let prompt: String
  var queue: FanOut<UUID>

  init(skillName: String, prompt: String, queue: FanOut<UUID>) {
    self.skillName = skillName
    self.prompt = prompt
    self.queue = queue
  }
}

/// The Run in Each Subfolder sheet, on a skill, or with none yet to pick one.
struct FanOutRequest: Identifiable {
  let id = UUID()
  var skill: SkillEntry?
}
```

In `Project`, near the other stored properties:

```swift
  /// The batches still sending or running, one banner each; not saved with the window.
  private(set) var fanOuts: [FanOutBatch] = []
  /// The Run in Each Subfolder sheet, while shown.
  var fanOutRequest: FanOutRequest?
```

Replace `newSession`:

```swift
  /// A new session in `folder` (the project's when nil), on top, running `agent` (Settings'
  /// default when nil), and shown unless `shows` is false. No process until it is prompted.
  @discardableResult func newSession(
    agent: AgentKind? = nil, folder: URL? = nil, select shows: Bool = true
  ) -> ProjectSession {
    let item = make(
      AgentSession(folder: folder ?? self.folder, agent: agent ?? ClaudeChoice.defaultAgent))
    sessions.insert(item, at: 0)
    if shows { select(item) }
    return item
  }
```

After `run(_:in:)`:

```swift
  /// `skill` in a new session in each of `folders`, on top in their order, the first shown:
  /// named after the skill and the folder, in `mode` when given, and sent the skill all at
  /// once or `limit` at a time.
  func runInSubfolders(
    _ skill: SkillEntry, folders: [URL], arguments: String, mode: PermissionMode?, limit: Int?
  ) {
    guard !folders.isEmpty else { return }
    let agent = skillsAgent
    if agent == .claude { capabilityMarks.skills.remove(skill.name) }
    // Each goes on top, so the last folder first leaves them in order.
    let items = folders.reversed().map { folder in
      let item = newSession(agent: agent, folder: folder, select: false)
      item.session.rename(to: "/\(skill.name) · \(folder.lastPathComponent)")
      if let mode { item.session.setMode(mode) }
      return item
    }.reversed()
    if let first = items.first { select(first) }
    let arguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    let batch = FanOutBatch(
      skillName: skill.name,
      prompt: arguments.isEmpty ? "/\(skill.name)" : "/\(skill.name) \(arguments)",
      queue: FanOut(ids: items.map(\.id), limit: limit))
    fanOuts.append(batch)
    send(batch.queue.start(), in: batch)
  }

  /// The waiting sessions of `batch` are not sent; those running go on.
  func cancelFanOut(_ batch: FanOutBatch) {
    _ = batch.queue.cancel()
    fanOuts.removeAll { $0.queue.isDone }
  }

  /// `item` ended a turn or stopped: its slot goes to the next waiting session.
  private func fanOutFinished(_ item: ProjectSession) {
    for batch in fanOuts { send(batch.queue.finished(item.id), in: batch) }
    fanOuts.removeAll { $0.queue.isDone }
  }

  /// Sends `batch`'s prompt to `ids`; one closed meanwhile passes its slot on.
  private func send(_ ids: [UUID], in batch: FanOutBatch) {
    for id in ids {
      guard let item = sessions.first(where: { $0.id == id }) else {
        send(batch.queue.finished(id), in: batch)
        continue
      }
      item.session.send(batch.prompt)
    }
  }
```

In `make(_:)`, call `fanOutFinished` first in both closures (before their guards):

```swift
    session.onTurnEnded = { [weak self, weak item] in
      guard let self, let item else { return }
      self.fanOutFinished(item)
      if item.id != self.selectedID { item.isUnread = true }
      Attention.shared.turnEnded(item, in: self)
    }
```

```swift
    session.onStopped = { [weak self, weak item] in
      Attention.shared.refresh()
      guard let self, let item else { return }
      self.fanOutFinished(item)
      guard item.id != self.selectedID, item.hasStopped else { return }
      item.isUnread = true
    }
```

If closing a waiting session removes it from `sessions` without stopping (it never had a process), `aClosedWaitingSessionIsSkipped` covers it through `send`'s guard.

- [ ] **Step 4: Run them to see them pass**

Run: `xcodebuild test -project Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath .build -only-testing:DrakarTests/ProjectFanOutTests -only-testing:DrakarTests/SkillRunTests -only-testing:DrakarTests/ProjectTests`
Expected: all pass (SkillRunTests and ProjectTests guard the `newSession` and `make` changes).

If `aSessionThatStopsFreesItsSlot` fails because a start failure does not call `onStopped`, read `AgentSession`'s exit path (`grep -n "onStopped" Drakar/Services/AgentSession.swift`) and find the event the session reports when its process ends; free the slot from there. Do not weaken the test.

- [ ] **Step 5: Commit**

```bash
git add Drakar/Services/Project.swift DrakarTests/ProjectFanOutTests.swift
git commit -m "feat(apple): a project runs a skill in a session per folder, a few at a time if asked"
```

---

### Task 5: FanOutDraft, the sheet's model

**Files:**
- Create: `Drakar/Services/FanOutDraft.swift`
- Test: `DrakarTests/FanOutDraftTests.swift`

**Interfaces:**
- Consumes: `SubfolderScan.children(of:)`, `Subfolder` (Task 1); `SkillReach.claudeMissing` (Task 3); `Project.runInSubfolders`, `Project.skillsAgent` (Task 4); `CodexSkillStore.shared.skills(for:)` (existing, `Drakar/Services/CodexSkills.swift`); `AccountStore.shared.windowAccount(for:)` (existing, returns `ClaudeAccount` with `.directory`).
- Produces:

```swift
@Observable final class FanOutDraft {
  let skill: SkillEntry
  let agent: AgentKind
  private(set) var parent: URL
  private(set) var folders: [Subfolder]
  var gitOnly: Bool                 // default true
  var arguments: String
  var mode: PermissionMode?         // nil: Settings' default
  var limitText: String             // "" = unlimited
  init(skill: SkillEntry, agent: AgentKind, parent: URL, account: URL,
       codexSkills: @escaping (URL) -> CodexSkills = { CodexSkillStore.shared.skills(for: $0) })
  func change(parent: URL)
  var shown: [Subfolder]            // folders, git ones only when gitOnly
  func reaches(_ folder: Subfolder) -> Bool
  func isTicked(_ folder: Subfolder) -> Bool
  func setTicked(_ folder: Subfolder, _ ticked: Bool)
  func tickAll(_ ticked: Bool)      // the shown ones
  var chosen: [URL]                 // shown and ticked, in order
  var limit: Int?                   // Int(limitText), nil when empty, not a number or <= 0
  var reachUnchecked: Bool          // a Codex read failed: every folder taken to hold the skill
  func start(in project: Project)
}
```

Ticks: `overrides: [URL: Bool]` set by the person; otherwise a folder is ticked when the skill reaches it. Codex reach is read from each folder's `CodexSkills` (its `skills` is nil until read, or after a failed read): unknown is reachable, so ticks follow as reads come in unless the person has set one.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("The Run in Each Subfolder sheet")
struct FanOutDraftTests {
  private let root: URL
  private let account: URL
  private let parent: URL

  init() throws {
    root = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-draft-\(UUID().uuidString)", directoryHint: .isDirectory)
    account = root.appending(path: ".claude-test", directoryHint: .isDirectory)
    parent = root.appending(path: "apps", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
    for (name, git) in [("alpha", true), ("beta", true), ("notes", false)] {
      let folder = parent.appending(path: name, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      if git {
        try FileManager.default.createDirectory(
          at: folder.appending(path: ".git"), withIntermediateDirectories: true)
      }
    }
  }

  private func draft(_ skill: SkillEntry = SkillEntry(name: "check"), agent: AgentKind = .claude)
    -> FanOutDraft
  {
    FanOutDraft(skill: skill, agent: agent, parent: parent, account: account)
  }

  /// Git repositories only, by default; every one ticked.
  @Test func gitRepositoriesAreShownAndTicked() {
    let draft = draft()
    #expect(draft.shown.map(\.name) == ["alpha", "beta"])
    #expect(draft.chosen.map(\.lastPathComponent) == ["alpha", "beta"])
    draft.gitOnly = false
    #expect(draft.shown.map(\.name) == ["alpha", "beta", "notes"])
  }

  /// A tick taken off stays off; hidden rows are not chosen even when ticked.
  @Test func ticksAndTheFilter() {
    let draft = draft()
    draft.setTicked(draft.shown[0], false)
    #expect(draft.chosen.map(\.lastPathComponent) == ["beta"])
    draft.gitOnly = false
    draft.tickAll(true)
    #expect(draft.chosen.count == 3)
    draft.gitOnly = true
    #expect(draft.chosen.count == 2)
    draft.tickAll(false)
    #expect(draft.chosen.isEmpty)
  }

  /// A skill only the parent's project holds starts unticked where it is not held, and can
  /// be ticked.
  @Test func aParentOnlySkillStartsUnticked() throws {
    let skills = parent.appending(path: ".claude/skills/deploy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
    try Data("---\nname: deploy\n---\n".utf8).write(to: skills.appending(path: "SKILL.md"))
    let draft = draft(SkillEntry(name: "deploy"))
    #expect(draft.shown.map { draft.reaches($0) } == [false, false])
    #expect(draft.chosen.isEmpty)
    draft.setTicked(draft.shown[0], true)
    #expect(draft.chosen.map(\.lastPathComponent) == ["alpha"])
  }

  /// The limit: a positive number, or unlimited.
  @Test func theLimit() {
    let draft = draft()
    #expect(draft.limit == nil)
    draft.limitText = "3"
    #expect(draft.limit == 3)
    for text in ["0", "-2", "many", " "] {
      draft.limitText = text
      #expect(draft.limit == nil)
    }
  }

  /// Another parent lists its own folders, ticks set before forgotten.
  @Test func changingTheParent() throws {
    let draft = draft()
    draft.setTicked(draft.shown[0], false)
    let other = root.appending(path: "other/zeta", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: other.appending(path: ".git"), withIntermediateDirectories: true)
    draft.change(parent: other.deletingLastPathComponent())
    #expect(draft.chosen.map(\.lastPathComponent) == ["zeta"])
  }

  /// Start hands the chosen folders, arguments, mode and limit to the project.
  @Test func startRunsTheBatch() {
    let project = Project(folder: parent)
    let draft = draft(SkillEntry(name: "audit", argumentHint: "<area>"))
    draft.arguments = "auth"
    draft.mode = .plan
    draft.limitText = "1"
    draft.start(in: project)
    #expect(project.sessions.prefix(2).map(\.displayTitle) == ["/audit · alpha", "/audit · beta"])
    #expect(project.fanOuts.first?.prompt == "/audit auth")
    #expect(project.fanOuts.first?.queue.limit == 1)
    project.stopAll()
  }
}
```

(`startRunsTheBatch` sends to a real `claude` if one is on PATH; set `project.executableOverride` to a `cat` stand-in as `ProjectFanOutTests.standIn()` does, copying that helper into this suite.)

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -project Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath .build -only-testing:DrakarTests/FanOutDraftTests`
Expected: build failure, `cannot find 'FanOutDraft' in scope`.

- [ ] **Step 3: Implement**

```swift
import DrakarKit
import Foundation
import Observation

/// What the Run in Each Subfolder sheet holds until it starts the sessions
/// (docs/superpowers/specs/2026-10-12-skill-fanout-design.md §3).
@Observable
final class FanOutDraft {
  let skill: SkillEntry
  let agent: AgentKind
  private(set) var parent: URL
  private(set) var folders: [Subfolder] = []
  /// Only the folders holding a `.git`.
  var gitOnly = true
  var arguments = ""
  /// The mode each session starts in; nil for Settings' default.
  var mode: PermissionMode?
  /// How many run at once, as typed; empty for all.
  var limitText = ""

  @ObservationIgnored private let account: URL
  @ObservationIgnored private let codexSkills: (URL) -> CodexSkills
  /// Where Claude Code would not find the skill, read with the folders.
  private var claudeMissing: Set<URL> = []
  /// The ticks the person set; the others follow whether the skill reaches the folder.
  private var overrides: [URL: Bool] = [:]

  init(
    skill: SkillEntry, agent: AgentKind, parent: URL, account: URL,
    codexSkills: @escaping (URL) -> CodexSkills = { CodexSkillStore.shared.skills(for: $0) }
  ) {
    self.skill = skill
    self.agent = agent
    self.parent = parent
    self.account = account
    self.codexSkills = codexSkills
    read()
  }

  func change(parent: URL) {
    self.parent = parent
    overrides = [:]
    read()
  }

  var shown: [Subfolder] { gitOnly ? folders.filter(\.isGitRepository) : folders }

  /// Whether a session there would find the skill; unknown counts as found.
  func reaches(_ folder: Subfolder) -> Bool {
    switch agent {
    case .claude: return !claudeMissing.contains(folder.url)
    case .codex:
      guard let skills = codexSkills(folder.url).skills else { return true }
      return skills.contains { $0.name == skill.name }
    }
  }

  func isTicked(_ folder: Subfolder) -> Bool { overrides[folder.url] ?? reaches(folder) }

  func setTicked(_ folder: Subfolder, _ ticked: Bool) { overrides[folder.url] = ticked }

  func tickAll(_ ticked: Bool) {
    for folder in shown { overrides[folder.url] = ticked }
  }

  var chosen: [URL] { shown.filter(isTicked).map(\.url) }

  /// Codex could not say which folders hold the skill: every one is taken to.
  var reachUnchecked: Bool {
    agent == .codex && folders.contains { codexSkills($0.url).problem != nil }
  }

  var limit: Int? {
    Int(limitText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
  }

  func start(in project: Project) {
    project.runInSubfolders(
      skill, folders: chosen, arguments: arguments, mode: mode, limit: limit)
  }

  private func read() {
    folders = SubfolderScan.children(of: parent)
    switch agent {
    case .claude:
      claudeMissing = SkillReach.claudeMissing(
        name: skill.name, isBuiltin: skill.isBuiltin, account: account, parent: parent,
        folders: folders.map(\.url))
    case .codex:
      // One short-lived `codex app-server` per folder, shared with the sessions' `/` menus.
      for folder in folders { codexSkills(folder.url).loadIfNeeded() }
    }
  }
}
```

- [ ] **Step 4: Run them to see them pass**

Run: `xcodebuild test -project Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath .build -only-testing:DrakarTests/FanOutDraftTests`
Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Drakar/Services/FanOutDraft.swift DrakarTests/FanOutDraftTests.swift
git commit -m "feat(apple): the Run in Each Subfolder sheet's model: folders, ticks, reach, limit"
```

---

### Task 6: The sheet, its two entry points, the banner and the row label

**Files:**
- Create: `Drakar/Views/SkillFanOutSheet.swift`
- Modify: `Drakar/Views/InspectorView.swift:117-126` (menu), `Drakar/DrakarApp.swift:135-165` (`SessionCommands`), `Drakar/ContentView.swift:74-78` (sheet), `Drakar/Views/ProjectSidebar.swift:91-105` (banner, row) and `:355-379` (`SessionRow.detail`)
- Test: `DrakarTests/FanOutDraftTests.swift` (one more test for the picker's list), plus the live check in Task 7.

**Interfaces:**
- Consumes: `FanOutDraft` (Task 5); `Project.fanOutRequest`, `Project.fanOuts`, `Project.cancelFanOut(_:)`, `FanOutRequest`, `FanOutBatch` (Task 4); `FanOut.summary` (Task 2); `ProjectPath.child(of:below:)` (Task 1); `SessionPills.offeredModes` is not reused (it needs a session); the sheet offers `PermissionMode.allCases` minus `.bypass` unless `ClaudeChoice.allowsBypass`.
- Produces: `Project.fanOutSkills: [SkillEntry]` (the picker's list: the inspector's for `skillsAgent`).

- [ ] **Step 1: Write the failing test for the picker's list**

Add to `FanOutDraftTests`:

```swift
  /// The Session menu's picker lists what the inspector does for the shown agent: Codex's
  /// skills for the shown session's folder.
  @Test func thePickerListsTheShownAgentsSkills() {
    let project = Project(folder: parent)
    let item = project.newSession(agent: .codex)
    _ = item
    #expect(project.fanOutSkills == (project.codexSkills(for: project.selected?.session).skills ?? []))
  }
```

Run: `xcodebuild test … -only-testing:DrakarTests/FanOutDraftTests/thePickerListsTheShownAgentsSkills`
Expected: build failure, no member `fanOutSkills`.

- [ ] **Step 2: Add `fanOutSkills` to `Project`** (after `skillsAgent`):

```swift
  /// What Run Skill in Subfolders… offers: the inspector's list for `skillsAgent`, the
  /// CLI's own left out.
  var fanOutSkills: [SkillEntry] {
    let all: [SkillEntry] =
      switch skillsAgent {
      case .claude: capabilities.lists.skills ?? []
      case .codex: codexSkills(for: selected?.session).skills ?? []
      }
    return all.filter { !$0.isBuiltin }
  }
```

Run the test again. Expected: PASS.

- [ ] **Step 3: Write the sheet** — `Drakar/Views/SkillFanOutSheet.swift`:

```swift
import AppKit
import DrakarKit
import SwiftUI

/// Run in Each Subfolder: a session per subfolder of a parent, each sent one skill
/// (docs/superpowers/specs/2026-10-12-skill-fanout-design.md §3). Without a skill, it asks for
/// one first.
struct SkillFanOutSheet: View {
  let project: Project
  let request: FanOutRequest
  @State private var draft: FanOutDraft?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Group {
      if let draft {
        FanOutForm(draft: draft, project: project, dismiss: { dismiss() })
      } else {
        FanOutSkillPicker(skills: project.fanOutSkills, cancel: { dismiss() }) { skill in
          draft = makeDraft(skill)
        }
      }
    }
    .frame(width: 520, height: 560)
    .onAppear {
      if draft == nil, let skill = request.skill { draft = makeDraft(skill) }
      if request.skill == nil { project.capabilities.loadIfNeeded() }
    }
  }

  private func makeDraft(_ skill: SkillEntry) -> FanOutDraft {
    FanOutDraft(
      skill: skill, agent: project.skillsAgent, parent: project.folder,
      account: AccountStore.shared.windowAccount(for: project.folder).directory)
  }
}

private struct FanOutSkillPicker: View {
  let skills: [SkillEntry]
  let cancel: () -> Void
  let pick: (SkillEntry) -> Void
  @State private var filter = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Run a Skill in Each Subfolder").font(.headline)
      TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
      List(skills.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) })
      { skill in
        Button {
          pick(skill)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("/\(skill.name)").font(.body.monospaced())
            if !skill.description.isEmpty {
              Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
        }
        .buttonStyle(.plain)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
  }
}

private struct FanOutForm: View {
  @Bindable var draft: FanOutDraft
  let project: Project
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Run /\(draft.skill.name) in Each Subfolder").font(.headline)
      HStack {
        Text(draft.parent.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Change…", action: chooseParent)
      }
      HStack {
        Toggle("Git repositories only", isOn: $draft.gitOnly)
        Spacer()
        Button("Select All") { draft.tickAll(true) }
        Button("Select None") { draft.tickAll(false) }
      }
      List(draft.shown) { folder in
        Toggle(isOn: Binding(
          get: { draft.isTicked(folder) }, set: { draft.setTicked(folder, $0) }
        )) {
          HStack {
            Text(folder.name)
            if let note = note(folder) {
              Text(note).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .accessibilityIdentifier("fanout.folder.\(folder.name)")
      }
      .overlay {
        if draft.shown.isEmpty {
          Text(draft.gitOnly ? "No git repositories here." : "No subfolders here.")
            .foregroundStyle(.secondary)
        }
      }
      if draft.reachUnchecked {
        Text("Couldn't check which folders have this skill.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Form {
        if draft.skill.takesArguments {
          TextField("Arguments", text: $draft.arguments, prompt: Text(draft.skill.argumentHint))
        }
        Picker("Mode", selection: $draft.mode) {
          Text("Default").tag(PermissionMode?.none)
          ForEach(modes, id: \.self) { mode in Text(mode.title).tag(Optional(mode)) }
        }
        TextField("Run at most", text: $draft.limitText, prompt: Text("Unlimited"))
          .accessibilityIdentifier("fanout.limit")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
        Button("Start \(draft.chosen.count) Sessions") {
          draft.start(in: project)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draft.chosen.isEmpty)
        .accessibilityIdentifier("fanout.start")
      }
    }
    .padding(20)
  }

  private var modes: [PermissionMode] {
    PermissionMode.allCases.filter { $0 != .bypass || ClaudeChoice.allowsBypass }
  }

  private func note(_ folder: Subfolder) -> String? {
    if !draft.reaches(folder) { return String(localized: "Not available here") }
    if !folder.isGitRepository { return String(localized: "Not a git repository") }
    return nil
  }

  private func chooseParent() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = draft.parent
    guard panel.runModal() == .OK, let url = panel.url else { return }
    draft.change(parent: url)
  }
}
```

- [ ] **Step 4: Wire the entry points, banner and row**

`InspectorView.swift`, in `menu(for:)` after "Run in New Session":

```swift
    Button("Run in Each Subfolder…") { project.fanOutRequest = FanOutRequest(skill: skill) }
```

`DrakarApp.swift`, `SessionCommands`, after `ForkSessionCommand(project: project)`:

```swift
    Button("Run Skill in Subfolders…") { project?.fanOutRequest = FanOutRequest() }
      .disabled(project == nil)
```

`ContentView.swift`, next to the two existing `.sheet` modifiers (inside the `if let project` branch, where `project` is in scope):

```swift
        .sheet(item: Binding(get: { project.fanOutRequest }, set: { project.fanOutRequest = $0 }))
        { request in SkillFanOutSheet(project: project, request: request) }
```

`ProjectSidebar.swift`, in `Section("This Window")`, before `ForEach(project.held)`:

```swift
        ForEach(project.fanOuts) { batch in
          HStack {
            Text("/\(batch.skillName) · \(batch.queue.summary)")
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if batch.queue.count(.waiting) > 0 {
              Button("Cancel") { project.cancelFanOut(batch) }
                .buttonStyle(.link).font(.caption)
            }
          }
          .accessibilityIdentifier("sessions.fanout.\(batch.skillName)")
        }
```

and pass the subfolder to the row:

```swift
          SessionRow(
            item: item, isSelected: item.id == project.selectedID,
            windowAccount: AccountStore.shared.windowAccount(for: project.folder),
            subfolder: ProjectPath.child(
              of: item.session.folder.path(percentEncoded: false),
              below: project.folder.path(percentEncoded: false))
          )
```

In `SessionRow`, add `var subfolder: String? = nil` beside its other `let`s, and in `detail` before the worktree line:

```swift
    if let subfolder { parts.append(subfolder) }
```

- [ ] **Step 5: Build, format, run the app suites touched**

Run: `make format-swift && make format-swift-check && xcodebuild test -project Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath .build -only-testing:DrakarTests/FanOutDraftTests -only-testing:DrakarTests/ProjectFanOutTests -only-testing:DrakarTests/SkillRunTests`
Expected: format check clean; all pass.

- [ ] **Step 6: Commit**

```bash
git add Drakar/Views/SkillFanOutSheet.swift Drakar/Views/InspectorView.swift Drakar/DrakarApp.swift Drakar/ContentView.swift Drakar/Views/ProjectSidebar.swift Drakar/Services/Project.swift DrakarTests/FanOutDraftTests.swift
git commit -m "feat(apple): Run in Each Subfolder… on a skill and in the Session menu, with a banner per batch"
```

---

### Task 7: Whole suite, live check, land

- [ ] **Step 1: Merge main and run everything**

```bash
git merge main
make test && make test-app
```

Expected: all pass (rerun the known flakes alone if they fail: see Global Constraints).

- [ ] **Step 2: Live check** (ask the person before `make run`: it quits the running Drakar)

Set up a scratch parent:

```bash
P=$(mktemp -d)/apps; for r in one two three; do mkdir -p $P/$r && git -C $P/$r init -q; done; mkdir $P/notes; echo $P
```

Then `make run ARGS="-drakar.debugFolder $P"` and drive with cupertino-desktop by accessibility identifier (screenshots are black here): open the inspector, right-click a user skill with no arguments (e.g. `check`), "Run in Each Subfolder…". Check:
- rows `fanout.folder.one/two/three` ticked; `notes` hidden until "Git repositories only" is off;
- type `2` in `fanout.limit`, press `fanout.start`;
- three rows named `/check · one`, `· two`, `· three`, each with its folder in the detail line;
- banner `sessions.fanout.check` reads "2 running · 1 waiting"; after the first turn ends, the third starts and the banner moves; it goes when all are done.

- [ ] **Step 3: Land**

In `~/Projects/apps/drakar`: if `git status` shows uncommitted edits in files this branch touches (`Project.swift`, `ProjectSidebar.swift`, `ContentView.swift`, `DrakarApp.swift`, `InspectorView.swift`), stop and ask. Otherwise `git merge --ff-only feat/skill-fanout`.
