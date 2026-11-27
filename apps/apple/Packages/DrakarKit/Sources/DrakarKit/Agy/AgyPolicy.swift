import Foundation

/// How Drakar's permission modes and answers map onto `agy acp` (docs/agy-acp.md):
/// Antigravity's four native modes (`default`, `accept-edits`, `plan`, `auto`) map directly,
/// and Bypass auto-approves every `session/request_permission` Drakar receives.
public enum AgyPolicy {
  /// One option offered by `session/request_permission`.
  public struct Option: Sendable, Equatable {
    public var optionID: String
    public var name: String
    /// `allow_once`, `allow_always`, `reject_once`, `reject_always`.
    public var kind: String

    public init(optionID: String, name: String, kind: String) {
      self.optionID = optionID
      self.name = name
      self.kind = kind
    }

    public init?(_ json: JSONValue) {
      guard let optionID = json["optionId"]?.stringValue else { return nil }
      self.optionID = optionID
      self.name = json["name"]?.stringValue ?? optionID
      self.kind = json["kind"]?.stringValue ?? ""
    }
  }

  /// Modes an Antigravity session's mode pill offers.
  public static func offeredModes(allowsBypass: Bool) -> [PermissionMode] {
    allowsBypass
      ? [.ask, .acceptEdits, .plan, .auto, .bypass] : [.ask, .acceptEdits, .plan, .auto]
  }

  /// Drakar's mode as an ACP `modeId`. Bypass runs in `auto` on the wire while Drakar
  /// auto-approves every permission request (`letsThrough`).
  public static func modeID(_ mode: PermissionMode) -> String {
    switch mode {
    case .ask: "default"
    case .acceptEdits: "accept-edits"
    case .plan: "plan"
    case .auto, .bypass: "auto"
    }
  }

  /// An ACP `modeId` back to Drakar's mode.
  public static func permissionMode(from modeID: String) -> PermissionMode? {
    switch modeID {
    case "default": .ask
    case "accept-edits": .acceptEdits
    case "plan": .plan
    case "auto": .auto
    default: nil
    }
  }

  /// Whether `mode` auto-approves every `session/request_permission` without asking.
  public static func letsThrough(in mode: PermissionMode) -> Bool {
    mode == .bypass
  }

  /// Any `allow_always` option a request offers, wrapped as a permission suggestion so the
  /// sheet shows it and passes its `optionId` back.
  public static func suggestions(from options: [Option]) -> [JSONValue] {
    options.filter { $0.kind == "allow_always" }.map { option in
      .object([
        "type": .string("agyOption"),
        "optionId": .string(option.optionID),
        "name": .string(option.name),
      ])
    }
  }

  /// The ACP `session/request_permission` result for `decision`.
  public static func result(_ decision: PermissionDecision, options: [Option]) -> JSONValue {
    switch decision {
    case .allow(_, let permissions):
      if let chosen = permissions.first, chosen["type"] == .string("agyOption"),
        let optionID = chosen["optionId"]?.stringValue
      {
        return selected(optionID)
      }
      return allowOnce(options: options)
    case .deny(_, let interrupt):
      if interrupt { return cancelled }
      let rejectID =
        options.first(where: { $0.kind == "reject_once" })?.optionID
        ?? options.first(where: { $0.kind == "reject_always" })?.optionID
        ?? "deny"
      return selected(rejectID)
    }
  }

  public static func allowOnce(options: [Option]) -> JSONValue {
    let allowID =
      options.first(where: { $0.kind == "allow_once" })?.optionID
      ?? options.first(where: { $0.kind == "allow_always" })?.optionID
      ?? "allow"
    return selected(allowID)
  }

  public static let cancelled: JSONValue = .object([
    "outcome": .object(["outcome": .string("cancelled")])
  ])

  public static func selected(_ optionID: String) -> JSONValue {
    .object([
      "outcome": .object([
        "outcome": .string("selected"),
        "optionId": .string(optionID),
      ])
    ])
  }
}
