import DrakarKit
import Foundation
import Testing

/// What the CLI says beside the conversation: a request only the client can answer, why a
/// turn failed, a retry, a compaction, a notification. The lines are in the shapes the CLI
/// (2.1.288) writes them, read from its source.
@Suite("Nothing the CLI says is dropped")
struct NothingSilentTests {

  private func message(_ line: String) throws -> StreamMessage {
    try StreamMessage(line: Data(line.utf8))
  }

  private func transcript(_ lines: [String]) throws -> ClaudeFeed {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Run it")
    for line in lines { transcript.apply(try message(line)) }
    return transcript
  }

  private func text(_ message: ClientMessage?) throws -> String? {
    try message.map { String(decoding: try $0.line(), as: UTF8.self) }
  }

  // MARK: Requests from the CLI

  private let elicitation =
    #"{"type":"control_request","request_id":"e1","request":{"subtype":"elicitation","mcp_server_name":"linear","message":"Which team?","mode":"form","requested_schema":{"type":"object"}}}"#

  /// An MCP server's question waits on the client with no deadline; Drakar declines it, as
  /// the extension does.
  @Test func declinesAnElicitation() throws {
    guard case .controlRequest(let request) = try message(elicitation) else {
      Issue.record("not a control request")
      return
    }
    #expect(request.kind == .elicitation(serverName: "linear", message: "Which team?"))
    #expect(
      try text(request.reply)
        == #"{"response":{"request_id":"e1","response":{"action":"decline"},"subtype":"success"},"type":"control_response"}"#
        + "\n")
  }

  /// A request Drakar has no answer for is refused at once, as the SDK refuses one, rather
  /// than left for the CLI to wait on.
  @Test func refusesARequestItCannotAnswer() throws {
    let line =
      #"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback","callback_id":"c"}}"#
    guard case .controlRequest(let request) = try message(line) else {
      Issue.record("not a control request")
      return
    }
    #expect(
      try text(request.reply)
        == #"{"response":{"error":"Unsupported control request subtype: hook_callback","request_id":"h1","subtype":"error"},"type":"control_response"}"#
        + "\n")
  }

  /// A permission is the person's to answer; nothing goes back on its own.
  @Test func leavesAPermissionToThePerson() throws {
    let request = try #require(
      try Fixture.permissionRequest.messages.lazy.compactMap { message -> ControlRequest? in
        if case .controlRequest(let request) = message { return request }
        return nil
      }.first)
    #expect(request.reply == nil)
  }

  @Test func saysWhatADeclinedQuestionAsked() throws {
    let transcript = try transcript([elicitation])
    guard case .notice(let note) = transcript.entries.last?.kind else {
      Issue.record("no notice: \(String(describing: transcript.entries.last?.kind))")
      return
    }
    #expect(note.contains("linear"))
    #expect(note.contains("Which team?"))
  }

  // MARK: Failed turns

  @Test func aFailedTurnSaysWhy() throws {
    let line =
      #"{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":3,"errors":["Reached maximum number of turns (3)"],"session_id":"s"}"#
    let transcript = try transcript([line])
    #expect(transcript.turnEnd == .failed)
    #expect(transcript.entries.last?.kind == .failure("Reached maximum number of turns (3)"))
  }

  /// An API error arrives as the CLI's own assistant text, then a result repeating it.
  @Test func anErrorAlreadyWrittenIsNotRepeated() throws {
    let error = "API Error: 529 Overloaded"
    let lines = [
      #"{"type":"assistant","message":{"id":"m1","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"\#(error)"}],"stop_reason":"stop_sequence"},"parent_tool_use_id":null,"session_id":"s"}"#,
      #"{"type":"result","subtype":"success","is_error":true,"result":"\#(error)","session_id":"s"}"#,
    ]
    let transcript = try transcript(lines)
    #expect(transcript.turnEnd == .failed)
    #expect(transcript.entries.last?.kind == .text(error))
  }

  @Test func anInterruptIsNotAFailure() throws {
    let line =
      #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","errors":["aborted"],"session_id":"s"}"#
    let transcript = try transcript([line])
    #expect(transcript.turnEnd == .interrupted)
    #expect(transcript.entries.count == 1)
  }

  // MARK: Retries, compaction, notifications

  @Test func aRetryLastsUntilTheNextAnswer() throws {
    let retry =
      #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":4000,"error_status":529,"error":"overloaded","session_id":"s"}"#
    var transcript = try transcript([retry])
    #expect(transcript.retry == APIRetry(attempt: 2, maxRetries: 10, delayMS: 4000))
    transcript.apply(
      try message(
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m2"}},"parent_tool_use_id":null,"session_id":"s"}"#
      ))
    #expect(transcript.retry == nil)
  }

  @Test func compactionIsShownWhileItRunsAndOnceItLands() throws {
    var transcript = try transcript([
      #"{"type":"system","subtype":"status","status":"compacting","session_id":"s"}"#
    ])
    #expect(transcript.isCompacting)
    transcript.apply(
      try message(
        #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":616509},"session_id":"s"}"#
      ))
    #expect(!transcript.isCompacting)
    guard case .notice(let note) = transcript.entries.last?.kind else {
      Issue.record("no notice: \(String(describing: transcript.entries.last?.kind))")
      return
    }
    #expect(note.hasPrefix("Conversation compacted"))
    #expect(note.contains("auto"))
  }

  @Test func aNotificationIsANote() throws {
    let transcript = try transcript([
      #"{"type":"system","subtype":"notification","key":"k","text":"Fast mode is off for now","priority":"immediate","color":"error","session_id":"s"}"#
    ])
    #expect(transcript.entries.last?.kind == .failure("Fast mode is off for now"))
  }
}
