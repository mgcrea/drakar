import DrakarKit
import Foundation
import Testing

@Suite("An Agy ACP session as a state machine")
struct AgySessionTests {
  private func json(_ text: String) throws -> JSONValue {
    try JSONValue.parse(Data(text.utf8))
  }

  private func answer(_ session: inout AgySession, _ write: JSONValue, _ result: String) throws
    -> AgySession.Step
  {
    let id = try #require(write["id"])
    return session.receive(
      .object(["jsonrpc": .string("2.0"), "id": id, "result": try json(result)]), at: .now)
  }

  private func fail(_ session: inout AgySession, _ write: JSONValue, _ message: String) throws
    -> AgySession.Step
  {
    let id = try #require(write["id"])
    return session.receive(
      .object([
        "jsonrpc": .string("2.0"), "id": id,
        "error": .object(["code": .number(-32603), "message": .string(message)]),
      ]), at: .now)
  }

  private let initResult =
    #"{"protocolVersion":1,"agentInfo":{"name":"Antigravity ACP Server","version":"1.5.18"}}"#

  private let sessionNewResult = #"""
    {
      "sessionId": "agy-sess-1",
      "models": {
        "currentModelId": "gemini-4-neon-high",
        "availableModels": [
          {"modelId": "gemini-4-neon-high", "name": "Gemini 4 Neon (High)"},
          {"modelId": "gemini-4-neon-low", "name": "Gemini 4 Neon (Low)"},
          {"modelId": "gemini-3.8-flash-low", "name": "Gemini 3.8 Flash (Low)"}
        ]
      },
      "modes": {"currentModeId": "default"},
      "configOptions": [
        {
          "id": "model",
          "currentValue": "gemini-4-neon",
          "options": [
            {"value": "gemini-4-neon", "name": "Gemini 4 Neon"},
            {"value": "gemini-3.8-flash", "name": "Gemini 3.8 Flash"}
          ]
        },
        {
          "id": "thought_level",
          "currentValue": "high",
          "options": [
            {"value": "low", "name": "Low"},
            {"value": "high", "name": "High"}
          ]
        },
        {"id": "mode", "currentValue": "default"}
      ]
    }
    """#

  private func input(_ text: String) -> JSONValue { .array([AgyInput.text(text)]) }

  @Test func opensSessionOnFirstPromptAndAppliesPreselectedPicks() throws {
    var session = AgySession(
      cwd: "/p", resuming: nil, mode: .acceptEdits, model: "gemini-3.8-flash", effort: "low",
      version: "1.4.0")
    let start = session.start()
    #expect(start.writes.map { $0["method"]?.stringValue } == ["initialize"])

    // Prompt sent before initialize holds until initialized.
    let early = session.send(.prompt(input: input("Hi"), uuid: "u-1"))
    #expect(early.writes.isEmpty)

    let afterInit = try answer(&session, start.writes[0], initResult)
    #expect(afterInit.writes.map { $0["method"]?.stringValue } == ["session/new"])

    let afterNew = try answer(&session, afterInit.writes[0], sessionNewResult)
    #expect(
      afterNew.writes.map { $0["method"]?.stringValue } == [
        "session/set_config_option",
        "session/set_config_option",
        "session/set_mode",
        "session/prompt",
      ])
    #expect(
      afterNew.events.contains(
        .sessionStarted(
          SessionInfo(
            sessionID: "agy-sess-1", cwd: "/p", model: "gemini-3.8-flash",
            permissionMode: "acceptEdits", agentVersion: "1.5.18"))))
    #expect(afterNew.signals.contains(.modeAdopted("acceptEdits")))
    #expect(afterNew.signals.contains(.session(id: "agy-sess-1")))
  }

  @Test func resumesExistingSessionWithSessionResume() throws {
    var session = AgySession(
      cwd: "/p", resuming: "existing-id", mode: nil, model: nil, effort: nil, version: "1.4.0")
    let start = session.start()
    _ = session.send(.prompt(input: input("Continue"), uuid: "u-1"))
    let afterInit = try answer(&session, start.writes[0], initResult)
    #expect(afterInit.writes.count == 1)
    #expect(afterInit.writes[0]["method"] == .string("session/resume"))
    #expect(afterInit.writes[0]["params"]?["sessionId"] == .string("existing-id"))
  }

  @Test func queuesMidTurnPromptsAndSupportsCancelQueuedAndStop() throws {
    var session = AgySession(
      cwd: "/p", resuming: nil, mode: nil, model: nil, effort: nil, version: "1.4.0")
    let start = session.start()
    _ = session.send(.prompt(input: input("First"), uuid: "u-1"))
    let afterInit = try answer(&session, start.writes[0], initResult)
    let afterNew = try answer(&session, afterInit.writes[0], sessionNewResult)
    let promptWrite = try #require(afterNew.writes.last)
    #expect(promptWrite["method"] == .string("session/prompt"))

    // Queue two prompts while turn 1 runs.
    #expect(session.send(.prompt(input: input("Second"), uuid: "u-2")).writes.isEmpty)
    #expect(session.send(.prompt(input: input("Third"), uuid: "u-3")).writes.isEmpty)

    // Cancel "u-2".
    let cancelled = session.send(.cancelQueued(uuid: "u-2"))
    #expect(cancelled.events == [.queue(id: "u-2", .cancelled)])

    // Complete turn 1 → "u-3" starts automatically.
    let done1 = try answer(&session, promptWrite, #"{"stopReason":"end_turn"}"#)
    #expect(done1.events.contains(.turnEnded(TurnSummary(outcome: .completed))))
    #expect(done1.events.contains(.queue(id: "u-3", .started)))
    #expect(done1.writes.map { $0["method"]?.stringValue } == ["session/prompt"])

    // Queue "u-4", then Stop (cancelQueued: true) cancels turn and drops "u-4".
    _ = session.send(.prompt(input: input("Fourth"), uuid: "u-4"))
    let stopped = session.send(.interrupt(cancelQueued: true))
    #expect(stopped.events.contains(.queue(id: "u-4", .cancelled)))
    #expect(stopped.writes.map { $0["method"]?.stringValue } == ["session/cancel"])

    let done3 = try answer(&session, done1.writes[0], #"{"stopReason":"cancelled"}"#)
    #expect(done3.events == [.turnEnded(TurnSummary(outcome: .interrupted))])
    #expect(done3.writes.isEmpty)
  }

  @Test func handlesPermissionsAndBypassMode() throws {
    var session = AgySession(
      cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.4.0")
    let start = session.start()
    _ = session.send(.prompt(input: input("Run"), uuid: "u-1"))
    let afterInit = try answer(&session, start.writes[0], initResult)
    _ = try answer(&session, afterInit.writes[0], sessionNewResult)

    let permReq = try json(
      #"""
      {
        "jsonrpc": "2.0",
        "id": "11",
        "method": "session/request_permission",
        "params": {
          "sessionId": "agy-sess-1",
          "toolCall": {
            "toolCallId": "call_1",
            "name": "run_command",
            "kind": "execute",
            "rawInput": {"CommandLine": "echo hi"}
          },
          "options": [
            {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
            {"optionId": "deny", "name": "Deny", "kind": "reject_once"}
          ]
        }
      }
      """#)
    let asked = session.receive(permReq, at: .now)
    #expect(asked.events.count == 1)
    #expect(asked.writes.isEmpty)

    // Switching to bypass auto-approves the waiting permission and withdraws it.
    let bypass = session.send(.setMode(.bypass))
    #expect(bypass.events == [.permissionWithdrawn(requestID: "11")])
    #expect(bypass.writes[0] == AgyRPC.answer(.string("11"), result: AgyPolicy.selected("allow")))
    #expect(bypass.writes[1]["method"] == .string("session/set_mode"))

    // Next permission while in bypass is auto-approved without emitting an event.
    let permReq2 = try json(
      #"""
      {
        "jsonrpc": "2.0",
        "id": "12",
        "method": "session/request_permission",
        "params": {
          "sessionId": "agy-sess-1",
          "toolCall": {"toolCallId": "call_2", "name": "run_command", "kind": "execute"},
          "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"}]
        }
      }
      """#)
    let autoAllowed = session.receive(permReq2, at: .now)
    #expect(autoAllowed.events.isEmpty)
    #expect(
      autoAllowed.writes == [AgyRPC.answer(.string("12"), result: AgyPolicy.selected("allow"))])
  }

  @Test func liveModelEffortAndModeChangesReturnRequestIDsAndSignals() throws {
    var session = AgySession(
      cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.4.0")
    let start = session.start()
    _ = session.send(.prompt(input: input("Hi"), uuid: "u-1"))
    let afterInit = try answer(&session, start.writes[0], initResult)
    _ = try answer(&session, afterInit.writes[0], sessionNewResult)

    let switchModel = session.send(.setModel("gemini-3.8-flash"))
    let reqID = try #require(switchModel.requestID)
    let replied = try answer(
      &session, switchModel.writes[0],
      #"{"configOptions":[{"id":"model","currentValue":"gemini-3.8-flash","options":[{"value":"gemini-3.8-flash","name":"Gemini 3.8 Flash"}]},{"id":"thought_level","currentValue":"low","options":[{"value":"low","name":"Low"}]}]}"#
    )
    #expect(replied.signals.contains(.changeAnswered(requestID: reqID, refusal: nil)))
    #expect(replied.signals.contains(.settingsApplied(effort: "low", model: "gemini-3.8-flash")))

    let refusedEffort = session.send(.setEffort("bogus"))
    let errID = try #require(refusedEffort.requestID)
    let failedReply = try fail(&session, refusedEffort.writes[0], "invalid thought level")
    #expect(
      failedReply.signals.contains(
        .changeAnswered(requestID: errID, refusal: "invalid thought level")))
  }

  @Test func authFailureMarksSessionUnusable() throws {
    var session = AgySession(
      cwd: "/p", resuming: nil, mode: nil, model: nil, effort: nil, version: "1.4.0")
    let start = session.start()
    _ = session.send(.prompt(input: input("Hi"), uuid: "u-1"))
    let afterInit = try answer(&session, start.writes[0], initResult)
    let failed = try fail(&session, afterInit.writes[0], "User is not authenticated")
    #expect(failed.signals == [.unusable(AgySession.notSignedIn)])
  }

  @Test func unknownServerRequestIsRefusedAndNoted() throws {
    var session = AgySession(
      cwd: "/p", resuming: nil, mode: nil, model: nil, effort: nil, version: "1.4.0")
    let step = session.receive(
      try json(#"{"jsonrpc":"2.0","id":"99","method":"fs/read_text_file","params":{}}"#), at: .now)
    #expect(step.writes.count == 1)
    #expect(step.writes[0]["id"] == .string("99"))
    #expect(step.writes[0]["error"]?["code"] == .number(-32601))
    #expect(step.events.count == 1)
  }
}
