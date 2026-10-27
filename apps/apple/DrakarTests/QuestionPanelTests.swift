import DrakarKit
import Foundation
import SwiftUI
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

  /// A digit picks its row, ⌘ with it answers too; typed into "Other", it is the field's.
  @Test func digitsPickAndCommandAnswers() {
    #expect(QuestionPanel.digitPick("3", modifiers: [], typing: false)! == (2, false))
    #expect(QuestionPanel.digitPick("3", modifiers: .command, typing: false)! == (2, true))
    #expect(QuestionPanel.digitPick("1", modifiers: .numericPad, typing: false)! == (0, false))
    #expect(QuestionPanel.digitPick("3", modifiers: [], typing: true) == nil)
    #expect(QuestionPanel.digitPick("3", modifiers: .command, typing: true) == nil)
    #expect(QuestionPanel.digitPick("3", modifiers: .option, typing: false) == nil)
    #expect(QuestionPanel.digitPick("0", modifiers: [], typing: false) == nil)
  }

  /// On AZERTY the digit row types digits with ⇧ held: ⇧& is "1", and it picks as 1 does.
  @Test func aDigitTypedWithShiftPicks() {
    #expect(QuestionPanel.digitPick("1", modifiers: .shift, typing: false)! == (0, false))
    #expect(
      QuestionPanel.digitPick("1", modifiers: [.command, .shift], typing: false)! == (0, true))
    #expect(QuestionPanel.digitPick("1", modifiers: [.option, .shift], typing: false) == nil)
  }

  /// ⌘'s pick answers only once it leaves every question with one: the last one picked,
  /// in whatever order, and never "Other", which waits for its text.
  @Test func aPickCompletesTheAnswersOnlyWhenEveryQuestionHasOne() {
    let questions = [which, also]
    var picked: [String: Set<String>] = [:]
    var otherPicked: Set<String> = []
    func answers() -> [String: String]? {
      QuestionPanel.answers(for: questions, picked: picked, otherPicked: otherPicked, other: [:])
    }
    QuestionPanel.pick(1, in: also, picked: &picked, otherPicked: &otherPicked)
    #expect(answers() == nil)
    QuestionPanel.pick(2, in: which, picked: &picked, otherPicked: &otherPicked)
    #expect(otherPicked == ["Which?"])
    #expect(answers() == nil)
    QuestionPanel.pick(0, in: which, picked: &picked, otherPicked: &otherPicked)
    #expect(otherPicked.isEmpty)
    #expect(answers() == ["Which?": "a.txt", "Also?": "Docs"])
    // A multiple choice's tick taken off again leaves it unanswered.
    QuestionPanel.pick(1, in: also, picked: &picked, otherPicked: &otherPicked)
    #expect(answers() == nil)
  }

  /// A request withdrawn and asked again keeps its call, and the card holds on to an equal
  /// value's closures: one that answered the first request would do nothing at all.
  @MainActor @Test func aRequestAskedAgainIsANewQuestion() {
    func asked(_ requestID: String?) -> AskedQuestion {
      AskedQuestion(
        callID: "toolu_1", requestID: requestID, focusRequest: 0, answer: { _ in }, skip: {})
    }
    #expect(asked("r1") == asked("r1"))
    #expect(asked("r1") != asked("r2"))
    // The same call asked live, and then as the question its process ended on.
    #expect(asked("r1") != asked(nil))
  }
}
