import DrakarKit
import Foundation
import Testing

@Suite("Compacting before the prompt cache expires, as Claude Code does when attended")
struct IdleCompactionTests {

  private let start = Date(timeIntervalSince1970: 1_791_063_600)

  private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  private func reply(_ id: String, wrote1h: Int = 0, wrote5m: Int = 0) throws -> StreamMessage {
    try StreamMessage(
      line: Data(
        #"""
        {"type":"assistant","message":{"id":"\#(id)","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":\#(wrote1h + wrote5m),"cache_read_input_tokens":0,"output_tokens":9,"cache_creation":{"ephemeral_5m_input_tokens":\#(wrote5m),"ephemeral_1h_input_tokens":\#(wrote1h)}}}}
        """#.utf8))
  }

  // MARK: when

  /// Six minutes before the hour is out: the CLI's 90 %, from when the prompt went.
  @Test func isDueAtNinetyPercentOfAnHour() throws {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote1h: 250_000), at: at(5))
    #expect(IdleCompaction.due(transcript.promptCache) == at(54 * 60))
  }

  /// Every five minutes would compact a session each time the person looks away.
  @Test func isNeverDueOnAFiveMinuteCache() throws {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote5m: 250_000), at: at(5))
    #expect(IdleCompaction.due(transcript.promptCache) == nil)
  }

  @Test func isNeverDueWithoutACacheOrRightAfterACompaction() throws {
    #expect(IdleCompaction.due(PromptCache()) == nil)
    var transcript = ClaudeFeed()
    transcript.addPrompt("Hi", at: start)
    transcript.apply(try reply("m1", wrote1h: 250_000), at: at(5))
    transcript.apply(
      try StreamMessage(
        line: Data(
          #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":250000}}"#
            .utf8)), at: at(60))
    #expect(IdleCompaction.due(transcript.promptCache) == nil)
  }

  // MARK: the floor

  @Test func theFloorIsTheCLIsAndItsEnvironmentVariable() {
    #expect(IdleCompaction.floor(environment: [:]) == 200_000)
    #expect(
      IdleCompaction.floor(environment: ["CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS": "400000"])
        == 400_000)
    // Never under 100k, as the CLI clamps it, and a value it cannot read leaves the default.
    #expect(
      IdleCompaction.floor(environment: ["CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS": "5000"])
        == 100_000)
    #expect(
      IdleCompaction.floor(environment: ["CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS": "lots"])
        == 200_000)
  }

  // MARK: whether

  private func refusal(
    at seconds: TimeInterval = 54 * 60, tokens: Int? = 250_000, autoCompacts: Bool = true
  ) -> IdleCompaction.Refusal? {
    IdleCompaction.refusal(
      at: at(seconds), due: at(54 * 60), contextTokens: tokens, autoCompacts: autoCompacts,
      floor: 200_000)
  }

  @Test func goesWhenLongEnoughAndOnTime() {
    #expect(refusal() == nil)
    #expect(refusal(at: 54 * 60 + 60) == nil)
  }

  /// A Mac that slept through it wakes to a cache that may be gone: nothing left to save.
  @Test func aTimerThatFiresLateGivesUp() {
    #expect(refusal(at: 54 * 60 + 61) == .lapsed)
  }

  @Test func neverBeforeItIsDue() {
    #expect(refusal(at: 54 * 60 - 1) == .early)
  }

  @Test func aShortConversationIsNotWorthCompacting() {
    #expect(refusal(tokens: 199_999) == .small)
    #expect(refusal(tokens: nil) == .small)
  }

  @Test func notWhereAutoCompactIsOff() {
    #expect(refusal(autoCompacts: false) == .autoCompactOff)
  }

  // MARK: the run

  @Test func withNothingFirstItCompactsAtOnce() {
    var run = CompactionRun(first: nil, idle: true)
    #expect(run.prompt == "/compact")
    #expect(run.turnEnded(asked: false) == nil)
  }

  @Test func theCommandFirstThenCompact() {
    var run = CompactionRun(first: "/distill", idle: true)
    #expect(run.prompt == "/distill")
    #expect(run.isRunningFirst)
    #expect(run.turnEnded(asked: false) == "/compact")
    #expect(run.prompt == "/compact")
    #expect(!run.isRunningFirst)
    #expect(run.turnEnded(asked: false) == nil)
  }

  /// The person came back to answer it: what they asked for next is theirs to say.
  @Test func aFirstTurnThatAskedThePersonDoesNotCompact() {
    var run = CompactionRun(first: "/distill", idle: true)
    #expect(run.turnEnded(asked: true) == nil)
  }

  @Test func aBlankCommandIsNone() {
    #expect(CompactionRun(first: "  \n", idle: false).prompt == "/compact")
    #expect(CompactionRun(first: " /distill ", idle: false).prompt == "/distill")
  }
}
