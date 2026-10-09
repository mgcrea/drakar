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
