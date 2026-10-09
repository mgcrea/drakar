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
