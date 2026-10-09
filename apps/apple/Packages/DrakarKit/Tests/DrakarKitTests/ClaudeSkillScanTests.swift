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
    try skill(
      account.appending(path: "skills/review"), name: "review", description: "Review the diff.")
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
