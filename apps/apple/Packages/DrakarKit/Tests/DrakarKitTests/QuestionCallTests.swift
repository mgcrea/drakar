import DrakarKit
import Foundation
import Testing

@Suite("An AskUserQuestion in the transcript")
struct QuestionCallTests {
  private static let asking =
    #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"AskUserQuestion","input":{"questions":[{"question":"Which file?","header":"File","options":[{"label":"a.txt"},{"label":"b.txt"}],"multiSelect":false}]}}],"stop_reason":"tool_use"}}"#

  private func result(_ content: String, isError: Bool = false, structured: String = "")
    -> String
  {
    let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
    let extra = structured.isEmpty ? "" : #","toolUseResult":\#(structured)"#
    return
      #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":\#(escaped),"is_error":\#(isError)}]}\#(extra)}"#
  }

  private func history(_ lines: [String]) -> Transcript {
    Transcript.history(lines: lines.map { Data($0.utf8) })
  }

  private func call(_ transcript: Transcript) throws -> Transcript.ToolCall {
    let calls = transcript.entries.compactMap { entry -> Transcript.ToolCall? in
      if case .tool(let call) = entry.kind { return call }
      return nil
    }
    return try #require(calls.first)
  }

  @Test func answeredReadsTheStructuredAnswers() throws {
    let text =
      #"Your questions have been answered: "Which file?"="b.txt". You can now continue with these answers in mind."#
    let transcript = history([
      Self.asking,
      result(text, structured: #"{"questions":[],"answers":{"Which file?":"a.txt"}}"#),
    ])
    // The structured answer wins over the text, which is only a fallback.
    #expect(try call(transcript).questionOutcome == .answered(["Which file?": "a.txt"]))
    #expect(transcript.unansweredQuestion == nil)
  }

  @Test func answeredFallsBackToTheText() throws {
    let text =
      #"Your questions have been answered: "Which file?"="b.txt". You can now continue with these answers in mind."#
    let transcript = history([Self.asking, result(text)])
    #expect(try call(transcript).questionOutcome == .answered(["Which file?": "b.txt"]))
  }

  @Test func readsEachWayItCanEnd() throws {
    let declined =
      "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). The user provided the following reason for the rejection: not now"
    let cases: [(String, Bool, Transcript.QuestionOutcome)] = [
      ("The user did not answer the questions.", false, .unanswered),
      (UserQuestion.declinedMessage, true, .declined(reason: nil)),
      (declined, true, .declined(reason: "not now")),
      ("The user chose not to answer.", true, .declined(reason: nil)),
      ("Tool permission request failed: AbortError: Stream closed", true, .sessionEnded),
      (
        "[Tool call interrupted: the session ended before this call's result was recorded]", true,
        .sessionEnded
      ),
      ("[Request interrupted by user for tool use]", true, .unanswered),
      ("<tool_use_error>InputValidationError</tool_use_error>", true, .other),
    ]
    for (text, isError, outcome) in cases {
      #expect(
        try call(history([Self.asking, result(text, isError: isError)])).questionOutcome == outcome)
    }
    #expect(try call(history([Self.asking])).questionOutcome == .waiting)
  }

  /// A question whose process ended before an answer is still asked; one answered,
  /// declined, or followed by anything else is not.
  @Test func findsTheQuestionStillAsked() throws {
    #expect(history([Self.asking]).unansweredQuestion?.id == "t")
    let ended = result("Tool permission request failed: AbortError: Stream closed", isError: true)
    #expect(history([Self.asking, ended]).unansweredQuestion?.id == "t")
    #expect(
      history([Self.asking, result(UserQuestion.declinedMessage, isError: true)]).unansweredQuestion
        == nil)
    let prompt = #"{"type":"user","message":{"role":"user","content":"never mind"}}"#
    #expect(history([Self.asking, prompt]).unansweredQuestion == nil)
    let bash =
      #"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}"#
    #expect(history([bash]).unansweredQuestion == nil)
  }

  /// The prompt that answers an earlier question marks it answered, live and from history.
  @Test func aPromptAnswersTheEarlierQuestion() throws {
    let answer = UserQuestion.earlierAnswerPrompt([("Which file?", "b.txt")])
    let prompt =
      #"{"type":"user","message":{"role":"user","content":\#(String(data: try JSONEncoder().encode(answer), encoding: .utf8)!)}}"#
    let fromHistory = history([Self.asking, prompt])
    #expect(try call(fromHistory).questionOutcome == .answered(["Which file?": "b.txt"]))
    var live = history([Self.asking])
    live.addPrompt(answer)
    #expect(try call(live).questionOutcome == .answered(["Which file?": "b.txt"]))
    #expect(live.unansweredQuestion == nil)
  }
}
