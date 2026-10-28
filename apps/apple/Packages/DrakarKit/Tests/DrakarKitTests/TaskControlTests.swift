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

  /// The backgrounded call's result names the file its output goes to
  /// (task-controls.jsonl:7).
  @Test func theResultNamesTheOutputFile() throws {
    var feed = ClaudeFeed()
    feed.addPrompt("Run it")
    for message in try Fixture.taskControls.messages.prefix(7) { feed.apply(message) }
    let result = feed.entries.lazy.compactMap { entry -> String? in
      if case .tool(let call) = entry.kind, call.id == "toolu_01Hriqem1KWjxUocjn2j6NJC" {
        return call.result?.content
      }
      return nil
    }.first
    #expect(
      TaskOutput.outputFile(inResult: try #require(result))
        == URL(filePath: "/p/tasks/b8cffcoy7.output"))
    // At the end of the text, and on a line of its own.
    #expect(
      TaskOutput.outputFile(inResult: "Output is being written to: /a b/t.output.")
        == URL(filePath: "/a b/t.output"))
    #expect(
      TaskOutput.outputFile(inResult: "Output is being written to: /t.output\nmore")
        == URL(filePath: "/t.output"))
    #expect(TaskOutput.outputFile(inResult: "(Bash completed with no output)") == nil)
    #expect(TaskOutput.outputFile(inResult: "Output is being written to: relative.output.") == nil)
    #expect(TaskOutput.outputFile(inResult: nil) == nil)
  }

  private func temporaryFile(_ bytes: Data) throws -> URL {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "drakar-output-\(UUID().uuidString).output")
    try bytes.write(to: file)
    return file
  }

  /// A file under the CLI's cap reads whole, as `get_task_output` would answer.
  @Test func aShortFileReadsWhole() throws {
    let file = try temporaryFile(Data("line one\nline two\n".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let output = try #require(TaskOutput(tailOf: file))
    #expect(output.text == "line one\nline two\n")
    #expect(output.totalBytes == 18)
    #expect(!output.isTruncated)
    #expect(output.note == nil)
  }

  /// Over it, its last 8192 bytes, shown from their first whole line, the note saying how
  /// much there is.
  @Test func aLongFileReadsItsTail() throws {
    let lines = (0..<2000).map { "line \($0)\n" }.joined()
    let file = try temporaryFile(Data(lines.utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let output = try #require(TaskOutput(tailOf: file))
    #expect(output.text.utf8.count == 8192)
    #expect(output.totalBytes == lines.utf8.count)
    #expect(output.isTruncated)
    #expect(lines.hasSuffix(output.text))
    #expect(output.displayText.hasPrefix("line "))
    #expect(output.displayText.hasSuffix("line 1999\n"))
    #expect(output.note != nil)
  }

  /// An empty file is no output yet; a file not there is no reading at all.
  @Test func anEmptyOrMissingFile() throws {
    let file = try temporaryFile(Data())
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(TaskOutput(tailOf: file)?.text == "")
    #expect(
      TaskOutput(tailOf: FileManager.default.temporaryDirectory.appending(path: "no-such.output"))
        == nil)
  }
}
