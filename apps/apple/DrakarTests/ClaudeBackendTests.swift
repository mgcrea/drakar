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

  /// A `cat` stands in for the process: what the backend writes is not read here. Ended when
  /// the suite's process exits; each is a few kilobytes.
  private func process() throws -> AgentProcess {
    let process = AgentProcess(
      .init(
        executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
        currentDirectory: FileManager.default.temporaryDirectory))
    _ = try process.start()
    return process
  }

  @Test func initializeAnswersWithModelsAndTheMode() throws {
    let backend = ClaudeBackend()
    let output = backend.receive(
      try line(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"models":[],"current_permission_mode":"plan"}}}"#
      ),
      from: try process(), at: .now)
    #expect(output.events.isEmpty)
    #expect(output.signals.contains(.modeAdopted("plan")))
    #expect(output.signals.contains { if case .initialized = $0 { true } else { false } })
  }

  /// Review Focus 5: each refusal names its own request.
  @Test func aRefusalNamesItsRequest() throws {
    let backend = ClaudeBackend()
    let process = try process()
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
    let output = ClaudeBackend().receive(
      try line(#"{"type":"command_lifecycle","command_uuid":"u","state":"queued"}"#),
      from: try process(), at: .now)
    #expect(output.signals == [.queueChanged])
  }
}
