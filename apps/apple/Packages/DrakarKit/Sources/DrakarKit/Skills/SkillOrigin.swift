import Foundation

/// The two agents a skill can reach.
public enum SkillAgent: String, Sendable, Hashable, CaseIterable {
  case claude, codex

  public var other: SkillAgent { self == .claude ? .codex : .claude }
}

/// Where a skill comes from, which says what the Skills window may do with it.
public enum SkillOrigin: Sendable, Hashable {
  /// The account's own folder, or `~/.agents`'s.
  case user
  case project
  /// A plugin's, by its id: `name@marketplace` for Claude Code's, the `pluginId` for Codex's.
  case plugin(String)
  case codexSystem
  case codexAdmin
  /// A name Claude Code lists that no folder Drakar reads explains.
  case unknown

  /// The person's own: a skill they can share or delete here.
  public var isOwn: Bool { self == .user || self == .project }
}

/// A skill folder, or a command file of `.claude/commands`.
public enum SkillKind: Sendable, Hashable {
  case skill
  case command
}

/// A folder skills are found in, and where a skill found there comes from.
public struct SkillFolder: Sendable, Hashable {
  public var url: URL
  public var origin: SkillOrigin

  public init(url: URL, origin: SkillOrigin) {
    self.url = url
    self.origin = origin
  }
}
