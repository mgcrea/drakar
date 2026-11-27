import Foundation

/// Grok Build's `grok models` output as `[ModelOption]`, until a live `grok agent stdio`
/// session provides the full list with display names and effort levels.
public enum GrokModels {
  public static func list(fromOutput text: String) -> [ModelOption] {
    var models: [ModelOption] = []
    var inList = false
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line == "Available models:" {
        inList = true
        continue
      }
      guard inList else { continue }
      let rest: Substring
      if line.hasPrefix("* ") {
        rest = line.dropFirst(2)
      } else if line.hasPrefix("- ") {
        rest = line.dropFirst(2)
      } else {
        continue
      }
      var id = String(rest)
      if id.hasSuffix(" (default)") {
        id = String(id.dropLast(" (default)".count))
      }
      id = id.trimmingCharacters(in: .whitespaces)
      guard !id.isEmpty else { continue }
      models.append(ModelOption(value: id, resolvedModel: id, displayName: id))
    }
    return models
  }
}
