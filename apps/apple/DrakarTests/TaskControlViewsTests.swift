import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What a card offers for its task")
struct TaskControlViewsTests {
  private func controls(available: Bool = true) -> TaskControls {
    TaskControls(availability: { available })
  }

  private func call(
    _ name: String = "Bash", id: String = "c", result: Transcript.ToolResult? = nil
  ) -> Transcript.ToolCall {
    let kind: ToolKind =
      name == "Agent" || name == "Task" ? .subagent(description: "d") : .shell(command: "sleep 9")
    return Transcript.ToolCall(id: id, name: name, input: .object([:]), kind: kind, result: result)
  }

  private func task(
    id: String? = "t", type: String? = "local_bash", background: Bool = false,
    status: AgentTask.Status = .running
  ) -> AgentTask {
    var task = AgentTask()
    task.taskID = id
    task.taskType = type
    task.isBackgrounded = background
    task.status = status
    return task
  }

  private let done = Transcript.ToolResult(content: "ok", isError: false)

  @Test func stopNeedsARunningTaskWithAnID() {
    let controls = controls()
    #expect(TaskOffer.of(call: call(), task: task(), controls: controls).stop)
    #expect(
      TaskOffer.of(call: call("Agent"), task: task(type: "local_agent"), controls: controls).stop)
    // A background one whose call already has its result is still running.
    #expect(
      TaskOffer.of(call: call(result: done), task: task(background: true), controls: controls).stop)
    #expect(!TaskOffer.of(call: call(), task: nil, controls: controls).stop)
    #expect(!TaskOffer.of(call: call(), task: task(id: nil), controls: controls).stop)
    for status in [AgentTask.Status.completed, .failed, .stopped, .ended("session ended")] {
      #expect(!TaskOffer.of(call: call(), task: task(status: status), controls: controls).stop)
    }
  }

  @Test func runInBackgroundNeedsAForegroundTaskAndNoResult() {
    let controls = controls()
    for name in ["Bash", "PowerShell", "Agent", "Task"] {
      #expect(TaskOffer.of(call: call(name), task: task(), controls: controls).runInBackground)
    }
    for name in ["Read", "Grep", "WebFetch", "Monitor"] {
      #expect(!TaskOffer.of(call: call(name), task: task(), controls: controls).runInBackground)
    }
    #expect(!TaskOffer.of(call: call(), task: nil, controls: controls).runInBackground)
    #expect(
      !TaskOffer.of(call: call(), task: task(background: true), controls: controls)
        .runInBackground)
    #expect(
      !TaskOffer.of(call: call(result: done), task: task(), controls: controls).runInBackground)
    #expect(
      !TaskOffer.of(call: call(), task: task(status: .completed), controls: controls)
        .runInBackground)
  }

  @Test func nothingWhenUnavailable() {
    let controls = controls(available: false)
    let offers = [
      TaskOffer.of(call: call(), task: task(), controls: controls),
      TaskOffer.of(call: call(result: done), task: task(background: true), controls: controls),
      TaskOffer.of(call: call(), task: task(), controls: nil),
      TaskOffer.of(call: call(result: done), task: task(background: true), controls: nil),
    ]
    for offer in offers {
      #expect(offer == TaskOffer(stop: false, runInBackground: false, output: false))
    }
  }

  @Test func nothingOnceDisabled() {
    let controls = controls()
    controls.runInBackground(toolUseID: "asked")
    controls.answered(.backgroundAnswered(toolUseID: "asked", .disabled))
    let offer = TaskOffer.of(call: call(), task: task(), controls: controls)
    #expect(!offer.runInBackground)
    // Run in background only: a stop is still offered.
    #expect(offer.stop)
    // The card that asked keeps its line, to say why.
    #expect(TaskOffer.of(call: call(id: "asked"), task: task(), controls: controls).runInBackground)
  }

  @Test func outputForABackgroundBashTask() {
    let controls = controls()
    #expect(
      TaskOffer.of(call: call(result: done), task: task(background: true), controls: controls)
        .output)
    // Once it ended too: its last output stays readable.
    #expect(
      TaskOffer.of(
        call: call(result: done), task: task(background: true, status: .completed),
        controls: controls
      ).output)
    #expect(!TaskOffer.of(call: call(), task: task(), controls: controls).output)
    #expect(
      !TaskOffer.of(call: call(), task: task(id: nil, background: true), controls: controls)
        .output)
  }

  @Test func noOutputForAnAgent() {
    let controls = controls()
    let agent = task(type: "local_agent", background: true)
    #expect(
      !TaskOffer.of(call: call("Agent", result: done), task: agent, controls: controls).output)
    #expect(TaskOffer.of(call: call("Agent", result: done), task: agent, controls: controls).stop)
  }

  @Test func aStoppedTaskBeatsTheResult() {
    let interrupted = Transcript.ToolResult(content: "Interrupted", isError: true)
    #expect(
      TaskCardState.of(result: interrupted, task: task(status: .stopped), isBackground: false)
        == .stopped)
    #expect(TaskCardState.of(result: interrupted, task: task(), isBackground: false) == .failed)
    #expect(TaskCardState.of(result: nil, task: nil, isBackground: false) == .running)
    #expect(TaskCardState.of(result: done, task: nil, isBackground: false) == .done)
  }

  @Test func aBackgroundTaskReadsAsItsTaskNotItsResult() {
    // The immediate result says it went to the background; the task says how it is doing.
    #expect(
      TaskCardState.of(result: done, task: task(background: true), isBackground: true) == .running)
    #expect(
      TaskCardState.of(
        result: done, task: task(background: true, status: .failed), isBackground: true)
        == .failed)
    #expect(
      TaskCardState.of(
        result: done, task: task(background: true, status: .completed), isBackground: true)
        == .done)
  }

  /// The kit's `task-controls` capture, folded up to its `count`th line, read from the repo.
  private func taskControls(upTo count: Int) throws -> ClaudeFeed {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/task-controls.jsonl")
    let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
    var feed = ClaudeFeed()
    feed.addPrompt("Run it")
    for line in lines.prefix(count) { feed.apply(try StreamMessage(line: Data(line.utf8))) }
    return feed
  }

  /// A foreground Bash moved by Run in background (task-controls.jsonl:5) gets its Output,
  /// and no longer the move.
  @Test func aMovedCallOffersItsOutput() throws {
    let id = "toolu_01Hriqem1KWjxUocjn2j6NJC"
    let feed = try taskControls(upTo: 7)
    let call = try #require(
      feed.entries.lazy.compactMap { entry -> Transcript.ToolCall? in
        if case .tool(let call) = entry.kind, call.id == id { return call }
        return nil
      }.first)
    let offer = TaskOffer.of(call: call, task: feed.agentTasks[id], controls: controls())
    #expect(offer == TaskOffer(stop: true, runInBackground: false, output: true))
  }
}
