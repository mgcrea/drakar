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
}
