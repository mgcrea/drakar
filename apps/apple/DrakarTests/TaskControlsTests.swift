import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Stopping, backgrounding and reading a task")
struct TaskControlsTests {
  /// What the controls sent, in order.
  private final class Sent {
    var commands: [AgentCommand] = []
  }

  private func controls(
    timeout: Duration = .seconds(10), available: @escaping () -> Bool = { true }
  ) -> (TaskControls, Sent) {
    let sent = Sent()
    let controls = TaskControls(
      timeout: timeout, availability: available, send: { sent.commands.append($0) })
    return (controls, sent)
  }

  @Test func stopWaitsThenClears() {
    let (controls, sent) = controls()
    controls.stop(taskID: "t")
    #expect(controls.stopping == ["t"])
    #expect(sent.commands == [.stopTask(taskID: "t")])
    controls.answered(.taskStopAnswered(taskID: "t", error: nil))
    #expect(controls.stopping.isEmpty)
    #expect(controls.stopFailures.isEmpty)
  }

  @Test func aRefusedStopKeepsTheError() {
    let (controls, _) = controls()
    controls.stop(taskID: "t")
    controls.answered(.taskStopAnswered(taskID: "t", error: "No such task"))
    #expect(controls.stopping.isEmpty)
    #expect(controls.stopFailures == ["t": "No such task"])
    // Tried again, the old error goes with the new attempt.
    controls.stop(taskID: "t")
    #expect(controls.stopFailures.isEmpty)
  }

  @Test func aStopIsRetriedOnlyAfterItClears() {
    let (controls, sent) = controls()
    controls.stop(taskID: "t")
    controls.stop(taskID: "t")
    #expect(sent.commands == [.stopTask(taskID: "t")])
    controls.answered(.taskStopAnswered(taskID: "t", error: nil))
    controls.stop(taskID: "t")
    #expect(sent.commands == [.stopTask(taskID: "t"), .stopTask(taskID: "t")])
  }

  @Test func aMoveIsSentOnceAndKeepsItsOutcome() {
    let (controls, sent) = controls()
    controls.runInBackground(toolUseID: "c")
    controls.runInBackground(toolUseID: "c")
    #expect(controls.moving == ["c"])
    #expect(sent.commands == [.backgroundCall(toolUseID: "c")])
    controls.answered(.backgroundAnswered(toolUseID: "c", .notFound))
    #expect(controls.moving.isEmpty)
    #expect(controls.backgroundOutcomes == ["c": .notFound])
    #expect(!controls.backgroundDisabled)
  }

  @Test func noReplyClearsAfterTheTimeout() async throws {
    let (controls, _) = controls(timeout: .milliseconds(50))
    controls.stop(taskID: "t")
    controls.runInBackground(toolUseID: "c")
    #expect(controls.stopping == ["t"])
    #expect(controls.moving == ["c"])
    // Polled: the main actor is shared with the other suites, so the timeout runs late.
    for _ in 0..<100 where !controls.stopping.isEmpty || !controls.moving.isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(controls.stopping.isEmpty)
    #expect(controls.moving.isEmpty)
    // A reply after the timeout still says what happened, and waits on nothing.
    controls.answered(.taskStopAnswered(taskID: "t", error: "Too late"))
    controls.answered(.backgroundAnswered(toolUseID: "c", .moved))
    #expect(controls.stopping.isEmpty)
    #expect(controls.moving.isEmpty)
    #expect(controls.stopFailures == ["t": "Too late"])
    #expect(controls.backgroundOutcomes == ["c": .moved])
  }

  @Test func disabledHidesForTheSession() {
    let (controls, sent) = controls()
    controls.runInBackground(toolUseID: "c")
    controls.answered(.backgroundAnswered(toolUseID: "c", .disabled))
    #expect(controls.backgroundDisabled)
    #expect(controls.backgroundOutcomes == ["c": .disabled])
    controls.runInBackground(toolUseID: "other")
    #expect(sent.commands == [.backgroundCall(toolUseID: "c")])
    #expect(controls.moving.isEmpty)
  }

  @Test func anExitClearsWhatWaits() {
    let (controls, _) = controls()
    controls.stop(taskID: "t")
    controls.runInBackground(toolUseID: "c")
    controls.processEnded()
    #expect(controls.stopping.isEmpty)
    #expect(controls.moving.isEmpty)
  }

  @Test func unavailableSendsNothing() {
    let (controls, sent) = controls(available: { false })
    #expect(!controls.isAvailable)
    controls.stop(taskID: "t")
    controls.runInBackground(toolUseID: "c")
    controls.fetchOutput(taskID: "t")
    #expect(sent.commands.isEmpty)
    #expect(controls.stopping.isEmpty)
    #expect(controls.moving.isEmpty)
  }

  @Test func anOutputReplyKeepsTheLastOne() {
    let (controls, sent) = controls()
    controls.fetchOutput(taskID: "t")
    #expect(sent.commands == [.taskOutput(taskID: "t")])
    let output = TaskOutput(
      .object(["output": .string("hi"), "total_bytes": .number(2), "truncated": .bool(false)]))
    controls.answered(.taskOutputAnswered(taskID: "t", output))
    #expect(controls.outputs["t"] == output)
    controls.answered(.taskOutputAnswered(taskID: "t", nil))
    #expect(controls.outputs["t"] == output)
  }

  @Test func otherSignalsAreIgnored() {
    let (controls, _) = controls()
    controls.stop(taskID: "t")
    controls.answered(.queueChanged)
    #expect(controls.stopping == ["t"])
  }
}
