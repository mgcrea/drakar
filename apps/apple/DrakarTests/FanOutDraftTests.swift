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
    let root = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-draft-\(UUID().uuidString)", directoryHint: .isDirectory)
    self.root = root
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

  /// A stand-in CLI that reads forever.
  private func standIn() throws -> URL {
    let script = root.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
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
  @Test func startRunsTheBatch() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    let draft = draft(SkillEntry(name: "audit", argumentHint: "<area>"))
    draft.arguments = "auth"
    draft.mode = .plan
    draft.limitText = "1"
    draft.start(in: project)
    #expect(project.sessions.prefix(2).map(\.displayTitle) == ["/audit · alpha", "/audit · beta"])
    #expect(project.fanOuts.first?.prompt == "/audit auth")
    #expect(project.fanOuts.first?.queue.limit == 1)
    #expect(project.sessions.first?.session.startingMode == .plan)
  }

  private func loaded(_ skills: CodexSkills) async throws {
    for _ in 0..<100 where skills.isLoading { try await Task.sleep(for: .milliseconds(10)) }
  }

  /// The Session menu's picker lists the inspector's skills for the shown agent, the CLI's
  /// own left out.
  @Test func thePickerListsTheShownAgentsSkills() async throws {
    let project = Project(folder: parent)
    let item = project.newSession(agent: .codex)
    let codex = project.codexSkills(for: item.session)
    let deploy = SkillEntry(name: "deploy", path: "/x/deploy/SKILL.md")
    codex.reader = { _, _ in
      CodexSkillList.Listing(entries: [deploy, SkillEntry(name: "init", isBuiltin: true)])
    }
    codex.refresh()
    try await loaded(codex)
    #expect(project.fanOutSkills == [deploy])
  }

  /// A Codex skill reaches the folders whose own list has it; a folder Codex could not
  /// answer for counts as reached, and the sheet says it could not check.
  @Test func codexReachFollowsEachFolder() async throws {
    var stores: [URL: CodexSkills] = [:]
    let deploy = SkillEntry(name: "deploy", path: "/x/deploy/SKILL.md")
    for (name, has) in [("alpha", true), ("beta", false)] {
      let folder = parent.appending(path: name, directoryHint: .isDirectory)
      let store = CodexSkills(folder: folder)
      store.reader = { _, _ in CodexSkillList.Listing(entries: has ? [deploy] : []) }
      stores[folder] = store
    }
    let draft = FanOutDraft(
      skill: deploy, agent: .codex, parent: parent, account: account,
      codexSkills: { url in
        stores[url] ?? CodexSkills(folder: url)
      })
    for store in stores.values { try await loaded(store) }
    #expect(draft.shown.map { draft.reaches($0) } == [true, false])
    #expect(draft.chosen.map(\.lastPathComponent) == ["alpha"])
    #expect(!draft.reachUnchecked)
    let beta = try #require(stores.values.first { $0.folder.lastPathComponent == "beta" })
    beta.reader = { _, _ in throw CodexOneShot.Failure(message: "boom") }
    beta.refresh()
    try await loaded(beta)
    #expect(draft.reachUnchecked)
  }

  /// Opening the picker reads the list it shows: Codex's for a Codex session, which nothing
  /// else may have read yet.
  @Test func loadingThePickersListReadsCodexs() async throws {
    let project = Project(folder: parent)
    let item = project.newSession(agent: .codex)
    let codex = project.codexSkills(for: item.session)
    let deploy = SkillEntry(name: "deploy", path: "/x/deploy/SKILL.md")
    codex.reader = { _, _ in CodexSkillList.Listing(entries: [deploy]) }
    project.loadFanOutSkills()
    try await loaded(codex)
    #expect(project.fanOutSkills == [deploy])
  }
}
