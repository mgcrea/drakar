import DrakarKit
import Foundation
import Testing

/// The CLI's guess at the next prompt, written after a turn ends under `initialize`'s
/// `promptSuggestions`, and offered in the empty composer until a prompt or a turn starts.
@Suite("Prompt suggestions")
struct PromptSuggestionTests {

  private static let suggestion =
    #"{"type":"prompt_suggestion","suggestion":"run the tests","uuid":"u-1","session_id":"s-1"}"#

  private func text(_ message: ClientMessage) throws -> String {
    String(decoding: try message.line(), as: UTF8.self)
  }

  @Test func decodesTheLine() throws {
    #expect(
      try StreamMessage(line: Data(Self.suggestion.utf8)) == .promptSuggestion("run the tests"))
  }

  @Test func asksForThemAndPausesThem() throws {
    #expect(
      try text(.initialize(requestID: "init-1", promptSuggestions: true))
        == #"{"request":{"hooks":null,"promptSuggestions":true,"subtype":"initialize"},"request_id":"init-1","type":"control_request"}"#
        + "\n")
    #expect(
      try text(.setPromptSuggestionsPaused(requestID: "suggestions-1", paused: true))
        == #"{"request":{"paused":true,"subtype":"set_prompt_suggestions_paused"},"request_id":"suggestions-1","type":"control_request"}"#
        + "\n")
  }

  @Test func theTranslatorPassesItOn() throws {
    var translator = ClaudeTranslator()
    let events = translator.translate(
      try StreamMessage(line: Data(Self.suggestion.utf8)), at: nil)
    #expect(events == [.promptSuggested("run the tests")])
  }

  @Test func standsUntilAPromptOrATurn() {
    var transcript = Transcript()
    transcript.addPrompt("fix the build")
    transcript.apply(.turnEnded(TurnSummary(outcome: .completed)))
    transcript.apply(.promptSuggested("  run the tests\n"))
    #expect(transcript.suggestedPrompt == "run the tests")
    transcript.addPrompt("something else")
    #expect(transcript.suggestedPrompt == nil)

    transcript.apply(.turnEnded(TurnSummary(outcome: .completed)))
    transcript.apply(.promptSuggested("commit it"))
    // A background task's notification starts a turn with no prompt.
    transcript.apply(.turnStarted)
    #expect(transcript.suggestedPrompt == nil)
  }

  /// One that lands once the next turn began is about the turn before; a blank one is none.
  @Test func ignoresALateOrBlankOne() {
    var transcript = Transcript()
    transcript.addPrompt("fix the build")
    transcript.apply(.promptSuggested("run the tests"))
    #expect(transcript.suggestedPrompt == nil)
    transcript.apply(.turnEnded(TurnSummary(outcome: .completed)))
    transcript.apply(.promptSuggested(" "))
    #expect(transcript.suggestedPrompt == nil)
  }
}
