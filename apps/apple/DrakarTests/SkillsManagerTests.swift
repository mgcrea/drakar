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
    try await settle(manager)
    #expect(!manager.records.contains { $0.name == "deploy" })
    #expect(FileManager.default.fileExists(atPath: trash.appending(path: "deploy").skillPath))
    #expect(!SkillPath.isLink(shared.skillPath))
  }

  /// A refusal is said in the alert, and nothing changes.
  @Test func aRefusalIsSaid() async throws {
    defer { cleanUp() }
    let manager = manager(Stubs())
    manager.choose(project: project)
    try await settle(manager)
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
    manager.settleDelay = .milliseconds(10)
    manager.projectFilesChanged()
    try await settle(manager)
    #expect(manager.selection == nil)
    #expect(manager.selected == nil)
  }

  /// File events come in bursts: the readings merge into one, and none leaves the flag set.
  @Test func aBurstOfFileEventsEndsScanning() async throws {
    defer { cleanUp() }
    let manager = manager(Stubs())
    manager.settleDelay = .milliseconds(10)
    manager.choose(project: project)
    for _ in 0..<5 { manager.projectFilesChanged() }
    manager.choose(project: nil)
    #expect(manager.isScanning)
    try await settle(manager)
    #expect(!manager.isScanning)
    #expect(manager.records.map(\.name) == ["review"])
  }

  /// A folder search and an install run off the main actor and are not busy after; the
  /// install reads everything again, and says why it did nothing.
  @Test func searchAndInstallRunOffTheMainActor() async throws {
    defer { cleanUp() }
    let manager = manager(Stubs())
    let lib = root.appending(path: "lib", directoryHint: .isDirectory)
    try skill(lib.appending(path: "one"))
    try skill(lib.appending(path: "two"))
    let found = await manager.skills(in: lib, depth: 3)
    #expect(found.map(\.lastPathComponent) == ["one", "two"])
    #expect(!manager.isBusy)
    await manager.install(found, place: .user, agents: [.claude], method: .copy)
    #expect(!manager.isBusy)
    #expect(manager.failure == nil)
    let copy = account.appending(path: "skills/one")
    #expect(!SkillPath.isLink(copy.skillPath))
    #expect(FileManager.default.fileExists(atPath: copy.appending(path: "SKILL.md").skillPath))
    try await settle(manager)
    #expect(manager.records.map(\.name).contains("two"))
    await manager.install(found, place: .user, agents: [.claude], method: .copy)
    #expect(manager.failure?.hasPrefix("A skill named one is already in") == true)
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

  @Test func thePreviewIsTheFirstFourKilobytes() async throws {
    defer { cleanUp() }
    let manager = manager(Stubs())
    let long = account.appending(path: "skills/long")
    try FileManager.default.createDirectory(at: long, withIntermediateDirectories: true)
    try Data(("---\nname: long\n---\n" + String(repeating: "x", count: 10_000)).utf8).write(
      to: long.appending(path: "SKILL.md"))
    manager.refresh(load: true)
    try await settle(manager)
    let record = try #require(manager.records.first { $0.name == "long" })
    #expect(manager.preview(of: record)?.utf8.count == 4096)
  }

  /// Review focus: a link whose target is gone has nothing to open, and Reveal shows the link.
  @Test func aMissingLinkRevealsTheLinkAndOpensNothing() async throws {
    defer { cleanUp() }
    let manager = manager(Stubs())
    let link = account.appending(path: "skills/gone")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: root.appending(path: "nowhere/gone"))
    manager.refresh(load: true)
    try await settle(manager)
    let gone = try #require(manager.records.first { $0.name == "gone" })
    #expect(gone.isMissing)
    #expect(gone.file == nil)
    #expect(manager.fileToOpen(gone) == nil)
    #expect(manager.itemToReveal(gone).skillPath == link.skillPath)
    let review = try #require(manager.records.first { $0.name == "review" })
    #expect(
      manager.fileToOpen(review)?.skillPath
        == account.appending(path: "skills/review/SKILL.md").skillPath)
  }

  /// Review focus: when the window's account changes, its skills are read and watched instead.
  @Test func aNewAccountIsReadAndWatched() async throws {
    defer { cleanUp() }
    let stubs = Stubs()
    let manager = manager(stubs)
    let other = home.appending(path: ".claude-other", directoryHint: .isDirectory)
    try skill(other.appending(path: "skills/lint"))
    var current = ClaudeAccount(directory: account, isDefault: false)
    manager.accountFor = { _ in current }
    manager.settleDelay = .milliseconds(10)
    manager.start()
    defer { manager.stop() }
    try await settle(manager)
    #expect(manager.records.map(\.name) == ["review"])
    let probes = stubs.probes
    manager.accountMayHaveChanged()
    #expect(!manager.isScanning)
    current = ClaudeAccount(directory: other, isDefault: false)
    manager.accountMayHaveChanged()
    #expect(manager.isScanning)
    try await settle(manager)
    #expect(manager.records.map(\.name) == ["lint"])
    #expect(stubs.probes > probes)
    // The new account's folder is the one watched now.
    for attempt in 0..<5 where !manager.records.contains(where: { $0.name.hasPrefix("added") }) {
      try skill(other.appending(path: "skills/added\(attempt)"))
      for _ in 0..<10 where !manager.records.contains(where: { $0.name.hasPrefix("added") }) {
        try await Task.sleep(for: .milliseconds(100))
      }
    }
    #expect(manager.records.contains { $0.name.hasPrefix("added") })
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
