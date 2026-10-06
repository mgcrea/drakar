import Foundation

// What the views need to say about a message, kept here so it can be argued about in a
// test rather than discovered in a screenshot.

extension Transcript.ToolCall {
  /// One line saying what the call does: the command, the file, the pattern. What a
  /// collapsed tool card shows next to the tool's name.
  public var summary: String { kind.presentedSummary(input: input) }
}

extension PermissionRequest {
  public var summary: String { kind.presentedSummary(input: input) }
}

extension ToolKind {
  /// `summary`, except a plan says its title and a todo list its progress.
  fileprivate func presentedSummary(input: JSONValue) -> String {
    switch self {
    case .planApproval:
      // Its first line with text, a heading's marks left off.
      let title = (PlanApproval.plan(input) ?? "").split(whereSeparator: \.isNewline).lazy
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
        .first { !$0.isEmpty }
      return title ?? ""
    case .todos:
      let todos = TodoList.todos(input)
      let done = String(localized: "\(TodoList.progress(todos)) done")
      guard let current = TodoList.current(todos) else { return done }
      return "\(done) · \(current.activeForm ?? current.content)"
    default:
      return summary(input: input)
    }
  }
}

extension JSONValue {
  /// Indented, keys sorted, for showing a tool's input.
  public var prettyPrinted: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
}

/// One of a `can_use_tool` request's ready-made "always allow" answers, read enough to
/// label a button. `raw` is what goes back in `updatedPermissions`, unchanged.
public struct PermissionSuggestion: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    /// Allow rules, written to `destination` (`localSettings`, `userSettings`, …).
    case addRules([String])
    case addDirectories([String])
    case setMode(String)
    case other(String)
  }

  public var id: Int
  public var kind: Kind
  /// Where the choice is remembered: `session`, `localSettings`, `projectSettings`,
  /// `userSettings`.
  public var destination: String?
  public var raw: JSONValue

  public init?(_ raw: JSONValue, id: Int) {
    guard let type = raw["type"]?.stringValue else { return nil }
    self.id = id
    self.raw = raw
    destination = raw["destination"]?.stringValue
    switch type {
    case "addRules":
      let rules = raw["rules"]?.arrayValue ?? []
      kind = .addRules(
        rules.compactMap { rule in
          guard let tool = rule["toolName"]?.stringValue else { return nil }
          return rule["ruleContent"]?.stringValue.map { "\(tool)(\($0))" } ?? tool
        })
    case "addDirectories":
      kind = .addDirectories(raw["directories"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    case "setMode":
      kind = .setMode(raw["mode"]?.stringValue ?? "")
    default:
      kind = .other(type)
    }
  }

  /// Whether the choice outlives this session, which a label should say.
  public var isPersistent: Bool { destination != nil && destination != "session" }
}

extension PermissionRequest {
  public var parsedSuggestions: [PermissionSuggestion] {
    suggestions.enumerated().compactMap { PermissionSuggestion($1, id: $0) }
  }
}
