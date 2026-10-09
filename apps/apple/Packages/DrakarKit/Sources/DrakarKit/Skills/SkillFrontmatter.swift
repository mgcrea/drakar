import Foundation

/// The `---` block at the top of a SKILL.md or a command file: the `key: value` lines Claude
/// Code and Codex read a skill's name and description from. Plain values, folded onto one
/// line when indented lines continue them, quoted ones, and `|` or `>` blocks; nothing else of
/// YAML. A byte order mark before the block is skipped.
public enum SkillFrontmatter {
  /// The fields; empty when the text has no frontmatter, or it never closes.
  public static func fields(_ text: String) -> [String: String] {
    // Lines are cut as they are read, so a long body after the closing "---" is never touched.
    // "\r\n" is one Character in Swift, so both line ends are told apart from the rest here.
    var rest = Substring(text)
    if rest.first == "\u{FEFF}" { rest = rest.dropFirst() }
    func next() -> Substring? {
      guard !rest.isEmpty else { return nil }
      guard let end = rest.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) else {
        defer { rest = "" }
        return rest
      }
      defer { rest = rest[rest.index(after: end)...] }
      return rest[..<end]
    }
    func isFence(_ line: Substring) -> Bool { line.trimmingCharacters(in: .whitespaces) == "---" }
    guard let opening = next(), isFence(opening) else { return [:] }
    var fields: [String: String] = [:]
    var pending = next()
    while let line = pending {
      pending = next()
      if isFence(line) { return fields }
      guard let first = line.first, !first.isWhitespace, first != "#",
        let colon = line.firstIndex(of: ":")
      else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if let style = value.first, style == "|" || style == ">", value.count <= 2 {
        var block: [String] = []
        while let more = pending, more.first?.isWhitespace ?? true, !isFence(more) {
          let part = more.trimmingCharacters(in: .whitespaces)
          if !part.isEmpty { block.append(part) }
          pending = next()
        }
        fields[key] = block.joined(separator: style == ">" ? " " : "\n")
      } else if let quote = value.first, quote == "\"" || quote == "'" {
        fields[key] = unquoted(value)
      } else {
        // A plain value goes on over the indented lines below it, joined by spaces.
        var parts = value.isEmpty ? [] : [value]
        while let more = pending, let first = more.first, first.isWhitespace, !isFence(more) {
          let part = more.trimmingCharacters(in: .whitespaces)
          guard !part.isEmpty else { break }
          parts.append(part)
          pending = next()
        }
        fields[key] = parts.joined(separator: " ")
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
