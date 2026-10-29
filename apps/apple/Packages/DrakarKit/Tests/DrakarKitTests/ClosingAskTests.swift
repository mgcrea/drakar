import DrakarKit
import Foundation
import Testing

@Suite("What a turn ended on")
struct ClosingAskTests {
  private func question(_ text: String) -> ClosingAsk { ClosingAsk(kind: .question, text: text) }
  private func yesOrNo(_ text: String) -> ClosingAsk {
    ClosingAsk(kind: .question, text: text, isYesOrNo: true)
  }
  private func offer(_ text: String) -> ClosingAsk { ClosingAsk(kind: .offer, text: text) }

  @Test func aQuestionAtTheEndIsAsked() {
    #expect(
      ClosingAsk.detect("Built and tested.\n\nWant me to build it that way?")
        == yesOrNo("Want me to build it that way?"))
  }

  @Test func aDirectAskNeedsNoQuestionMark() {
    #expect(
      ClosingAsk.detect("The plan is ready. Should I go ahead with option B.")
        == yesOrNo("Should I go ahead with option B."))
  }

  /// Most real asks explain themselves after the question.
  @Test func aQuestionFollowedByItsExplanationIsAsked() {
    #expect(
      ClosingAsk.detect(
        "Should I commit this on a branch? It would be something like `fix/x`, since you're on main."
      ) == yesOrNo("Should I commit this on a branch?"))
  }

  @Test func askingThePersonToActIsAQuestion() {
    #expect(
      ClosingAsk.detect("Stop the recording.\n\nTell me when it's saved. I'll convert it.")
        == question("Tell me when it's saved."))
  }

  @Test func aStatementIsNothing() {
    #expect(ClosingAsk.detect("All 146 tests pass. Committed as 2add3ce.") == nil)
  }

  @Test func aSignOffIsAnOfferNeverAQuestion() {
    #expect(
      ClosingAsk.detect("Done. Let me know if you'd like any changes.")
        == offer("Let me know if you'd like any changes."))
    #expect(
      ClosingAsk.detect("Fixed. Let me know if that works for you?")
        == offer("Let me know if that works for you?"))
  }

  @Test func offersAreRecognised() {
    #expect(
      ClosingAsk.detect("Shipped.\n\nSay the word and I'll add the readout.")
        == offer("Say the word and I'll add the readout."))
    #expect(
      ClosingAsk.detect("Say if you want this landed.") == offer("Say if you want this landed."))
  }

  @Test func aQuestionOutranksAnOffer() {
    #expect(
      ClosingAsk.detect("Shall I push? If you want, I can also tag it.")
        == yesOrNo("Shall I push?"))
  }

  @Test func onlyTheLastTwoParagraphsCount() {
    #expect(ClosingAsk.detect("Should I keep it?\n\nI kept it.\n\nAll green.") == nil)
  }

  @Test func aListOfOptionsAfterTheQuestionAsks() {
    #expect(
      ClosingAsk.detect("Which do you prefer?\n1. Rules\n2. A model")
        == question("Which do you prefer?"))
    #expect(
      ClosingAsk.detect("Done.\n\nStill to do:\n- `.work/` is 12 GB. Shall I delete it?")
        == yesOrNo("Shall I delete it?"))
  }

  @Test func codeQuotesAndLinksAreNotSentences() {
    #expect(ClosingAsk.detect("Run `grep -E 'a?'` to check.") == nil)
    #expect(ClosingAsk.detect("Done.\n\n```\nwhat?\n```") == nil)
    #expect(ClosingAsk.detect("> Should we ship?\n\nShipped.") == nil)
    #expect(ClosingAsk.detect("It is at https://example.com/search?") == nil)
  }

  @Test func anUnclosedFenceIsCodeToTheEnd() {
    #expect(ClosingAsk.detect("Here:\n\n```swift\nlet a = b ?? c\nwhat?") == nil)
  }

  @Test func emphasisAndQuotesAreNotPartOfIt() {
    #expect(ClosingAsk.detect("**Want me to proceed?**") == yesOrNo("Want me to proceed?"))
    #expect(ClosingAsk.detect(#"Reply "OK to remove?" Then I delete it."#)?.kind == .question)
  }

  @Test func otherQuestionMarksCount() {
    #expect(ClosingAsk.detect("C'est prêt. Voulez-vous que je continue ?")?.kind == .question)
    #expect(ClosingAsk.detect("準備できました。続けますか？")?.kind == .question)
  }

  @Test func typographicApostrophesMatch() {
    #expect(
      ClosingAsk.detect("Done. Let me know if you\u{2019}d like changes.")?.kind == .offer)
  }

  @Test func aLongAskIsCutOnAWord() throws {
    let long = "Should I " + String(repeating: "rename every file ", count: 20) + "now?"
    let shown = try #require(ClosingAsk.detect(long)).text
    #expect(shown.count <= ClosingAsk.maxLength)
    #expect(shown.hasSuffix("…"))
    #expect(!shown.dropLast().hasSuffix(" "))
  }

  @Test func windowsLineEndingsAreLines() {
    #expect(ClosingAsk.detect("Done.\r\n\r\nWant me to push?") == yesOrNo("Want me to push?"))
  }

  @Test func aLongReplyIsReadQuickly() {
    let reply =
      String(repeating: "A line of prose about the change. ", count: 6_000)
      + "\n\n```\n" + String(repeating: "code();\n", count: 2_000) + "```\n\nWant me to push?"
    let start = ContinuousClock.now
    #expect(ClosingAsk.detect(reply) == yesOrNo("Want me to push?"))
    // About 0.08 s on a quiet Mac, 0.5 s on CI's runner and up to 0.8 s here under load. The
    // budget is for a scan gone quadratic over a reply this long, which takes far longer.
    #expect(ContinuousClock.now - start < .seconds(2))
  }

  @Test func aConfirmationTakesYesOrNo() {
    #expect(
      ClosingAsk.detect("Clefs stay fixed.\n\n**Does this section look right?**")?.isYesOrNo == true
    )
    #expect(ClosingAsk.detect("Want me to?")?.isYesOrNo == true)
    #expect(
      ClosingAsk.detect("It's a one-line change; do you want me to make it?")?.isYesOrNo == true)
    #expect(ClosingAsk.detect("Here is the plan. Sound good?")?.isYesOrNo == true)
  }

  /// A wrong "Yes" sends the session off on its own, so anything else needs words.
  @Test func aChoiceOrAnOpenQuestionNeedsWords() {
    #expect(ClosingAsk.detect("Should I deploy it as is, or remove it first?")?.isYesOrNo == false)
    #expect(
      ClosingAsk.detect("Does the plan look right, and which approach should we use?")?.isYesOrNo
        == false)
    #expect(ClosingAsk.detect("Which option?")?.isYesOrNo == false)
    #expect(ClosingAsk.detect("Could you take a look?")?.isYesOrNo == false)
    #expect(ClosingAsk.detect("Tell me when it's saved.")?.isYesOrNo == false)
  }

  @Test func twoQuestionsNeedWords() {
    #expect(ClosingAsk.detect("Should I push? Should I also tag it?")?.isYesOrNo == false)
  }

  @Test func anOfferIsNeverYesOrNo() {
    #expect(ClosingAsk.detect("Shipped. Say the word and I'll add it.")?.isYesOrNo == false)
  }

  /// No wrong "Yes" on real endings, and most of the right ones found. The failures print;
  /// the labels are never edited to pass.
  @Test func yesOrNoMeetsItsTargetsOnRealEndings() throws {
    var wrong: [String] = []
    var missed: [String] = []
    var labelled = 0
    for line in try Fixture.closingEndings.lines {
      let json = try JSONValue.parse(line)
      let text = try #require(json["text"]?.stringValue)
      let expected = json["yesOrNo"]?.boolValue == true
      let found = ClosingAsk.detect(text)?.isYesOrNo == true
      if expected { labelled += 1 }
      if found, !expected { wrong.append(text) }
      if expected, !found { missed.append(text) }
    }
    #expect(labelled >= 25, "the fixture is too thin to measure")
    #expect(wrong.isEmpty, "a wrong Yes: \(wrong)")
    #expect(missed.count * 5 < labelled, "missed: \(missed)")
  }

  /// The spec's targets on real endings. The failures print, which is how the rules get
  /// tuned; the labels are never edited to pass.
  @Test func meetsItsTargetsOnRealEndings() throws {
    var wrongQuestions: [String] = []
    var missedQuestions: [String] = []
    var missedOffers: [String] = []
    var questionMarks = 0
    var questions = 0
    var offers = 0
    for line in try Fixture.closingEndings.lines {
      let json = try JSONValue.parse(line)
      let text = try #require(json["text"]?.stringValue)
      let expected = json["kind"]?.stringValue
      let found = ClosingAsk.detect(text)?.kind.rawValue
      if expected == "question" { questions += 1 }
      if expected == "offer" { offers += 1 }
      if found == "question" { questionMarks += 1 }
      if found == "question", expected != "question" { wrongQuestions.append(text) }
      if expected == "question", found != "question" { missedQuestions.append(text) }
      if expected == "offer", found != "offer" { missedOffers.append(text) }
    }
    #expect(questions >= 40 && offers >= 6, "the fixture is too thin to measure")
    #expect(wrongQuestions.count * 20 <= questionMarks, "marked wrongly: \(wrongQuestions)")
    #expect(missedQuestions.count * 10 < questions, "missed: \(missedQuestions)")
    #expect(missedOffers.count * 3 <= offers, "offers missed: \(missedOffers)")
  }
}
