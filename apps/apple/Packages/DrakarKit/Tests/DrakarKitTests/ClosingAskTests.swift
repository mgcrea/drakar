import DrakarKit
import Foundation
import Testing

@Suite("What a turn ended on")
struct ClosingAskTests {
  private func question(_ text: String) -> ClosingAsk { ClosingAsk(kind: .question, text: text) }
  private func offer(_ text: String) -> ClosingAsk { ClosingAsk(kind: .offer, text: text) }

  @Test func aQuestionAtTheEndIsAsked() {
    #expect(
      ClosingAsk.detect("Built and tested.\n\nWant me to build it that way?")
        == question("Want me to build it that way?"))
  }

  @Test func aDirectAskNeedsNoQuestionMark() {
    #expect(
      ClosingAsk.detect("The plan is ready. Should I go ahead with option B.")
        == question("Should I go ahead with option B."))
  }

  /// Most real asks explain themselves after the question.
  @Test func aQuestionFollowedByItsExplanationIsAsked() {
    #expect(
      ClosingAsk.detect(
        "Should I commit this on a branch? It would be something like `fix/x`, since you're on main."
      ) == question("Should I commit this on a branch?"))
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
        == question("Shall I push?"))
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
        == question("Shall I delete it?"))
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
    #expect(ClosingAsk.detect("**Want me to proceed?**") == question("Want me to proceed?"))
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
    #expect(ClosingAsk.detect("Done.\r\n\r\nWant me to push?") == question("Want me to push?"))
  }

  @Test func aLongReplyIsReadQuickly() {
    let reply =
      String(repeating: "A line of prose about the change. ", count: 6_000)
      + "\n\n```\n" + String(repeating: "code();\n", count: 2_000) + "```\n\nWant me to push?"
    let start = ContinuousClock.now
    #expect(ClosingAsk.detect(reply) == question("Want me to push?"))
    #expect(ContinuousClock.now - start < .milliseconds(500))
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
