import DrakarKit
import Foundation
import Testing

/// `ExitPlanMode`, answered with the extension's three choices.
@Suite("Approving a plan")
struct PlanApprovalTests {

  private func request() throws -> Transcript.PendingPermission {
    var transcript = Transcript()
    transcript.addPrompt("Plan it")
    for message in try Fixture.planRequest.messages {
      transcript.apply(message)
      if let pending = transcript.pendingPermissions.first { return pending }
    }
    throw FixtureError.noRequest
  }

  private enum FixtureError: Error { case noRequest }

  private func line(_ decision: PermissionDecision) throws -> String {
    String(decoding: try ClientMessage.permission(requestID: "r1", decision).line(), as: UTF8.self)
  }

  @Test func readsThePlanOffTheRequest() throws {
    let pending = try request()
    #expect(pending.request.isPlan)
    #expect(pending.request.toolUseID == "toolu_01CCZh57dthfdqy6ere3n884")
    #expect(!pending.request.isChoice)
    #expect(PlanApproval.plan(pending.request.input)?.hasPrefix("# Add hello.txt") == true)
  }

  /// Auto-accept switches the mode first, then allows the plan as it came.
  @Test func approvingRunsThePlanAsWritten() throws {
    let input = try request().request.input
    #expect(PlanApproval.approve(input, editsManually: false) == .allow(updatedInput: input))
  }

  /// Approving edits by hand leaves plan mode for the default one, for this session.
  @Test func approvingWithManualEditsSetsTheDefaultMode() throws {
    let decision = PlanApproval.approve(.object([:]), editsManually: true)
    #expect(
      try line(decision)
        == #"{"response":{"request_id":"r1","response":{"behavior":"allow","updatedInput":{},"updatedPermissions":[{"destination":"session","mode":"default","type":"setMode"}]},"subtype":"success"},"type":"control_response"}"#
        + "\n")
  }

  /// Without feedback the turn ends, as the extension ends it; with some, Claude reads it and
  /// plans again.
  @Test func keepingOnPlanning() throws {
    #expect(
      try line(PlanApproval.keepPlanning(feedback: "  "))
        == #"{"response":{"request_id":"r1","response":{"behavior":"deny","interrupt":true,"message":"User chose to stay in plan mode and continue planning"},"subtype":"success"},"type":"control_response"}"#
        + "\n")
    let revise = PlanApproval.keepPlanning(feedback: "Use touch instead")
    #expect(
      revise
        == .deny(message: PlanApproval.feedbackPrefix + "Use touch instead", interrupt: false))
  }

  @Test func aPlainDenyDoesNotInterrupt() throws {
    #expect(
      try line(.deny(message: "No"))
        == #"{"response":{"request_id":"r1","response":{"behavior":"deny","message":"No"},"subtype":"success"},"type":"control_response"}"#
        + "\n")
  }

  @Test func theCardSaysWhatBecameOfThePlan() throws {
    var transcript = Transcript()
    transcript.addPrompt("Plan it")
    for message in try Fixture.planRequest.messages { transcript.apply(message) }
    let call = try #require(
      transcript.entries.lazy.compactMap { entry -> Transcript.ToolCall? in
        if case .tool(let call) = entry.kind, call.name == PlanApproval.toolName { return call }
        return nil
      }.first)
    #expect(call.planOutcome == .keptPlanning(feedback: nil))

    var revised = call
    revised.result = Transcript.ToolResult(
      content: PlanApproval.feedbackPrefix + "Use touch", isError: true)
    #expect(revised.planOutcome == .keptPlanning(feedback: "Use touch"))
    revised.result = Transcript.ToolResult(
      content: "User has approved your plan. You can now start coding.", isError: false)
    #expect(revised.planOutcome == .approved)
    revised.result = nil
    #expect(revised.planOutcome == .waiting)
  }
}
