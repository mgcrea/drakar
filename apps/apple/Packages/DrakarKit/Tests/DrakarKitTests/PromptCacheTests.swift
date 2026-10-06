import DrakarKit
import Foundation
import Testing

@Suite("The prompt cache, reckoned as the extension reckons it")
struct PromptCacheTests {

  private let start = Date(timeIntervalSince1970: 1_791_063_600)

  private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  /// An assistant line shaped as the stream sends it: `cache_creation` splits what the
  /// request wrote by how long it stays.
  private func reply(
    _ id: String, wrote1h: Int = 0, wrote5m: Int = 0, read: Int = 0, input: Int = 3,
    model: String = "claude-opus-5-5", parent: String? = nil
  ) throws -> StreamMessage {
    let parentField = parent.map { #","parent_tool_use_id":"\#($0)""# } ?? ""
    return try StreamMessage(
      line: Data(
        #"""
        {"type":"assistant"\#(parentField),"message":{"id":"\#(id)","model":"\#(model)","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(wrote1h + wrote5m),"cache_read_input_tokens":\#(read),"output_tokens":9,"cache_creation":{"ephemeral_5m_input_tokens":\#(wrote5m),"ephemeral_1h_input_tokens":\#(wrote1h)}}}}
        """#.utf8))
  }

  private func toolResult(_ id: String) throws -> StreamMessage {
    try StreamMessage(
      line: Data(
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"done"}]}}"#
          .utf8))
  }

  // MARK: live

  /// Anchored on when the prompt went, not when the answer came: the cache was written by
  /// the request.
  @Test func isWarmFromThePromptForAnHour() throws {
    var transcript = Transcript()
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote1h: 20_840), at: at(5))
    let cache = transcript.promptCache
    #expect(cache.state(at: at(10 * 60)) == .warm(minutesLeft: 50))
    // Minutes round up, so the last 30 seconds still read as one.
    #expect(cache.state(at: at(59 * 60 + 30)) == .warm(minutesLeft: 1))
    #expect(cache.state(at: at(60 * 60)) == .expired(idle: 3600, recacheTokens: 20_843))
  }

  @Test func aFiveMinuteWriteLastsFiveMinutes() throws {
    var transcript = Transcript()
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote5m: 4_000), at: at(2))
    #expect(transcript.promptCache.state(at: at(60)) == .warm(minutesLeft: 4))
    #expect(transcript.promptCache.state(at: at(301)) == .expired(idle: 301, recacheTokens: 4_003))
  }

  /// A request that only read the cache refreshed it for as long as it was written for.
  @Test func aReadKeepsTheTTLAndMovesTheAnchor() throws {
    var transcript = Transcript()
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote1h: 20_000), at: at(3))
    transcript.apply(try toolResult("t1"), at: at(600))
    transcript.apply(try reply("m2", read: 20_000), at: at(604))
    #expect(transcript.promptCache.state(at: at(700)) == .warm(minutesLeft: 59))
  }

  /// A request that neither read nor wrote the cache says nothing of it.
  @Test func isUnknownWithoutCacheTokens() throws {
    var transcript = Transcript()
    #expect(transcript.promptCache.state(at: start) == .unknown)
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote1h: 20_000), at: at(3))
    transcript.apply(try reply("m2", input: 50), at: at(9))
    #expect(transcript.promptCache.state(at: at(10)) == .unknown)
  }

  /// Every block of a message is its own line; the first one placed the anchor.
  @Test func keepsTheAnchorAcrossAMessagesLines() throws {
    var transcript = Transcript()
    transcript.apply(try reply("m1", wrote1h: 20_000), at: start)
    transcript.apply(try reply("m1", wrote1h: 20_000), at: at(120))
    #expect(transcript.promptCache.state(at: at(600)) == .warm(minutesLeft: 50))
  }

  /// A subagent has its own cache, and a `<synthetic>` line was never a request.
  @Test func ignoresSubagentsAndSyntheticLines() throws {
    var transcript = Transcript()
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote1h: 20_000), at: at(3))
    transcript.apply(try reply("s1", wrote5m: 900, parent: "agent1"), at: at(1200))
    transcript.apply(try reply("x1", model: "<synthetic>"), at: at(1300))
    #expect(transcript.promptCache.state(at: at(1800)) == .warm(minutesLeft: 30))
  }

  /// What was cached is not what the compacted conversation sends, until a request after it.
  @Test func aCompactionIsColdUntilTheNextMessage() throws {
    var transcript = Transcript()
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote1h: 20_000), at: at(3))
    transcript.apply(
      try StreamMessage(
        line: Data(
          #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":20000}}"#
            .utf8)), at: at(60))
    #expect(transcript.promptCache.state(at: at(70)) == .compacted)
    transcript.addPrompt("Go on", at: at(90))
    transcript.apply(try reply("m2", wrote1h: 3_000), at: at(95))
    #expect(transcript.promptCache.state(at: at(100)) == .warm(minutesLeft: 60))
  }

  // MARK: history

  private func history(_ lines: [String]) -> Transcript {
    Transcript.history(lines: lines.map { Data($0.utf8) })
  }

  private func line(_ type: String, _ time: String, _ rest: String) -> String {
    #"{"type":"\#(type)","timestamp":"2026-10-06T\#(time)Z",\#(rest)}"#
  }

  private let wrote1h =
    #""usage":{"input_tokens":3,"cache_creation_input_tokens":20000,"cache_read_input_tokens":100000,"output_tokens":9,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":20000}}"#

  private func date(_ time: String) throws -> Date {
    try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-10-06T\(time)Z")
  }

  /// A transcript file's lines carry when they were written, which is what history reckons by.
  @Test func historyReckonsByTheLinesTimestamps() throws {
    let transcript = history([
      line("user", "10:00:00.000", #""message":{"role":"user","content":"Hi"}"#),
      line(
        "assistant", "10:00:04.000",
        #""message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}],\#(wrote1h)}"#
      ),
      line(
        "user", "10:20:00.000",
        #""message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}"#
      ),
      line(
        "assistant", "10:20:03.000",
        #""message":{"id":"m2","model":"claude-opus-5-5","content":[{"type":"text","text":"done"}],\#(wrote1h)}"#
      ),
    ])
    let cache = transcript.promptCache
    #expect(cache.state(at: try date("10:30:00.000")) == .warm(minutesLeft: 50))
    #expect(
      cache.state(at: try date("12:32:00.000"))
        == .expired(idle: 2 * 3600 + 12 * 60, recacheTokens: 120_003))
  }

  @Test func historyKnowsACompaction() throws {
    let before = line(
      "assistant", "10:00:04.000",
      #""message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"hi"}],\#(wrote1h)}"#
    )
    let summary = line(
      "user", "10:05:00.000",
      #""isCompactSummary":true,"message":{"role":"user","content":"This session is being continued…"}"#
    )
    #expect(
      history([before, summary]).promptCache.state(at: try date("10:06:00.000")) == .compacted)
    let prompt = line("user", "10:06:00.000", #""message":{"role":"user","content":"Go on"}"#)
    let after = line(
      "assistant", "10:06:05.000",
      #""message":{"id":"m2","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],\#(wrote1h)}"#
    )
    #expect(
      history([before, summary, prompt, after]).promptCache.state(at: try date("10:07:00.000"))
        == .warm(minutesLeft: 59))
  }

  // MARK: wording

  @Test func saysWhatTheExtensionSays() {
    #expect(PromptCache.State.warm(minutesLeft: 42).help == "Prompt cache warm, about 42 min left.")
    #expect(
      PromptCache.State.expired(idle: 72 * 60, recacheTokens: nil).help
        == "Prompt cache likely expired (idle 1h 12m).")
    #expect(
      PromptCache.State.compacted.help == "Prompt cache does not cover the compacted conversation.")
    #expect(PromptCache.State.unknown.help == nil)
  }

  @Test func formatsIdleTimeAsTheExtensionDoes() {
    #expect(PromptCache.idle(59) == "0m")
    #expect(PromptCache.idle(12 * 60 + 59) == "12m")
    #expect(PromptCache.idle(3600 + 5 * 60) == "1h 5m")
    #expect(PromptCache.idle(2 * 86400 + 3 * 3600 + 40 * 60) == "2d 3h")
  }

  /// Resuming a cold session says what the next message will cost; a warm one says nothing.
  @Test func notesAColdCacheOnResume() {
    #expect(
      PromptCache.State.expired(idle: 2 * 3600 + 5 * 60, recacheTokens: 120_400).resumeNote
        == "Idle 2h 5m. The prompt cache has likely expired, so your next message will re-cache about 120k tokens."
    )
    #expect(
      PromptCache.State.expired(idle: 600, recacheTokens: 1_310_000).resumeNote
        == "Idle 10m. The prompt cache has likely expired, so your next message will re-cache about 1.3M tokens."
    )
    #expect(
      PromptCache.State.expired(idle: 600, recacheTokens: nil).resumeNote
        == "Idle 10m. The prompt cache has likely expired, so your next message will re-cache the conversation."
    )
    #expect(
      PromptCache.State.compacted.resumeNote
        == "The conversation was compacted, so your next message will re-cache it.")
    #expect(PromptCache.State.warm(minutesLeft: 3).resumeNote == nil)
  }

  /// The note is the client's, not the conversation's: a turn that ended on a question
  /// still ends on it, and a second note replaces the first.
  @Test func theNoteLeavesTheClosingTextAlone() throws {
    let transcript = history([
      line("user", "10:00:00.000", #""message":{"role":"user","content":"Hi"}"#),
      line(
        "assistant", "10:00:04.000",
        #""message":{"id":"m1","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"Shall I apply it?"}],\#(wrote1h)}"#
      ),
    ])
    var noted = transcript
    noted.noteColdCache(at: try date("12:00:00.000"))
    noted.noteColdCache(at: try date("13:00:00.000"))
    #expect(noted.entries.count == transcript.entries.count + 1)
    #expect(noted.closingText == transcript.closingText)
    #expect(noted.closingText?.text == "Shall I apply it?")
  }

  @Test func theNoteJoinsTheTranscriptOnlyWhenCold() throws {
    var transcript = Transcript()
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote5m: 4_000), at: at(2))
    transcript.noteColdCache(at: at(60))
    #expect(transcript.entries.count == 2)
    transcript.noteColdCache(at: at(59 * 60))
    #expect(
      transcript.entries.last?.kind
        == .notice(
          "Idle 59m. The prompt cache has likely expired, so your next message will re-cache about 4k tokens."
        ))
  }
}
