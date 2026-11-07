import Foundation
import MCPKit

/// Reading what an agent passed. Every refusal is a `SessionError` whose sentence names what
/// was wrong, so the agent's next call can be right.
enum Arguments {

  /// Nil when absent, null or blank; refused when it is anything but a string.
  static func string(_ value: MCPKit.JSONValue?, name: String) throws -> String? {
    guard let value, !value.isNull else { return nil }
    guard let text = value.stringValue else { throw SessionError("\(name) must be a string.") }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func requiredString(_ value: MCPKit.JSONValue?, name: String) throws -> String {
    guard let text = try string(value, name: name) else { throw SessionError("Give \(name).") }
    return text
  }

  static func bool(_ value: MCPKit.JSONValue?, name: String) throws -> Bool? {
    guard let value, !value.isNull else { return nil }
    guard let flag = value.boolValue else { throw SessionError("\(name) must be true or false.") }
    return flag
  }

  /// `fallback` when absent; otherwise held to `range`, a number outside it taken as the
  /// nearest end rather than refused. A whole number passed as a string is taken.
  static func clampedInt(
    _ value: MCPKit.JSONValue?, name: String, in range: ClosedRange<Int>, default fallback: Int
  ) throws -> Int {
    guard let value, !value.isNull else { return fallback }
    guard let number = value.intValue ?? value.stringValue.flatMap({ Int($0) }) else {
      throw SessionError("\(name) must be a whole number.")
    }
    return min(max(number, range.lowerBound), range.upperBound)
  }

  /// One of `E`'s raw values, or nil when absent; anything else is refused with the list.
  static func choice<E: RawRepresentable & CaseIterable>(
    _ value: MCPKit.JSONValue?, name: String, as _: E.Type
  ) throws -> E? where E.RawValue == String {
    guard let text = try string(value, name: name) else { return nil }
    guard let found = E(rawValue: text.lowercased()) else {
      let allowed = E.allCases.map(\.rawValue).joined(separator: ", ")
      throw SessionError("\(name) must be one of: \(allowed).")
    }
    return found
  }

  /// The session `value` names, resolved among every session the source knows of, ended
  /// ones included, as `drakar_list_sessions` with `include_ended` would list them.
  static func session(_ value: MCPKit.JSONValue?, in source: some SessionSource) async throws
    -> String
  {
    let given = try requiredString(value, name: "session")
    let known = await source.sessions(includeEnded: true, endedLimit: 100).map(\.id)
    return try SessionIDs.resolve(given, among: known)
  }
}

/// Naming a session by the agent's own id, or a prefix of it (spec §2).
enum SessionIDs {
  /// The shortest prefix taken: a UUID's first group, as the siblings take id prefixes.
  static let minimumPrefix = 8

  /// Exact id, or a unique prefix of ≥ 8 characters among `known`.
  static func resolve(_ given: String, among known: [String]) throws -> String {
    if known.contains(given) { return given }
    guard given.count >= minimumPrefix else {
      throw SessionError(
        "\"\(given)\" is too short to name a session: give \(minimumPrefix) characters or more.")
    }
    let prefix = given.lowercased()
    var matches: [String] = []
    for id in known where id.lowercased().hasPrefix(prefix) && !matches.contains(id) {
      matches.append(id)
    }
    switch matches.count {
    case 0: throw unknown(given)
    case 1: return matches[0]
    default:
      throw SessionError(
        "\"\(given)\" names \(matches.count) sessions: \(matches.joined(separator: ", ")). "
          + "Give more of the id.")
    }
  }

  /// The refusal for an id no session has, which also serves a session gone between calls.
  static func unknown(_ given: String) -> SessionError {
    SessionError("No session \(given). drakar_list_sessions lists them.")
  }
}
