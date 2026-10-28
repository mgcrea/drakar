import DrakarKit
import Foundation
import Testing

@Suite("Stopping, backgrounding and reading a task")
struct TaskControlTests {

  /// `task-controls`'s reply to `id` (Fixture.swift names each one's scenario).
  private func reply(_ id: String) throws -> ControlResponse {
    let replies = try Fixture.taskControls.messages.compactMap { message -> ControlResponse? in
      if case .controlResponse(let response) = message { return response }
      return nil
    }
    return try #require(replies.first { $0.requestID == id })
  }

  private func outcome(_ id: String) throws -> BackgroundOutcome {
    let reply = try reply(id)
    return BackgroundOutcome(
      isSuccess: reply.isSuccess, response: reply.response, error: reply.error)
  }

  /// A reply as `get_task_output` gives it, for the shapes the capture has no sample of.
  private func output(_ text: String, totalBytes: Int = 0, truncated: Bool) throws
    -> TaskOutput
  {
    try #require(
      TaskOutput(
        .object([
          "output": .string(text), "total_bytes": .number(Double(totalBytes)),
          "truncated": .bool(truncated),
        ])))
  }

  /// Scenario 1: the call moved, `backgrounded: true`.
  @Test func aMovedCallIsMoved() throws {
    let outcome = try outcome("r-bg")
    #expect(outcome == .moved)
    #expect(outcome.message == nil)
  }

  /// Scenario 5: the call had finished, `backgrounded: false`.
  @Test func aFinishedCallIsNotFound() throws {
    let outcome = try outcome("r-bg-finished")
    #expect(outcome == .notFound)
    #expect(
      outcome.message
        == "Could not move this to the background. It may have just finished or already be running in the background."
    )
  }

  /// Scenario 6: `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, refused.
  @Test func aDisabledSessionSaysSo() throws {
    let outcome = try outcome("r-bg-disabled")
    #expect(outcome == .disabled)
    #expect(outcome.message == "Moving to the background is turned off for this session.")
  }

  @Test func anyOtherErrorFails() {
    let outcome = BackgroundOutcome(isSuccess: false, response: nil, error: "boom")
    #expect(outcome == .failed)
    #expect(outcome.message == "Could not move this to the background. Try again.")
  }

  /// Scenario 2: empty while the sleep ran, the CLI's own exit line after it ended.
  @Test func outputDecodes() throws {
    let running = try #require(TaskOutput(try reply("r-out-running").response))
    #expect(running.text == "")
    #expect(running.totalBytes == 0)
    #expect(!running.isTruncated)
    #expect(running.note == nil)

    let ended = try #require(TaskOutput(try reply("r-out-ended").response))
    #expect(ended.text == "\n[exited with code 0]\n")
    #expect(ended.totalBytes == 22)
    #expect(!ended.isTruncated)
    #expect(ended.displayText == "\n[exited with code 0]\n")

    #expect(TaskOutput(.object(["output": .string("x")])) == nil)
    #expect(TaskOutput(nil) == nil)
    #expect(TaskControl.noOutput == "No output yet.")
    #expect(
      TaskControl.stopFailure == "The agent could not be stopped. It may have finished already.")
  }

  /// A truncated tail starts mid-line, or mid-character: both are cut to where it is whole.
  @Test func aTruncatedTailStartsOnALine() throws {
    #expect(try output("tial\nline two", truncated: true).displayText == "line two")
    #expect(try output("\u{FFFD}\u{FFFD}abc", truncated: true).displayText == "abc")
    #expect(try output("tial\nline two", truncated: false).displayText == "tial\nline two")
  }

  @Test func escapesAndReturnsAreStripped() throws {
    #expect(
      try output("\u{1B}[31mred\u{1B}[0m\r\nok", truncated: false).displayText == "red\nok")
  }

  /// The size as `ByteCountFormatStyle(.file)` writes it here: "12 kB", not "12 KB".
  @Test func theNoteSaysHowMuch() throws {
    #expect(
      try output("x", totalBytes: 12288, truncated: true).note == "Showing the end of 12 kB")
    #expect(try output("x", totalBytes: 12288, truncated: false).note == nil)
  }
}
