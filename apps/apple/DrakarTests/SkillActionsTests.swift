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

  /// The confirmation says each step, in order, and nothing else.
  private func expectLinesSay(_ plan: DeletePlan, sourceLocation: SourceLocation = #_sourceLocation)
  {
    #expect(plan.lines.count == plan.steps.count, sourceLocation: sourceLocation)
    for (step, line) in zip(plan.steps, plan.lines) {
      switch step {
      case .removeLink(let path):
        #expect(
          line.hasPrefix("Remove the link at \(SkillText.path(path))"),
          sourceLocation: sourceLocation)
      case .trash(let path):
        #expect(
          line.hasPrefix("Move ") && line.contains(SkillText.path(path))
            && line.contains("to the Trash"), sourceLocation: sourceLocation)
      }
    }
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

  /// A link whose target is gone still takes the name.
  @Test func aShareOntoADanglingLinkIsRefused() throws {
    defer { cleanUp() }
    try skill(account.appending(path: "skills/review"))
    let dangling = home.appending(path: ".agents/skills/review")
    try link(dangling, to: root.appending(path: "gone"))
    let record = try #require(rows().first { $0.name == "review" && !$0.isMissing })
    #expect(
      throws: SkillActionError.exists(
        "review", in: home.appending(path: ".agents/skills", directoryHint: .isDirectory))
    ) { try actions.share(record) }
    #expect(SkillPath.target(ofLink: dangling.skillPath) == root.appending(path: "gone").skillPath)
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
    expectLinesSay(plan)
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

  /// Review focus: a file is not a link either, and stays.
  @Test func removingALinkRefusesAFile() throws {
    defer { cleanUp() }
    let file = project.appending(path: ".claude/commands/ship.md")
    try write("Ship.", to: file)
    #expect(throws: SkillActionError.self) { try files.removeLink(file) }
    #expect(exists(file))
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
    expectLinesSay(plan)
    #expect(!plan.lines.contains { $0.contains("stays") })
    try actions.delete(plan)
    for url in [claude, inProject, real] { #expect(!exists(url)) }
    #expect(exists(trash.appending(path: "find-skills")))
  }

  /// Review focus: Claude Code's link to a folder Codex sees; the row shows the folder itself,
  /// so it goes, and the link's line does not say it stays.
  @Test func aFolderTheRowShowsGoesWithItsLink() throws {
    defer { cleanUp() }
    let real = try skill(home.appending(path: ".agents/skills/find-skills"))
    let claude = account.appending(path: "skills/find-skills")
    try link(claude, to: real)
    let plan = try actions.deletePlan(for: try row("find-skills", codex: [real]))
    #expect(plan.steps == [.removeLink(claude.skillPath), .trash(real.skillPath)])
    #expect(
      plan.lines == [
        "Remove the link at \(SkillText.path(claude)).",
        "Move \(SkillText.path(real)) to the Trash.",
      ])
  }

  /// Review focus: the same link with Codex's records not in: the row shows only the link, so
  /// only the link goes.
  @Test func aFolderOnlyALinkShowsStays() throws {
    defer { cleanUp() }
    let real = try skill(home.appending(path: ".agents/skills/find-skills"))
    let claude = account.appending(path: "skills/find-skills")
    try link(claude, to: real)
    let plan = try actions.deletePlan(for: try row("find-skills"))
    #expect(plan.steps == [.removeLink(claude.skillPath)])
    #expect(
      plan.lines == [
        "Remove the link at \(SkillText.path(claude)) (the folder it points to stays)."
      ])
    try actions.delete(plan)
    #expect(!exists(claude))
    #expect(exists(real.appending(path: "SKILL.md")))
    #expect(try FileManager.default.contentsOfDirectory(atPath: trash.skillPath).isEmpty)
  }

  /// Review focus: a link to a link: both go, the folder at the end stays.
  @Test func aChainOfLinksKeepsItsTarget() throws {
    defer { cleanUp() }
    let notes = try skill(outside.appending(path: "notes"))
    let middle = home.appending(path: ".agents/skills/notes")
    let seen = account.appending(path: "skills/notes")
    try link(middle, to: notes)
    try link(seen, to: middle)
    let plan = try actions.deletePlan(for: try row("notes"))
    #expect(plan.steps == [.removeLink(seen.skillPath), .removeLink(middle.skillPath)])
    expectLinesSay(plan)
    #expect(plan.lines.allSatisfy { $0.contains("stays") })
    try actions.delete(plan)
    #expect(!exists(seen))
    #expect(!exists(middle))
    #expect(exists(notes.appending(path: "SKILL.md")))
  }

  /// One link spelled through `/private` and without is one step.
  @Test func aLinkSpelledTwoWaysIsRemovedOnce() throws {
    defer { cleanUp() }
    let notes = try skill(outside.appending(path: "notes"))
    let seen = account.appending(path: "skills/notes")
    try link(seen, to: notes)
    let other = "/private" + seen.skillPath
    try #require(SkillPath.isLink(other))
    var record = try row("notes")
    record.sightings[0].path = other
    let plan = try actions.deletePlan(for: record)
    #expect(plan.steps == [.removeLink(other)])
    expectLinesSay(plan)
  }

  /// Review focus: the folder a plan trashes was swapped for a link: nothing happens.
  @Test func aFolderReplacedByALinkIsNotTrashed() throws {
    defer { cleanUp() }
    let real = try skill(home.appending(path: ".agents/skills/find-skills"))
    let claude = account.appending(path: "skills/find-skills")
    try link(claude, to: real)
    let plan = try actions.deletePlan(for: try row("find-skills", codex: [real]))
    let moved = outside.appending(path: "find-skills")
    try FileManager.default.moveItem(at: real, to: moved)
    try link(real, to: moved)
    #expect(throws: SkillActionError.self) { try actions.delete(plan) }
    #expect(SkillPath.isLink(claude.skillPath))
    #expect(SkillPath.isLink(real.skillPath))
    #expect(exists(moved.appending(path: "SKILL.md")))
    #expect(try FileManager.default.contentsOfDirectory(atPath: trash.skillPath).isEmpty)
  }

  /// Review focus: the folder's parent became a link to somewhere else: nothing is trashed.
  @Test func aFolderReachedThroughANewLinkIsNotTrashed() throws {
    defer { cleanUp() }
    let real = try skill(home.appending(path: ".agents/skills/find-skills"))
    let plan = try actions.deletePlan(for: try row("find-skills", codex: [real]))
    #expect(plan.steps == [.trash(real.skillPath)])
    let skills = home.appending(path: ".agents/skills")
    let elsewhere = outside.appending(path: "skills")
    try FileManager.default.moveItem(at: skills, to: elsewhere)
    try link(skills, to: elsewhere)
    #expect(throws: SkillActionError.self) { try actions.delete(plan) }
    #expect(exists(elsewhere.appending(path: "find-skills/SKILL.md")))
    #expect(try FileManager.default.contentsOfDirectory(atPath: trash.skillPath).isEmpty)
  }

  @Test func deletingAMissingLinkRemovesOnlyIt() throws {
    defer { cleanUp() }
    let seen = account.appending(path: "skills/old")
    try link(seen, to: root.appending(path: "gone"))
    let record = try row("old")
    #expect(record.isMissing)
    let plan = try actions.deletePlan(for: record)
    #expect(plan.steps == [.removeLink(seen.skillPath)])
    expectLinesSay(plan)
    try actions.delete(plan)
    #expect(!exists(seen))
  }

  @Test func deletingAProjectCommandTrashesItsFile() throws {
    defer { cleanUp() }
    let file = project.appending(path: ".claude/commands/a/b.md")
    try write("Do b.", to: file)
    let plan = try actions.deletePlan(for: try row("a:b"))
    #expect(plan.steps == [.trash(file.skillPath)])
    expectLinesSay(plan)
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

  /// Review focus: a clone never goes to the Trash, not even with its last link here: another
  /// project or account may link into it. The sheet says it stays.
  @Test func aClonesLastLinkLeavesTheClone() throws {
    defer { cleanUp() }
    let clone = places.sources.appending(path: "local/me/repo", directoryHint: .isDirectory)
    let one = try skill(clone.appending(path: "skills/one"))
    let two = try skill(clone.appending(path: "skills/two"))
    let oneLink = account.appending(path: "skills/one")
    let twoLink = account.appending(path: "skills/two")
    try link(oneLink, to: one)
    try link(twoLink, to: two)
    let stays = "The clone at \(SkillText.path(clone)) stays."
    let first = try actions.deletePlan(for: try row("one"))
    #expect(first.steps == [.removeLink(oneLink.skillPath)])
    #expect(first.notes == [stays])
    expectLinesSay(first)
    try actions.delete(first)
    let last = try actions.deletePlan(for: try row("two"))
    #expect(last.steps == [.removeLink(twoLink.skillPath)])
    #expect(
      last.lines == [
        "Remove the link at \(SkillText.path(twoLink)) (the folder it points to stays)."
      ])
    #expect(last.notes == [stays])
    try actions.delete(last)
    #expect(!exists(twoLink))
    #expect(exists(two.appending(path: "SKILL.md")))
    #expect(try FileManager.default.contentsOfDirectory(atPath: trash.skillPath).isEmpty)
  }

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

  /// A file, a folder or a link whose target is gone: none is ever replaced.
  @Test func nothingAtADestinationIsOverwritten() throws {
    defer { cleanUp() }
    let one = try skill(outside.appending(path: "lib/one"))
    let dangling = account.appending(path: "skills/one")
    try link(dangling, to: outside.appending(path: "gone"))
    #expect(throws: SkillActionError.self) {
      try actions.install([one], place: .user, agents: [.claude], method: .copy)
    }
    #expect(
      SkillPath.target(ofLink: dangling.skillPath) == outside.appending(path: "gone").skillPath)
    let file = home.appending(path: ".agents/skills/one")
    try write("mine", to: file)
    #expect(throws: SkillActionError.self) {
      try actions.install([one], place: .user, agents: [.codex], method: .link)
    }
    #expect((try? String(contentsOf: file, encoding: .utf8)) == "mine")
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

  @Test func twoFoldersWithOneNameAreRefused() throws {
    defer { cleanUp() }
    let first = try skill(outside.appending(path: "a/one"))
    let second = try skill(outside.appending(path: "b/one"))
    #expect(throws: SkillActionError.self) {
      try actions.install([first, second], place: .user, agents: [.claude], method: .link)
    }
    #expect(!exists(account.appending(path: "skills/one")))
  }

  /// A step that fails after others succeeded says what was already made.
  @Test func aLaterFailureNamesWhatWasAlreadyMade() throws {
    defer { cleanUp() }
    let one = try skill(outside.appending(path: "lib/one"))
    try write("in the way", to: home.appending(path: ".agents"))
    let error = #expect(throws: SkillActionError.self) {
      try actions.install([one], place: .user, agents: [.claude, .codex], method: .link)
    }
    let made = account.appending(path: "skills/one")
    #expect(SkillPath.isLink(made.skillPath))
    #expect(error?.message.contains(SkillText.path(made)) == true)
  }
}
