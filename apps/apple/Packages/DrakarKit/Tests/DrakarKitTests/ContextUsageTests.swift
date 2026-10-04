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

  @Test func theStreamCarriesUsageIntoTheTranscript() throws {
    var transcript = Transcript()
    for message in try Fixture.contextUsage.messages { transcript.apply(message) }
    let usage = try #require(transcript.contextUsage)
    #expect(usage.total > 0)
    #expect(transcript.contextModelID != nil)
  }

  /// A subagent's request has its own context, which is not the session's.
  @Test func aSubagentsUsageLeavesTheSessionsAlone() throws {
    var transcript = Transcript()
    transcript.apply(
      try StreamMessage(
        line: Data(
          #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":99,"output_tokens":1}}}"#
            .utf8)))
    transcript.apply(
      try StreamMessage(
        line: Data(
          #"{"type":"assistant","parent_tool_use_id":"task1","message":{"id":"s1","content":[{"type":"text","text":"sub"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":5,"output_tokens":1}}}"#
            .utf8)))
    #expect(transcript.contextUsage?.total == 100)
  }

  /// History replays the same messages, so a resumed session has its gauge before it runs.
  @Test func historyCarriesTheNewestUsage() throws {
    // The captured history fixture carries no usage; build synthetic history from context-usage fixture
    let contextUsageLines = try Fixture.contextUsage.lines
    let assistantLine = try #require(
      contextUsageLines.first { line in
        String(decoding: line, as: UTF8.self).contains("\"type\":\"assistant\"")
      })
    let userLine = Data(#"{"type":"user","message":{"role":"user","content":"go"}}"#.utf8)
    let transcript = Transcript.history(lines: [userLine, assistantLine])
    #expect(transcript.contextUsage != nil)
  }

  /// What the CLI writes itself when a session hits its limit or the API fails: model
  /// `<synthetic>`, every figure zero. Trimmed from a local transcript (2.1.263).
  private let syntheticTurn =
    #"{"isSidechain":false,"type":"assistant","timestamp":"2026-09-08T15:46:39.018Z","message":{"id":"4a80696d","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","type":"message","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}},"content":[{"type":"text","text":"You've hit your session limit"}]},"isApiErrorMessage":true}"#

  /// A `<synthetic>` turn is not a reading: the gauge keeps the last real one, never 0 %.
  @Test func aSyntheticTurnIsNotAReading() throws {
    #expect(tail([warmTurn, syntheticTurn]).newestReading?.total == 100_281)
    #expect(tail([syntheticTurn]).newestReading == nil)
  }

  @Test func aSyntheticTurnLeavesTheTranscriptsUsageAlone() throws {
    let transcript = Transcript.history(lines: [Data(warmTurn.utf8), Data(syntheticTurn.utf8)])
    #expect(transcript.contextUsage?.total == 100_281)
    #expect(transcript.contextModelID == "claude-opus-5-5")
    var live = Transcript()
    live.apply(try StreamMessage(line: Data(warmTurn.utf8)))
    live.apply(try StreamMessage(line: Data(syntheticTurn.utf8)))
    #expect(live.contextUsage?.total == 100_281)
    #expect(live.contextModelID == "claude-opus-5-5")
  }

  @Test func asksForTheContextInSummary() throws {
    let json = ClientMessage.contextUsage(requestID: "context-1").json
    #expect(json["type"]?.stringValue == "control_request")
    #expect(json["request_id"]?.stringValue == "context-1")
    #expect(json["request"]?["subtype"]?.stringValue == "get_context_usage")
    #expect(json["request"]?["detail"]?.stringValue == "summary")
  }

  @Test func readsTheCapturedReply() throws {
    let responses = try Fixture.contextUsage.messages.compactMap { message -> ControlResponse? in
      if case .controlResponse(let response) = message, response.requestID.hasPrefix("ctx-") {
        return response
      }
      return nil
    }
    let reply = try #require(responses.last.flatMap { ContextUsageReply($0.response) })
    #expect(reply.maxTokens >= 200_000)
    #expect(reply.totalTokens > 0)
    #expect(!reply.categories.isEmpty)
    #expect(!reply.categories.contains { $0.name == "Free space" || $0.tokens == 0 })
    // Verify deferred and free categories are excluded
    #expect(!reply.categories.contains { $0.name.contains("(deferred)") })
    #expect(!reply.categories.contains { $0.name == "Autocompact buffer" })
    #expect(!reply.categories.contains { $0.name == "MCP tools (deferred)" })
    #expect(!reply.categories.contains { $0.name == "System tools (deferred)" })
  }

  private let endedOnAQuestion = [
    #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
    #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Built."}]}}"#,
    #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Want me to commit it?"}]}}"#,
    #"{"type":"system","subtype":"turn_duration"}"#,
    #"{"type":"last-prompt","lastPrompt":"Build it"}"#,
  ]

  @Test func theTailKnowsTheTextATurnEndedOn() {
    #expect(
      tail(endedOnAQuestion).closingText
        == ClosingText(messageID: "m1", text: "Built.\n\nWant me to commit it?"))
  }

  @Test func aPromptAfterTheEndTakesItAway() {
    let answered =
      endedOnAQuestion + [#"{"type":"user","message":{"role":"user","content":"yes"}}"#]
    #expect(tail(answered).closingText == nil)
  }

  @Test func aTurnThatCalledAToolHasNone() {
    #expect(
      tail([
        #"{"type":"assistant","message":{"id":"m","stop_reason":"tool_use","content":[{"type":"text","text":"Should I?"}]}}"#
      ]).closingText == nil)
  }

  /// "You've hit your session limit" is the CLI talking, not the model asking.
  @Test func aSyntheticTurnHasNone() {
    #expect(
      tail([
        #"{"type":"assistant","message":{"id":"m","model":"<synthetic>","stop_reason":"end_turn","content":[{"type":"text","text":"Limit reached. Upgrade?"}]}}"#
      ]).closingText == nil)
  }

  @Test func aSubagentsEndIsNotTheSessions() {
    let lines =
      endedOnAQuestion + [
        #"{"type":"assistant","isSidechain":true,"message":{"id":"s","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}"#
      ]
    #expect(tail(lines).closingText?.messageID == "m1")
  }

  @Test func aSummaryCarriesTheAsk() throws {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "drakar-closing-\(UUID().uuidString).jsonl")
    try Data(endedOnAQuestion.joined(separator: "\n").utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let account = ClaudeAccount(directory: file.deletingLastPathComponent(), isDefault: false)
    let summary = try #require(SessionIndex.summary(of: file, account: account))
    #expect(summary.closingAsk == ClosingAsk(kind: .question, text: "Want me to commit it?"))
    #expect(summary.closingMessageID == "m1")
  }
}
