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
