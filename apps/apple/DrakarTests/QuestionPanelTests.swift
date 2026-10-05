import DrakarKit
import Foundation
import Testing

@testable import Drakar

@Suite("Answering a question in the panel")
struct QuestionPanelTests {
  private let which = UserQuestion(
    question: "Which?", header: "File",
    options: [.init(label: "a.txt", description: nil), .init(label: "b.txt", description: nil)],
    multiSelect: false)
  private let also = UserQuestion(
    question: "Also?", header: nil,
    options: [.init(label: "Tests", description: nil), .init(label: "Docs", description: nil)],
    multiSelect: true)

  /// Answer waits for every question; "Other" counts once something is typed in it.
  @Test func answersOnceEveryQuestionHasOne() {
    let questions = [which, also]
    #expect(
      QuestionPanel.answers(
        for: questions, picked: ["Which?": ["b.txt"]], otherPicked: [], other: [:]) == nil)
    #expect(
      QuestionPanel.answers(
        for: questions, picked: ["Which?": ["b.txt"]], otherPicked: ["Also?"],
        other: ["Also?": "  "]) == nil)
    #expect(
      QuestionPanel.answers(
        for: questions, picked: ["Which?": ["b.txt"], "Also?": ["Docs", "Tests"]],
        otherPicked: ["Also?"], other: ["Also?": "a changelog"])
        == ["Which?": "b.txt", "Also?": "Tests, Docs, a changelog"])
  }

  /// Text left in "Other" after picking an option instead is not sent.
  @Test func anUnpickedOtherIsNotSent() {
    #expect(
      QuestionPanel.answers(
        for: [which], picked: ["Which?": ["a.txt"]], otherPicked: [], other: ["Which?": "c.txt"])
        == ["Which?": "a.txt"])
  }
}
