import Foundation

/// `ExitPlanMode`: Claude's plan, waiting on the person. Answered with the extension's three
/// choices, in its words (webview 2.1.289): run it with edits accepted, run it approving each
/// edit, or keep planning, told what to change or not.
public enum PlanApproval {
  public static let toolName = "ExitPlanMode"

  /// A "keep planning" with nothing to say: the turn ends.
  public static let keepPlanningMessage = "User chose to stay in plan mode and continue planning"
  /// Ahead of what the person said to change, as the extension writes any rejection with a
  /// reason.
  public static let feedbackPrefix =
    "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). The user provided the following reason for the rejection: "

  public static func plan(_ input: JSONValue) -> String? {
    input["plan"]?.stringValue
  }

  /// Run the plan as written. With edits approved by hand, the session leaves plan mode for
  /// the default one; otherwise the caller switches the mode itself first, to acceptEdits or
  /// auto, as the extension does.
  public static func approve(_ input: JSONValue, editsManually: Bool) -> PermissionDecision {
    guard editsManually else { return .allow(updatedInput: input) }
    return .allow(
      updatedInput: input,
      updatedPermissions: [
        .object([
          "type": .string("setMode"), "mode": .string("default"),
          "destination": .string("session"),
        ])
      ])
  }

  /// Back to planning: with feedback Claude reads it and plans again; without, the turn ends.
  public static func keepPlanning(feedback: String) -> PermissionDecision {
    let feedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
    return feedback.isEmpty
      ? .deny(message: keepPlanningMessage, interrupt: true)
      : .deny(message: feedbackPrefix + feedback, interrupt: false)
  }
}

extension PermissionRequest {
  public var isPlan: Bool { kind == .planApproval }
}

extension Transcript {
  /// What became of a plan, read from its call's result.
  public enum PlanOutcome: Sendable, Equatable {
    case waiting
    case approved
    /// The person kept planning, saying what to change or not.
    case keptPlanning(feedback: String?)
  }
}

extension Transcript.ToolCall {
  /// For an `ExitPlanMode`; nil for any other tool.
  public var planOutcome: Transcript.PlanOutcome? {
    guard kind == .planApproval else { return nil }
    guard let result else { return .waiting }
    guard result.isError else { return .approved }
    guard result.content.hasPrefix(PlanApproval.feedbackPrefix) else {
      return .keptPlanning(feedback: nil)
    }
    let feedback = String(result.content.dropFirst(PlanApproval.feedbackPrefix.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return .keptPlanning(feedback: feedback.isEmpty ? nil : feedback)
  }
}
