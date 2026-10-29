import Testing

@testable import Drakar

@MainActor
@Suite("What a prompt's menu offers")
struct RewindOfferTests {
  /// A prompt with no message uuid (Codex history) has nothing to fork or rewind to.
  @Test func noUUIDNoFork() {
    let offer = RewindOffer.of(messageID: nil, canFork: true, canRewindCode: true)
    #expect(!offer.fork)
    #expect(!offer.rewindCode)
    #expect(!offer.offersAnything)
  }

  @Test func forkWithoutCode() {
    let offer = RewindOffer.of(messageID: "u-a", canFork: true, canRewindCode: false)
    #expect(offer.fork)
    #expect(!offer.rewindCode)
    #expect(offer.offersAnything)
  }

  /// No driven process: neither "Rewind code to here" nor "Fork conversation and rewind code".
  @Test func codeNeedsTheProcess() {
    #expect(!RewindOffer.of(messageID: "u-a", canFork: true, canRewindCode: false).rewindCode)
    #expect(!RewindOffer.of(messageID: "u-a", canFork: false, canRewindCode: false).offersAnything)
  }

  @Test func bothWhenBoth() {
    let offer = RewindOffer.of(messageID: "u-a", canFork: true, canRewindCode: true)
    #expect(offer.fork)
    #expect(offer.rewindCode)
    #expect(offer.isEnabled)
  }

  /// While a turn runs the items stay in the menu, disabled: nothing is queued.
  @Test func aTurnDisablesWhatIsOffered() {
    let offer = RewindOffer.of(
      messageID: "u-a", canFork: true, canRewindCode: true, duringTurn: true)
    #expect(offer.fork)
    #expect(offer.rewindCode)
    #expect(!offer.isEnabled)
  }
}
