import Foundation

/// How Drakar's permission modes map onto `grok agent stdio` over ACP:
/// Grok supports `ask` (`default`) and `plan` natively via `session/set_mode`, while Bypass
/// auto-approves every `session/request_permission` Drakar receives (`AgyPolicy.letsThrough`).
public enum GrokPolicy {
  /// Modes a Grok session offers in Settings and the composer's mode pill.
  public static func offeredModes(allowsBypass: Bool) -> [PermissionMode] {
    allowsBypass ? [.ask, .plan, .bypass] : [.ask, .plan]
  }

  /// Drakar's mode as a Grok ACP `modeId`. Bypass runs in `default` on the wire while Drakar
  /// auto-approves every permission request (`AgyPolicy.letsThrough`).
  public static func modeID(_ mode: PermissionMode) -> String {
    switch mode {
    case .plan: "plan"
    case .ask, .acceptEdits, .auto, .bypass: "default"
    }
  }

  /// A Grok ACP `modeId` back to Drakar's mode.
  public static func permissionMode(from modeID: String) -> PermissionMode? {
    switch modeID {
    case "default", "ask", "agent": .ask
    case "plan": .plan
    default: nil
    }
  }
}
