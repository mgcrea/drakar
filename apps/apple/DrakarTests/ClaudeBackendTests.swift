import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Claude Code behind the backend")
struct ClaudeBackendTests {
  private func line(_ json: String) throws -> AgentProcess.Line {
    .json(try JSONValue.parse(Data(json.utf8)))
  }

  /// A `cat` stands in for the process: what the backend writes is not read here. Each test
  /// terminates its own.
  private func process() throws -> AgentProcess {
    let process = AgentProcess(
      .init(
        executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
        currentDirectory: FileManager.default.temporaryDirectory))
    _ = try process.start()
    return process
  }

  /// The settings reply says whether settings turn auto mode off, beside what it applies.
  @Test func settingsSayWhetherAutoModeIsOff() throws {
    let backend = ClaudeBackend()
    let process = try process()
    defer { process.terminate() }
    let output = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"settings-1","response":{"effective":{"permissions":{"disableAutoMode":"disable"}},"applied":{"model":"claude-opus-5-5","effort":"high"}}}}"#
      ),
      from: process, at: .now)
    #expect(
      output.signals == [
        .settingsApplied(effort: "high", model: "claude-opus-5-5", autoModeDisabled: true)
      ])
  }

  @Test func initializeAnswersWithModelsAndTheMode() throws {
    let backend = ClaudeBackend()
    let process = try process()
    defer { process.terminate() }
    let output = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"models":[],"current_permission_mode":"plan"}}}"#
      ),
      from: process, at: .now)
    #expect(output.events.isEmpty)
    #expect(output.signals.contains(.modeAdopted("plan")))
    #expect(output.signals.contains { if case .initialized = $0 { true } else { false } })
  }

  /// Review Focus 5: each refusal names its own request.
  @Test func aRefusalNamesItsRequest() throws {
    let backend = ClaudeBackend()
    let process = try process()
    defer { process.terminate() }
    let first = try backend.send(.setMode("acceptEdits"), to: process)
    let second = try backend.send(.setMode("bypassPermissions"), to: process)
    #expect(first != second)
    let output = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(second!)","error":"Not allowed"}}"#
      ),
      from: process, at: .now)
    #expect(output.signals == [.changeAnswered(requestID: second!, refusal: "Not allowed")])
  }

  @Test func aLifecycleLineSaysTheQueueMoved() throws {
    let process = try process()
    defer { process.terminate() }
    let output = ClaudeBackend().receive(
      try line(#"{"type":"command_lifecycle","command_uuid":"u","state":"queued"}"#),
      from: process, at: .now)
    #expect(output.signals == [.queueChanged])
  }

  @Test func taskControlsEncodeWithTheirOwnIDs() throws {
    let backend = ClaudeBackend()
    let process = try process()
    defer { process.terminate() }
    let id = try #require(try backend.send(.stopTask(taskID: "t"), to: process))
    #expect(id.hasPrefix("stop-"))
    #expect(UUID(uuidString: String(id.dropFirst("stop-".count))) != nil)
    let background = try #require(
      try backend.send(.backgroundCall(toolUseID: "toolu_1"), to: process))
    #expect(background.hasPrefix("background-"))
    #expect(UUID(uuidString: String(background.dropFirst("background-".count))) != nil)
    let output = try #require(try backend.send(.taskOutput(taskID: "t"), to: process))
    #expect(output.hasPrefix("output-"))
    #expect(UUID(uuidString: String(output.dropFirst("output-".count))) != nil)
  }

  /// Replies come back in any order, and each names the task or call it was sent for.
  @Test func eachTaskReplyNamesItsOwnTask() throws {
    let backend = ClaudeBackend()
    let process = try process()
    defer { process.terminate() }
    let first = try #require(try backend.send(.stopTask(taskID: "t1"), to: process))
    let second = try #require(try backend.send(.stopTask(taskID: "t2"), to: process))
    let background = try #require(
      try backend.send(.backgroundCall(toolUseID: "toolu_1"), to: process))
    let output = try #require(try backend.send(.taskOutput(taskID: "t3"), to: process))
    // Fixture.taskControls' refusal (task-controls.jsonl:46), its request id put back: that
    // fixture lives in DrakarKit's test target, out of this one's reach.
    let disabled = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(background)","error":"Background tasks are disabled in this session."}}"#
      ),
      from: process, at: .now)
    #expect(disabled.signals == [.backgroundAnswered(toolUseID: "toolu_1", .disabled)])
    #expect(disabled.events.isEmpty)
    let refused = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(second)","error":"No such task"}}"#
      ),
      from: process, at: .now)
    #expect(refused.signals == [.taskStopAnswered(taskID: "t2", error: "No such task")])
    let stopped = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(first)","response":{}}}"#
      ),
      from: process, at: .now)
    #expect(stopped.signals == [.taskStopAnswered(taskID: "t1", error: nil)])
    let read = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(output)","response":{"output":"hi\n","total_bytes":3,"truncated":false}}}"#
      ),
      from: process, at: .now)
    let expected = TaskOutput(
      .object(["output": .string("hi\n"), "total_bytes": .number(3), "truncated": .bool(false)]))
    #expect(read.signals == [.taskOutputAnswered(taskID: "t3", expected)])
    // Answered once: the same id again, or one never sent, says nothing.
    let again = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(first)","response":{}}}"#
      ),
      from: process, at: .now)
    #expect(again.signals.isEmpty)
    let unknown = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"stop-unknown","response":{}}}"#
      ),
      from: process, at: .now)
    #expect(unknown.signals.isEmpty)
  }

  /// A refusal with no error still reads as one.
  @Test func aStopRefusedWithoutAnErrorStillFails() throws {
    let backend = ClaudeBackend()
    let process = try process()
    defer { process.terminate() }
    let id = try #require(try backend.send(.stopTask(taskID: "t"), to: process))
    let output = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(id)"}}"#),
      from: process, at: .now)
    #expect(output.signals == [.taskStopAnswered(taskID: "t", error: "")])
  }
}
