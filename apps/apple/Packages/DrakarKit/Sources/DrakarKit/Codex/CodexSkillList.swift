import Foundation

/// Codex's `skills/list` as the `/` menu and the inspector list it (docs/codex-app-server.md,
/// "Skills"): the enabled skills, one per name, sorted as Claude Code's are. A name found in
/// more than one place is the nearest one's: the repo's, then the user's, the admin's, the
/// system's.
public enum CodexSkillList {
  public static func entries(_ result: JSONValue) -> [SkillEntry] {
    let skills = (result["data"]?.arrayValue ?? []).flatMap { $0["skills"]?.arrayValue ?? [] }
    var kept: [String: (rank: Int, entry: SkillEntry)] = [:]
    for skill in skills {
      guard skill["enabled"]?.boolValue == true, let name = skill["name"]?.stringValue,
        !name.isEmpty
      else { continue }
      let rank = rank(of: skill["scope"]?.stringValue)
      if let existing = kept[name], existing.rank <= rank { continue }
      let description = [
        skill["interface"]?["shortDescription"]?.stringValue,
        skill["shortDescription"]?.stringValue, skill["description"]?.stringValue,
      ].lazy.compactMap { $0 }.first { !$0.isEmpty }
      kept[name] = (
        rank,
        SkillEntry(
          name: name, description: description ?? "", path: skill["path"]?.stringValue)
      )
    }
    return ProjectCapabilities.sorted(kept.values.map(\.entry))
  }

  /// Nearest first; a scope this version does not know comes last.
  private static func rank(of scope: String?) -> Int {
    switch scope {
    case "repo": 0
    case "user": 1
    case "admin": 2
    case "system": 3
    default: 4
    }
  }
}
