import Foundation

/// The `---` block at the top of a SKILL.md or a command file: the `key: value` lines Claude
/// Code and Codex read a skill's name and description from. Plain values, quoted ones, and
/// `|` or `>` blocks; nothing else of YAML.
public enum SkillFrontmatter {
  /// The fields; empty when the text has no frontmatter, or it never closes.
  public static func fields(_ text: String) -> [String: String] {
    // "\r\n" is one Character in Swift, so line ends are made "\n" before splitting.
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
    var fields: [String: String] = [:]
    var index = 1
    while index < lines.count {
      let line = lines[index]
      index += 1
      if line.trimmingCharacters(in: .whitespaces) == "---" { return fields }
      guard let first = line.first, !first.isWhitespace, first != "#",
        let colon = line.firstIndex(of: ":")
      else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if let style = value.first, style == "|" || style == ">", value.count <= 2 {
        var block: [String] = []
        while index < lines.count, lines[index].first?.isWhitespace ?? true,
          lines[index].trimmingCharacters(in: .whitespaces) != "---"
        {
          let part = lines[index].trimmingCharacters(in: .whitespaces)
          if !part.isEmpty { block.append(part) }
          index += 1
        }
        fields[key] = block.joined(separator: style == ">" ? " " : "\n")
      } else {
        fields[key] = unquoted(value)
      }
    }
    return [:]
  }

  private static func unquoted(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
      value.last == first
    else { return value }
    let inner = String(value.dropFirst().dropLast())
    return first == "\""
      ? inner.replacingOccurrences(of: "\\\"", with: "\"")
      : inner.replacingOccurrences(of: "''", with: "'")
  }
}
