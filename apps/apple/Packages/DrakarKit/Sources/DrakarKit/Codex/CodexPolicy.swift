import Foundation

/// How Drakar's permission modes and answers read in Codex's words
/// (docs/codex-app-server.md, "Mode, model, effort"): a mode is an approval policy and a
/// sandbox, sent with every `turn/start` and kept by the thread.
public enum CodexPolicy {
  /// What a Codex session's mode pill offers: Codex has no plan mode outside its
  /// experimental API, and Auto (`approvalsReviewer: auto_review`) is unverified.
  public static func offeredModes(allowsBypass: Bool) -> [PermissionMode] {
    allowsBypass ? [.ask, .acceptEdits, .bypass] : [.ask, .acceptEdits]
  }

  /// `thread/start` and `thread/resume`'s `approvalPolicy` and `sandbox` (a mode string).
  public static func threadSettings(_ mode: PermissionMode) -> [String: JSONValue] {
    let (approval, sandbox) = pair(mode)
    return ["approvalPolicy": .string(approval), "sandbox": .string(sandbox)]
  }

  /// `turn/start`'s `approvalPolicy` and `sandboxPolicy` (the object form, verified
  /// 2026-10-07).
  public static func turnSettings(_ mode: PermissionMode) -> [String: JSONValue] {
    let (approval, sandbox) = pair(mode)
    return ["approvalPolicy": .string(approval), "sandboxPolicy": sandboxPolicy(sandbox)]
  }

  /// Ask before edits asks for edits and any command not known safe; Edit automatically runs
  /// edits and sandboxed commands unasked (both verified 2026-10-06). A mode Codex has no
  /// counterpart for asks.
  private static func pair(_ mode: PermissionMode) -> (approval: String, sandbox: String) {
    switch mode {
    case .acceptEdits: ("on-request", "workspace-write")
    case .bypass: ("never", "danger-full-access")
    case .ask, .plan, .auto: ("untrusted", "workspace-write")
    }
  }

  private static func sandboxPolicy(_ sandbox: String) -> JSONValue {
    switch sandbox {
    case "danger-full-access":
      .object(["type": .string("dangerFullAccess")])
    default:
      .object([
        "type": .string("workspaceWrite"), "writableRoots": .array([]),
        "networkAccess": .bool(false), "excludeTmpdirEnvVar": .bool(false),
        "excludeSlashTmp": .bool(false),
      ])
    }
  }

  /// The "for this session" choice a request offers, as a permission suggestion the sheet
  /// shows and passes back.
  public static let acceptForSession: JSONValue = .object([
    "type": .string("codexDecision"), "decision": .string("acceptForSession"),
  ])

  /// The answer to a command or file-change approval. Reject declines and the turn goes on,
  /// as with Claude; a deny that interrupts cancels, which ends the turn.
  public static func decision(_ decision: PermissionDecision) -> JSONValue {
    switch decision {
    case .allow(_, let permissions):
      if let chosen = permissions.first, chosen["type"] == .string("codexDecision"),
        let value = chosen["decision"]?.stringValue
      {
        return .string(value)
      }
      return .string("accept")
    case .deny(_, let interrupt):
      return .string(interrupt ? "cancel" : "decline")
    }
  }
}
