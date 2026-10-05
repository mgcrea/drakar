import DrakarKit
import Foundation
import Testing

@Suite("Answering AskUserQuestion")
struct UserQuestionTests {
  /// The input captured on 2026-10-04 (docs/claude-stream-json.md, "AskUserQuestion").
  private let captured = try! JSONValue.parse(
    Data(
      #"{"questions":[{"question":"Which filename would you prefer?","header":"Filename","options":[{"label":"a.txt","description":"Name the file a.txt"},{"label":"b.txt","description":"Name the file b.txt"}],"multiSelect":false}]}"#
        .utf8))

  @Test func readsTheCapturedQuestion() throws {
    let questions = UserQuestion.list(captured)
    #expect(questions.count == 1)
    let first = try #require(questions.first)
    #expect(first.question == "Which filename would you prefer?")
    #expect(first.header == "Filename")
    #expect(first.options.map(\.label) == ["a.txt", "b.txt"])
    #expect(first.options.first?.description == "Name the file a.txt")
    #expect(!first.multiSelect)
  }

  @Test func theRequestSaysItWantsThePerson() throws {
    let line =
      #"{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[]},"tool_use_id":"t","requires_user_interaction":true}}"#
    guard case .controlRequest(let request) = try StreamMessage(line: Data(line.utf8)),
      case .canUseTool(let permission) = request.kind
    else {
      Issue.record("not a can_use_tool request")
      return
    }
    #expect(permission.requiresUserInteraction)
    #expect(permission.isChoice)
  }

  /// Picked labels in the options' order, then the typed answer, joined as the CLI's own
  /// picker joins them.
  @Test func anAnswerIsItsLabelsInOrderThenOther() throws {
    let question = UserQuestion(
      question: "Which?", header: nil,
      options: [.init(label: "A", description: nil), .init(label: "B", description: nil)],
      multiSelect: true)
    #expect(question.answer(picked: ["B", "A"], other: "") == "A, B")
    #expect(question.answer(picked: ["B"], other: "  my own  ") == "B, my own")
    #expect(question.answer(picked: [], other: " ") == nil)
  }

  @Test func theAnswersRideInTheInput() throws {
    let answered = UserQuestion.answering(
      captured, with: ["Which filename would you prefer?": "a.txt"])
    #expect(answered["answers"]?["Which filename would you prefer?"]?.stringValue == "a.txt")
    #expect(answered["questions"] == captured["questions"])
  }

  /// An option may carry a `preview` (a mockup, a snippet) the picker shows beside it; four
  /// of ten calls in real transcripts had one.
  @Test func readsAnOptionsPreview() throws {
    let input = try JSONValue.parse(
      Data(
        #"{"questions":[{"question":"Q","options":[{"label":"A","preview":"┌─┐"},{"label":"B","preview":"  "}]}]}"#
          .utf8))
    let options = try #require(UserQuestion.list(input).first).options
    #expect(options.map(\.preview) == ["┌─┐", nil])
  }

  /// An answer read back as the options it picked: the inverse of `answer(picked:other:)`.
  @Test func readsAnAnswerBackAsItsOptions() {
    let single = UserQuestion(
      question: "Q", header: nil,
      options: [.init(label: "A", description: nil), .init(label: "B", description: nil)],
      multiSelect: false)
    #expect(single.reading("B") == .init(picked: ["B"], other: nil))
    #expect(single.reading("B, A") == .init(picked: [], other: "B, A"))
    let multi = UserQuestion(
      question: "Q", header: nil,
      options: [.init(label: "A", description: nil), .init(label: "A b", description: nil)],
      multiSelect: true)
    #expect(multi.reading("A, A b") == .init(picked: ["A", "A b"], other: nil))
    #expect(multi.reading("A b, my own") == .init(picked: ["A b"], other: "my own"))
    #expect(multi.reading("nothing listed") == .init(picked: [], other: "nothing listed"))
  }

  /// The tool result names each answer; read back when the structured one is missing.
  @Test func readsTheAnswersFromTheResultText() {
    let text =
      #"Your questions have been answered: "Which, really?"="A, my own", "Then?"="B". You can now continue with these answers in mind."#
    #expect(
      UserQuestion.answers(inResult: text, questions: ["Which, really?", "Then?"])
        == ["Which, really?": "A, my own", "Then?": "B"])
    let newer =
      #"The user answered: "Q"="A". Read the answers carefully — they may request clarification, changes, or that you not proceed — and follow what they actually say."#
    #expect(UserQuestion.answers(inResult: newer, questions: ["Q"]) == ["Q": "A"])
    #expect(
      UserQuestion.answers(inResult: "The user did not answer the questions.", questions: ["Q"])
        == nil)
  }

  /// A question asked by a process that is gone is answered by a prompt, written as the
  /// extension writes it so either can read the other's.
  @Test func anEarlierQuestionIsAnsweredByAPrompt() {
    let one = UserQuestion.earlierAnswerPrompt([("Which file?", "a.txt")])
    #expect(one == #"Answering your earlier question "Which file?": a.txt"#)
    #expect(
      UserQuestion.earlierAnswers(in: one, questions: ["Which file?"]) == ["Which file?": "a.txt"])
    let two = UserQuestion.earlierAnswerPrompt([("Which?", "A, B"), ("Then?", "C")])
    #expect(two == "Answering your earlier questions:\n- \"Which?\": A, B\n- \"Then?\": C")
    #expect(
      UserQuestion.earlierAnswers(in: two, questions: ["Which?", "Then?"])
        == ["Which?": "A, B", "Then?": "C"])
    #expect(UserQuestion.earlierAnswers(in: "Use a.txt", questions: ["Which file?"]) == nil)
  }
}
