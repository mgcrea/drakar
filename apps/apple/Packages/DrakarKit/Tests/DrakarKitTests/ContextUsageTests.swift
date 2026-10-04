import DrakarKit
import Foundation
import Testing

@Suite("Context in a transcript")
struct ContextUsageTests {

  private func tail(_ lines: [String], dropsFirstLine: Bool = false) -> TranscriptTail {
    TranscriptTail(data: Data(lines.joined(separator: "\n").utf8), dropsFirstLine: dropsFirstLine)
  }

  private let warmTurn =
    #"{"type":"assistant","timestamp":"2026-10-03T21:40:11.123Z","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":13456,"cache_read_input_tokens":86823,"output_tokens":386}}}"#

  /// All three input figures, always: `input_tokens` alone is 2 on a 100k prompt.
  @Test func readsTheWholePromptFromTheNewestTurn() throws {
    let reading = try #require(
      tail([
        #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":1}}}"#,
        warmTurn,
        #"{"type":"user","message":{"role":"user","content":"next"}}"#,
      ]).newestReading)
    #expect(reading.total == 100_281)
    #expect(reading.usage.output == 386)
    #expect(reading.modelID == "claude-opus-5-5")
    #expect(abs((reading.at?.timeIntervalSince1970 ?? 0) - 1_791_063_611.123) < 0.001)
  }

  /// A subagent's turn has its own context; it must not stand for the session's.
  @Test func skipsSidechainTurns() throws {
    let reading = try #require(
      tail([
        warmTurn,
        #"{"type":"assistant","isSidechain":true,"message":{"id":"s1","usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":1}}}"#,
      ]).newestReading)
    #expect(reading.total == 100_281)
  }

  /// A shape change that drops a key reads as nothing, not as an empty session.
  @Test func refusesAUsageMissingAnInputFigure() {
    #expect(
      tail([
        #"{"type":"assistant","message":{"id":"m","usage":{"input_tokens":3,"output_tokens":1}}}"#
      ])
      .newestReading == nil)
  }

  /// A tail read starts mid-line; that fragment is not JSON and is never parsed.
  @Test func dropsTheFragmentAtTheStartOfATail() {
    let reading = tail(
      [#"_tokens":9,"cache_read_input_tokens":9}}}"#, warmTurn], dropsFirstLine: true
    )
    .newestReading
    #expect(reading?.total == 100_281)
  }

  @Test func readsTheModelAttachmentWithItsVariant() {
    let model = tail([
      #"{"type":"attachment","attachment":{"type":"model","identity":{"modelId":"claude-opus-5[1m]"}}}"#,
      warmTurn,
    ]).newestModelID
    #expect(model == "claude-opus-5[1m]")
  }

  @Test func seesAnUnansweredToolCall() {
    let calling =
      #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#
    let answered =
      #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#
    #expect(tail([calling]).isAwaitingToolResult)
    #expect(!tail([calling, answered]).isAwaitingToolResult)
    #expect(!tail([warmTurn]).isAwaitingToolResult)
  }

  /// `suffixOf` takes the last 64KB of a mapped file and knows whether it cut a line.
  @Test func takesTheEndOfALongFile() throws {
    let filler = String(repeating: "x", count: 70_000)
    let data = Data((#"{"type":"user","message":{"content":"\#(filler)"}}"# + "\n" + warmTurn).utf8)
    let tail = TranscriptTail(suffixOf: data)
    #expect(tail.dropsFirstLine)
    #expect(tail.data.count == TranscriptTail.bytes)
    #expect(tail.newestReading?.total == 100_281)
  }

  @Test func readsTheEndOfAFile() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID()).jsonl")
    try Data(warmTurn.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let tail = try #require(TranscriptTail.read(file))
    #expect(!tail.dropsFirstLine)
    #expect(tail.newestReading?.total == 100_281)
  }
}
