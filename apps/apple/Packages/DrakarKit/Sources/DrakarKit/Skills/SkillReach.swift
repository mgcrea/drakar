import Foundation

/// Where a session would not find a skill (docs/superpowers/specs/2026-10-12-skill-fanout-design.md
/// §2). Claude Code reads the account's skills, its plugins', and the session folder's own
/// `.claude`; not a parent folder's.
public enum SkillReach {
  /// The folders among `folders` whose sessions would not find `name`. None when it is the
  /// CLI's own, the account's or a plugin's, or when neither `parent` nor `source` (the
  /// project the skill was listed for) holds it: a skill from somewhere Drakar doesn't read
  /// is taken to be found.
  public static func claudeMissing(
    name: String, isBuiltin: Bool, account: URL, parent: URL, source: URL? = nil,
    folders: [URL]
  ) -> Set<URL> {
    guard !isBuiltin,
      !ClaudeSkillScan.scan(account: account, project: nil).skills.contains(where: {
        $0.name == name
      }),
      ([parent] + (source.map { [$0] } ?? [])).contains(where: { projectNames($0).contains(name) })
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
