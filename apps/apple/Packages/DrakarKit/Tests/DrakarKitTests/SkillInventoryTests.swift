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

  private func path(_ url: URL) -> String { ProjectPath.normalize(url) }

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
      claude: [
        SkillEntry(name: "review"), SkillEntry(name: "mystery", description: "From somewhere."),
      ])
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
      name: "tools:lint", origin: .plugin("tools@market"),
      path: "/Users/me/cache/tools/skills/lint",
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

  /// Two folders holding a skill of one name are two rows; a name no folder explains is known
  /// by its name.
  @Test func oneNameInTwoFoldersIsTwoRows() {
    let mine = ScannedSkill(
      name: "review", origin: .user, path: "/Users/me/.claude/skills/review",
      realPath: "/Users/me/.claude/skills/review")
    let theirs = ScannedSkill(
      name: "review", origin: .project, path: "/Users/me/p/.claude/skills/review",
      realPath: "/Users/me/p/.claude/skills/review")
    let rows = merge([mine, theirs], claude: [SkillEntry(name: "review"), SkillEntry(name: "x")])
    #expect(rows.map(\.id) == [mine.realPath, theirs.realPath, "unknown:x"])
    #expect(rows.map(\.origin) == [.user, .project, .unknown])
  }

  /// The first to find a folder names the row and gives its origin; Codex adds its sighting,
  /// and its description only to a row without one.
  @Test func theScanGivesARowItsOrigin() {
    let folder = "/Users/me/.agents/skills/deploy"
    let scanned = ScannedSkill(
      name: "deploy", origin: .user, path: "/Users/me/.claude/skills/deploy", realPath: folder,
      isLink: true)
    let codex = CodexSkillRecord(
      name: "deploy-codex", description: "Deploy it.", path: folder + "/SKILL.md", scope: .repo,
      pluginID: nil, isEnabled: true)
    let rows = merge([scanned], codex: [codex])
    #expect(rows.count == 1)
    #expect(rows.first?.name == "deploy")
    #expect(rows.first?.origin == .user)
    #expect(rows.first?.description == "Deploy it.")
    #expect(rows.first?.sightings.map(\.agent) == [.claude, .codex])
    var described = scanned
    described.description = "Mine."
    #expect(merge([described], codex: [codex]).first?.description == "Mine.")
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
