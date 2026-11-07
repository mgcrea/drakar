import DrakarKit
import Foundation

/// The "always" answers an agent may apply to a permission prompt: only what lasts no longer
/// than the session (spec §3 Permissions). Rules written to a settings file, directories added
/// and a mode switched are the person's to choose, never an agent's, so they are neither
/// listed nor applied.
public enum AlwaysOffer {
  /// Codex's session-long yes, the one Codex decision offered.
  static let codexSessionDecision = CodexPolicy.acceptForSession["decision"]?.stringValue

  /// The request's suggestions an agent may apply: `.addRules` with destination "session",
  /// and `.codexDecision` (Codex's session-long yes). Index = the suggestion's own `id`.
  public static func offered(_ request: PermissionRequest) -> [PermissionSuggestion] {
    request.parsedSuggestions.filter { suggestion in
      switch suggestion.kind {
      case .addRules: suggestion.destination == "session"
      case .codexDecision(let decision): decision == codexSessionDecision
      case .addDirectories, .setMode, .other: false
      }
    }
  }
}

/// An agent's answer to a permission prompt, built as the window's own controls build it: the
/// input runs as requested, and only offered suggestions travel back.
public enum PermissionAnswer {
  public enum Verdict: String, CaseIterable, Sendable { case allow, deny }

  /// What a deny says when the agent gives no reason.
  static let deniedMessage = "Denied by an agent through Drakar's MCP server."

  /// The decision the window would send for this choice. Throws SessionError for an
  /// AskUserQuestion request, or an `always` index not in `AlwaysOffer.offered`.
  public static func decision(
    for request: PermissionRequest, verdict: Verdict, message: String?, interrupt: Bool,
    always: [Int]
  ) throws -> PermissionDecision {
    guard !request.isChoice else {
      throw SessionError("This request is a question: use drakar_answer_question.")
    }
    // A plan, as the panel's "Yes, and approve edits manually" and "No, keep planning".
    if request.isPlan {
      guard always.isEmpty else {
        throw SessionError("A plan offers nothing to always allow: leave always out.")
      }
      switch verdict {
      case .allow: return PlanApproval.approve(request.input, editsManually: true)
      case .deny: return PlanApproval.keepPlanning(feedback: message ?? "")
      }
    }
    switch verdict {
    case .deny:
      guard always.isEmpty else {
        throw SessionError("always goes with an allow: leave it out of a deny.")
      }
      return .deny(message: message ?? deniedMessage, interrupt: interrupt)
    case .allow:
      let offered = AlwaysOffer.offered(request)
      let unknown = always.filter { index in !offered.contains { $0.id == index } }
      guard unknown.isEmpty else {
        let indices = offered.map { String($0.id) }
        throw SessionError(
          "always: \(unknown.map(String.init).joined(separator: ", ")) is not offered. "
            + (indices.isEmpty
              ? "This request offers nothing to always allow."
              : "It offers \(indices.joined(separator: ", ")), from its suggestions."))
      }
      let chosen = offered.filter { always.contains($0.id) }
      return .allow(updatedInput: request.input, updatedPermissions: chosen.map(\.raw))
    }
  }
}
