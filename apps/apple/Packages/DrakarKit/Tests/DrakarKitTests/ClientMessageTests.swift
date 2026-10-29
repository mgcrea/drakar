import DrakarKit
import Foundation
import Testing

@Suite("Writing to the CLI")
struct ClientMessageTests {

  private func text(_ message: ClientMessage) throws -> String {
    String(decoding: try message.line(), as: UTF8.self)
  }

  /// The exact lines the spike sent, which the CLI accepted; `sortedKeys` makes them
  /// reproducible.
  @Test func encodesInitialize() throws {
    #expect(
      try text(.initialize(requestID: "req_init"))
        == #"{"request":{"hooks":null,"subtype":"initialize"},"request_id":"req_init","type":"control_request"}"#
        + "\n")
  }

  @Test func encodesMCPStatus() throws {
    #expect(
      try text(.mcpStatus(requestID: "probe-mcp"))
        == #"{"request":{"subtype":"mcp_status"},"request_id":"probe-mcp","type":"control_request"}"#
        + "\n")
  }

  @Test func encodesTheModeAndModelSwitches() throws {
    #expect(
      try text(.setModel(requestID: "model-1", model: "sonnet"))
        == #"{"request":{"model":"sonnet","subtype":"set_model"},"request_id":"model-1","type":"control_request"}"#
        + "\n")
    #expect(
      try text(.setPermissionMode(requestID: "mode-2", mode: "plan"))
        == #"{"request":{"mode":"plan","subtype":"set_permission_mode"},"request_id":"mode-2","type":"control_request"}"#
        + "\n")
  }

  /// Effort goes as a flag setting: the process's alone, never written to settings.json.
  @Test func encodesTheEffortSwitchAndItsReadBack() throws {
    #expect(
      try text(.setEffort(requestID: "effort-1", level: "high"))
        == #"{"request":{"settings":{"effortLevel":"high"},"subtype":"apply_flag_settings"},"request_id":"effort-1","type":"control_request"}"#
        + "\n")
    #expect(
      try text(.getSettings(requestID: "settings-2"))
        == #"{"request":{"subtype":"get_settings"},"request_id":"settings-2","type":"control_request"}"#
        + "\n")
  }

  /// Stop, Run in background and the output read, as the extension sends them (2.1.312).
  @Test func taskControlsEncode() throws {
    #expect(
      try text(.stopTask(requestID: "r-stop", taskID: "b8cffcoy7"))
        == #"{"request":{"subtype":"stop_task","task_id":"b8cffcoy7"},"request_id":"r-stop","type":"control_request"}"#
        + "\n")
    #expect(
      try text(.backgroundCall(requestID: "r-bg", toolUseID: "toolu_1"))
        == #"{"request":{"subtype":"background_tasks","tool_use_id":"toolu_1"},"request_id":"r-bg","type":"control_request"}"#
        + "\n")
    #expect(
      try text(.taskOutput(requestID: "r-out", taskID: "b8cffcoy7"))
        == #"{"request":{"subtype":"get_task_output","task_id":"b8cffcoy7"},"request_id":"r-out","type":"control_request"}"#
        + "\n")
  }

  /// A rewind and its dry run, as the extension sends them (2.1.312).
  @Test func rewindEncodes() throws {
    #expect(
      try text(.rewindFiles(requestID: "rewind-1", userMessageID: "aaaaaaaa", dryRun: true))
        == #"{"request":{"dry_run":true,"subtype":"rewind_files","user_message_id":"aaaaaaaa"},"request_id":"rewind-1","type":"control_request"}"#
        + "\n")
    #expect(
      try text(.rewindFiles(requestID: "rewind-2", userMessageID: "aaaaaaaa", dryRun: false))
        == #"{"request":{"dry_run":false,"subtype":"rewind_files","user_message_id":"aaaaaaaa"},"request_id":"rewind-2","type":"control_request"}"#
        + "\n")
  }

  @Test func encodesAPrompt() throws {
    #expect(
      try text(.prompt("Run it"))
        == #"{"message":{"content":"Run it","role":"user"},"parent_tool_use_id":null,"session_id":"","type":"user"}"#
        + "\n")
  }

  /// `allow` echoes the request's input back, and a whole number must stay whole: the
  /// tool reads `limit: 5`, not `limit: 5.0`.
  @Test func echoesTheInputInAnAllow() throws {
    let input: JSONValue = .object([
      "command": .string("touch amiral-probe.txt"), "limit": .number(5),
    ])
    let line = try text(.permission(requestID: "r1", .allow(updatedInput: input)))
    #expect(
      line
        == #"{"response":{"request_id":"r1","response":{"behavior":"allow","updatedInput":{"command":"touch amiral-probe.txt","limit":5}},"subtype":"success"},"type":"control_response"}"#
        + "\n")
  }

  @Test func passesChosenSuggestionsBack() throws {
    let suggestion: JSONValue = .object([
      "type": .string("setMode"), "mode": .string("acceptEdits"),
    ])
    let json = ClientMessage.permission(
      requestID: "r1", .allow(updatedInput: .object([:]), updatedPermissions: [suggestion])
    ).json
    #expect(json["response"]?["response"]?["updatedPermissions"] == .array([suggestion]))
  }

  @Test func encodesADeny() throws {
    let json = ClientMessage.permission(requestID: "r1", .deny(message: "Not now")).json
    #expect(
      json["response"]?["response"]
        == .object(["behavior": .string("deny"), "message": .string("Not now")]))
  }

  /// The envelope 2.1.311 accepted (`Fixture.elicitation`); an integer stays an integer.
  @Test func answersAnElicitation() throws {
    #expect(
      try text(
        .answerElicitation(
          requestID: "e1", .accept(["size": .number(4), "team": .string("core")])))
        == #"{"response":{"request_id":"e1","response":{"action":"accept","content":{"size":4,"team":"core"}},"subtype":"success"},"type":"control_response"}"#
        + "\n")
    let response = { (answer: ElicitationAnswer) in
      ClientMessage.answerElicitation(requestID: "e1", answer).json["response"]?["response"]
    }
    #expect(response(.accept(nil)) == .object(["action": .string("accept")]))
    #expect(response(.decline) == .object(["action": .string("decline")]))
    #expect(response(.cancel) == .object(["action": .string("cancel")]))
  }

  /// What a log keeps of an accepted form: the keys the server's schema named, never what
  /// the person typed. A line holding nothing typed is kept as it is.
  @Test func redactsAnAnsweredFormForALog() throws {
    let answered = ClientMessage.answerElicitation(
      requestID: "e1", .accept(["team": .string("core"), "size": .number(3)]))
    #expect(
      try answered.redactedLine().map { String(decoding: $0, as: UTF8.self) }
        == #"{"response":{"request_id":"e1","response":{"action":"accept","content":{"size":"<redacted>","team":"<redacted>"}},"subtype":"success"},"type":"control_response"}"#
        + "\n")
    let untyped: [ClientMessage] = [
      .answerElicitation(requestID: "e1", .accept(nil)),
      .answerElicitation(requestID: "e1", .decline),
      .answerElicitation(requestID: "e1", .cancel),
      .prompt("hello"), .initialize(requestID: "x"),
    ]
    for message in untyped { #expect(try message.redactedLine() == nil) }
  }

  /// Every line is one line: a newline inside would split it into two broken messages.
  @Test func endsEveryLineWithItsOnlyNewline() throws {
    let line = try ClientMessage.prompt("two\nlines").line()
    #expect(line.last == 0x0A)
    #expect(line.filter { $0 == 0x0A }.count == 1)
  }

  @Test func roundTripsThroughTheDecoder() throws {
    let line = try ClientMessage.initialize(requestID: "x").line()
    var buffer = LineBuffer()
    let lines = buffer.append(line)
    #expect(lines.count == 1)
    #expect(try JSONValue.parse(lines[0])["request_id"] == .string("x"))
  }
}

@Suite("Splitting the byte stream into lines")
struct LineBufferTests {

  @Test func holdsAPartialLineUntilItsNewline() {
    var buffer = LineBuffer()
    #expect(buffer.append(Data(#"{"type":"#.utf8)).isEmpty)
    #expect(buffer.append(Data(#""system"}"#.utf8)).isEmpty)
    #expect(buffer.append(Data("\n".utf8)) == [Data(#"{"type":"system"}"#.utf8)])
    #expect(buffer.remainder.isEmpty)
  }

  @Test func splitsSeveralLinesInOneChunk() {
    var buffer = LineBuffer()
    let lines = buffer.append(Data("a\r\n\nb\nc".utf8))
    #expect(lines == [Data("a".utf8), Data("b".utf8)])
    #expect(buffer.remainder == Data("c".utf8))
  }

  /// The real capture, fed one byte at a time, splits into the same lines as fed whole.
  @Test func splitsTheCaptureTheSameByteByByte() throws {
    let whole = try Fixture.turnWithTool.lines
    var buffer = LineBuffer()
    var lines: [Data] = []
    for line in whole {
      for byte in line + Data("\n".utf8) { lines += buffer.append(Data([byte])) }
    }
    #expect(lines == whole)
  }
}
