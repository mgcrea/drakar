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

  /// A rewind goes under its own `rewind-<UUID>` id, and its reply names the message and
  /// whether it was a dry run, in whatever order replies come.
  @Test func aRewindReplyNamesItsMessage() throws {
    let backend = ClaudeBackend()
    let process = try process()
    defer { process.terminate() }
    let dry = try #require(
      try backend.send(.rewindFiles(userMessageID: "u-a", dryRun: true), to: process))
    #expect(dry.hasPrefix("rewind-"))
    #expect(UUID(uuidString: String(dry.dropFirst("rewind-".count))) != nil)
    let real = try #require(
      try backend.send(.rewindFiles(userMessageID: "u-b", dryRun: false), to: process))
    #expect(real != dry)
    // The capture's rewind reply (docs/claude-stream-json.md, "Rewind").
    let rewound = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(real)","response":{"canRewind":true,"skippedLinks":0}}}"#
      ),
      from: process, at: .now)
    let done = try #require(
      RewindResult(.object(["canRewind": .bool(true), "skippedLinks": .number(0)])))
    #expect(rewound.signals == [.rewindAnswered(userMessageID: "u-b", dryRun: false, done)])
    #expect(rewound.events.isEmpty)
    let checked = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(dry)","response":{"canRewind":true,"filesChanged":["/p/a.txt"],"insertions":0,"deletions":2}}}"#
      ),
      from: process, at: .now)
    let result = try #require(checked.signals.first)
    guard case .rewindAnswered("u-a", true, let answer?) = result else {
      Issue.record("unexpected \(result)")
      return
    }
    #expect(answer.canRewind)
    #expect(answer.filesChanged == ["/p/a.txt"])
    #expect(answer.deletions == 2)
    // Answered once: the same id again, or one never sent, says nothing.
    let again = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(dry)","response":{"canRewind":true}}}"#
      ),
      from: process, at: .now)
    #expect(again.signals.isEmpty)
    let unknown = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"rewind-unknown","response":{"canRewind":true}}}"#
      ),
      from: process, at: .now)
    #expect(unknown.signals.isEmpty)
  }

  /// A refused rewind is a control `error` with no response: its text still tells "no
  /// checkpoint" from "not enabled". Only an error with no text says nothing.
  @Test func aRefusedRewindCarriesItsError() throws {
    let backend = ClaudeBackend()
    let process = try process()
    defer { process.terminate() }
    let noCheckpoint = "No file checkpoint found for this message."
    let notEnabled = "File rewinding is not enabled."
    let first = try #require(
      try backend.send(.rewindFiles(userMessageID: "u-a", dryRun: false), to: process))
    let second = try #require(
      try backend.send(.rewindFiles(userMessageID: "u-b", dryRun: false), to: process))
    let third = try #require(
      try backend.send(.rewindFiles(userMessageID: "u-c", dryRun: false), to: process))
    let missing = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(first)","error":"\#(noCheckpoint)"}}"#
      ),
      from: process, at: .now)
    #expect(
      missing.signals == [
        .rewindAnswered(userMessageID: "u-a", dryRun: false, RewindResult(refusal: noCheckpoint))
      ])
    let off = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(second)","error":"\#(notEnabled)"}}"#
      ),
      from: process, at: .now)
    #expect(
      off.signals == [
        .rewindAnswered(userMessageID: "u-b", dryRun: false, RewindResult(refusal: notEnabled))
      ])
    guard case .rewindAnswered(_, _, let refused?) = off.signals.first else {
      Issue.record("no refusal")
      return
    }
    #expect(refused.isNotEnabled)
    #expect(!refused.hasNoCheckpoint)
    let silent = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(third)"}}"#),
      from: process, at: .now)
    #expect(silent.signals == [.rewindAnswered(userMessageID: "u-c", dryRun: false, nil)])
  }
}
