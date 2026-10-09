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
