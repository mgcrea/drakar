# Skills manager window: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Skills window that lists every skill Claude Code and Codex see for one project (or none), where each comes from and which agent sees it, and that installs (from a folder or git), shares (by symbolic link) and deletes skills without ever deleting through a link or leaving one dangling.

**Architecture:** DrakarKit gets the vocabulary (`SkillAgent`, `SkillOrigin`, `SkillKind`), Codex's full `skills/list` (`CodexSkillList.records`), a disk scan of the places Claude Code reads (`ClaudeSkillScan`, with `SkillFrontmatter` and `SkillPath`), the merge into one row per real folder (`SkillInventory.merge` → `SkillRecord`), and the install helpers (`SkillFolderSearch`, `GitSource`). The app gets `CodexSkills` keeping the records beside its entries, `SkillActions` (share, delete, install over a `SkillFileSystem` seam with a test trash), `SkillSources` (git clone and pull through `GitRunner`), the window's model `SkillsManager`, and the views: a `Window("Skills", id: "skills")` scene, a Window menu item and a Manage… button in the inspector's Skills pane.

**Tech Stack:** Swift 6 (DrakarKit tools 6.3, app `SWIFT_VERSION = 6.0` with default actor isolation `MainActor`), SwiftUI (`NavigationSplitView`, `Table`), Swift Testing, SwiftPM package `apps/apple/Packages/DrakarKit` (zero dependencies), Xcode project `apps/apple/Drakar.xcodeproj` (synchronized folders: a new file joins its target by sitting in its folder; DrakarKit picks up the new `Sources/DrakarKit/Skills/` folder by itself).

**Spec:** `docs/superpowers/specs/2026-10-09-skills-manager-design.md`.

## Global Constraints

- Work in the worktree above; never edit /Users/olivier/Projects/apps/drakar. (The worktree: `/Users/olivier/Projects/apps/drakar-skills-manager`, branch `feat/skills-manager`.)
- Every commit passes `make -C apps/apple test` and `make -C apps/apple test-app`; run `make -C apps/apple format-swift` before committing and revert its rewrites of exactly LiveSessionTests.swift, PresentationTests.swift, TranscriptTests.swift (pre-existing; `git checkout -- <file>` allowed for those three only). Known load flake: CapabilityProbeTests.endsWhileAServerStaysPending (rerun once if only it fails, and say so).
- DrakarKit stays dependency-free (Foundation only). Claude and Codex session behaviour, the `/` menu, the inspector's existing panes and the goldens in DrakarKitTests/Goldens must not change.
- Never run `make run`. The in-app check is the plan's last task and needs the person's go-ahead.
- Comments follow the codebase: a doc comment says what a thing is for, plain sentences, no em dashes.
- Commits `feat(apple): …` / `test(apple): …` / `docs: …`, imperative, ≤ 72 chars, no Co-Authored-By trailer or signature, stage files by name, never --no-verify, never `git reset --hard`/`git clean`.
- Tests never touch the real ~/.claude, ~/.agents, ~/.codex or the real Trash: every file operation in tests goes through temp folders and seams (account directory, home directory, a fake trash). Tests needing `git` create a local repo in a temp folder and clone from a file:// URL.
- No user email or account data in fixtures, code or docs; fixtures use /Users/me paths.
- Existing tests change only where a task says so (Task 5 adapts the `CodexSkills.reader` stand-ins, nothing else).
- Focused test commands, from the worktree root: DrakarKit `swift test --package-path apps/apple/Packages/DrakarKit --filter <Suite>`; app `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/<Suite>`.
- The commit step of every task is: `make -C apps/apple format-swift`, then `git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift`, then `git add` of the task's files by name, then `git commit -m "…"`.

## Refinements of the spec

Found while planning against the code; each keeps the spec's intent.

- **Missing links in Codex's folders come from the scan.** Codex lists only skills that load, so a link in `~/.agents/skills`, `~/.codex/skills`, `<project>/.agents/skills` or `<project>/.codex/skills` whose target is gone is found by `ClaudeSkillScan` (`codexFolders`), as a Codex sighting. Live links there are left to Codex's own list.
- **A delete looks in every folder the window watches**, not only the four install folders: the account's `skills`, `~/.agents/skills`, `~/.codex/skills`, and the project's `.claude/skills`, `.claude/commands`, `.agents/skills`, `.codex/skills` (`SkillPlaces.roots`). A real folder (or command file) inside one of them goes to the Trash; outside them only links are removed. Without this, a Codex skill living in `~/.codex/skills` could never be deleted, and a link from `.claude/commands` could dangle.
- **`isLink` is per sighting**: the location itself is a symbolic link (`lstat`), not "its path differs from `realPath`", which would also be true for every skill under a linked parent folder. The row's `isLink` is "any sighting is a link", as the spec says.
- **Paths are resolved with `URL.resolvingSymlinksInPath`** (`SkillPath.real`), as the spec says, on both sides of every comparison: it drops `/private` from `/private/var/…`, so a path Codex writes one way and the scan the other still meet.
- **With no project, both agents are asked about the home folder**: Codex's `skills/list` with the home folder as its cwd (the spec), and Claude Code's names from the existing probe run in the home folder under the Settings account (the spec's "loaded if needed", applied the same way).
- **A Codex record's description is its full `description`**, then its `shortDescription`, then its interface's; the `/` menu's entries keep their shortest-first choice.
- **`installed_plugins.json`:** for one plugin, a `local` install of this project beats a `project` one, which beats the user's. A plugin whose value is an object instead of an array is read as one install. A file that is not JSON, or whose `plugins` is not an object, adds one sentence to the scan's `problems` and the rest of the scan goes on; odd entries are skipped silently.
- **`CodexSkills.reader` returns a `CodexSkillList.Listing`** (entries and records from the same answer), so the existing stand-ins in `CodexSkillsTests` and `SkillRunTests` are adapted in Task 5. "Codex was not found" is told apart by `CodexSkills.isCodexMissing`, with the inspector's problem text unchanged.
- **Install from Git is one sheet**: a URL field and Fetch, then the found skills, Place and Agents (always by link, so no Method). It also takes `file://` addresses, which the tests clone from; the clone of one goes under `skill-sources/local/<owner>/<repo>`. An address with `.` or `..` in its path is refused.
- **Window menu:** the `Window` scene's automatic menu item is removed (`.commandsRemoved()`) and replaced by a "Skills" command that knows the focused project window, so Window › Skills opens on that project as the spec asks. The window keeps its size through a frame autosave name and is not restored at launch (`.restorationBehavior(.disabled)`).
- **Manage… is an icon button** (`slider.horizontal.3`, help "Manage Skills…") beside the pane's refresh button, identifier `inspector.skills.manage`: the header has no room for a text button.
- **A git address with a timeout**: a `git` that runs past 120 s is stopped and reported as "Git took longer than 120 seconds and was stopped."

## Review Focus

1. **Deleting a skill seen through a link must never delete the link's target** (a link in `~/.claude/skills` to `~/Projects/claude-skills/notes`): only the link goes, the folder stays, nothing reaches the Trash; and removing a "link" that turns out to be a real folder is refused. Pinned in Task 6 (`deletingALinkKeepsItsTarget`, `removingALinkRefusesARealFolder`).
2. **A delete must not leave dangling links**: trashing a real folder also removes every link to it in the account's, `~/.agents`'s and the project's skill folders, and a git clone goes to the Trash only with its last link. Pinned in Tasks 6 and 8 (`deletingARealFolderTakesItsLinks`, `aClonesLastLinkTakesTheCloneWithIt`, `theCloneGoesWithItsLastLink`).
3. **A skill linked into both agents is one row**, even when Codex spells the path through `/private`: one row with a Claude sighting (the link) and a Codex sighting (the folder). Pinned in Task 3 (`aSkillLinkedIntoBothAgentsIsOneRow`).
4. **An `installed_plugins.json` of an unexpected shape must not crash the scan or hide the other skills**: a top-level array, text that is not JSON, `plugins` as an array, an install as an object, installs without `installPath`, numbers and nulls. Pinned in Task 2 (`aPluginsFileOfAnotherShapeIsAProblemNotACrash`).
5. **The window must work with no project chosen**: user-level skills under the Settings account, both agents asked about the home folder, no "This project" place, and an install into the project refused. Pinned in Tasks 7 and 9 (`withoutAProjectOnlyYoursCanBeInstalledInto`, `aProjectAddsItsPlaceAndItsSkills`, `theAccountIsTheProjectWindowsOrSettings`).

---

## File map

DrakarKit (`apps/apple/Packages/DrakarKit/Sources/DrakarKit/`):

| File | Responsibility |
| --- | --- |
| `Skills/SkillOrigin.swift` (new) | `SkillAgent`, `SkillOrigin`, `SkillKind`, `SkillFolder` |
| `Codex/CodexSkillList.swift` (modify) | `CodexSkillRecord`, `records(_:)`, `Listing`, `listing(_:)` |
| `Skills/SkillFrontmatter.swift` (new) | A SKILL.md's `name` and `description` |
| `Skills/SkillPath.swift` (new) | Resolving links, telling a link apart, a link's target |
| `Skills/ClaudeSkillScan.swift` (new) | `ScannedSkill`; the account's, the project's and plugins' skills, commands, missing links |
| `Skills/SkillInventory.swift` (new) | `SkillSighting`, `SkillRecord`, `SkillInventory.merge` |
| `Skills/SkillFolderSearch.swift` (new) | The skills a chosen folder or clone offers |
| `Skills/GitSource.swift` (new) | A git address → `<host>/<owner>/<repo>` |

DrakarKit tests (`apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/`): `CodexSkillRecordsTests.swift`, `ClaudeSkillScanTests.swift`, `SkillInventoryTests.swift`, `SkillInstallSearchTests.swift` (new).

App (`apps/apple/Drakar/`):

| File | Responsibility |
| --- | --- |
| `Services/CodexSkills.swift` (modify) | `records`, `isCodexMissing`, `NotFound`, reader returns a `Listing` |
| `Services/SkillActions.swift` (new) | `SkillPlace`, `SkillPlaces`, `SkillFileSystem`, `SkillActionError`, `DeletePlan`, `InstallMethod`, `SkillActions`, `SkillText.path`, `URL.skillPath` |
| `Services/SkillSources.swift` (new) | `GitRunner`, `SkillSources` |
| `Services/SkillsManager.swift` (new) | `SkillsPlace`, `SkillsManager` (the window's model) |
| `Services/Project.swift` (modify) | `observeSkillFiles(_:)`, `stopObservingSkillFiles(_:)` |
| `Views/SkillsWindow.swift` (new) | The window, sidebar, table, detail; `SkillText` wording |
| `Views/SkillSheets.swift` (new) | Install and delete sheets |
| `DrakarApp.swift` (modify) | The `Window` scene and Window › Skills |
| `Views/InspectorView.swift` (modify) | Manage… in the Skills pane |

App tests (`apps/apple/DrakarTests/`): `SkillActionsTests.swift`, `SkillSourcesTests.swift`, `SkillsManagerTests.swift`, `SkillsWindowTests.swift` (new); `CodexSkillsTests.swift`, `SkillRunTests.swift` (modify, Task 5).

---

### Task 1: Codex's full skill list

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/SkillOrigin.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexSkillList.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexSkillRecordsTests.swift`

**Interfaces:**
- Consumes: `JSONValue`, `SkillEntry`, `CodexSkillList.entries(_:)` and its private `rank(of:)`, `Fixture.codexSkillsList`.
- Produces: `public enum SkillAgent: String { case claude, codex; var other }`; `public enum SkillOrigin { case user, project, plugin(String), codexSystem, codexAdmin, unknown; var isOwn: Bool }`; `public enum SkillKind { case skill, command }`; `public struct SkillFolder { url: URL; origin: SkillOrigin; init(url:origin:) }`; `public struct CodexSkillRecord { name, description, path: String; scope: Scope; pluginID: String?; isEnabled: Bool; isShadowed: Bool; origin: SkillOrigin; init(name:description:path:scope:pluginID:isEnabled:isShadowed: = false) }` with `Scope { repo, user, system, admin, other(String) }`; `CodexSkillList.records(_: JSONValue) -> [CodexSkillRecord]`; `CodexSkillList.Listing { entries: [SkillEntry]; records: [CodexSkillRecord]; init(entries: = [], records: = []) }`; `CodexSkillList.listing(_: JSONValue) -> Listing`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Codex's skills, every one kept")
struct CodexSkillRecordsTests {
  private func records() throws -> [CodexSkillRecord] {
    CodexSkillList.records(try Fixture.codexSkillsList)
  }

  /// Shadowed and disabled skills are kept, in the order Codex listed them.
  @Test func keepsEverySkillListed() throws {
    #expect(
      try records().map(\.name) == [
        "skill-creator", "deploy", "skill-creator", "data:analyze", "legacy-notes",
      ])
  }

  @Test func keepsWhereEachComesFrom() throws {
    let all = try records()
    #expect(all.map(\.scope) == [.system, .repo, .user, .user, .repo])
    #expect(all.map(\.origin) == [.codexSystem, .project, .user, .plugin("data"), .project])
    #expect(all[1].path == "/Users/me/project/.agents/skills/deploy/SKILL.md")
    #expect(all[3].pluginID == "data")
    #expect(all[0].pluginID == nil)
  }

  /// The system skill-creator loses to the user's; a disabled skill is off, not shadowed.
  @Test func marksTheShadowedAndTheDisabled() throws {
    let all = try records()
    #expect(all.map(\.isShadowed) == [true, false, false, false, false])
    #expect(all.map(\.isEnabled) == [true, true, true, true, false])
  }

  /// The whole description, for the manager; a shorter one only when there is no other.
  @Test func describesASkillInFull() throws {
    let all = try records()
    #expect(
      all[1].description
        == "Deploy the project to staging once the checks pass, then say where it runs.")
    let bare: JSONValue = .object([
      "data": .array([
        .object([
          "skills": .array([
            .object([
              "name": .string("x"), "path": .string("/x/SKILL.md"), "scope": .string("user"),
              "enabled": .bool(true), "shortDescription": .string("Short"),
            ])
          ])
        ])
      ])
    ])
    #expect(CodexSkillList.records(bare).first?.description == "Short")
  }

  /// An admin skill, a scope this version does not know, and entries without a name or path.
  @Test func readsOddEntries() {
    let result: JSONValue = .object([
      "data": .array([
        .object([
          "skills": .array([
            .object([
              "name": .string("a"), "path": .string("/a/SKILL.md"), "scope": .string("admin"),
              "enabled": .bool(true),
            ]),
            .object([
              "name": .string("b"), "path": .string("/b/SKILL.md"), "scope": .string("team"),
              "enabled": .bool(true),
            ]),
            .object(["name": .string(""), "path": .string("/c/SKILL.md")]),
            .object(["name": .string("d")]),
          ])
        ])
      ])
    ])
    let all = CodexSkillList.records(result)
    #expect(all.map(\.name) == ["a", "b"])
    #expect(all.map(\.origin) == [.codexAdmin, .unknown])
    #expect(all[1].scope == .other("team"))
    #expect(CodexSkillList.records(.null).isEmpty)
  }

  /// One answer serves the `/` menu and the manager.
  @Test func aListingCarriesBoth() throws {
    let result = try Fixture.codexSkillsList
    let listing = CodexSkillList.listing(result)
    #expect(listing.entries == CodexSkillList.entries(result))
    #expect(listing.records == CodexSkillList.records(result))
    #expect(CodexSkillList.Listing().entries.isEmpty)
  }

  @Test func eachAgentKnowsTheOther() {
    #expect(SkillAgent.claude.other == .codex)
    #expect(SkillAgent.codex.other == .claude)
    #expect(SkillOrigin.user.isOwn && SkillOrigin.project.isOwn)
    #expect(!SkillOrigin.plugin("x").isOwn && !SkillOrigin.codexSystem.isOwn)
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexSkillRecordsTests`
Expected: FAIL to build, `cannot find type 'CodexSkillRecord' in scope`.

- [ ] **Step 3: Write `SkillOrigin.swift`**

```swift
import Foundation

/// The two agents a skill can reach.
public enum SkillAgent: String, Sendable, Hashable, CaseIterable {
  case claude, codex

  public var other: SkillAgent { self == .claude ? .codex : .claude }
}

/// Where a skill comes from, which says what the Skills window may do with it.
public enum SkillOrigin: Sendable, Hashable {
  /// The account's own folder, or `~/.agents`'s.
  case user
  case project
  /// A plugin's, by its id: `name@marketplace` for Claude Code's, the `pluginId` for Codex's.
  case plugin(String)
  case codexSystem
  case codexAdmin
  /// A name Claude Code lists that no folder Drakar reads explains.
  case unknown

  /// The person's own: a skill they can share or delete here.
  public var isOwn: Bool { self == .user || self == .project }
}

/// A skill folder, or a command file of `.claude/commands`.
public enum SkillKind: Sendable, Hashable {
  case skill
  case command
}

/// A folder skills are found in, and where a skill found there comes from.
public struct SkillFolder: Sendable, Hashable {
  public var url: URL
  public var origin: SkillOrigin

  public init(url: URL, origin: SkillOrigin) {
    self.url = url
    self.origin = origin
  }
}
```

- [ ] **Step 4: Add the records to `CodexSkillList.swift`**

After the closing brace of `entries(_:)` and before `rank(of:)`, inside `enum CodexSkillList`, add:

```swift
  /// What `records` and `entries` read from one answer.
  public struct Listing: Sendable, Equatable {
    public var entries: [SkillEntry]
    public var records: [CodexSkillRecord]

    public init(entries: [SkillEntry] = [], records: [CodexSkillRecord] = []) {
      self.entries = entries
      self.records = records
    }
  }

  /// The `/` menu's entries and the Skills window's records, from one answer.
  public static func listing(_ result: JSONValue) -> Listing {
    Listing(entries: entries(result), records: records(result))
  }

  /// Every skill `skills/list` answered, shadowed and disabled ones kept, in its order: what
  /// the Skills window lists. A skill without a name or a path is left out.
  public static func records(_ result: JSONValue) -> [CodexSkillRecord] {
    let skills = (result["data"]?.arrayValue ?? []).flatMap { $0["skills"]?.arrayValue ?? [] }
    var records: [CodexSkillRecord] = []
    for skill in skills {
      guard let name = skill["name"]?.stringValue, !name.isEmpty,
        let path = skill["path"]?.stringValue, !path.isEmpty
      else { continue }
      let description = [
        skill["description"]?.stringValue, skill["shortDescription"]?.stringValue,
        skill["interface"]?["shortDescription"]?.stringValue,
      ].lazy.compactMap { $0 }.first { !$0.isEmpty }
      records.append(
        CodexSkillRecord(
          name: name, description: description ?? "", path: path,
          scope: CodexSkillRecord.Scope(skill["scope"]?.stringValue),
          pluginID: skill["pluginId"]?.stringValue,
          isEnabled: skill["enabled"]?.boolValue == true))
    }
    // The nearest enabled skill of a name is Codex's, the first listed on a tie, as `entries`
    // keeps it; every other enabled one of that name is shadowed.
    var winners: [String: (rank: Int, index: Int)] = [:]
    for (index, record) in records.enumerated() where record.isEnabled {
      let rank = rank(of: record.scope.raw)
      if let winner = winners[record.name], winner.rank <= rank { continue }
      winners[record.name] = (rank, index)
    }
    for index in records.indices where records[index].isEnabled {
      records[index].isShadowed = winners[records[index].name]?.index != index
    }
    return records
  }
```

At the end of the file, add:

```swift
/// One skill of Codex's `skills/list`, kept whole for the Skills window.
public struct CodexSkillRecord: Sendable, Hashable {
  /// Where Codex found it, in its words.
  public enum Scope: Sendable, Hashable {
    case repo, user, system, admin
    case other(String)

    public init(_ raw: String?) {
      switch raw {
      case "repo": self = .repo
      case "user": self = .user
      case "system": self = .system
      case "admin": self = .admin
      default: self = .other(raw ?? "")
      }
    }

    var raw: String {
      switch self {
      case .repo: "repo"
      case .user: "user"
      case .system: "system"
      case .admin: "admin"
      case .other(let raw): raw
      }
    }
  }

  public var name: String
  public var description: String
  /// The SKILL.md.
  public var path: String
  public var scope: Scope
  public var pluginID: String?
  public var isEnabled: Bool
  /// Enabled, but a nearer skill of the same name is the one Codex uses.
  public var isShadowed: Bool

  public init(
    name: String, description: String, path: String, scope: Scope, pluginID: String?,
    isEnabled: Bool, isShadowed: Bool = false
  ) {
    self.name = name
    self.description = description
    self.path = path
    self.scope = scope
    self.pluginID = pluginID
    self.isEnabled = isEnabled
    self.isShadowed = isShadowed
  }

  public var origin: SkillOrigin {
    if let pluginID { return .plugin(pluginID) }
    switch scope {
    case .repo: return .project
    case .user: return .user
    case .system: return .codexSystem
    case .admin: return .codexAdmin
    case .other: return .unknown
    }
  }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter CodexSkillRecordsTests`, then `make -C apps/apple test` and `make -C apps/apple test-app`.
Expected: PASS (7 tests); the existing `CodexSkillsTests` unchanged and green.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/SkillOrigin.swift apps/apple/Packages/DrakarKit/Sources/DrakarKit/Codex/CodexSkillList.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/CodexSkillRecordsTests.swift
git commit -m "feat(apple): keep every skill Codex lists, shadowed or disabled"
```

---

### Task 2: The places Claude Code reads skills from

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/SkillFrontmatter.swift`, `Skills/SkillPath.swift`, `Skills/ClaudeSkillScan.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ClaudeSkillScanTests.swift`

**Interfaces:**
- Consumes: `SkillAgent`, `SkillOrigin`, `SkillKind`, `SkillFolder` (Task 1); `JSONValue.parse`; `ProjectPath.normalize`.
- Produces: `SkillFrontmatter.fields(_: String) -> [String: String]`; `SkillPath.real(_: String) -> String`, `SkillPath.isLink(_: String) -> Bool`, `SkillPath.target(ofLink: String) -> String?`; `public struct ScannedSkill: Hashable { name, description: String; kind: SkillKind; origin: SkillOrigin; agent: SkillAgent; path, realPath: String; isLink: Bool; missingTarget: String?; isPluginDisabled: Bool; init(name:description: = "":kind: = .skill:origin:agent: = .claude:path:realPath:isLink: = false:missingTarget: = nil:isPluginDisabled: = false) }`; `ClaudeSkillScan.Result { skills: [ScannedSkill]; problems: [String]; init(skills: = [], problems: = []) }`; `ClaudeSkillScan.scan(account: URL, project: URL?, codexFolders: [SkillFolder] = []) -> Result`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Claude Code's skills, read from disk")
struct ClaudeSkillScanTests {
  private let root: URL
  private let account: URL
  private let project: URL
  private let elsewhere: URL

  init() throws {
    // Resolved first, so the paths the tests spell are the ones the scan resolves to.
    root = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
    account = root.appending(path: ".claude-test", directoryHint: .isDirectory)
    project = root.appending(path: "project", directoryHint: .isDirectory)
    elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
    for folder in [account, project, elsewhere] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  private func cleanUp() { try? FileManager.default.removeItem(at: root) }

  private func path(_ url: URL) -> String { ProjectPath.normalize(url.path(percentEncoded: false)) }

  private func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  private func skill(_ folder: URL, name: String? = nil, description: String? = nil) throws {
    var text = "---\n"
    if let name { text += "name: \(name)\n" }
    if let description { text += "description: \(description)\n" }
    try write(text + "---\n\nBody.\n", to: folder.appending(path: "SKILL.md"))
  }

  private func link(_ at: URL, to target: URL) throws {
    try FileManager.default.createDirectory(
      at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: at, withDestinationURL: target)
  }

  @Test func readsTheFrontmatter() {
    defer { cleanUp() }
    #expect(
      SkillFrontmatter.fields("---\nname: review\ndescription: \"Review: the diff\"\n---\nBody")
        == ["name": "review", "description": "Review: the diff"])
    #expect(SkillFrontmatter.fields("---\r\nname: a\r\n---\r\n") == ["name": "a"])
    #expect(
      SkillFrontmatter.fields("---\ndescription: >\n  Two\n  lines.\nname: x\n---\n")
        == ["description": "Two lines.", "name": "x"])
    #expect(SkillFrontmatter.fields("---\nname: 'it''s'\n---") == ["name": "it's"])
    #expect(SkillFrontmatter.fields("# Title\nname: x\n").isEmpty)
    #expect(SkillFrontmatter.fields("---\nname: never closed\n").isEmpty)
  }

  /// A folder with a SKILL.md is a skill, named by its frontmatter, else by the folder; a
  /// folder without one, and a hidden one, are not.
  @Test func readsTheAccountsSkills() throws {
    defer { cleanUp() }
    try skill(account.appending(path: "skills/review"), name: "review", description: "Review the diff.")
    try skill(account.appending(path: "skills/plain"))
    try write("No frontmatter here.", to: account.appending(path: "skills/bare/SKILL.md"))
    try FileManager.default.createDirectory(
      at: account.appending(path: "skills/empty"), withIntermediateDirectories: true)
    try skill(account.appending(path: "skills/.hidden"), name: "hidden")
    try skill(account.appending(path: "skills/renamed"), name: "other-name")
    let skills = ClaudeSkillScan.scan(account: account, project: nil).skills
    #expect(skills.map(\.name) == ["bare", "plain", "other-name", "review"])
    let folder = path(account.appending(path: "skills/review"))
    #expect(
      skills.last
        == ScannedSkill(
          name: "review", description: "Review the diff.", origin: .user, path: folder,
          realPath: folder))
    #expect(skills.allSatisfy { $0.agent == .claude && $0.kind == .skill && !$0.isLink })
    #expect(skills.first?.description == "")
  }

  @Test func aLinkIsSeenWhereItIsAndKnownByItsFolder() throws {
    defer { cleanUp() }
    let shared = elsewhere.appending(path: "find-skills")
    try skill(shared, name: "find-skills")
    let seen = account.appending(path: "skills/find-skills")
    try link(seen, to: shared)
    #expect(
      ClaudeSkillScan.scan(account: account, project: nil).skills == [
        ScannedSkill(
          name: "find-skills", origin: .user, path: path(seen), realPath: path(shared),
          isLink: true)
      ])
  }

  @Test func aLinkWhoseTargetIsGoneIsListedMissing() throws {
    defer { cleanUp() }
    let gone = root.appending(path: "gone")
    let seen = account.appending(path: "skills/old")
    try link(seen, to: gone)
    #expect(
      ClaudeSkillScan.scan(account: account, project: nil).skills == [
        ScannedSkill(
          name: "old", origin: .user, path: path(seen), realPath: path(gone), isLink: true,
          missingTarget: path(gone))
      ])
  }

  /// Commands are named by their path below `commands/`, `a/b.md` as `a:b`.
  @Test func readsTheProjectsSkillsAndCommands() throws {
    defer { cleanUp() }
    let deploy = project.appending(path: ".claude/skills/deploy")
    try skill(deploy, name: "deploy", description: "Ship it.")
    let commands = project.appending(path: ".claude/commands")
    try write("---\ndescription: Top level.\n---\nDo it.", to: commands.appending(path: "top.md"))
    try write("Nested, no frontmatter.", to: commands.appending(path: "a/b.md"))
    try write("not a command", to: commands.appending(path: "notes.txt"))
    let folder = path(commands)
    #expect(
      ClaudeSkillScan.scan(account: account, project: project).skills == [
        ScannedSkill(
          name: "deploy", description: "Ship it.", origin: .project, path: path(deploy),
          realPath: path(deploy)),
        ScannedSkill(
          name: "a:b", kind: .command, origin: .project, path: folder + "/a/b.md",
          realPath: folder + "/a/b.md"),
        ScannedSkill(
          name: "top", description: "Top level.", kind: .command, origin: .project,
          path: folder + "/top.md", realPath: folder + "/top.md"),
      ])
  }

  /// A user install is in effect everywhere, a project or local one only in its project; a
  /// plugin `settings.json` turns off is kept and marked.
  @Test func readsThePluginsInEffectForTheProject() throws {
    defer { cleanUp() }
    let cache = root.appending(path: "plugin-cache", directoryHint: .isDirectory)
    for (plugin, name) in [("tools", "lint"), ("here", "fmt"), ("there", "far"), ("off", "quiet")] {
      try skill(cache.appending(path: "\(plugin)/skills/\(name)"), name: name)
    }
    func install(_ plugin: String, _ scope: String, _ at: URL? = nil) -> String {
      let projectPath = at.map { #","projectPath":"\#(path($0))""# } ?? ""
      return
        #"[{"scope":"\#(scope)"\#(projectPath),"installPath":"\#(path(cache.appending(path: plugin)))","version":"1.0.0"}]"#
    }
    try write(
      #"{"version":2,"plugins":{"tools@market":\#(install("tools", "user")),"here@market":\#(install("here", "project", project)),"there@market":\#(install("there", "local", elsewhere)),"off@market":\#(install("off", "user"))}}"#,
      to: account.appending(path: "plugins/installed_plugins.json"))
    try write(
      #"{"enabledPlugins":{"off@market":false,"tools@market":true}}"#,
      to: account.appending(path: "settings.json"))
    let skills = ClaudeSkillScan.scan(account: account, project: project).skills
    #expect(skills.map(\.name) == ["here:fmt", "off:quiet", "tools:lint"])
    #expect(
      skills.map(\.origin) == [
        .plugin("here@market"), .plugin("off@market"), .plugin("tools@market"),
      ])
    #expect(skills.map(\.isPluginDisabled) == [false, true, false])
    #expect(
      ClaudeSkillScan.scan(account: account, project: nil).skills.map(\.name) == [
        "off:quiet", "tools:lint",
      ])
  }

  /// Review focus: a plugins file of a shape Drakar does not know is one sentence in the
  /// problems, never a crash, and every other skill is still listed.
  @Test func aPluginsFileOfAnotherShapeIsAProblemNotACrash() throws {
    defer { cleanUp() }
    try skill(account.appending(path: "skills/review"), name: "review")
    let file = account.appending(path: "plugins/installed_plugins.json")
    for text in ["[1, 2]", "not json", #"{"version":2,"plugins":[]}"#] {
      try write(text, to: file)
      let result = ClaudeSkillScan.scan(account: account, project: project)
      #expect(result.skills.map(\.name) == ["review"])
      #expect(result.problems.count == 1)
    }
    let tools = root.appending(path: "plugin-cache/tools", directoryHint: .isDirectory)
    try skill(tools.appending(path: "skills/lint"), name: "lint")
    try write(
      #"{"plugins":{"tools@m":{"scope":"user","installPath":"\#(path(tools))"},"bare@m":[{"scope":"user"}],"odd@m":[42,"x",null],"who@m":[{"scope":"team","installPath":"/nowhere"}]}}"#,
      to: file)
    let result = ClaudeSkillScan.scan(account: account, project: project)
    #expect(result.skills.map(\.name) == ["review", "tools:lint"])
    #expect(result.problems.isEmpty)
  }

  /// Codex lists its live skills itself: only its links whose target is gone come from here.
  @Test func codexsFoldersAreReadForMissingLinksOnly() throws {
    defer { cleanUp() }
    let agents = root.appending(path: "home/.agents/skills", directoryHint: .isDirectory)
    try skill(elsewhere.appending(path: "live"), name: "live")
    try link(agents.appending(path: "live"), to: elsewhere.appending(path: "live"))
    let gone = root.appending(path: "gone")
    try link(agents.appending(path: "old"), to: gone)
    try skill(agents.appending(path: "own"), name: "own")
    let result = ClaudeSkillScan.scan(
      account: account, project: nil, codexFolders: [SkillFolder(url: agents, origin: .user)])
    #expect(
      result.skills == [
        ScannedSkill(
          name: "old", origin: .user, agent: .codex, path: path(agents.appending(path: "old")),
          realPath: path(gone), isLink: true, missingTarget: path(gone))
      ])
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter ClaudeSkillScanTests`
Expected: FAIL to build, `cannot find 'SkillPath' in scope`.

- [ ] **Step 3: Write `SkillFrontmatter.swift`**

```swift
import Foundation

/// The `---` block at the top of a SKILL.md or a command file: the `key: value` lines Claude
/// Code and Codex read a skill's name and description from. Plain values, quoted ones, and
/// `|` or `>` blocks; nothing else of YAML.
public enum SkillFrontmatter {
  /// The fields; empty when the text has no frontmatter, or it never closes.
  public static func fields(_ text: String) -> [String: String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
    }
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
    var fields: [String: String] = [:]
    var index = 1
    while index < lines.count {
      let line = lines[index]
      index += 1
      if line.trimmingCharacters(in: .whitespaces) == "---" { return fields }
      guard let first = line.first, !first.isWhitespace, first != "#",
        let colon = line.firstIndex(of: ":")
      else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if let style = value.first, style == "|" || style == ">", value.count <= 2 {
        var block: [String] = []
        while index < lines.count, lines[index].first?.isWhitespace ?? true,
          lines[index].trimmingCharacters(in: .whitespaces) != "---"
        {
          let part = lines[index].trimmingCharacters(in: .whitespaces)
          if !part.isEmpty { block.append(part) }
          index += 1
        }
        fields[key] = block.joined(separator: style == ">" ? " " : "\n")
      } else {
        fields[key] = unquoted(value)
      }
    }
    return [:]
  }

  private static func unquoted(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
      value.last == first
    else { return value }
    let inner = String(value.dropFirst().dropLast())
    return first == "\""
      ? inner.replacingOccurrences(of: "\\\"", with: "\"")
      : inner.replacingOccurrences(of: "''", with: "'")
  }
}
```

- [ ] **Step 4: Write `SkillPath.swift`**

```swift
import Foundation

/// Skill locations on disk, resolved through their links: a folder reached by a link and by
/// its own path is one skill.
public enum SkillPath {
  /// `path` with its links resolved, as `URL.resolvingSymlinksInPath` does (which also drops
  /// `/private` from `/private/var/…`), without a trailing slash.
  public static func real(_ path: String) -> String {
    ProjectPath.normalize(
      URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false))
  }

  /// Whether `path` itself is a symbolic link, whatever it points to.
  public static func isLink(_ path: String) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
  }

  /// Where the link at `path` points, made absolute; nil when `path` is not a link.
  public static func target(ofLink path: String) -> String? {
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    else { return nil }
    if destination.hasPrefix("/") { return ProjectPath.normalize(destination) }
    let parent = URL(filePath: path).deletingLastPathComponent()
    return ProjectPath.normalize(
      parent.appending(path: destination).standardized.path(percentEncoded: false))
  }
}
```

- [ ] **Step 5: Write `ClaudeSkillScan.swift`**

```swift
import Foundation

/// One skill or command found on disk, where it was found.
public struct ScannedSkill: Sendable, Hashable {
  public var name: String
  public var description: String
  public var kind: SkillKind
  public var origin: SkillOrigin
  /// Who reads the folder it was found in.
  public var agent: SkillAgent
  /// Where it was found: the link, when it is one.
  public var path: String
  /// The folder (or command file) with every link resolved; a missing link's target.
  public var realPath: String
  public var isLink: Bool
  /// The target of a link whose target is gone; nil otherwise.
  public var missingTarget: String?
  /// A plugin's skill whose plugin the account's `settings.json` turns off.
  public var isPluginDisabled: Bool

  public init(
    name: String, description: String = "", kind: SkillKind = .skill, origin: SkillOrigin,
    agent: SkillAgent = .claude, path: String, realPath: String, isLink: Bool = false,
    missingTarget: String? = nil, isPluginDisabled: Bool = false
  ) {
    self.name = name
    self.description = description
    self.kind = kind
    self.origin = origin
    self.agent = agent
    self.path = path
    self.realPath = realPath
    self.isLink = isLink
    self.missingTarget = missingTarget
    self.isPluginDisabled = isPluginDisabled
  }
}

/// The places Claude Code reads skills from, read the way it reads them: the account's
/// `skills/`, the project's `.claude/skills/` and `.claude/commands/`, and the skills of the
/// plugins in effect for the project. Claude Code's `initialize` reports names only, so this
/// is where the Skills window learns where a skill lives.
public enum ClaudeSkillScan {
  public struct Result: Sendable, Equatable {
    public var skills: [ScannedSkill]
    /// What could not be read, a sentence each.
    public var problems: [String]

    public init(skills: [ScannedSkill] = [], problems: [String] = []) {
      self.skills = skills
      self.problems = problems
    }
  }

  /// `account` is the account's directory, `project` nil for user-level skills only.
  /// `codexFolders` are read for links whose target is gone, which Codex does not list.
  public static func scan(account: URL, project: URL?, codexFolders: [SkillFolder] = [])
    -> Result
  {
    var result = Result()
    result.skills += skills(in: account.appending(path: "skills"), origin: .user)
    if let project {
      result.skills += skills(in: project.appending(path: ".claude/skills"), origin: .project)
      result.skills += commands(in: project.appending(path: ".claude/commands"))
    }
    plugins(account: account, project: project, into: &result)
    for folder in codexFolders {
      result.skills += skills(in: folder.url, origin: folder.origin, agent: .codex).filter {
        $0.missingTarget != nil
      }
    }
    return result
  }

  /// Each folder of `folder` holding a SKILL.md, and each link in it whose target is gone, in
  /// name order. Hidden entries are skipped.
  static func skills(
    in folder: URL, origin: SkillOrigin, agent: SkillAgent = .claude, prefix: String = "",
    disabled: Bool = false
  ) -> [ScannedSkill] {
    let manager = FileManager.default
    let names = ((try? manager.contentsOfDirectory(atPath: path(folder))) ?? [])
      .filter { !$0.hasPrefix(".") }.sorted()
    return names.compactMap { name in
      let location = path(folder.appending(path: name))
      let isLink = SkillPath.isLink(location)
      if isLink, !manager.fileExists(atPath: location) {
        let target = SkillPath.target(ofLink: location) ?? location
        return ScannedSkill(
          name: prefix + name, origin: origin, agent: agent, path: location, realPath: target,
          isLink: true, missingTarget: target, isPluginDisabled: disabled)
      }
      let file = location + "/SKILL.md"
      guard manager.fileExists(atPath: file) else { return nil }
      let fields = SkillFrontmatter.fields(head(file))
      let named = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name
      return ScannedSkill(
        name: prefix + named, description: fields["description"] ?? "", origin: origin,
        agent: agent, path: location, realPath: SkillPath.real(location), isLink: isLink,
        isPluginDisabled: disabled)
    }
  }

  /// The project's commands, every `.md` below `folder`, named by their path below it.
  static func commands(in folder: URL) -> [ScannedSkill] {
    let root = path(folder)
    guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
    var found: [ScannedSkill] = []
    for case let relative as String in walker
    where relative.hasSuffix(".md") && !relative.split(separator: "/").contains(where: {
      $0.hasPrefix(".")
    }) {
      let location = root + "/" + relative
      var isFolder: ObjCBool = false
      guard FileManager.default.fileExists(atPath: location, isDirectory: &isFolder),
        !isFolder.boolValue
      else { continue }
      let name = String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")
      let fields = SkillFrontmatter.fields(head(location))
      found.append(
        ScannedSkill(
          name: name, description: fields["description"] ?? "", kind: .command,
          origin: .project, path: location, realPath: SkillPath.real(location),
          isLink: SkillPath.isLink(location)))
    }
    return found.sorted { $0.path < $1.path }
  }

  /// The skills of every plugin `installed_plugins.json` (version 2) has in effect, named
  /// `plugin:skill`. A file of another shape is a problem; an entry of another shape is skipped.
  static func plugins(account: URL, project: URL?, into result: inout Result) {
    let file = account.appending(path: "plugins/installed_plugins.json")
    guard let data = FileManager.default.contents(atPath: path(file)) else { return }
    guard let json = try? JSONValue.parse(data), case .object(let plugins)? = json["plugins"]
    else {
      result.problems.append(
        "Couldn't read the plugins Claude Code installed: \(path(file)) is not in a shape Drakar knows."
      )
      return
    }
    let enabled = enabledPlugins(account)
    for id in plugins.keys.sorted() {
      let value = plugins[id] ?? .null
      let installs = value.arrayValue ?? [value]
      guard let installPath = install(in: installs, for: project)?["installPath"]?.stringValue,
        !installPath.isEmpty
      else { continue }
      let name = id.split(separator: "@", maxSplits: 1).first.map(String.init) ?? id
      result.skills += skills(
        in: URL(filePath: installPath, directoryHint: .isDirectory).appending(path: "skills"),
        origin: .plugin(id), prefix: name + ":", disabled: enabled[id] == false)
    }
  }

  /// The install in effect for `project`: a local one of this project, else a project one of
  /// it, else the user's.
  static func install(in installs: [JSONValue], for project: URL?) -> JSONValue? {
    let here = project.map(path)
    func rank(_ install: JSONValue) -> Int? {
      switch install["scope"]?.stringValue {
      case "user": return 2
      case let scope? where scope == "local" || scope == "project":
        guard let here, let at = install["projectPath"]?.stringValue,
          ProjectPath.normalize(at) == here
        else { return nil }
        return scope == "local" ? 0 : 1
      default: return nil
      }
    }
    return installs.compactMap { install in rank(install).map { ($0, install) } }
      .min { $0.0 < $1.0 }?.1
  }

  /// `enabledPlugins` of the account's `settings.json`; a plugin it does not name is on.
  static func enabledPlugins(_ account: URL) -> [String: Bool] {
    guard
      let data = FileManager.default.contents(
        atPath: path(account.appending(path: "settings.json"))),
      let json = try? JSONValue.parse(data), case .object(let flags)? = json["enabledPlugins"]
    else { return [:] }
    return flags.compactMapValues(\.boolValue)
  }

  /// The first 16 KB of a file, where the frontmatter is.
  static func head(_ path: String) -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 16_384)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  static func path(_ url: URL) -> String { ProjectPath.normalize(url.path(percentEncoded: false)) }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter ClaudeSkillScanTests`, then `make -C apps/apple test` and `make -C apps/apple test-app`.
Expected: PASS (8 tests).

- [ ] **Step 7: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/SkillFrontmatter.swift apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/SkillPath.swift apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/ClaudeSkillScan.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/ClaudeSkillScanTests.swift
git commit -m "feat(apple): read Claude Code's skills, commands and plugins from disk"
```

---

### Task 3: One row per real skill

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/SkillInventory.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/SkillInventoryTests.swift`

**Interfaces:**
- Consumes: `ScannedSkill`, `ClaudeSkillScan.scan`, `SkillPath` (Task 2); `CodexSkillRecord`, `SkillOrigin`, `SkillAgent`, `SkillKind` (Task 1); `SkillEntry.displayDescription`, `CapabilityName.matches` (internal).
- Produces: `public struct SkillSighting: Hashable { agent: SkillAgent; path: String?; isLink: Bool; isEnabled: Bool; isShadowed: Bool; init(agent:path:isLink: = false, isEnabled: = true, isShadowed: = false) }`; `public struct SkillRecord: Hashable, Identifiable { name, description: String; kind: SkillKind; origin: SkillOrigin; sightings: [SkillSighting]; realPath: String; isMissing: Bool; notLoadedByClaude: Bool; init(name:description:kind:origin:realPath:sightings: = [], isMissing: = false, notLoadedByClaude: = false); id: String; isLink; isShadowed; canDelete; canShare; file: String?; sighting(for:) -> SkillSighting?; matches(_:) -> Bool }`; `SkillInventory.merge(scan: [ScannedSkill], claude: [SkillEntry]?, codex: [CodexSkillRecord]?, resolve: (String) -> (real: String, isLink: Bool) = disk) -> [SkillRecord]`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Both agents' skills, one row per real folder")
struct SkillInventoryTests {
  private let root = URL(
    filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
    directoryHint: .isDirectory
  ).appending(path: "drakar-inventory-\(UUID().uuidString)", directoryHint: .isDirectory)

  private func cleanUp() { try? FileManager.default.removeItem(at: root) }

  private func path(_ url: URL) -> String { ProjectPath.normalize(url.path(percentEncoded: false)) }

  /// No disk: every path is its own folder, and none is a link.
  private func merge(
    _ scan: [ScannedSkill], claude: [SkillEntry]? = nil, codex: [CodexSkillRecord]? = nil
  ) -> [SkillRecord] {
    SkillInventory.merge(scan: scan, claude: claude, codex: codex, resolve: { ($0, false) })
  }

  /// Review focus: `~/.claude/skills/find-skills` linked to `~/.agents/skills/find-skills` is
  /// one row both agents see, even with Codex spelling the folder through `/private`.
  @Test func aSkillLinkedIntoBothAgentsIsOneRow() throws {
    defer { cleanUp() }
    let account = root.appending(path: ".claude", directoryHint: .isDirectory)
    let shared = root.appending(path: ".agents/skills/find-skills", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try Data("---\nname: find-skills\ndescription: Find skills.\n---\n".utf8).write(
      to: shared.appending(path: "SKILL.md"))
    let seen = account.appending(path: "skills/find-skills")
    try FileManager.default.createDirectory(
      at: seen.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: seen, withDestinationURL: shared)
    let folder = path(shared)
    let spelled =
      folder.hasPrefix("/var/") || folder.hasPrefix("/tmp/") ? "/private" + folder : folder
    let codex = CodexSkillRecord(
      name: "find-skills", description: "Find skills.", path: spelled + "/SKILL.md",
      scope: .user, pluginID: nil, isEnabled: true)
    let rows = SkillInventory.merge(
      scan: ClaudeSkillScan.scan(account: account, project: nil).skills, claude: nil,
      codex: [codex])
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.realPath == folder)
    #expect(row.origin == .user)
    #expect(row.sightings.map(\.agent) == [.claude, .codex])
    #expect(row.sighting(for: .claude)?.isLink == true)
    #expect(row.sighting(for: .codex)?.isLink == false)
    #expect(row.isLink)
    #expect(row.canShare && row.canDelete)
  }

  /// Before Claude Code's list loads nothing is marked; then a scanned skill it does not list
  /// is not loaded, and a name it lists that no folder explains is a row of its own.
  @Test func marksWhatClaudeCodeDoesNotLoad() {
    let review = ScannedSkill(
      name: "review", origin: .user, path: "/Users/me/.claude/skills/review",
      realPath: "/Users/me/.claude/skills/review")
    let broken = ScannedSkill(
      name: "broken", origin: .user, path: "/Users/me/.claude/skills/broken",
      realPath: "/Users/me/.claude/skills/broken")
    #expect(merge([review, broken]).allSatisfy { !$0.notLoadedByClaude })
    let rows = merge(
      [review, broken],
      claude: [SkillEntry(name: "review"), SkillEntry(name: "mystery", description: "From somewhere.")])
    #expect(rows.map(\.name) == ["broken", "mystery", "review"])
    #expect(rows.map(\.notLoadedByClaude) == [true, false, false])
    let mystery = rows[1]
    #expect(mystery.origin == .unknown)
    #expect(mystery.description == "From somewhere.")
    #expect(mystery.sightings == [SkillSighting(agent: .claude, path: nil)])
    #expect(!mystery.canDelete && !mystery.canShare)
    #expect(mystery.file == nil)
    let codexOnly = merge(
      [], claude: [],
      codex: [
        CodexSkillRecord(
          name: "x", description: "", path: "/Users/me/.agents/skills/x/SKILL.md", scope: .user,
          pluginID: nil, isEnabled: true)
      ])
    #expect(codexOnly.map(\.notLoadedByClaude) == [false])
  }

  /// Plugins, Codex's own and unknown skills are listed and left alone; commands are deleted
  /// but not shared; a missing link says what it pointed at.
  @Test func onlyYourOwnSkillsCanBeSharedOrDeleted() throws {
    let plugin = ScannedSkill(
      name: "tools:lint", origin: .plugin("tools@market"), path: "/Users/me/cache/tools/skills/lint",
      realPath: "/Users/me/cache/tools/skills/lint", isPluginDisabled: true)
    let command = ScannedSkill(
      name: "a:b", kind: .command, origin: .project,
      path: "/Users/me/project/.claude/commands/a/b.md",
      realPath: "/Users/me/project/.claude/commands/a/b.md")
    let missing = ScannedSkill(
      name: "old", origin: .user, path: "/Users/me/.claude/skills/old", realPath: "/Users/me/gone",
      isLink: true, missingTarget: "/Users/me/gone")
    let rows = merge(
      [plugin, command, missing], codex: CodexSkillList.records(try Fixture.codexSkillsList))
    func row(_ name: String, _ origin: SkillOrigin) throws -> SkillRecord {
      try #require(rows.first { $0.name == name && $0.origin == origin })
    }
    let lint = try row("tools:lint", .plugin("tools@market"))
    #expect(!lint.canDelete && !lint.canShare)
    #expect(lint.sighting(for: .claude)?.isEnabled == false)
    let ab = try row("a:b", .project)
    #expect(ab.canDelete && !ab.canShare)
    #expect(ab.file == "/Users/me/project/.claude/commands/a/b.md")
    let old = try row("old", .user)
    #expect(old.description == "Missing: /Users/me/gone")
    #expect(old.isMissing && old.canDelete && !old.canShare)
    let system = try row("skill-creator", .codexSystem)
    #expect(!system.canDelete && system.isShadowed)
    #expect(system.sighting(for: .codex)?.isShadowed == true)
    #expect(try !row("data:analyze", .plugin("data")).canDelete)
    let legacy = try row("legacy-notes", .project)
    #expect(legacy.sighting(for: .codex)?.isEnabled == false)
    #expect(legacy.canDelete)
    let deploy = try row("deploy", .project)
    #expect(deploy.file == "/Users/me/project/.agents/skills/deploy/SKILL.md")
    #expect(deploy.sighting(for: .claude) == nil)
  }

  @Test func aRowMatchesItsNameAndDescription() {
    let row = SkillRecord(
      name: "deploy", description: "Ship to staging", kind: .skill, origin: .project,
      realPath: "/x")
    #expect(row.matches("STAG"))
    #expect(row.matches("dep"))
    #expect(row.matches(" "))
    #expect(!row.matches("lint"))
    #expect(row.id == "/x")
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter SkillInventoryTests`
Expected: FAIL to build, `cannot find 'SkillInventory' in scope`.

- [ ] **Step 3: Write `SkillInventory.swift`**

```swift
import Foundation

/// Where one agent sees a skill.
public struct SkillSighting: Sendable, Hashable {
  public var agent: SkillAgent
  /// The folder (or command file) the agent reads: the link, when it is one; nil for a name
  /// Claude Code lists from a place Drakar does not read.
  public var path: String?
  /// `path` itself is a symbolic link.
  public var isLink: Bool
  /// Off: a plugin the account's `settings.json` turns off, or a skill Codex's configuration
  /// disables.
  public var isEnabled: Bool
  /// Codex only: a nearer skill of the same name is the one Codex uses.
  public var isShadowed: Bool

  public init(
    agent: SkillAgent, path: String?, isLink: Bool = false, isEnabled: Bool = true,
    isShadowed: Bool = false
  ) {
    self.agent = agent
    self.path = path
    self.isLink = isLink
    self.isEnabled = isEnabled
    self.isShadowed = isShadowed
  }
}

/// One real skill, however many places it is seen from: a row of the Skills window.
public struct SkillRecord: Sendable, Hashable, Identifiable {
  public var name: String
  public var description: String
  public var kind: SkillKind
  public var origin: SkillOrigin
  public var sightings: [SkillSighting]
  /// The folder (or command file) with its links resolved; the target of a missing link;
  /// empty for a name no folder explains.
  public var realPath: String
  /// A link whose target is gone.
  public var isMissing: Bool
  /// Seen by Claude Code on disk, and not in the names it reports.
  public var notLoadedByClaude: Bool

  public init(
    name: String, description: String, kind: SkillKind, origin: SkillOrigin, realPath: String,
    sightings: [SkillSighting] = [], isMissing: Bool = false, notLoadedByClaude: Bool = false
  ) {
    self.name = name
    self.description = description
    self.kind = kind
    self.origin = origin
    self.realPath = realPath
    self.sightings = sightings
    self.isMissing = isMissing
    self.notLoadedByClaude = notLoadedByClaude
  }

  public var id: String { realPath.isEmpty ? "unknown:" + name : realPath }

  public var isLink: Bool { sightings.contains(where: \.isLink) }
  public var isShadowed: Bool { sightings.contains(where: \.isShadowed) }

  /// Only the person's own skills, the account's or `~/.agents`'s and the project's.
  public var canDelete: Bool { origin.isOwn }
  /// Their own skill folders that are there: Codex has no commands.
  public var canShare: Bool { origin.isOwn && kind == .skill && !isMissing }

  /// What the detail shows and Open opens: the SKILL.md, or the command file.
  public var file: String? {
    guard !realPath.isEmpty else { return nil }
    return kind == .command ? realPath : realPath + "/SKILL.md"
  }

  public func sighting(for agent: SkillAgent) -> SkillSighting? {
    sightings.first { $0.agent == agent }
  }

  /// As `SkillEntry.matches`: the name and the description, case- and accent-insensitive.
  public func matches(_ query: String) -> Bool {
    CapabilityName.matches(query, in: [name, description])
  }
}

/// The Skills window's rows, from what each agent says.
public enum SkillInventory {
  /// One row per real folder: Claude Code's scan, then Codex's records joined by the folder
  /// they resolve to. `claude` is the names Claude Code reports, nil until they load: then a
  /// scanned skill it does not list is marked, and a name no row explains is a row of its own.
  /// `resolve` gives a folder's real path and whether it is a link; the disk unless a test
  /// says otherwise.
  public static func merge(
    scan: [ScannedSkill], claude: [SkillEntry]?, codex: [CodexSkillRecord]?,
    resolve: (String) -> (real: String, isLink: Bool) = {
      (SkillPath.real($0), SkillPath.isLink($0))
    }
  ) -> [SkillRecord] {
    var rows: [SkillRecord] = []
    var byPath: [String: Int] = [:]
    func add(_ sighting: SkillSighting, at realPath: String, _ make: () -> SkillRecord) {
      if let index = byPath[realPath] {
        if !rows[index].sightings.contains(where: {
          $0.agent == sighting.agent && $0.path == sighting.path
        }) {
          rows[index].sightings.append(sighting)
        }
      } else {
        byPath[realPath] = rows.count
        var row = make()
        row.sightings = [sighting]
        rows.append(row)
      }
    }
    for skill in scan {
      let sighting = SkillSighting(
        agent: skill.agent, path: skill.path, isLink: skill.isLink,
        isEnabled: !skill.isPluginDisabled)
      add(sighting, at: skill.realPath) {
        SkillRecord(
          name: skill.name,
          description: skill.missingTarget.map { "Missing: \($0)" } ?? skill.description,
          kind: skill.kind, origin: skill.origin, realPath: skill.realPath,
          isMissing: skill.missingTarget != nil)
      }
    }
    for record in codex ?? [] {
      let folder = ProjectPath.normalize(
        URL(filePath: record.path).deletingLastPathComponent().path(percentEncoded: false))
      let (real, isLink) = resolve(folder)
      let sighting = SkillSighting(
        agent: .codex, path: folder, isLink: isLink, isEnabled: record.isEnabled,
        isShadowed: record.isShadowed)
      add(sighting, at: real) {
        SkillRecord(
          name: record.name, description: record.description, kind: .skill,
          origin: record.origin, realPath: real)
      }
      if let index = byPath[real], rows[index].description.isEmpty, !rows[index].isMissing {
        rows[index].description = record.description
      }
    }
    if let claude {
      let listed = Set(claude.map(\.name))
      var placed = Set<String>()
      for index in rows.indices where rows[index].sightings.contains(where: { $0.agent == .claude })
      {
        rows[index].notLoadedByClaude = !listed.contains(rows[index].name)
        placed.insert(rows[index].name)
      }
      for entry in claude where !placed.contains(entry.name) {
        placed.insert(entry.name)
        rows.append(
          SkillRecord(
            name: entry.name, description: entry.displayDescription, kind: .skill,
            origin: .unknown, realPath: "", sightings: [SkillSighting(agent: .claude, path: nil)]))
      }
    }
    return rows.sorted { a, b in
      switch a.name.localizedStandardCompare(b.name) {
      case .orderedAscending: true
      case .orderedDescending: false
      case .orderedSame: a.realPath < b.realPath
      }
    }
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter SkillInventoryTests`, then `make -C apps/apple test` and `make -C apps/apple test-app`.
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/SkillInventory.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/SkillInventoryTests.swift
git commit -m "feat(apple): merge both agents' skills into one row per real folder"
```

---

### Task 4: Finding skills to install

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/SkillFolderSearch.swift`, `Skills/GitSource.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/SkillInstallSearchTests.swift`

**Interfaces:**
- Consumes: `SkillPath.real` (Task 2).
- Produces: `SkillFolderSearch.skills(in: URL, depth: Int) -> [URL]`; `public struct GitSource: Hashable { host, owner, repo: String; init(host:owner:repo:); init?(_ text: String); folder(in root: URL) -> URL }`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Finding skills to install")
struct SkillInstallSearchTests {
  private let root = URL(
    filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
    directoryHint: .isDirectory
  ).appending(path: "drakar-search-\(UUID().uuidString)", directoryHint: .isDirectory)

  private func cleanUp() { try? FileManager.default.removeItem(at: root) }

  private func skill(_ relative: String) throws {
    let folder = root.appending(path: relative, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("---\nname: x\n---\n".utf8).write(to: folder.appending(path: "SKILL.md"))
  }

  /// Each found folder below `root`, as a relative path.
  private func names(_ found: [URL]) -> [String] {
    let base = root.path(percentEncoded: false)
    return found.map {
      String($0.path(percentEncoded: false).dropFirst(base.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
  }

  @Test func aFolderHoldingASkillIsThatSkill() throws {
    defer { cleanUp() }
    try skill("one")
    try skill("one/inner")
    #expect(
      names(SkillFolderSearch.skills(in: root.appending(path: "one", directoryHint: .isDirectory), depth: 3))
        == ["one"])
  }

  /// A skill's own folders are not searched, nor hidden ones; nothing deeper than `depth`.
  @Test func aFolderOfSkillsOffersEachDownToTheDepth() throws {
    defer { cleanUp() }
    for relative in ["a", "group/b", "deep/x/c", "deeper/x/y/d", "a/nested", ".git/e", "node/.hidden/f"] {
      try skill(relative)
    }
    #expect(names(SkillFolderSearch.skills(in: root, depth: 3)) == ["a", "deep/x/c", "group/b"])
    #expect(
      names(SkillFolderSearch.skills(in: root, depth: 4)) == [
        "a", "deep/x/c", "deeper/x/y/d", "group/b",
      ])
    #expect(SkillFolderSearch.skills(in: root.appending(path: "missing"), depth: 3).isEmpty)
  }

  @Test func readsWhereAGitAddressClonesTo() {
    let skills = GitSource(host: "github.com", owner: "me", repo: "skills")
    #expect(GitSource("https://github.com/me/skills") == skills)
    #expect(GitSource("https://GitHub.com/me/skills.git/") == skills)
    #expect(GitSource("git@github.com:me/skills.git") == skills)
    #expect(GitSource("  https://github.com/me/skills \n") == skills)
    #expect(
      GitSource("ssh://git@gitlab.example.com/team/sub/tools.git")
        == GitSource(host: "gitlab.example.com", owner: "sub", repo: "tools"))
    #expect(
      GitSource("file:///Users/me/src/skills")
        == GitSource(host: "local", owner: "src", repo: "skills"))
  }

  /// Nothing that would put a clone outside its folder, or is not a repository's address.
  @Test func refusesWhatIsNotARepository() {
    for text in [
      "skills please", "github.com/me/skills", "https://github.com/me",
      "https://github.com/me/../../etc", "ftp://host/me/skills", "git@github.com:skills", "",
    ] {
      #expect(GitSource(text) == nil, "\(text)")
    }
  }

  @Test func aCloneGoesUnderHostOwnerAndRepo() {
    let sources = URL(filePath: "/Users/me/.agents/skill-sources", directoryHint: .isDirectory)
    #expect(
      GitSource("git@github.com:me/skills.git")?.folder(in: sources).path(percentEncoded: false)
        == "/Users/me/.agents/skill-sources/github.com/me/skills/")
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter SkillInstallSearchTests`
Expected: FAIL to build, `cannot find 'SkillFolderSearch' in scope`.

- [ ] **Step 3: Write `SkillFolderSearch.swift`**

```swift
import Foundation

/// The skills a folder offers for an install: the folder chosen in Install from Folder…, or
/// a git clone.
public enum SkillFolderSearch {
  /// `folder` itself when it holds a SKILL.md; else its folders that do, `depth` levels down
  /// at most, in path order. Hidden folders are skipped, and a skill's own folders are not
  /// searched.
  public static func skills(in folder: URL, depth: Int) -> [URL] {
    let manager = FileManager.default
    func holdsSkill(_ url: URL) -> Bool {
      manager.fileExists(atPath: url.appending(path: "SKILL.md").path(percentEncoded: false))
    }
    if holdsSkill(folder) { return [folder] }
    var found: [URL] = []
    var level = [folder]
    for _ in 0..<depth {
      var next: [URL] = []
      for parent in level {
        let names = ((try? manager.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) ?? [])
          .filter { !$0.hasPrefix(".") }.sorted()
        for name in names {
          let child = parent.appending(path: name, directoryHint: .isDirectory)
          var isFolder: ObjCBool = false
          guard manager.fileExists(atPath: child.path(percentEncoded: false), isDirectory: &isFolder),
            isFolder.boolValue
          else { continue }
          if holdsSkill(child) { found.append(child) } else { next.append(child) }
        }
      }
      level = next
    }
    return found.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
  }
}
```

- [ ] **Step 4: Write `GitSource.swift`**

```swift
import Foundation

/// A git repository's address, read for where its clone goes: `<host>/<owner>/<repo>` below
/// the folder Drakar keeps clones in.
public struct GitSource: Sendable, Hashable {
  public var host: String
  public var owner: String
  public var repo: String

  public init(host: String, owner: String, repo: String) {
    self.host = host
    self.owner = owner
    self.repo = repo
  }

  /// `https://host/owner/repo(.git)`, `ssh://…`, `git://…`, `file://…` (host `local`), or
  /// `git@host:owner/repo(.git)`; nil for anything else, or a path with `.` or `..` in it.
  public init?(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let host: String
    let path: String
    if !text.contains("://"), let at = text.firstIndex(of: "@"),
      let colon = text[at...].firstIndex(of: ":")
    {
      host = String(text[text.index(after: at)..<colon])
      path = String(text[text.index(after: colon)...])
    } else if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      ["https", "http", "ssh", "git", "file"].contains(scheme)
    {
      host = url.host(percentEncoded: false) ?? (scheme == "file" ? "local" : "")
      path = url.path(percentEncoded: false)
    } else {
      return nil
    }
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 2, !host.isEmpty, !host.contains("/"),
      parts.allSatisfy({ $0 != "." && $0 != ".." })
    else { return nil }
    var repo = parts[parts.count - 1]
    if repo.hasSuffix(".git") { repo.removeLast(4) }
    guard !repo.isEmpty else { return nil }
    self.host = host.lowercased()
    self.owner = parts[parts.count - 2]
    self.repo = repo
  }

  public func folder(in root: URL) -> URL {
    root.appending(path: host, directoryHint: .isDirectory)
      .appending(path: owner, directoryHint: .isDirectory)
      .appending(path: repo, directoryHint: .isDirectory)
  }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter SkillInstallSearchTests`, then `make -C apps/apple test` and `make -C apps/apple test-app`.
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/SkillFolderSearch.swift apps/apple/Packages/DrakarKit/Sources/DrakarKit/Skills/GitSource.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/SkillInstallSearchTests.swift
git commit -m "feat(apple): find skills to install in a folder or a git address"
```

---

### Task 5: `CodexSkills` keeps the records

**Files:**
- Modify: `apps/apple/Drakar/Services/CodexSkills.swift`
- Modify (tests, as listed in Step 1): `apps/apple/DrakarTests/CodexSkillsTests.swift`, `apps/apple/DrakarTests/SkillRunTests.swift`

**Interfaces:**
- Consumes: `CodexSkillList.Listing`, `CodexSkillList.listing(_:)`, `CodexSkillRecord` (Task 1).
- Produces: `CodexSkills.records: [CodexSkillRecord]?`; `CodexSkills.isCodexMissing: Bool`; `CodexSkills.NotFound` (an `Error`, "Codex was not found."); `CodexSkills.reader: (URL, Bool) async throws -> CodexSkillList.Listing`; `CodexSkills.read(folder:force:)` and `read(folder:force:configuration:)` return `CodexSkillList.Listing`.

- [ ] **Step 1: Adapt the existing stand-ins, then add the failing tests**

In `apps/apple/DrakarTests/CodexSkillsTests.swift`:
- in `counted(_:_:)`, replace `return skills` with `return CodexSkillList.Listing(entries: skills)`;
- in `refreshesAskedDuringAReadRunOnceAfterIt`, replace `return []` with `return CodexSkillList.Listing()`;
- replace each `entry.reader = { _, _ in [self.deploy] }` (in `aFailedReadSaysWhyAndWaitsForRetry`, `aFailedReloadKeepsTheLastList`, `theBackendNamesASkillOfItsFolder`) with `entry.reader = { _, _ in CodexSkillList.Listing(entries: [self.deploy]) }`;
- in `readsSkillsListFromCodex`, replace `plain.map(\.name)` with `plain.entries.map(\.name)`, `plain.first?.path` with `plain.entries.first?.path`, `forced.map(\.name)` with `forced.entries.map(\.name)`, and add after the `plain` expectations: `#expect(plain.records.map(\.name) == ["plain"])`.

In `apps/apple/DrakarTests/SkillRunTests.swift`:
- in `theMenuListsTheSessionsAgentsSkills`, replace `entry.reader = { _, _ in [self.deploy] }` with `entry.reader = { _, _ in CodexSkillList.Listing(entries: [self.deploy]) }`;
- in `typingASlashLoadsTheSessionsAgentsList`, replace `return []` inside the reader with `return CodexSkillList.Listing()`.

Then add to `CodexSkillsTests`, after `aFailedReloadKeepsTheLastList`:

```swift
  /// One `skills/list` answers both: the menu's entries and the Skills window's records; a
  /// failed reload keeps them, as it keeps the entries.
  @Test func keepsTheRecordsBesideTheEntries() async throws {
    let entry = CodexSkills(folder: folder)
    let record = CodexSkillRecord(
      name: "deploy", description: "Deploy to staging", path: deploy.path ?? "", scope: .repo,
      pluginID: nil, isEnabled: true)
    entry.reader = { _, _ in CodexSkillList.Listing(entries: [self.deploy], records: [record]) }
    entry.refresh()
    try await settle(entry)
    #expect(entry.records == [record])
    entry.reader = { _, _ in throw CodexOneShot.Failure(message: "boom") }
    entry.refresh()
    try await settle(entry)
    #expect(entry.records == [record])
  }

  /// No `codex` at all is told apart from a read that failed, for the Skills window's caption;
  /// the inspector's sentence is the same as before.
  @Test func aMissingCodexIsToldApart() async throws {
    let entry = CodexSkills(folder: folder)
    entry.reader = { _, _ in throw CodexSkills.NotFound() }
    entry.refresh()
    try await settle(entry)
    #expect(entry.isCodexMissing)
    #expect(entry.problem == "Couldn't read Codex's skills. Codex was not found.")
    entry.reader = { _, _ in CodexSkillList.Listing() }
    entry.refresh()
    try await settle(entry)
    #expect(!entry.isCodexMissing)
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/CodexSkillsTests`
Expected: FAIL to build, `cannot convert value of type 'CodexSkillList.Listing' to closure result type '[SkillEntry]'`.

- [ ] **Step 3: Rewrite `CodexSkills` in `CodexSkills.swift`**

Replace the whole `CodexSkills` class (from its doc comment down to the closing brace before `/// Every folder's \`CodexSkills\``) with:

```swift
/// Codex's skills for one folder, as a short-lived `codex app-server` lists them
/// (`skills/list`, docs/codex-app-server.md, "Skills"): what a Codex session's `/` menu and
/// the inspector offer, and what a prompt can name; the Skills window reads the same answer's
/// records. Read when first asked for, again when Codex or the folder's files say they
/// changed; in memory only. Every window on the folder shares it, under the one Codex home
/// until Codex accounts (slice 4).
@Observable
final class CodexSkills {
  let folder: URL
  /// The last list read; a failed reload leaves it.
  private(set) var skills: [SkillEntry]?
  /// Every skill the last read listed, shadowed and disabled ones too; a failed reload
  /// leaves them.
  private(set) var records: [CodexSkillRecord]?
  /// Why the last read failed, until one succeeds.
  private(set) var problem: String?
  /// The last read failed because there is no `codex` to ask.
  private(set) var isCodexMissing = false
  private(set) var isLoading = false
  /// A read has listed the skills at least once.
  private(set) var hasLoaded = false

  /// Stands in for Codex, in tests: the folder, and whether Codex reads its files again.
  @ObservationIgnored var reader: (URL, Bool) async throws -> CodexSkillList.Listing = {
    try await CodexSkills.read(folder: $0, force: $1)
  }
  @ObservationIgnored private var running: Task<Void, Never>?
  /// Asked again while a read ran: whether that read forces a reload; nil when not asked.
  @ObservationIgnored private var rerun: Bool?

  /// No `codex` on the login shell's PATH.
  struct NotFound: Error, LocalizedError {
    var errorDescription: String? { String(localized: "Codex was not found.") }
  }

  init(folder: URL) {
    self.folder = folder
  }

  /// The first time a list is shown; after a failed read, the next time one is asked for.
  func loadIfNeeded() {
    guard !hasLoaded, running == nil else { return }
    refresh()
  }

  /// A read now, or, while one runs, once more after it however often this is asked.
  /// `force` has Codex read the skill files again rather than answer from its cache.
  func refresh(force: Bool = false) {
    if running != nil {
      rerun = (rerun ?? false) || force
      return
    }
    rerun = nil
    isLoading = true
    running = Task { await self.read(force: force) }
  }

  /// For a change Codex or the files reported: only a list something already asked for.
  func refreshIfLoaded() {
    guard hasLoaded || running != nil else { return }
    refresh()
  }

  private func read(force: Bool) async {
    var force = force
    while true {
      do {
        let listing = try await reader(folder, force)
        skills = listing.entries
        records = listing.records
        problem = nil
        isCodexMissing = false
        hasLoaded = true
      } catch {
        problem = String(localized: "Couldn't read Codex's skills. \(error.localizedDescription)")
        isCodexMissing = error is NotFound
      }
      guard let again = rerun else { break }
      force = again
      rerun = nil
    }
    isLoading = false
    running = nil
  }

  /// Asks a `codex app-server` started in `folder`, as the model list's is.
  static func read(folder: URL, force: Bool) async throws -> CodexSkillList.Listing {
    let environment = await AgentSession.environment.value
    guard let executable = CodexLaunch.locate(path: environment["PATH"]) else {
      throw NotFound()
    }
    return try await read(
      folder: folder, force: force,
      configuration: CodexLaunch.configuration(
        executable: executable, environment: environment, folder: folder))
  }

  static func read(folder: URL, force: Bool, configuration: AgentProcess.Configuration)
    async throws -> CodexSkillList.Listing
  {
    var params: [String: JSONValue] = [
      "cwds": .array([.string(ProjectPath.normalize(folder.path(percentEncoded: false)))])
    ]
    if force { params["forceReload"] = .bool(true) }
    let results = try await CodexOneShot(configuration: configuration).run { previous in
      previous == nil ? ("skills/list", .object(params)) : nil
    }
    return CodexSkillList.listing(results.first ?? .null)
  }
}
```

(`CodexSkillStore` below it is unchanged.)

- [ ] **Step 4: Run the tests**

Run the focused `CodexSkillsTests` command, then `-only-testing:DrakarTests/SkillRunTests`, then `make -C apps/apple test-app` and `make -C apps/apple test`.
Expected: PASS; the inspector and the `/` menu read `skills` as before.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Drakar/Services/CodexSkills.swift apps/apple/DrakarTests/CodexSkillsTests.swift apps/apple/DrakarTests/SkillRunTests.swift
git commit -m "feat(apple): keep Codex's skill records beside the menu's entries"
```

---

### Task 6: Share and delete

**Files:**
- Create: `apps/apple/Drakar/Services/SkillActions.swift`
- Test: `apps/apple/DrakarTests/SkillActionsTests.swift`

**Interfaces:**
- Consumes: `SkillRecord`, `SkillSighting`, `SkillInventory.merge` (Task 3); `ClaudeSkillScan.scan`, `SkillPath` (Task 2); `SkillAgent`, `SkillOrigin`, `SkillFolder` (Task 1); `AgentKind` (app); `ProjectPath`.
- Produces:
  - `extension URL { var skillPath: String }` (path without a trailing slash);
  - `enum SkillText { static func path(_: String, home: String = <real home>) -> String; static func path(_: URL) -> String }`;
  - `enum SkillPlace: CaseIterable { case user, project }`; `extension SkillOrigin { var place: SkillPlace? }`; `extension SkillAgent { var kind: AgentKind }`;
  - `struct SkillPlaces: Equatable { account: URL; home: URL; project: URL?; folder(_: SkillPlace, for: SkillAgent) -> URL?; roots: [URL]; codexFolders: [SkillFolder]; sources: URL; clone(containing: String) -> URL?; static clone(containing: String, sources: URL) -> URL?; static spellings(of: URL) -> [String] }`;
  - `struct SkillFileSystem { var moveToTrash: (URL) throws -> Void; exists(_:) -> Bool; isLink(_:) -> Bool; createFolder(_:) throws; link(_:to:) throws; copy(_:to:) throws; trash(_:) throws; removeLink(_:) throws; children(of:) -> [URL]; read(_:limit:) -> String? }`;
  - `struct SkillActionError: Error, LocalizedError, Equatable { message: String; static func exists(_ name: String, in folder: URL) -> SkillActionError }`;
  - `struct DeletePlan: Equatable { enum Step: Hashable { case removeLink(String), trash(String) }; steps: [Step]; lines: [String] }`;
  - `enum InstallMethod { case link, copy }` (used by Task 7);
  - `struct SkillActions { places: SkillPlaces; files: SkillFileSystem; share(_:) throws -> URL; deletePlan(for:) throws -> DeletePlan; delete(_:) throws }`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Every file operation runs in this test's own folders, with a trash of its own.
@MainActor
@Suite("Sharing, deleting and installing skills")
struct SkillActionsTests {
  private let root: URL
  private let home: URL
  private let account: URL
  private let project: URL
  private let outside: URL
  private let trash: URL

  init() throws {
    root = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-skill-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    account = home.appending(path: ".claude-test", directoryHint: .isDirectory)
    project = root.appending(path: "project", directoryHint: .isDirectory)
    outside = root.appending(path: "outside", directoryHint: .isDirectory)
    trash = root.appending(path: "trash", directoryHint: .isDirectory)
    for folder in [account, project, outside, trash] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  private func cleanUp() { try? FileManager.default.removeItem(at: root) }

  private var places: SkillPlaces { SkillPlaces(account: account, home: home, project: project) }

  /// Moves to this test's trash, never the real one.
  private var files: SkillFileSystem {
    let trash = trash
    return SkillFileSystem(moveToTrash: { item in
      try FileManager.default.moveItem(at: item, to: trash.appending(path: item.lastPathComponent))
    })
  }

  private var actions: SkillActions { SkillActions(places: places, files: files) }

  @discardableResult
  private func skill(_ folder: URL) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("---\nname: \(folder.lastPathComponent)\n---\n".utf8).write(
      to: folder.appending(path: "SKILL.md"))
    return folder
  }

  private func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  private func link(_ at: URL, to target: URL) throws {
    try FileManager.default.createDirectory(
      at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: at, withDestinationURL: target)
  }

  /// Something is there, a link whose target is gone included.
  private func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.skillPath)) != nil
  }

  /// The rows the window would list, Codex seeing the skills in `codex`.
  private func rows(codex: [URL] = [], scope: CodexSkillRecord.Scope = .user) -> [SkillRecord] {
    let scan = ClaudeSkillScan.scan(
      account: account, project: places.project, codexFolders: places.codexFolders)
    let records = codex.map { folder in
      CodexSkillRecord(
        name: folder.lastPathComponent, description: "",
        path: folder.appending(path: "SKILL.md").skillPath, scope: scope, pluginID: nil,
        isEnabled: true)
    }
    return SkillInventory.merge(scan: scan.skills, claude: nil, codex: records)
  }

  private func row(_ name: String, codex: [URL] = [], scope: CodexSkillRecord.Scope = .user)
    throws -> SkillRecord
  {
    try #require(rows(codex: codex, scope: scope).first { $0.name == name })
  }

  @Test func sharesYourSkillWithCodex() throws {
    defer { cleanUp() }
    let review = try skill(account.appending(path: "skills/review"))
    let made = try actions.share(try row("review"))
    let expected = home.appending(path: ".agents/skills/review")
    #expect(made.skillPath == expected.skillPath)
    #expect(SkillPath.isLink(expected.skillPath))
    #expect(SkillPath.real(expected.skillPath) == review.skillPath)
    #expect(try row("review", codex: [expected]).sightings.map(\.agent) == [.claude, .codex])
  }

  @Test func sharesAProjectsCodexSkillWithClaudeCode() throws {
    defer { cleanUp() }
    let deploy = try skill(project.appending(path: ".agents/skills/deploy"))
    let record = try row("deploy", codex: [deploy], scope: .repo)
    #expect(record.origin == .project)
    try actions.share(record)
    let made = project.appending(path: ".claude/skills/deploy")
    #expect(SkillPath.isLink(made.skillPath))
    #expect(SkillPath.real(made.skillPath) == deploy.skillPath)
  }

  /// Another skill of the same name is in the way: nothing is written.
  @Test func aShareThatWouldOverwriteIsRefused() throws {
    defer { cleanUp() }
    try skill(account.appending(path: "skills/review"))
    let theirs = try skill(home.appending(path: ".agents/skills/review"))
    let record = try row("review")
    #expect(
      throws: SkillActionError.exists(
        "review", in: home.appending(path: ".agents/skills", directoryHint: .isDirectory))
    ) { try actions.share(record) }
    #expect(!SkillPath.isLink(theirs.skillPath))
  }

  @Test func commandsAreNotShared() throws {
    defer { cleanUp() }
    try write("Ship.", to: project.appending(path: ".claude/commands/ship.md"))
    let command = try row("ship")
    #expect(throws: SkillActionError.self) { try actions.share(command) }
  }

  /// Review focus: removing a link never touches what it points to.
  @Test func deletingALinkKeepsItsTarget() throws {
    defer { cleanUp() }
    let notes = try skill(outside.appending(path: "notes"))
    let seen = account.appending(path: "skills/notes")
    try link(seen, to: notes)
    let plan = try actions.deletePlan(for: try row("notes"))
    #expect(plan.steps == [.removeLink(seen.skillPath)])
    #expect(plan.lines.first?.hasPrefix("Remove the link at") == true)
    #expect(plan.lines.last?.contains("stays") == true)
    try actions.delete(plan)
    #expect(!exists(seen))
    #expect(FileManager.default.fileExists(atPath: notes.appending(path: "SKILL.md").skillPath))
    #expect(try FileManager.default.contentsOfDirectory(atPath: trash.skillPath).isEmpty)
  }

  /// Review focus: a "link" that is a real folder is refused, never removed.
  @Test func removingALinkRefusesARealFolder() throws {
    defer { cleanUp() }
    let real = try skill(account.appending(path: "skills/real"))
    #expect(throws: SkillActionError.self) { try files.removeLink(real) }
    #expect(exists(real.appending(path: "SKILL.md")))
  }

  /// Review focus: the real folder goes with every link to it, so none is left dangling.
  @Test func deletingARealFolderTakesItsLinks() throws {
    defer { cleanUp() }
    let real = try skill(home.appending(path: ".agents/skills/find-skills"))
    let claude = account.appending(path: "skills/find-skills")
    let inProject = project.appending(path: ".claude/skills/find-skills")
    try link(claude, to: real)
    try link(inProject, to: real)
    let plan = try actions.deletePlan(for: try row("find-skills", codex: [real]))
    #expect(
      Set(plan.steps) == [
        .removeLink(claude.skillPath), .removeLink(inProject.skillPath), .trash(real.skillPath),
      ])
    #expect(plan.steps.last == .trash(real.skillPath))
    try actions.delete(plan)
    for url in [claude, inProject, real] { #expect(!exists(url)) }
    #expect(exists(trash.appending(path: "find-skills")))
  }

  @Test func deletingAMissingLinkRemovesOnlyIt() throws {
    defer { cleanUp() }
    let seen = account.appending(path: "skills/old")
    try link(seen, to: root.appending(path: "gone"))
    let record = try row("old")
    #expect(record.isMissing)
    let plan = try actions.deletePlan(for: record)
    #expect(plan.steps == [.removeLink(seen.skillPath)])
    try actions.delete(plan)
    #expect(!exists(seen))
  }

  @Test func deletingAProjectCommandTrashesItsFile() throws {
    defer { cleanUp() }
    let file = project.appending(path: ".claude/commands/a/b.md")
    try write("Do b.", to: file)
    let plan = try actions.deletePlan(for: try row("a:b"))
    #expect(plan.steps == [.trash(file.skillPath)])
    try actions.delete(plan)
    #expect(!exists(file))
  }

  @Test func pluginSkillsAreNotDeleted() throws {
    defer { cleanUp() }
    let record = SkillRecord(
      name: "tools:lint", description: "", kind: .skill, origin: .plugin("tools@market"),
      realPath: outside.skillPath)
    #expect(throws: SkillActionError.self) { try actions.deletePlan(for: record) }
  }

  /// Review focus: a clone goes to the Trash with its last link, not before.
  @Test func aClonesLastLinkTakesTheCloneWithIt() throws {
    defer { cleanUp() }
    let clone = places.sources.appending(path: "local/me/repo", directoryHint: .isDirectory)
    let one = try skill(clone.appending(path: "skills/one"))
    let two = try skill(clone.appending(path: "skills/two"))
    let oneLink = account.appending(path: "skills/one")
    let twoLink = account.appending(path: "skills/two")
    try link(oneLink, to: one)
    try link(twoLink, to: two)
    let first = try actions.deletePlan(for: try row("one"))
    #expect(first.steps == [.removeLink(oneLink.skillPath)])
    #expect(first.lines.last?.contains("stays") == true)
    try actions.delete(first)
    let last = try actions.deletePlan(for: try row("two"))
    #expect(last.steps == [.removeLink(twoLink.skillPath), .trash(clone.skillPath)])
    try actions.delete(last)
    #expect(!exists(clone))
    #expect(exists(trash.appending(path: "repo")))
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/SkillActionsTests`
Expected: FAIL to build, `cannot find type 'SkillPlaces' in scope`.

- [ ] **Step 3: Write `SkillActions.swift`**

```swift
import DrakarKit
import Foundation

extension URL {
  /// The path as skill rows spell it: no trailing slash.
  var skillPath: String { ProjectPath.normalize(path(percentEncoded: false)) }
}

/// How the Skills window writes a path: under the home folder with `~`.
enum SkillText {
  static func path(
    _ path: String,
    home: String = FileManager.default.homeDirectoryForCurrentUser.skillPath
  ) -> String {
    let path = ProjectPath.normalize(path)
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
  }

  static func path(_ url: URL) -> String { path(url.skillPath) }
}

/// The two places a skill of the person's own lives.
enum SkillPlace: CaseIterable {
  /// The account's and `~/.agents`'s: every project.
  case user
  case project
}

extension SkillOrigin {
  /// The place an own skill lives in; nil for the others.
  var place: SkillPlace? {
    switch self {
    case .user: .user
    case .project: .project
    default: nil
    }
  }
}

extension SkillAgent {
  var kind: AgentKind { self == .claude ? .claude : .codex }
}

/// The folders one account and one project keep skills in: where installs and shares write,
/// and where a delete looks for links.
struct SkillPlaces: Equatable {
  var account: URL
  var home: URL
  var project: URL?

  /// Where an install or a share for `agent` writes in `place`; nil for the project without one.
  func folder(_ place: SkillPlace, for agent: SkillAgent) -> URL? {
    switch (place, agent) {
    case (.user, .claude): account.appending(path: "skills", directoryHint: .isDirectory)
    case (.user, .codex): home.appending(path: ".agents/skills", directoryHint: .isDirectory)
    case (.project, .claude):
      project?.appending(path: ".claude/skills", directoryHint: .isDirectory)
    case (.project, .codex):
      project?.appending(path: ".agents/skills", directoryHint: .isDirectory)
    }
  }

  /// Every folder a skill of the person's own sits in: the four install folders, Codex's
  /// `.codex/skills`, and the project's commands.
  var roots: [URL] {
    var roots = [
      account.appending(path: "skills", directoryHint: .isDirectory),
      home.appending(path: ".agents/skills", directoryHint: .isDirectory),
      home.appending(path: ".codex/skills", directoryHint: .isDirectory),
    ]
    if let project {
      roots += [".claude/skills", ".claude/commands", ".agents/skills", ".codex/skills"].map {
        project.appending(path: $0, directoryHint: .isDirectory)
      }
    }
    return roots
  }

  /// Codex's folders, read for links whose target is gone: Codex lists none of those.
  var codexFolders: [SkillFolder] {
    var folders = [
      SkillFolder(url: home.appending(path: ".agents/skills"), origin: .user),
      SkillFolder(url: home.appending(path: ".codex/skills"), origin: .user),
    ]
    if let project {
      folders += [
        SkillFolder(url: project.appending(path: ".agents/skills"), origin: .project),
        SkillFolder(url: project.appending(path: ".codex/skills"), origin: .project),
      ]
    }
    return folders
  }

  /// Where git installs clone to.
  var sources: URL { home.appending(path: ".agents/skill-sources", directoryHint: .isDirectory) }

  func clone(containing path: String) -> URL? { Self.clone(containing: path, sources: sources) }

  /// The clone `path` lies in, `<sources>/<host>/<owner>/<repo>`; nil outside them.
  static func clone(containing path: String, sources: URL) -> URL? {
    for root in spellings(of: sources) where ProjectPath.contains(root, path) && path != root {
      let parts = path.dropFirst(root.count + 1).split(separator: "/")
      guard parts.count >= 3 else { return nil }
      return URL(
        filePath: root + "/" + parts.prefix(3).joined(separator: "/"), directoryHint: .isDirectory)
    }
    return nil
  }

  /// A folder as written and as resolved, which differ when a link leads to it.
  static func spellings(of folder: URL) -> [String] {
    let written = folder.skillPath
    let real = SkillPath.real(written)
    return written == real ? [written] : [written, real]
  }
}

/// The file operations the actions make, apart so tests can give a trash of their own.
struct SkillFileSystem {
  /// Moves an item to the Trash; tests move it into a folder of theirs.
  var moveToTrash: (URL) throws -> Void = {
    try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
  }

  private var manager: FileManager { .default }

  /// Something is at `url`, a link whose target is gone included.
  func exists(_ url: URL) -> Bool {
    (try? manager.attributesOfItem(atPath: url.skillPath)) != nil
  }

  func isLink(_ url: URL) -> Bool { SkillPath.isLink(url.skillPath) }

  func createFolder(_ url: URL) throws {
    try manager.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func link(_ url: URL, to target: URL) throws {
    try manager.createSymbolicLink(at: url, withDestinationURL: target)
  }

  func copy(_ source: URL, to destination: URL) throws {
    try manager.copyItem(at: source, to: destination)
  }

  func trash(_ url: URL) throws { try moveToTrash(url) }

  /// Removes the link itself, never what it points to; anything else at `url` is refused.
  func removeLink(_ url: URL) throws {
    guard isLink(url) else {
      throw SkillActionError(
        message: String(localized: "\(SkillText.path(url)) is not a link, so it was left alone."))
    }
    try manager.removeItem(atPath: url.skillPath)
  }

  func children(of folder: URL) -> [URL] {
    ((try? manager.contentsOfDirectory(atPath: folder.skillPath)) ?? []).sorted().map {
      folder.appending(path: $0)
    }
  }

  /// The first `limit` bytes of a file, as text; nil when it cannot be read.
  func read(_ url: URL, limit: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

/// Why an action did nothing, as the window's alert says it.
struct SkillActionError: Error, LocalizedError, Equatable {
  var message: String
  var errorDescription: String? { message }

  static func exists(_ name: String, in folder: URL) -> SkillActionError {
    SkillActionError(
      message: String(
        localized: "A skill named \(name) is already in \(SkillText.path(folder)). Nothing was written."))
  }
}

/// What a delete will do, step by step, and the sentences the confirmation says it in.
struct DeletePlan: Equatable {
  enum Step: Hashable {
    case removeLink(String)
    case trash(String)
  }

  var steps: [Step] = []
  var lines: [String] = []

  func removes(_ link: String) -> Bool { steps.contains(.removeLink(link)) }

  mutating func removeLink(_ link: String) {
    guard !removes(link) else { return }
    steps.append(.removeLink(link))
    lines.append(
      String(localized: "Remove the link at \(SkillText.path(link)) (the folder it points to stays)."))
  }

  mutating func trash(_ item: String, saying line: String) {
    steps.append(.trash(item))
    lines.append(line)
  }
}

/// How Install from Folder… puts a skill in place.
enum InstallMethod {
  /// A link per agent to the folder where it is.
  case link
  /// Copied once into the first agent's folder, the other agent linked to the copy.
  case copy
}

/// The Skills window's file operations: share, delete, install. Nothing overwrites: a name
/// already taken at a destination is refused before anything is written.
struct SkillActions {
  var places: SkillPlaces
  var files = SkillFileSystem()

  /// A link, in the other agent's folder of the same place, to the skill's real folder;
  /// returns the link.
  @discardableResult
  func share(_ record: SkillRecord) throws -> URL {
    guard record.canShare, let place = record.origin.place,
      let seen = record.sightings.first(where: { $0.path != nil }), let seenPath = seen.path
    else {
      throw SkillActionError(
        message: String(localized: "Only your own skills and the project's can be shared; commands cannot."))
    }
    let other = seen.agent.other
    guard record.sighting(for: other) == nil else {
      throw SkillActionError(
        message: String(localized: "\(other.kind.name) already sees \(record.name)."))
    }
    guard let folder = places.folder(place, for: other) else {
      throw SkillActionError(message: String(localized: "Choose a project to share its skills."))
    }
    let destination = folder.appending(path: URL(filePath: seenPath).lastPathComponent)
    guard !files.exists(destination) else {
      throw SkillActionError.exists(destination.lastPathComponent, in: folder)
    }
    try files.createFolder(folder)
    try files.link(destination, to: URL(filePath: record.realPath))
    return destination
  }

  /// What deleting `record` does: each link to it goes; the real folder (or command file)
  /// goes to the Trash when it lies in one of the skill folders, a clone with its last link,
  /// and anything else stays.
  func deletePlan(for record: SkillRecord) throws -> DeletePlan {
    guard record.canDelete else {
      throw SkillActionError(
        message: String(
          localized: "\(record.name) is not yours to delete here: plugins, Codex's own skills and unknown ones are managed elsewhere."
        ))
    }
    var plan = DeletePlan()
    for sighting in record.sightings where sighting.isLink {
      if let path = sighting.path { plan.removeLink(ProjectPath.normalize(path)) }
    }
    for link in links(where: { $0 == record.realPath }) { plan.removeLink(link) }
    guard !record.isMissing, files.exists(URL(filePath: record.realPath)) else { return plan }
    let shown = SkillText.path(record.realPath)
    if let clone = places.clone(containing: record.realPath) {
      let spellings = SkillPlaces.spellings(of: clone)
      let others = links { target in spellings.contains { ProjectPath.contains($0, target) } }
        .filter { !plan.removes($0) }
      if others.isEmpty {
        plan.trash(
          clone.skillPath,
          saying: String(
            localized: "Move the clone at \(SkillText.path(clone)) to the Trash: no other skill links into it."))
      } else {
        plan.lines.append(
          String(localized: "The clone at \(SkillText.path(clone)) stays: other skills still link into it."))
      }
    } else if isInRoots(record.realPath) {
      plan.trash(record.realPath, saying: String(localized: "Move \(shown) to the Trash."))
    } else {
      plan.lines.append(String(localized: "\(shown) stays: it is outside the skill folders."))
    }
    return plan
  }

  /// Carries out a plan: the links first, then the Trash.
  func delete(_ plan: DeletePlan) throws {
    for step in plan.steps {
      switch step {
      case .removeLink(let path): try files.removeLink(URL(filePath: path))
      case .trash(let path): try files.trash(URL(filePath: path))
      }
    }
  }

  /// The links directly in the roots whose resolved target `matches`.
  private func links(where matches: (String) -> Bool) -> [String] {
    places.roots.flatMap(files.children(of:))
      .filter { files.isLink($0) && matches(resolved($0)) }
      .map(\.skillPath)
  }

  /// A live link's real path; a dead one's target as written.
  private func resolved(_ link: URL) -> String {
    let path = link.skillPath
    return FileManager.default.fileExists(atPath: path)
      ? SkillPath.real(path) : SkillPath.target(ofLink: path) ?? path
  }

  private func isInRoots(_ path: String) -> Bool {
    places.roots.flatMap(SkillPlaces.spellings(of:)).contains {
      ProjectPath.contains($0, path) && $0 != path
    }
  }
}
```

- [ ] **Step 4: Run the tests**

Run the focused `SkillActionsTests` command, then `make -C apps/apple test-app` and `make -C apps/apple test`.
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Drakar/Services/SkillActions.swift apps/apple/DrakarTests/SkillActionsTests.swift
git commit -m "feat(apple): share and delete skills without leaving dangling links"
```

---

### Task 7: Install from a folder

**Files:**
- Modify: `apps/apple/Drakar/Services/SkillActions.swift` (add `install`)
- Test: `apps/apple/DrakarTests/SkillActionsTests.swift` (add tests)

**Interfaces:**
- Consumes: `SkillActions`, `SkillPlaces`, `SkillFileSystem`, `SkillActionError`, `InstallMethod`, `SkillPlace` (Task 6); `SkillPath.real` (Task 2).
- Produces: `SkillActions.install(_ sources: [URL], place: SkillPlace, agents: [SkillAgent], method: InstallMethod) throws -> [URL]` (the links and copies made, Claude Code's first for each source).

- [ ] **Step 1: Write the failing tests** (append inside `SkillActionsTests`)

```swift
  @Test func installsByLinkingForBothAgents() throws {
    defer { cleanUp() }
    let one = try skill(outside.appending(path: "lib/one"))
    let made = try actions.install([one], place: .user, agents: [.codex, .claude], method: .link)
    #expect(
      made.map(\.skillPath) == [
        account.appending(path: "skills/one").skillPath,
        home.appending(path: ".agents/skills/one").skillPath,
      ])
    for url in made {
      #expect(SkillPath.isLink(url.skillPath))
      #expect(SkillPath.real(url.skillPath) == one.skillPath)
    }
  }

  @Test func aCopyIsMadeOnceAndLinkedForTheOtherAgent() throws {
    defer { cleanUp() }
    let one = try skill(outside.appending(path: "lib/one"))
    try actions.install([one], place: .user, agents: [.claude, .codex], method: .copy)
    let copy = account.appending(path: "skills/one")
    #expect(!SkillPath.isLink(copy.skillPath))
    #expect(FileManager.default.fileExists(atPath: copy.appending(path: "SKILL.md").skillPath))
    #expect(SkillPath.real(home.appending(path: ".agents/skills/one").skillPath) == copy.skillPath)
    #expect(exists(one.appending(path: "SKILL.md")))
  }

  @Test func installsIntoTheProjectForOneAgent() throws {
    defer { cleanUp() }
    let one = try skill(outside.appending(path: "lib/one"))
    try actions.install([one], place: .project, agents: [.codex], method: .link)
    #expect(SkillPath.isLink(project.appending(path: ".agents/skills/one").skillPath))
    #expect(!exists(project.appending(path: ".claude/skills/one")))
  }

  /// A name taken at any destination refuses the whole install: nothing is written.
  @Test func aClashRefusesTheWholeInstall() throws {
    defer { cleanUp() }
    let one = try skill(outside.appending(path: "lib/one"))
    let two = try skill(outside.appending(path: "lib/two"))
    try skill(home.appending(path: ".agents/skills/two"))
    #expect(
      throws: SkillActionError.exists(
        "two", in: home.appending(path: ".agents/skills", directoryHint: .isDirectory))
    ) { try actions.install([one, two], place: .user, agents: [.claude, .codex], method: .link) }
    #expect(!exists(account.appending(path: "skills/one")))
    #expect(!exists(home.appending(path: ".agents/skills/one")))
  }

  /// Review focus: with no project chosen there is no project to install into.
  @Test func withoutAProjectOnlyYoursCanBeInstalledInto() throws {
    defer { cleanUp() }
    let one = try skill(outside.appending(path: "lib/one"))
    let actions = SkillActions(
      places: SkillPlaces(account: account, home: home, project: nil), files: files)
    #expect(throws: SkillActionError.self) {
      try actions.install([one], place: .project, agents: [.claude], method: .link)
    }
    try actions.install([one], place: .user, agents: [.claude], method: .link)
    #expect(SkillPath.isLink(account.appending(path: "skills/one").skillPath))
  }

  @Test func aFolderWithoutASkillIsRefused() throws {
    defer { cleanUp() }
    let empty = outside.appending(path: "empty", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(throws: SkillActionError.self) {
      try actions.install([empty], place: .user, agents: [.claude], method: .link)
    }
    #expect(throws: SkillActionError.self) {
      try actions.install([], place: .user, agents: [], method: .link)
    }
  }
```

- [ ] **Step 2: Run them to see them fail**

Run the focused `SkillActionsTests` command.
Expected: FAIL to build, `value of type 'SkillActions' has no member 'install'`.

- [ ] **Step 3: Add `install` to `SkillActions`** (after `delete(_:)`)

```swift
  /// Puts each skill folder of `sources` into `place` for `agents`, Claude Code first: a link
  /// per agent, or one copy and links to it. Every destination is checked before anything is
  /// written; returns what was made.
  @discardableResult
  func install(
    _ sources: [URL], place: SkillPlace, agents: [SkillAgent], method: InstallMethod
  ) throws -> [URL] {
    let agents = SkillAgent.allCases.filter(agents.contains)
    guard !agents.isEmpty, !sources.isEmpty else {
      throw SkillActionError(message: String(localized: "Choose a skill, and Claude Code, Codex or both."))
    }
    let folders = try agents.map { agent in
      guard let folder = places.folder(place, for: agent) else {
        throw SkillActionError(message: String(localized: "Choose a project to install into it."))
      }
      return folder
    }
    var names = Set<String>()
    for source in sources {
      let name = source.lastPathComponent
      guard
        FileManager.default.fileExists(atPath: source.appending(path: "SKILL.md").skillPath)
      else {
        throw SkillActionError(
          message: String(localized: "\(SkillText.path(source)) has no SKILL.md, so it is not a skill."))
      }
      guard names.insert(name).inserted else {
        throw SkillActionError(message: String(localized: "Two of the chosen skills are named \(name)."))
      }
      for folder in folders where files.exists(folder.appending(path: name)) {
        throw SkillActionError.exists(name, in: folder)
      }
    }
    var made: [URL] = []
    for source in sources {
      let name = source.lastPathComponent
      var target = URL(filePath: SkillPath.real(source.skillPath), directoryHint: .isDirectory)
      for (index, folder) in folders.enumerated() {
        try files.createFolder(folder)
        let destination = folder.appending(path: name)
        if method == .copy, index == 0 {
          try files.copy(target, to: destination)
          target = destination
        } else {
          try files.link(destination, to: target)
        }
        made.append(destination)
      }
    }
    return made
  }
```

- [ ] **Step 4: Run the tests**

Run the focused `SkillActionsTests` command, then `make -C apps/apple test-app` and `make -C apps/apple test`.
Expected: PASS (17 tests).

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Drakar/Services/SkillActions.swift apps/apple/DrakarTests/SkillActionsTests.swift
git commit -m "feat(apple): install skills from a folder by link or copy"
```

---

### Task 8: Install from git

**Files:**
- Create: `apps/apple/Drakar/Services/SkillSources.swift`
- Test: `apps/apple/DrakarTests/SkillSourcesTests.swift`

**Interfaces:**
- Consumes: `GitSource`, `SkillFolderSearch` (Task 4); `SkillPlaces.clone(containing:sources:)`, `SkillActionError`, `SkillActions`, `URL.skillPath` (Tasks 6, 7); `AgentSession.environment` (app).
- Produces: `nonisolated enum GitRunner` with `GitRunner.Output { status: Int32; output: String; errors: String; timedOut: Bool }`; `GitRunner.locate(path: String?, isExecutable:) -> URL?`; `GitRunner.run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration) async throws -> Output`; `struct SkillSources { root: URL; environment: () async -> [String: String]; timeout: Duration = .seconds(120); fetch(_ address: String) async throws -> URL; update(_ record: SkillRecord) async throws }`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Clones from a repository made in the test, by a `file://` address; `git` runs with no
/// system or global configuration, so the person's signing and hooks never reach it.
@MainActor
@Suite("Skills installed from git")
struct SkillSourcesTests {
  private let root: URL
  private let home: URL
  private let account: URL
  private let origin: URL
  private let trash: URL

  init() throws {
    root = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-skill-sources-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    account = home.appending(path: ".claude-test", directoryHint: .isDirectory)
    origin = root.appending(path: "origin/skills-repo", directoryHint: .isDirectory)
    trash = root.appending(path: "trash", directoryHint: .isDirectory)
    for folder in [account, origin, trash] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  private func cleanUp() { try? FileManager.default.removeItem(at: root) }

  private var environment: [String: String] {
    [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": home.skillPath,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
    ]
  }

  private var places: SkillPlaces { SkillPlaces(account: account, home: home, project: nil) }

  private var sources: SkillSources {
    let environment = environment
    return SkillSources(root: places.sources, environment: { environment })
  }

  private var actions: SkillActions {
    let trash = trash
    return SkillActions(
      places: places,
      files: SkillFileSystem(moveToTrash: { item in
        try FileManager.default.moveItem(at: item, to: trash.appending(path: item.lastPathComponent))
      }))
  }

  private var address: String { "file://" + origin.skillPath }

  private func git(_ arguments: [String]) async throws {
    let executable = try #require(GitRunner.locate(path: environment["PATH"]))
    let result = try await GitRunner.run(
      executable, ["-C", origin.skillPath] + arguments, environment: environment,
      timeout: .seconds(30))
    try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.errors)")
  }

  private func skill(_ name: String, description: String = "") throws {
    let folder = origin.appending(path: "skills/\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("---\nname: \(name)\ndescription: \(description)\n---\n".utf8).write(
      to: folder.appending(path: "SKILL.md"))
  }

  private func commit(_ message: String) async throws {
    try await git(["add", "-A"])
    try await git([
      "-c", "user.name=Drakar", "-c", "user.email=tests@drakar.invalid", "-c",
      "commit.gpgsign=false", "commit", "-q", "-m", message,
    ])
  }

  private func makeOrigin() async throws {
    try skill("one")
    try skill("two")
    try await git(["init", "-q", "-b", "main"])
    try await commit("Two skills")
  }

  private func rows() -> [SkillRecord] {
    SkillInventory.merge(
      scan: ClaudeSkillScan.scan(account: account, project: nil).skills, claude: nil, codex: nil)
  }

  @Test func clonesOnceAndLinksTheChosenSkills() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    #expect(clone.skillPath == places.sources.appending(path: "local/origin/skills-repo").skillPath)
    let found = SkillFolderSearch.skills(in: clone, depth: 4)
    #expect(found.map(\.lastPathComponent) == ["one", "two"])
    try actions.install([found[0]], place: .user, agents: [.claude, .codex], method: .link)
    let linked = SkillPath.real(account.appending(path: "skills/one").skillPath)
    #expect(linked == found[0].skillPath)
    #expect(places.clone(containing: linked)?.skillPath == clone.skillPath)
  }

  /// An address cloned before is pulled, not cloned again.
  @Test func fetchingAgainPullsTheClone() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    try skill("three")
    try await commit("A third")
    #expect(try await sources.fetch(address).skillPath == clone.skillPath)
    #expect(
      FileManager.default.fileExists(atPath: clone.appending(path: "skills/three/SKILL.md").skillPath))
  }

  @Test func updatePullsTheCloneASkillCameFrom() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    try actions.install(
      [clone.appending(path: "skills/one", directoryHint: .isDirectory)], place: .user,
      agents: [.claude], method: .link)
    let record = try #require(rows().first { $0.name == "one" })
    try skill("one", description: "Better.")
    try await commit("A better one")
    try await sources.update(record)
    let text = try String(
      contentsOf: clone.appending(path: "skills/one/SKILL.md"), encoding: .utf8)
    #expect(text.contains("Better."))
  }

  /// Review focus: the clone goes to the Trash with its last link.
  @Test func theCloneGoesWithItsLastLink() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    try actions.install(
      SkillFolderSearch.skills(in: clone, depth: 4), place: .user, agents: [.claude],
      method: .link)
    for name in ["one", "two"] {
      let record = try #require(rows().first { $0.name == name })
      try actions.delete(try actions.deletePlan(for: record))
    }
    #expect(!FileManager.default.fileExists(atPath: clone.skillPath))
    #expect(FileManager.default.fileExists(atPath: trash.appending(path: "skills-repo").skillPath))
  }

  @Test func gitsOwnWordsSayWhatFailed() async throws {
    defer { cleanUp() }
    let missing = "file://" + root.appending(path: "nowhere/repo").skillPath
    let error = await #expect(throws: SkillActionError.self) {
      try await sources.fetch(missing)
    }
    #expect(error?.message.contains("fatal") == true)
  }

  @Test func withoutGitItSaysSo() async throws {
    defer { cleanUp() }
    let sources = SkillSources(root: places.sources, environment: { ["PATH": "/nowhere"] })
    let error = await #expect(throws: SkillActionError.self) {
      try await sources.fetch("https://github.com/me/skills")
    }
    #expect(error?.message == "Git was not found. Install the Xcode command line tools.")
  }

  @Test func anAddressGitCannotCloneIsRefused() async throws {
    defer { cleanUp() }
    let error = await #expect(throws: SkillActionError.self) {
      try await sources.fetch("skills please")
    }
    #expect(error?.message.contains("is not a git URL") == true)
  }

  @Test func aGitThatHangsIsStopped() async throws {
    defer { cleanUp() }
    let result = try await GitRunner.run(
      URL(filePath: "/bin/sleep"), ["5"], environment: [:], timeout: .milliseconds(200))
    #expect(result.timedOut)
    #expect(result.status != 0)
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/SkillSourcesTests`
Expected: FAIL to build, `cannot find 'SkillSources' in scope`.

- [ ] **Step 3: Write `SkillSources.swift`**

```swift
import DrakarKit
import Foundation

/// Runs `git`, both outputs read as they come so a full pipe never stalls it, and stops it
/// after a timeout. Waits on the termination handler rather than `waitUntilExit`, which can
/// hold a thread of the shared pool (see `ClaudeVersion.read`). Off the main actor: it waits
/// on a process.
nonisolated enum GitRunner {
  nonisolated struct Output: Sendable {
    var status: Int32
    var output: String
    var errors: String
    /// Stopped by the timeout.
    var timedOut: Bool
  }

  /// The first `git` on `path`; nil when there is none.
  static func locate(
    path: String?,
    isExecutable: (URL) -> Bool = {
      FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false))
    }
  ) -> URL? {
    (path ?? "").split(separator: ":").lazy
      .map { URL(filePath: String($0)).appending(path: "git") }
      .first(where: isExecutable)
  }

  static func run(
    _ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration
  ) async throws -> Output {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    let (ended, ending) = AsyncStream<Void>.makeStream()
    process.terminationHandler = { _ in ending.finish() }
    try process.run()
    let watchdog = Task {
      try await Task.sleep(for: timeout)
      if process.isRunning { process.terminate() }
      return true
    }
    async let out = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
    async let err = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
    let (outData, errData) = await (out, err)
    for await _ in ended {}
    watchdog.cancel()
    let timedOut = (try? await watchdog.value) == true
    return Output(
      status: process.terminationStatus, output: String(decoding: outData, as: UTF8.self),
      errors: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
  }
}

/// Skills installed from git: each repository cloned once, shallow, under
/// `~/.agents/skill-sources/<host>/<owner>/<repo>`, pulled to update, and its skills linked
/// into the agents' folders like any other.
struct SkillSources {
  var root: URL
  /// The login shell's, so `git` and its credential helpers are found as in a terminal.
  var environment: () async -> [String: String] = { await AgentSession.environment.value }
  var timeout: Duration = .seconds(120)

  /// Clones `address`, or pulls the clone already there; returns the clone's folder.
  func fetch(_ address: String) async throws -> URL {
    let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let source = GitSource(address) else {
      throw SkillActionError(
        message: String(
          localized: "\(address) is not a git URL Drakar can clone. Use https://host/owner/repo or git@host:owner/repo."
        ))
    }
    let folder = source.folder(in: root)
    if FileManager.default.fileExists(atPath: folder.appending(path: ".git").skillPath) {
      try await git(["-C", folder.skillPath, "pull", "--ff-only"])
    } else {
      try FileManager.default.createDirectory(
        at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
      try await git(["clone", "--depth", "1", address, folder.skillPath])
    }
    return folder
  }

  /// Pulls the clone `record` was installed from.
  func update(_ record: SkillRecord) async throws {
    guard let clone = SkillPlaces.clone(containing: record.realPath, sources: root) else {
      throw SkillActionError(message: String(localized: "\(record.name) was not installed from git."))
    }
    try await git(["-C", clone.skillPath, "pull", "--ff-only"])
  }

  private func git(_ arguments: [String]) async throws {
    let environment = await environment()
    guard let executable = GitRunner.locate(path: environment["PATH"]) else {
      throw SkillActionError(
        message: String(localized: "Git was not found. Install the Xcode command line tools."))
    }
    let result = try await GitRunner.run(
      executable, arguments, environment: environment, timeout: timeout)
    if result.timedOut {
      throw SkillActionError(
        message: String(
          localized: "Git took longer than \(Int(timeout.components.seconds)) seconds and was stopped."))
    }
    guard result.status == 0 else {
      let words = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
      throw SkillActionError(
        message: words.isEmpty ? String(localized: "Git failed with status \(result.status).") : words)
    }
  }
}
```

- [ ] **Step 4: Run the tests**

Run the focused `SkillSourcesTests` command, then `make -C apps/apple test-app` and `make -C apps/apple test`.
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Drakar/Services/SkillSources.swift apps/apple/DrakarTests/SkillSourcesTests.swift
git commit -m "feat(apple): install skills from git into a managed clone"
```

---

### Task 9: The window's model

**Files:**
- Create: `apps/apple/Drakar/Services/SkillsManager.swift`
- Modify: `apps/apple/Drakar/Services/Project.swift` (skill-file observers)
- Test: `apps/apple/DrakarTests/SkillsManagerTests.swift`

**Interfaces:**
- Consumes: everything above; `AccountStore.shared.windowAccount(for:)`, `AccountStore.shared.shellAccount`, `ClaudeChoice.newSessionAccount`, `OpenSessions.shared.projects`, `CodexSkillStore.shared.skills(for:)`, `CapabilityStore.shared.capabilities(for:account:)`, `Capabilities` (`lists`, `isLoading`, `loadIfNeeded`, `refresh`, `refreshIfLoaded`, `probe`), `FolderWatcher`, `Workspace.open(_:)`, `Workspace.window`.
- Produces:
  - `Project.observeSkillFiles(_ handler: @escaping () -> Void) -> UUID`, `Project.stopObservingSkillFiles(_: UUID)`;
  - `enum SkillsPlace: String, CaseIterable, Identifiable { case all, yours, project, plugins, codex; includes(_: SkillRecord) -> Bool }`;
  - `@Observable final class SkillsManager` with `static let shared`, `static let windowID = "skills"`, `init()`; state `project: URL?` (read-only), `place`, `filter`, `selection: SkillRecord.ID?`, `scan`, `failure: String?`, `isFetching`; seams `home`, `accountFor`, `openFolders`, `projectAt`, `codexFor`, `claudeFor`, `files`, `environment`; reading `account`, `places`, `codex`, `claude`, `records`, `shown`, `count(_:)`, `selected`, `visiblePlaces`, `problems`, `isLoading`; `show(project:open:)`, `choose(project:)`, `openProjectsChanged()`, `start()`, `stop()`, `refresh(load:)`, `projectFilesChanged()`, `userFilesChanged()`; actions `share(_:)`, `deletePlan(for:) -> DeletePlan?`, `delete(_:)`, `install(_:place:agents:method:)`, `fetch(_:) async throws -> [URL]`, `update(_:) async`, `isFromGit(_:)`, `preview(of:) -> String?`, `open(_:)`, `reveal(_:)`; statics `account(for:)`, `openProjectFolders()`, `openProject(at:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("The Skills window's model")
struct SkillsManagerTests {
  /// Codex and Claude Code standing in, one list per folder, each read counted.
  final class Stubs {
    var codexRecords: [CodexSkillRecord] = []
    var claudeSkills: [SkillEntry]?
    var codex: [String: CodexSkills] = [:]
    var claude: [String: Capabilities] = [:]
    var forced: [Bool] = []
    var probes = 0
  }

  final class Counter { var count = 0 }

  private let root: URL
  private let home: URL
  private let account: URL
  private let project: URL
  private let trash: URL

  init() throws {
    root = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-skills-window-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    account = home.appending(path: ".claude-test", directoryHint: .isDirectory)
    project = root.appending(path: "project", directoryHint: .isDirectory)
    trash = root.appending(path: "trash", directoryHint: .isDirectory)
    for folder in [account, project, trash] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try skill(account.appending(path: "skills/review"), description: "Review the diff.")
    try skill(project.appending(path: ".claude/skills/deploy"))
  }

  private func cleanUp() { try? FileManager.default.removeItem(at: root) }

  private func skill(_ folder: URL, description: String = "") throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("---\nname: \(folder.lastPathComponent)\ndescription: \(description)\n---\n".utf8)
      .write(to: folder.appending(path: "SKILL.md"))
  }

  private func settle(_ manager: SkillsManager) async throws {
    for _ in 0..<100 where manager.isLoading {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// A manager over this test's folders, its trash and stand-ins; the project is open.
  private func manager(_ stubs: Stubs) -> SkillsManager {
    let manager = SkillsManager()
    manager.home = home
    let claudeAccount = ClaudeAccount(directory: account, isDefault: false)
    manager.accountFor = { _ in claudeAccount }
    let project = project
    manager.openFolders = { [project] }
    manager.projectAt = { _ in nil }
    let trash = trash
    manager.files = SkillFileSystem(moveToTrash: { item in
      try FileManager.default.moveItem(at: item, to: trash.appending(path: item.lastPathComponent))
    })
    manager.codexFor = { folder in
      if let entry = stubs.codex[folder.skillPath] { return entry }
      let entry = CodexSkills(folder: folder)
      entry.reader = { _, force in
        stubs.forced.append(force)
        return CodexSkillList.Listing(records: stubs.codexRecords)
      }
      stubs.codex[folder.skillPath] = entry
      return entry
    }
    manager.claudeFor = { folder, account in
      if let entry = stubs.claude[folder.skillPath] { return entry }
      let entry = Capabilities(folder: folder, account: account)
      entry.probe = { _, _ in
        stubs.probes += 1
        return ProbeOutcome(capabilities: ProjectCapabilities(skills: stubs.claudeSkills))
      }
      stubs.claude[folder.skillPath] = entry
      return entry
    }
    return manager
  }

  /// The project window's account; with no project, Settings' for new sessions.
  @Test func theAccountIsTheProjectWindowsOrSettings() throws {
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      cleanUp()
    }
    let settings = root.appending(path: ".claude-settings", directoryHint: .isDirectory)
    let picked = root.appending(path: ".claude-picked", directoryHint: .isDirectory)
    for folder in [settings, picked] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    defaults.set(settings.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
    ClaudeChoice.$testSuite.withValue(suite) {
      ClaudeChoice.pick(ClaudeChoice.account(at: picked.path(percentEncoded: false)), for: project)
      #expect(SkillsManager.account(for: nil).name == "settings")
      #expect(SkillsManager.account(for: project).name == "picked")
    }
  }

  /// Review focus: with no project, user-level skills only, both agents asked about the home
  /// folder, and no "This project"; choosing the project adds its place and its skills.
  @Test func aProjectAddsItsPlaceAndItsSkills() async throws {
    defer { cleanUp() }
    let stubs = Stubs()
    let manager = manager(stubs)
    manager.refresh(load: true)
    try await settle(manager)
    #expect(manager.records.map(\.name) == ["review"])
    #expect(!manager.visiblePlaces.contains(.project))
    #expect(stubs.codex[home.skillPath]?.hasLoaded == true)
    #expect(stubs.claude[home.skillPath] != nil)
    manager.choose(project: project)
    try await settle(manager)
    #expect(manager.records.map(\.name) == ["deploy", "review"])
    #expect(manager.visiblePlaces.contains(.project))
    #expect(stubs.codex[project.skillPath]?.hasLoaded == true)
    #expect(manager.places.project?.skillPath == project.skillPath)
    manager.place = .project
    manager.choose(project: nil)
    #expect(manager.place == .all)
  }

  @Test func placesAndTheFilterNarrowTheList() async throws {
    defer { cleanUp() }
    let stubs = Stubs()
    stubs.codexRecords = [
      CodexSkillRecord(
        name: "skill-creator", description: "",
        path: "/Users/me/.codex/skills/.system/skill-creator/SKILL.md", scope: .system,
        pluginID: nil, isEnabled: true)
    ]
    let manager = manager(stubs)
    manager.choose(project: project)
    try await settle(manager)
    #expect(manager.count(.all) == 3)
    #expect(manager.count(.yours) == 1)
    #expect(manager.count(.project) == 1)
    #expect(manager.count(.codex) == 1)
    #expect(manager.count(.plugins) == 0)
    manager.place = .yours
    #expect(manager.shown.map(\.name) == ["review"])
    manager.place = .all
    manager.filter = "diff"
    #expect(manager.shown.map(\.name) == ["review"])
    manager.filter = "DEP"
    #expect(manager.shown.map(\.name) == ["deploy"])
  }

  /// After an action the folders are read again at once, and both agents asked again.
  @Test func anActionReadsEverythingAgain() async throws {
    defer { cleanUp() }
    let stubs = Stubs()
    let manager = manager(stubs)
    manager.choose(project: project)
    try await settle(manager)
    let probes = stubs.probes
    let deploy = try #require(manager.records.first { $0.name == "deploy" })
    manager.share(deploy)
    #expect(manager.failure == nil)
    try await settle(manager)
    #expect(stubs.forced.last == true)
    #expect(stubs.probes > probes)
    let shared = project.appending(path: ".agents/skills/deploy")
    #expect(SkillPath.isLink(shared.skillPath))
    let plan = try #require(manager.deletePlan(for: deploy))
    manager.delete(plan)
    #expect(!manager.records.contains { $0.name == "deploy" })
    #expect(FileManager.default.fileExists(atPath: trash.appending(path: "deploy").skillPath))
    #expect(!SkillPath.isLink(shared.skillPath))
  }

  /// A refusal is said in the alert, and nothing changes.
  @Test func aRefusalIsSaid() async throws {
    defer { cleanUp() }
    let manager = manager(Stubs())
    manager.choose(project: project)
    let review = try #require(manager.records.first { $0.name == "review" })
    try skill(home.appending(path: ".agents/skills/review"))
    manager.share(review)
    #expect(manager.failure?.hasPrefix("A skill named review is already in") == true)
  }

  @Test func aSkillRemovedByHandClearsTheSelection() async throws {
    defer { cleanUp() }
    let manager = manager(Stubs())
    manager.choose(project: project)
    try await settle(manager)
    let review = try #require(manager.records.first { $0.name == "review" })
    manager.selection = review.id
    #expect(manager.selected?.name == "review")
    try FileManager.default.removeItem(at: account.appending(path: "skills/review"))
    manager.projectFilesChanged()
    #expect(manager.selection == nil)
    #expect(manager.selected == nil)
  }

  /// The inspector's Manage… and Window › Skills: the window opens on the project asked for,
  /// keeps its project when none is, and drops one no longer open.
  @Test func manageOpensTheWindowOnItsProject() {
    defer { cleanUp() }
    let manager = manager(Stubs())
    var opened: [String] = []
    manager.show(project: project) { opened.append($0) }
    #expect(opened == ["skills"])
    #expect(manager.project?.skillPath == project.skillPath)
    manager.show(project: nil) { opened.append($0) }
    #expect(manager.project?.skillPath == project.skillPath)
    manager.openFolders = { [] }
    manager.show(project: nil) { opened.append($0) }
    #expect(manager.project == nil)
    #expect(opened == ["skills", "skills", "skills"])
  }

  @Test func thePreviewIsTheFirstFourKilobytes() throws {
    defer { cleanUp() }
    let manager = manager(Stubs())
    let long = account.appending(path: "skills/long")
    try FileManager.default.createDirectory(at: long, withIntermediateDirectories: true)
    try Data(("---\nname: long\n---\n" + String(repeating: "x", count: 10_000)).utf8).write(
      to: long.appending(path: "SKILL.md"))
    manager.refresh(load: true)
    let record = try #require(manager.records.first { $0.name == "long" })
    #expect(manager.preview(of: record)?.utf8.count == 4096)
  }

  /// A project window tells the Skills window about its skill files as they change.
  @Test func aProjectsSkillFileChangeIsHeard() async throws {
    let window = Project(folder: project)
    defer {
      window.stopAll()
      cleanUp()
    }
    let heard = Counter()
    let id = window.observeSkillFiles { heard.count += 1 }
    for attempt in 0..<5 where heard.count == 0 {
      try skill(project.appending(path: ".claude/skills/s\(attempt)"))
      for _ in 0..<10 where heard.count == 0 {
        try await Task.sleep(for: .milliseconds(100))
      }
    }
    #expect(heard.count > 0)
    window.stopObservingSkillFiles(id)
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/SkillsManagerTests`
Expected: FAIL to build, `cannot find 'SkillsManager' in scope`.

- [ ] **Step 3: Add the skill-file observers to `Project.swift`**

Below `@ObservationIgnored private var codexSkillRefresh: Task<Void, Never>?` add:

```swift
  /// Who hears the project's skill files change as it happens: the Skills window.
  @ObservationIgnored private var skillFileObservers: [UUID: () -> Void] = [:]
```

Just above `private func observeCapabilities()`, add:

```swift
  /// `handler` hears each change to a file either agent reads the project's skills from, as
  /// it comes (the lists themselves are read again once changes settle).
  func observeSkillFiles(_ handler: @escaping () -> Void) -> UUID {
    let id = UUID()
    skillFileObservers[id] = handler
    return id
  }

  func stopObservingSkillFiles(_ id: UUID) {
    skillFileObservers[id] = nil
  }

  private func tellSkillFileObservers() {
    for handler in skillFileObservers.values { handler() }
  }
```

and make the first line of both `capabilityFilesChanged()` and `codexSkillFilesChanged()` a call to `tellSkillFileObservers()`.

- [ ] **Step 4: Write `SkillsManager.swift`**

```swift
import AppKit
import DrakarKit
import Foundation
import Observation

/// A place of the Skills window's sidebar.
enum SkillsPlace: String, CaseIterable, Identifiable {
  case all, yours, project, plugins, codex

  var id: Self { self }

  func includes(_ record: SkillRecord) -> Bool {
    switch self {
    case .all: true
    case .yours: record.origin == .user
    case .project: record.origin == .project
    case .plugins: if case .plugin = record.origin { true } else { false }
    case .codex: record.origin == .codexSystem || record.origin == .codexAdmin
    }
  }
}

/// The Skills window's model: one project's skills (or none) under its window's account, as
/// both agents see them, and what the window does to them. One for the app, as the window is.
@Observable
final class SkillsManager {
  static let shared = SkillsManager()
  static let windowID = "skills"

  /// The project shown; nil for the account's and `~/.agents`'s skills only.
  private(set) var project: URL?
  var place: SkillsPlace = .all
  var filter = ""
  var selection: SkillRecord.ID?
  /// The last reading of the places Claude Code reads.
  private(set) var scan = ClaudeSkillScan.Result()
  /// Why the last action did nothing, for the alert.
  var failure: String?
  /// A git clone or pull is running.
  private(set) var isFetching = false

  /// The seams tests replace: the home folder, the account, the open projects, both agents'
  /// lists, the disk's trash, the login shell's environment.
  @ObservationIgnored var home = FileManager.default.homeDirectoryForCurrentUser
  @ObservationIgnored var accountFor: (URL?) -> ClaudeAccount = { SkillsManager.account(for: $0) }
  @ObservationIgnored var openFolders: () -> [URL] = { SkillsManager.openProjectFolders() }
  @ObservationIgnored var projectAt: (URL) -> Project? = { SkillsManager.openProject(at: $0) }
  @ObservationIgnored var codexFor: (URL) -> CodexSkills = {
    CodexSkillStore.shared.skills(for: $0)
  }
  @ObservationIgnored var claudeFor: (URL, ClaudeAccount) -> Capabilities = {
    CapabilityStore.shared.capabilities(for: $0, account: $1)
  }
  @ObservationIgnored var files = SkillFileSystem()
  @ObservationIgnored var environment: () async -> [String: String] = {
    await AgentSession.environment.value
  }
  @ObservationIgnored private var watchers: [FolderWatcher] = []
  @ObservationIgnored private var observed: (project: Project, id: UUID)?
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var merged: (inputs: Inputs, records: [SkillRecord])?

  private struct Inputs: Equatable {
    var scan: [ScannedSkill]
    var claude: [SkillEntry]?
    var codex: [CodexSkillRecord]?
  }

  init() {}

  // MARK: - What is shown

  /// The project window's account, else Settings' for new sessions.
  var account: ClaudeAccount { accountFor(project) }
  var places: SkillPlaces { SkillPlaces(account: account.directory, home: home, project: project) }
  /// The folder both agents are asked about: the project, or the home folder for user-level
  /// skills only.
  private var folder: URL { project ?? home }
  var codex: CodexSkills { codexFor(folder) }
  var claude: Capabilities { claudeFor(folder, account) }

  var records: [SkillRecord] {
    let inputs = Inputs(scan: scan.skills, claude: claude.lists.skills, codex: codex.records)
    if let merged, merged.inputs == inputs { return merged.records }
    let records = SkillInventory.merge(
      scan: inputs.scan, claude: inputs.claude, codex: inputs.codex)
    merged = (inputs, records)
    return records
  }

  var shown: [SkillRecord] { records.filter { place.includes($0) && $0.matches(filter) } }

  func count(_ place: SkillsPlace) -> Int { records.count(where: place.includes) }

  var selected: SkillRecord? { records.first { $0.id == selection } }

  var visiblePlaces: [SkillsPlace] {
    SkillsPlace.allCases.filter { $0 != .project || project != nil }
  }

  /// What failed to read, shown above the list with Retry; Codex missing is a caption instead.
  var problems: [String] {
    scan.problems + (codex.isCodexMissing ? [] : [codex.problem].compactMap { $0 })
  }

  var isLoading: Bool { codex.isLoading || claude.isLoading }

  // MARK: - Choosing the project

  /// Opens the window (`open` is SwiftUI's `openWindow(id:)`) on `folder`'s project; with no
  /// folder, keeps the project shown while it is still open.
  func show(project folder: URL?, open: (String) -> Void) {
    if let folder { choose(project: folder) } else { openProjectsChanged() }
    open(Self.windowID)
  }

  func choose(project folder: URL?) {
    let folder = folder.map { URL(filePath: $0.skillPath, directoryHint: .isDirectory) }
    guard folder?.skillPath != project?.skillPath else { return }
    project = folder
    selection = nil
    if folder == nil, place == .project { place = .all }
    if isStarted { watch() }
    refresh(load: true)
  }

  /// A project window closed: a project no longer open is no longer shown.
  func openProjectsChanged() {
    guard let project, !openFolders().map(\.skillPath).contains(project.skillPath) else {
      return
    }
    choose(project: nil)
  }

  // MARK: - Reading

  /// The window appeared: watch the folders and read everything.
  func start() {
    isStarted = true
    watch()
    refresh(load: true)
  }

  func stop() {
    isStarted = false
    unwatch()
  }

  /// Reads the folders again, and asks both agents again; with `load`, only those that have
  /// not answered yet.
  func refresh(load: Bool = false) {
    rescan()
    if load {
      codex.loadIfNeeded()
      claude.loadIfNeeded()
    } else {
      codex.refresh(force: true)
      claude.refresh()
    }
  }

  /// A file in the project's skill folders changed; the project reads both lists again itself.
  func projectFilesChanged() { rescan() }

  /// A file in the account's, `~/.agents`'s or `~/.codex`'s skills changed.
  func userFilesChanged() {
    rescan()
    codex.refreshIfLoaded()
    claude.refreshIfLoaded()
  }

  private func rescan() {
    scan = ClaudeSkillScan.scan(
      account: account.directory, project: project, codexFolders: places.codexFolders)
    if let selection, !records.contains(where: { $0.id == selection }) { self.selection = nil }
  }

  private func watch() {
    unwatch()
    let roots = [
      account.directory.appending(path: "skills"), home.appending(path: ".agents/skills"),
      home.appending(path: ".codex/skills"),
    ]
    watchers = roots.filter { FileManager.default.fileExists(atPath: $0.skillPath) }.compactMap {
      FolderWatcher(folder: $0) { [weak self] _ in self?.userFilesChanged() }
    }
    if let project, let window = projectAt(project) {
      observed = (window, window.observeSkillFiles { [weak self] in self?.projectFilesChanged() })
    }
  }

  private func unwatch() {
    for watcher in watchers { watcher.stop() }
    watchers = []
    if let observed { observed.project.stopObservingSkillFiles(observed.id) }
    observed = nil
  }

  // MARK: - Actions

  private var actions: SkillActions { SkillActions(places: places, files: files) }
  private var sources: SkillSources { SkillSources(root: places.sources, environment: environment) }

  func share(_ record: SkillRecord) { perform { _ = try actions.share(record) } }

  /// What deleting `record` would do, for the confirmation; nil after saying why it cannot.
  func deletePlan(for record: SkillRecord) -> DeletePlan? {
    do {
      return try actions.deletePlan(for: record)
    } catch {
      failure = error.localizedDescription
      return nil
    }
  }

  func delete(_ plan: DeletePlan) { perform { try actions.delete(plan) } }

  func install(_ folders: [URL], place: SkillPlace, agents: [SkillAgent], method: InstallMethod) {
    perform { _ = try actions.install(folders, place: place, agents: agents, method: method) }
  }

  /// Clones or pulls `address`; the skills its clone offers.
  func fetch(_ address: String) async throws -> [URL] {
    isFetching = true
    defer { isFetching = false }
    let folder = try await sources.fetch(address)
    return SkillFolderSearch.skills(in: folder, depth: 4)
  }

  /// Update: pulls the clone `record` came from.
  func update(_ record: SkillRecord) async {
    isFetching = true
    do {
      try await sources.update(record)
    } catch {
      failure = error.localizedDescription
    }
    isFetching = false
    afterAction()
  }

  func isFromGit(_ record: SkillRecord) -> Bool { places.clone(containing: record.realPath) != nil }

  /// The first 4 KB of the SKILL.md or command file.
  func preview(of record: SkillRecord) -> String? {
    record.file.flatMap { files.read(URL(filePath: $0), limit: 4096) }
  }

  /// In the project window's editor, or the default app with no project.
  func open(_ record: SkillRecord) {
    guard let file = record.file else { return }
    let url = URL(filePath: file)
    if let project, let window = projectAt(project) {
      window.workspace.open(url)
      window.workspace.window?.makeKeyAndOrderFront(nil)
    } else {
      NSWorkspace.shared.open(url)
    }
  }

  func reveal(_ record: SkillRecord) {
    let path = record.sightings.compactMap(\.path).first ?? record.realPath
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
  }

  private func perform(_ action: () throws -> Void) {
    do {
      try action()
    } catch {
      failure = error.localizedDescription
    }
    afterAction()
  }

  /// A folder may have appeared: watch it; then read everything again at once.
  private func afterAction() {
    if isStarted { watch() }
    refresh()
  }

  // MARK: - Defaults

  static func account(for folder: URL?) -> ClaudeAccount {
    if let folder { return AccountStore.shared.windowAccount(for: folder) }
    return ClaudeChoice.newSessionAccount ?? AccountStore.shared.shellAccount
  }

  static func openProjectFolders() -> [URL] {
    Set(OpenSessions.shared.projects.values.map(\.folder.skillPath)).sorted().map {
      URL(filePath: $0, directoryHint: .isDirectory)
    }
  }

  static func openProject(at folder: URL) -> Project? {
    OpenSessions.shared.projects.values.first { $0.folder.skillPath == folder.skillPath }
  }
}
```

- [ ] **Step 5: Run the tests**

Run the focused `SkillsManagerTests` command, then `-only-testing:DrakarTests/CodexSkillsTests` (the project's own file-change refreshes are unchanged), then `make -C apps/apple test-app` and `make -C apps/apple test`.
Expected: PASS (9 tests).

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Drakar/Services/SkillsManager.swift apps/apple/Drakar/Services/Project.swift apps/apple/DrakarTests/SkillsManagerTests.swift
git commit -m "feat(apple): model the Skills window over one project and account"
```

---

### Task 10: The window and its entry points

**Files:**
- Create: `apps/apple/Drakar/Views/SkillsWindow.swift`, `apps/apple/Drakar/Views/SkillSheets.swift`
- Modify: `apps/apple/Drakar/DrakarApp.swift`, `apps/apple/Drakar/Views/InspectorView.swift`
- Test: `apps/apple/DrakarTests/SkillsWindowTests.swift`

**Interfaces:**
- Consumes: `SkillsManager`, `SkillsPlace` (Task 9); `SkillText.path`, `SkillPlace`, `InstallMethod`, `DeletePlan`, `SkillAgent.kind` (Tasks 6, 7); `SkillFolderSearch` (Task 4); `SkillRecord`, `SkillSighting`, `SkillOrigin` (Tasks 1, 3); `WindowReader` (`ContentView.swift`), `.themed()`, `@FocusedValue(\.project)`.
- Produces: `SkillText.location(of:home:)`, `SkillText.origin(_:)`, `SkillText.caption(of:)`, `SkillText.notes(of:)`; `SkillsPlace.title`, `.systemImage`; `SkillsWindow(manager:)`; `InstallRequest`, `InstallSheet`, `DeleteRequest`, `DeleteSheet`; the `Window` scene and `SkillsCommand`; `ManageSkillsButton`.
- Accessibility identifiers (from the spec): `skills.window`, `skills.sidebar`, `skills.table`, `skills.detail`, `skills.install.folder`, `skills.install.git`, `skills.refresh`, `skills.share`, `skills.delete`, `skills.open`, `skills.reveal`, `skills.project`, and `inspector.skills.manage`. Added for the check: `skills.place.<place>`, `skills.update`, `skills.git.url`, `skills.git.fetch`, `skills.install.confirm`, `skills.delete.confirm`.

- [ ] **Step 1: Write the failing tests**

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("How the Skills window words a skill")
struct SkillsWindowTests {
  private let home = "/Users/me"

  @Test func pathsUnderHomeStartWithATilde() {
    #expect(SkillText.path("/Users/me/.claude/skills/x/", home: home) == "~/.claude/skills/x")
    #expect(SkillText.path("/Users/me", home: home) == "~")
    #expect(SkillText.path("/Users/meadow/x", home: home) == "/Users/meadow/x")
  }

  @Test func aLinksLocationNamesItsTarget() {
    let linked = SkillRecord(
      name: "find-skills", description: "", kind: .skill, origin: .user,
      realPath: "/Users/me/.agents/skills/find-skills",
      sightings: [
        SkillSighting(agent: .claude, path: "/Users/me/.claude/skills/find-skills", isLink: true),
        SkillSighting(agent: .codex, path: "/Users/me/.agents/skills/find-skills"),
      ])
    #expect(
      SkillText.location(of: linked, home: home)
        == "~/.claude/skills/find-skills → ~/.agents/skills/find-skills")
    let plain = SkillRecord(
      name: "deploy", description: "", kind: .skill, origin: .project,
      realPath: "/Users/me/p/.agents/skills/deploy",
      sightings: [SkillSighting(agent: .codex, path: "/Users/me/p/.agents/skills/deploy")])
    #expect(SkillText.location(of: plain, home: home) == "~/p/.agents/skills/deploy")
    let unknown = SkillRecord(
      name: "mystery", description: "", kind: .skill, origin: .unknown, realPath: "",
      sightings: [SkillSighting(agent: .claude, path: nil)])
    #expect(SkillText.location(of: unknown, home: home) == "")
  }

  @Test func originsReadAsTheColumnSaysThem() {
    #expect(
      [SkillOrigin.user, .project, .plugin("tools@market"), .codexSystem, .codexAdmin, .unknown]
        .map(SkillText.origin) == [
          "Yours", "Project", "tools@market", "Codex system", "Codex admin", "Unknown",
        ])
  }

  @Test func theNameCellSaysWhatHoldsASkillBack() {
    var record = SkillRecord(
      name: "x", description: "", kind: .skill, origin: .user, realPath: "/x",
      sightings: [SkillSighting(agent: .claude, path: "/x")])
    #expect(SkillText.caption(of: record) == nil)
    #expect(SkillText.notes(of: record).isEmpty)
    record.notLoadedByClaude = true
    #expect(SkillText.caption(of: record) == "Not loaded by Claude Code")
    record.notLoadedByClaude = false
    record.sightings.append(SkillSighting(agent: .codex, path: "/x", isShadowed: true))
    #expect(SkillText.caption(of: record) == "Shadowed")
    record.sightings[1].isEnabled = false
    #expect(SkillText.notes(of: record).contains("Turned off for Codex"))
  }

  @Test func eachPlaceHasATitle() {
    #expect(
      SkillsPlace.allCases.map(\.title) == [
        "All", "Yours", "This project", "Plugins", "Codex built-in",
      ])
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/SkillsWindowTests`
Expected: FAIL to build, `type 'SkillText' has no member 'location'`.

- [ ] **Step 3: Write `SkillsWindow.swift`**

```swift
import AppKit
import DrakarKit
import SwiftUI

extension SkillText {
  /// The Location column: where the first agent sees it, and for a link, where it leads.
  static func location(
    of record: SkillRecord,
    home: String = FileManager.default.homeDirectoryForCurrentUser.skillPath
  ) -> String {
    guard let sighting = record.sightings.first(where: { $0.path != nil }),
      let path = sighting.path
    else { return "" }
    let seen = Self.path(path, home: home)
    return sighting.isLink ? "\(seen) → \(Self.path(record.realPath, home: home))" : seen
  }

  static func origin(_ origin: SkillOrigin) -> String {
    switch origin {
    case .user: String(localized: "Yours")
    case .project: String(localized: "Project")
    case .plugin(let id): id
    case .codexSystem: String(localized: "Codex system")
    case .codexAdmin: String(localized: "Codex admin")
    case .unknown: String(localized: "Unknown")
    }
  }

  /// The Name cell's second line.
  static func caption(of record: SkillRecord) -> String? {
    if record.notLoadedByClaude { return String(localized: "Not loaded by Claude Code") }
    if record.isShadowed { return String(localized: "Shadowed") }
    return nil
  }

  /// The detail's notes.
  static func notes(of record: SkillRecord) -> [String] {
    var notes: [String] = []
    if record.isMissing { notes.append(String(localized: "The folder this link points to is gone")) }
    if record.notLoadedByClaude {
      notes.append(String(localized: "Not loaded by Claude Code"))
    }
    for sighting in record.sightings where !sighting.isEnabled {
      notes.append(String(localized: "Turned off for \(sighting.agent.kind.name)"))
    }
    if record.isShadowed {
      notes.append(String(localized: "Shadowed: Codex uses a nearer skill of the same name"))
    }
    return notes
  }
}

extension SkillsPlace {
  var title: String {
    switch self {
    case .all: String(localized: "All")
    case .yours: String(localized: "Yours")
    case .project: String(localized: "This project")
    case .plugins: String(localized: "Plugins")
    case .codex: String(localized: "Codex built-in")
    }
  }

  var systemImage: String {
    switch self {
    case .all: "square.stack"
    case .yours: "person"
    case .project: "folder"
    case .plugins: "puzzlepiece.extension"
    case .codex: "shippingbox"
    }
  }
}

/// The Skills window: every skill Claude Code and Codex see for one project or none, where
/// each comes from, and the actions that install, share and delete them.
struct SkillsWindow: View {
  @Bindable var manager: SkillsManager
  @State private var sortOrder = [
    KeyPathComparator(\SkillRecord.name, comparator: .localizedStandard)
  ]
  @State private var install: InstallRequest?
  @State private var deleting: DeleteRequest?

  var body: some View {
    let openPaths = manager.openFolders().map(\.skillPath)
    NavigationSplitView {
      SkillsSidebar(manager: manager)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
    } content: {
      SkillsList(manager: manager, sortOrder: $sortOrder)
        .navigationSplitViewColumnWidth(min: 440, ideal: 580)
    } detail: {
      SkillDetail(manager: manager, delete: askToDelete)
    }
    .navigationTitle("Skills")
    .toolbar {
      ToolbarItemGroup {
        Button("Install from Folder…", systemImage: "folder.badge.plus") { chooseFolder() }
          .help(String(localized: "Install from Folder…"))
          .accessibilityIdentifier("skills.install.folder")
        Button("Install from Git…", systemImage: "arrow.down.circle") {
          install = InstallRequest(source: .git)
        }
        .help(String(localized: "Install from Git…"))
        .accessibilityIdentifier("skills.install.git")
        Button("Refresh", systemImage: "arrow.clockwise") { manager.refresh() }
          .help(String(localized: "Read the skills again"))
          .accessibilityIdentifier("skills.refresh")
      }
    }
    .onAppear { manager.start() }
    .onDisappear { manager.stop() }
    .onChange(of: openPaths) { manager.openProjectsChanged() }
    .alert(
      "Skills", isPresented: failureShown, presenting: manager.failure
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { failure in
      Text(failure)
    }
    .sheet(item: $install) { request in InstallSheet(request: request, manager: manager) }
    .sheet(item: $deleting) { request in DeleteSheet(request: request, manager: manager) }
    // The window keeps its size between openings; SwiftUI does not reopen it at launch.
    .background(WindowReader { $0.setFrameAutosaveName("drakar.skills") })
    .accessibilityIdentifier("skills.window")
  }

  private var failureShown: Binding<Bool> {
    Binding(
      get: { manager.failure != nil },
      set: { if !$0 { manager.failure = nil } })
  }

  private func askToDelete(_ record: SkillRecord) {
    guard let plan = manager.deletePlan(for: record) else { return }
    deleting = DeleteRequest(record: record, plan: plan)
  }

  /// A skill's folder or its SKILL.md, or a folder of skills three levels deep at most.
  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Choose")
    panel.message = String(localized: "Choose a skill's folder or its SKILL.md, or a folder of skills.")
    guard panel.runModal() == .OK, var folder = panel.url else { return }
    var isFolder: ObjCBool = false
    if !FileManager.default.fileExists(atPath: folder.skillPath, isDirectory: &isFolder)
      || !isFolder.boolValue
    {
      folder.deleteLastPathComponent()
    }
    let found = SkillFolderSearch.skills(in: folder, depth: 3)
    guard !found.isEmpty else {
      manager.failure = String(
        localized: "\(SkillText.path(folder)) has no SKILL.md, nor do its folders three levels down.")
      return
    }
    install = InstallRequest(source: .folder(found))
  }
}

private struct SkillsSidebar: View {
  @Bindable var manager: SkillsManager

  var body: some View {
    let folders = manager.openFolders()
    List(selection: placeBinding) {
      ForEach(manager.visiblePlaces) { place in
        HStack {
          Label {
            VStack(alignment: .leading, spacing: 1) {
              Text(place.title)
              if let caption = caption(place) {
                Text(caption)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
            }
          } icon: {
            Image(systemName: place.systemImage)
          }
          Spacer()
          Text(manager.count(place), format: .number)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .tag(place)
        .accessibilityIdentifier("skills.place.\(place.rawValue)")
      }
    }
    .safeAreaInset(edge: .top) {
      Picker("Project", selection: projectBinding) {
        Text("No Project").tag(String?.none)
        ForEach(folders, id: \.self) { folder in
          Text(folder.lastPathComponent).tag(Optional(folder.skillPath))
        }
      }
      .labelsHidden()
      .help(manager.project.map(SkillText.path) ?? String(localized: "Your skills only"))
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .accessibilityIdentifier("skills.project")
    }
    .accessibilityIdentifier("skills.sidebar")
  }

  private var placeBinding: Binding<SkillsPlace?> {
    Binding(get: { manager.place }, set: { if let place = $0 { manager.place = place } })
  }

  private var projectBinding: Binding<String?> {
    Binding(
      get: { manager.project?.skillPath },
      set: { manager.choose(project: $0.map { URL(filePath: $0, directoryHint: .isDirectory) }) })
  }

  private func caption(_ place: SkillsPlace) -> String? {
    switch place {
    case .yours: manager.account.name
    case .project: manager.project?.lastPathComponent
    default: nil
    }
  }
}

private struct SkillsList: View {
  @Bindable var manager: SkillsManager
  @Binding var sortOrder: [KeyPathComparator<SkillRecord>]

  var body: some View {
    let rows = manager.shown.sorted(using: sortOrder)
    VStack(spacing: 0) {
      ForEach(manager.problems, id: \.self) { problem in
        HStack {
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
          Spacer()
          Button("Retry") { manager.refresh() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        Divider()
      }
      Table(rows, selection: $manager.selection, sortOrder: $sortOrder) {
        TableColumn("Name", value: \.name) { record in NameCell(record: record) }
        TableColumn("Agents") { record in AgentTags(record: record) }
          .width(min: 110, ideal: 120)
        TableColumn("Origin") { record in
          Text(SkillText.origin(record.origin)).foregroundStyle(.secondary)
        }
        TableColumn("Location") { record in
          let location = SkillText.location(of: record)
          Text(location)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(location)
        }
      }
      .overlay {
        if rows.isEmpty {
          if manager.isLoading {
            ProgressView()
          } else {
            Text(manager.filter.isEmpty ? "No skills" : "No match").foregroundStyle(.secondary)
          }
        }
      }
      .accessibilityIdentifier("skills.table")
      if manager.isLoading || manager.codex.isCodexMissing {
        HStack(spacing: 6) {
          if manager.isLoading {
            ProgressView().controlSize(.small)
            Text("Reading skills…")
          }
          if manager.codex.isCodexMissing { Text("Codex was not found") }
          Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
      }
    }
    .searchable(text: $manager.filter, placement: .toolbar, prompt: "Filter skills")
  }
}

private struct NameCell: View {
  let record: SkillRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        Text(record.name).lineLimit(1)
        if record.isLink {
          Image(systemName: "link")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Link")
        }
      }
      if let caption = SkillText.caption(of: record) {
        Text(caption).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

/// A tag per agent that sees the skill, dimmed when it is turned off or shadowed there.
private struct AgentTags: View {
  let record: SkillRecord

  var body: some View {
    HStack(spacing: 4) {
      ForEach(SkillAgent.allCases, id: \.self) { agent in
        if let sighting = record.sighting(for: agent) {
          Text(agent.kind.shortName)
            .font(.caption)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .opacity(sighting.isEnabled && !sighting.isShadowed ? 1 : 0.45)
        }
      }
    }
  }
}

private struct SkillDetail: View {
  @Bindable var manager: SkillsManager
  let delete: (SkillRecord) -> Void

  var body: some View {
    if let record = manager.selected {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(record.name).font(.title2.bold()).textSelection(.enabled)
          if !record.description.isEmpty {
            Text(record.description).textSelection(.enabled)
          }
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            row(String(localized: "Origin"), SkillText.origin(record.origin))
            ForEach(record.sightings, id: \.self) { sighting in
              row(
                sighting.agent.kind.name,
                sighting.path.map { SkillText.path($0) }
                  ?? String(localized: "Listed, not found on disk"))
            }
            if !record.realPath.isEmpty {
              row(String(localized: "Real path"), SkillText.path(record.realPath))
            }
          }
          ForEach(SkillText.notes(of: record), id: \.self) { note in
            Label(note, systemImage: "info.circle")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          buttons(record)
          if let preview = manager.preview(of: record) {
            Text(preview)
              .font(.body.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
              .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("skills.detail")
    } else {
      Text("Select a skill")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("skills.detail")
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value).textSelection(.enabled)
    }
  }

  @ViewBuilder private func buttons(_ record: SkillRecord) -> some View {
    HStack {
      Button("Open") { manager.open(record) }
        .disabled(record.file == nil || record.isMissing)
        .accessibilityIdentifier("skills.open")
      Button("Reveal in Finder") { manager.reveal(record) }
        .disabled(record.sightings.allSatisfy { $0.path == nil })
        .accessibilityIdentifier("skills.reveal")
      if record.canShare,
        let other = SkillAgent.allCases.first(where: { record.sighting(for: $0) == nil })
      {
        Button("Share with \(other.kind.shortName)") { manager.share(record) }
          .accessibilityIdentifier("skills.share")
      }
      if manager.isFromGit(record) {
        Button("Update") { Task { await manager.update(record) } }
          .disabled(manager.isFetching)
          .accessibilityIdentifier("skills.update")
      }
      if record.canDelete {
        Button("Delete…", role: .destructive) { delete(record) }
          .accessibilityIdentifier("skills.delete")
      }
    }
  }
}
```

- [ ] **Step 4: Write `SkillSheets.swift`**

```swift
import DrakarKit
import SwiftUI

/// What an install starts from: the skills found in a chosen folder, or a git address still
/// to fetch.
struct InstallRequest: Identifiable {
  enum Source {
    case folder([URL])
    case git
  }

  let id = UUID()
  var source: Source
}

/// Install from Folder… and Install from Git…: which skills, which place, which agents, and
/// for a folder whether to link or copy.
struct InstallSheet: View {
  let request: InstallRequest
  let manager: SkillsManager
  @Environment(\.dismiss) private var dismiss
  @State private var address = ""
  @State private var found: [URL] = []
  @State private var picked: Set<URL> = []
  @State private var place: SkillPlace = .user
  @State private var forClaude = true
  @State private var forCodex = true
  @State private var method: InstallMethod = .link
  @State private var note: String?

  private var isGit: Bool {
    if case .git = request.source { true } else { false }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(isGit ? "Install from Git" : "Install from Folder").font(.headline)
      if isGit {
        HStack {
          TextField(
            "Repository", text: $address,
            prompt: Text("https://github.com/owner/repo or git@host:owner/repo")
          )
          .textFieldStyle(.roundedBorder)
          .onSubmit(fetch)
          .accessibilityIdentifier("skills.git.url")
          if manager.isFetching {
            ProgressView().controlSize(.small)
          } else {
            Button("Fetch", action: fetch)
              .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
              .accessibilityIdentifier("skills.git.fetch")
          }
        }
        if let note {
          Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      if found.count > 1 || (isGit && !found.isEmpty) {
        Text("Skills").font(.subheadline).foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(found, id: \.self) { folder in
              Toggle(folder.lastPathComponent, isOn: binding(folder))
                .help(SkillText.path(folder))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
      } else if let only = found.first {
        Text(SkillText.path(only)).font(.callout.monospaced()).foregroundStyle(.secondary)
      }
      if !found.isEmpty {
        Picker("Place", selection: $place) {
          Text("Yours").tag(SkillPlace.user)
          if manager.project != nil { Text("This project").tag(SkillPlace.project) }
        }
        .pickerStyle(.segmented)
        HStack {
          Text("Agents")
          Toggle("Claude Code", isOn: $forClaude)
          Toggle("Codex", isOn: $forCodex)
        }
        if !isGit {
          Picker("Method", selection: $method) {
            Text("Link to it where it is").tag(InstallMethod.link)
            Text("Copy into the place's folder").tag(InstallMethod.copy)
          }
          .pickerStyle(.radioGroup)
        }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Install") {
          manager.install(
            found.filter(picked.contains), place: place, agents: agents,
            method: isGit ? .link : method)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(picked.isEmpty || agents.isEmpty)
        .accessibilityIdentifier("skills.install.confirm")
      }
    }
    .padding(20)
    .frame(width: 520)
    .onAppear {
      if case .folder(let folders) = request.source {
        found = folders
        picked = Set(folders)
      }
    }
  }

  private var agents: [SkillAgent] {
    (forClaude ? [.claude] : []) + (forCodex ? [.codex] : [])
  }

  private func binding(_ folder: URL) -> Binding<Bool> {
    Binding(
      get: { picked.contains(folder) },
      set: { if $0 { picked.insert(folder) } else { picked.remove(folder) } })
  }

  private func fetch() {
    note = nil
    Task {
      do {
        let skills = try await manager.fetch(address)
        found = skills
        picked = Set(skills)
        if skills.isEmpty {
          note = String(localized: "The repository has no SKILL.md in its first four levels.")
        }
      } catch {
        note = error.localizedDescription
      }
    }
  }
}

/// A delete waiting for its confirmation.
struct DeleteRequest: Identifiable {
  let id = UUID()
  let record: SkillRecord
  let plan: DeletePlan
}

/// Says exactly what a delete does, sighting by sighting, before it does it.
struct DeleteSheet: View {
  let request: DeleteRequest
  let manager: SkillsManager
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Delete \(request.record.name)?").font(.headline)
      ForEach(request.plan.lines, id: \.self) { line in
        Label(line, systemImage: "arrow.right.circle")
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Delete", role: .destructive) {
          manager.delete(request.plan)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(request.plan.steps.isEmpty)
        .accessibilityIdentifier("skills.delete.confirm")
      }
    }
    .padding(20)
    .frame(width: 480)
  }
}
```

- [ ] **Step 5: Add the scene and the menu item to `DrakarApp.swift`**

Inside `.commands { … }` of the `WindowGroup`, after `CommandGroup(replacing: .printItem) { QuickOpenCommand() }`, add:

```swift
      CommandGroup(before: .windowList) { SkillsCommand() }
```

After the `Settings { … }` scene, add:

```swift
    // The Skills window: one for the app, opened from Window › Skills or the inspector's
    // Manage…, on the project of the window it came from. Its own menu item is replaced by
    // `SkillsCommand`, which knows that project; it is not reopened at launch.
    Window("Skills", id: SkillsManager.windowID) {
      SkillsWindow(manager: .shared)
        .themed()
    }
    .defaultSize(width: 1040, height: 640)
    .restorationBehavior(.disabled)
    .commandsRemoved()
```

After `QuickOpenCommand`, add:

```swift
/// Window › Skills: the Skills window, on the focused window's project.
private struct SkillsCommand: View {
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.project) private var project

  var body: some View {
    Button("Skills") {
      SkillsManager.shared.show(project: project?.folder) { openWindow(id: $0) }
    }
    Divider()
  }
}
```

- [ ] **Step 6: Add Manage… to the inspector's Skills pane** (`InspectorView.swift`)

In `SkillsPane.body`, in the `PaneHeader` trailing block, insert `ManageSkillsButton(folder: project.folder)` between `if let all { CountLabel(count: all.count) }` and `RefreshButton(`. After the `SkillsPane` struct, add:

```swift
/// Opens the Skills window on this window's project.
private struct ManageSkillsButton: View {
  let folder: URL
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Manage…", systemImage: "slider.horizontal.3") {
      SkillsManager.shared.show(project: folder) { openWindow(id: $0) }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help(String(localized: "Manage Skills…"))
    .accessibilityIdentifier("inspector.skills.manage")
  }
}
```

- [ ] **Step 7: Run the tests**

Run the focused `SkillsWindowTests` command, then `make -C apps/apple build`, `make -C apps/apple test-app` and `make -C apps/apple test`.
Expected: PASS (5 tests); the app builds; the inspector's existing tests unchanged.

- [ ] **Step 8: Commit**

```bash
make -C apps/apple format-swift
git checkout -- apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/LiveSessionTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/PresentationTests.swift apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift
git add apps/apple/Drakar/Views/SkillsWindow.swift apps/apple/Drakar/Views/SkillSheets.swift apps/apple/Drakar/DrakarApp.swift apps/apple/Drakar/Views/InspectorView.swift apps/apple/DrakarTests/SkillsWindowTests.swift
git commit -m "feat(apple): add the Skills window, its menu item and Manage button"
```

---

### Task 11: Check in the running app

Needs the person's go-ahead: `make run` quits the Drakar they are using. Everything the check writes goes to a scratch project and a scratch repository; the one exception is the git clone, which lands in the real `~/.agents/skill-sources/local/…` and is deleted through the window at the end. Nothing is committed unless a fix is needed.

- [ ] **Step 1: Ask the person** whether to run the check now, and say that the git step clones into `~/.agents/skill-sources/local/` and removes it again.
- [ ] **Step 2: Back up the window set and make the scratch folders**

```bash
make -C apps/apple quit
B=$(mktemp -d) && defaults export io.mgcrea.Drakar "$B/backup.plist" && echo "$B"
S=$(mktemp -d)/skills-check && mkdir -p "$S/.claude/skills/scratch-one" && printf -- '---\nname: scratch-one\ndescription: A scratch skill.\n---\nHello.\n' > "$S/.claude/skills/scratch-one/SKILL.md"
R=$(mktemp -d)/scratch-skills && mkdir -p "$R/skills/scratch-git" && printf -- '---\nname: scratch-git\n---\nFrom git.\n' > "$R/skills/scratch-git/SKILL.md"
git -C "$R" init -q -b main && git -C "$R" add -A && git -C "$R" -c user.name=Drakar -c user.email=tests@drakar.invalid -c commit.gpgsign=false commit -qm init
make -C apps/apple run ARGS="-drakar.debugFolder $S"
```

- [ ] **Step 3: Check, through cupertino-desktop's accessibility tree** (bundle `io.mgcrea.Drakar`, `maxDepth` 30; screenshots come back black on this Mac; click the window's title before using the menu bar):
  - Window › Skills is listed with no shortcut; it opens `skills.window` with `skills.sidebar`, `skills.table`, `skills.detail`, `skills.project` (reading the scratch folder's name), and the three toolbar buttons;
  - the inspector's `inspector.skills.manage` opens the same window on the scratch project;
  - `skills.place.project` counts 1; selecting `scratch-one` fills `skills.detail` with its paths and "Hello."; `skills.share` makes `$S/.agents/skills/scratch-one` a link to it (`ls -l` on disk), and the row then shows both agent tags once Codex has answered;
  - `skills.install.git` with `file://$R` in `skills.git.url`, `skills.git.fetch`, This project, `skills.install.confirm`: links in `$S/.claude/skills/scratch-git` and `$S/.agents/skills/scratch-git` point into `~/.agents/skill-sources/local/<tmp>/scratch-skills`; the row shows `skills.update`;
  - `skills.delete` on `scratch-git`, then `skills.delete.confirm`: both links go and the clone goes to the Trash (check `~/.agents/skill-sources/local/`); `skills.delete` on `scratch-one`: the sheet names the link and the folder; after it, no link is left in `$S/.agents/skills`;
  - choosing "No Project" in `skills.project` hides "This project" and lists the user's own skills without changing them;
  - resize the window, close it, open it again: same size;
  - Install from Folder…'s open panel does not take presses from the tree: ask the person to try it by hand on `$R/skills`.
- [ ] **Step 4: Put things back and report.** Quit the check's Drakar (`make -C apps/apple quit`), `defaults import io.mgcrea.Drakar "$B/backup.plist"`, remove the empty `~/.agents/skill-sources/local/<tmp>` folders the clone left (`rmdir`, only if empty), and report what was checked and anything that failed.
