import AmiralKit
import Foundation
import Testing

@Suite("Decoding the CLI's stream")
struct StreamMessageTests {

  /// The property everything else rests on: every line the real CLI wrote decodes into a
  /// message this package models. An `.unknown` here means a capture outgrew the decoder.
  @Test(arguments: [Fixture.turnWithTool, .permissionRequest, .interruptThenTurn])
  func decodesEveryCapturedLine(_ fixture: Fixture) throws {
    let messages = try fixture.messages
    #expect(!messages.isEmpty)
    for message in messages {
      if case .unknown(let type, _) = message { Issue.record("unmodelled line: \(type)") }
    }
  }

  @Test func readsTheSessionFromInit() throws {
    let info = try #require(
      try Fixture.turnWithTool.messages.lazy.compactMap { message -> SessionInfo? in
        if case .system(.initialized(let info)) = message { return info }
        return nil
      }.first)
    #expect(info.sessionID == "84e79584-4dcd-48db-b738-57f6d1946155")
    #expect(info.cwd == "/Users/me/project")
    #expect(info.model == "claude-haiku-4-5-20251001")
    #expect(info.claudeCodeVersion == AmiralKit.capturedClaudeCodeVersion)
    #expect(info.tools.contains("Bash"))
  }

  /// One `assistant` line per content block, all sharing the message id: the quirk that
  /// makes merging necessary at all.
  @Test func assistantLinesArriveOnePerBlock() throws {
    let assistants = try Fixture.turnWithTool.messages.compactMap { message -> AssistantMessage? in
      if case .assistant(let assistant) = message { return assistant }
      return nil
    }
    #expect(assistants.count == 4)
    #expect(assistants.allSatisfy { $0.content.count == 1 })
    #expect(Set(assistants.map(\.messageID)).count == 2)
    #expect(
      assistants[1].content == [
        .toolUse(
          id: "toolu_01GGE8TDFnCoR7JQYCRuSz9e", name: "Bash",
          input: .object([
            "command": .string("echo amiral"),
            "description": .string("Run echo command with amiral argument"),
          ]))
      ])
  }

  @Test func readsAToolResult() throws {
    let results = try Fixture.turnWithTool.messages.flatMap { message -> [ContentBlock] in
      if case .user(let user) = message { return user.content }
      return []
    }
    #expect(
      results == [
        .toolResult(toolUseID: "toolu_01GGE8TDFnCoR7JQYCRuSz9e", content: "amiral", isError: false)
      ])
  }

  @Test func readsAPermissionRequest() throws {
    let requests = try Fixture.permissionRequest.messages.compactMap { message -> ControlRequest? in
      if case .controlRequest(let request) = message { return request }
      return nil
    }
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.requestID == "4fad1802-9dc6-4a2b-8406-b35194ce2f30")
    guard case .canUseTool(let permission) = request.kind else {
      Issue.record("not can_use_tool: \(request.kind)")
      return
    }
    #expect(permission.toolName == "Bash")
    #expect(permission.input["command"] == .string("touch amiral-probe.txt"))
    #expect(permission.blockedPath == "/Users/me/project/amiral-probe.txt")
    #expect(
      permission.suggestions.compactMap { $0["type"]?.stringValue } == [
        "addRules", "addDirectories", "setMode",
      ])
  }

  @Test func readsTheTurnResult() throws {
    let result = try #require(
      try Fixture.turnWithTool.messages.compactMap { message -> TurnResult? in
        if case .result(let result) = message { return result }
        return nil
      }.first)
    #expect(result.subtype == "success")
    #expect(!result.isError)
    #expect(result.stopReason == "end_turn")
    #expect(result.text == "Amiral.")
    #expect((result.totalCostUSD ?? 0) > 0)
  }

  @Test func answersInitializeFirst() throws {
    let first = try #require(try Fixture.turnWithTool.messages.first)
    guard case .controlResponse(let response) = first else {
      Issue.record("first line is \(first)")
      return
    }
    #expect(response.requestID == "req_init")
    #expect(response.isSuccess)
    #expect(response.response?["commands"]?.arrayValue?.isEmpty == false)
  }

  // MARK: - Leniency

  @Test func keepsAnUnknownTypeInsteadOfThrowing() throws {
    let message = try StreamMessage(line: Data(#"{"type":"from_the_future","x":1}"#.utf8))
    #expect(
      message
        == .unknown(
          type: "from_the_future",
          raw: .object(["type": .string("from_the_future"), "x": .number(1)])))
  }

  @Test func keepsAKnownTypeMissingItsFieldsAsUnknown() throws {
    let message = try StreamMessage(line: Data(#"{"type":"assistant"}"#.utf8))
    guard case .unknown(let type, _) = message else {
      Issue.record("decoded as \(message)")
      return
    }
    #expect(type == "assistant")
  }

  @Test func throwsOnlyWithoutAType() {
    #expect(throws: StreamMessageError.missingType) {
      try StreamMessage(line: Data(#"{"subtype":"init"}"#.utf8))
    }
    #expect(throws: (any Error).self) { try StreamMessage(line: Data("not json".utf8)) }
  }
}
