import DrakarKit
import Foundation
import Testing

/// A prompt sent while a turn runs: held by the CLI until it picks it up, at the next tool
/// boundary or once the turn ends, and said so by `command_lifecycle` lines keyed by the
/// prompt's `uuid`.
@Suite("Queued prompts")
struct QueuedPromptTests {

  private let banana = "bbbbbbbb-2222-4222-8222-222222222222"
  private let cherry = "cccccccc-3333-4333-8333-333333333333"

  private func message(_ line: String) throws -> StreamMessage {
    try StreamMessage(line: Data(line.utf8))
  }

  @Test func decodesALifecycleLine() throws {
    let line = try Fixture.queuedPrompts.lines[1]
    #expect(
      try StreamMessage(line: line)
        == .commandLifecycle(commandUUID: "aaaaaaaa-1111-4111-8111-111111111111", state: "started"))
  }

  /// The capture: a text-only turn, "banana" queued during it and "cherry" queued and
  /// cancelled. Banana waits through the first turn and starts its own.
  @Test func aPromptQueuedDuringATextTurnStartsTheNextOne() throws {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Write a 120-word paragraph about longships. No tools.")
    let messages = try Fixture.queuedPrompts.messages
    for message in messages.prefix(2) { transcript.apply(message) }
    transcript.queue(QueuedPrompt(uuid: banana, text: "Now say the word banana."))
    transcript.queue(QueuedPrompt(uuid: cherry, text: "Now say the word cherry."))
    #expect(transcript.queuedPrompts.map(\.uuid) == [banana, cherry])

    var sawFirstEnd = false
    for message in messages.dropFirst(2) {
      transcript.apply(message)
      if case .result = message, !sawFirstEnd {
        sawFirstEnd = true
        // The first turn ended; banana is still waiting, the cancelled cherry gone.
        #expect(transcript.queuedPrompts.map(\.uuid) == [banana])
        #expect(!transcript.isRunning)
      }
    }
    #expect(transcript.queuedPrompts.isEmpty)
    let prompts = transcript.entries.compactMap { entry -> String? in
      if case .prompt(let text) = entry.kind { return text }
      return nil
    }
    #expect(prompts.last == "Now say the word banana.")
    #expect(transcript.entries.last?.kind == .text("Banana."))
    #expect(transcript.turnEnd == .completed)
  }

  /// Picked up mid-turn, after a tool's result: the prompt lands there, and the turn runs on.
  @Test func aPromptPickedUpMidTurnLandsWhereTheCLITookIt() throws {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Run three commands")
    transcript.apply(
      try message(
        #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo one"}}]},"parent_tool_use_id":null,"session_id":"s"}"#
      ))
    transcript.queue(QueuedPrompt(uuid: banana, text: "Also say banana"))
    transcript.apply(
      try message(
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"one"}]},"parent_tool_use_id":null,"session_id":"s"}"#
      ))
    transcript.apply(
      try message(
        #"{"type":"command_lifecycle","command_uuid":"\#(banana)","state":"started","session_id":"s"}"#
      ))
    #expect(transcript.entries.last?.kind == .prompt("Also say banana"))
    #expect(transcript.isRunning)
    #expect(transcript.queuedPrompts.isEmpty)
  }

  /// A prompt the CLI will not run leaves the queue, saying so.
  @Test func aRefusedPromptLeavesTheQueue() throws {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Go")
    transcript.queue(QueuedPrompt(uuid: banana, text: "Also"))
    transcript.apply(
      try message(
        #"{"type":"command_lifecycle","command_uuid":"\#(banana)","state":"refused","session_id":"s"}"#
      ))
    #expect(transcript.queuedPrompts.isEmpty)
    guard case .notice(let note) = transcript.entries.last?.kind else {
      Issue.record("no notice: \(String(describing: transcript.entries.last?.kind))")
      return
    }
    #expect(note.contains("Also"))
  }

  @Test func anEndedProcessDropsItsQueue() {
    var transcript = Transcript()
    transcript.addPrompt("Go")
    transcript.queue(QueuedPrompt(uuid: banana, text: "One"))
    transcript.queue(QueuedPrompt(uuid: cherry, text: "Two"))
    transcript.processExited()
    #expect(transcript.queuedPrompts.isEmpty)
    #expect(transcript.entries.last?.kind == .notice("2 queued messages were not sent"))
  }

  @Test func writesThePromptsUUIDAndTheCancels() throws {
    func text(_ message: ClientMessage) throws -> String {
      String(decoding: try message.line(), as: UTF8.self)
    }
    #expect(
      try text(.prompt("Hi", uuid: banana))
        == #"{"message":{"content":"Hi","role":"user"},"parent_tool_use_id":null,"session_id":"","type":"user","uuid":"\#(banana)"}"#
        + "\n")
    #expect(
      try text(.cancelQueued(requestID: "cancel-1", uuid: banana))
        == #"{"request":{"message_uuid":"\#(banana)","subtype":"cancel_async_message"},"request_id":"cancel-1","type":"control_request"}"#
        + "\n")
    #expect(
      try text(.interrupt(requestID: "int-1", cancelQueued: true))
        == #"{"request":{"cancel_queued":true,"subtype":"interrupt"},"request_id":"int-1","type":"control_request"}"#
        + "\n")
    #expect(
      try text(.interrupt(requestID: "int-2"))
        == #"{"request":{"subtype":"interrupt"},"request_id":"int-2","type":"control_request"}"#
        + "\n")
  }
}
