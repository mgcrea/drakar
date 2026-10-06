import Foundation

/// The composer's `/` menu: what is being typed, and the commands it matches.
public enum SlashCommand {
  /// The name typed so far when the draft is a command's name being written: a `/` at its
  /// very start and no space yet. Nil otherwise, which closes the menu.
  public static func query(in draft: String) -> String? {
    guard draft.hasPrefix("/") else { return nil }
    let name = draft.dropFirst()
    guard !name.contains(where: \.isWhitespace) else { return nil }
    return String(name)
  }

  /// The commands whose name starts with `query`, or whose part after a namespace does
  /// (`brain` finds `superpowers:brainstorming`), then those containing it anywhere; each
  /// group in the list's own order. An empty query matches them all.
  public static func matches(_ query: String, in commands: [SkillEntry]) -> [SkillEntry] {
    guard !query.isEmpty else { return commands }
    let needle = query.lowercased()
    var starts: [SkillEntry] = []
    var contains: [SkillEntry] = []
    for command in commands {
      let name = command.name.lowercased()
      if name.hasPrefix(needle) || command.shortName.lowercased().hasPrefix(needle) {
        starts.append(command)
      } else if name.contains(needle) {
        contains.append(command)
      }
    }
    return starts + contains
  }
}
