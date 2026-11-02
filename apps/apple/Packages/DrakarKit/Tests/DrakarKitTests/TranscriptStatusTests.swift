import DrakarKit
import Foundation
import Testing

/// The status is what other windows read about a session, so it must say what the transcript
/// says about the things they show.
@Suite("A transcript's status")
struct TranscriptStatusTests {
  private func history(_ lines: [String]) -> Transcript {
    Transcript.history(lines: lines.map { Data($0.utf8) })
  }

  @Test func anEmptyTranscriptHasTheEmptyStatus() {
    #expect(Transcript().status == Transcript.Status())
  }

  @Test func itNamesTheFirstPromptByItsOpening() {
    let long = String(repeating: "word ", count: 40)
    let status = history([
      #"{"type":"user","message":{"role":"user","content":""# + long + #""}}"#,
      #"{"type":"user","message":{"role":"user","content":"second"}}"#,
    ]).status
    #expect(status.hasEntries)
    #expect(status.firstPrompt == String(long.prefix(80)))
  }

  /// A history cut to its tail can start mid-reply: the first prompt is wherever it lands,
  /// and there may be none.
  @Test func theFirstPromptNeedNotBeTheFirstEntry() {
    let reply =
      #"{"type":"assistant","message":{"id":"m0","stop_reason":null,"content":[{"type":"text","text":"…and done."}]}}"#
    #expect(history([reply]).status.firstPrompt == nil)
    let status = history([
      reply, #"{"type":"user","message":{"role":"user","content":"Next one"}}"#,
      #"{"type":"user","message":{"role":"user","content":"And another"}}"#,
    ]).status
    #expect(status.firstPrompt == "Next one")
  }

  @Test func itCarriesTheClosingTextATurnEndedOn() {
    let transcript = history([
      #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
      #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Want me to commit it?"}]}}"#,
      #"{"type":"system","subtype":"turn_duration"}"#,
    ])
    #expect(transcript.status.closingText == transcript.closingText)
    #expect(transcript.status.closingText?.text == "Want me to commit it?")
    #expect(!transcript.status.isRunning)
  }
}
