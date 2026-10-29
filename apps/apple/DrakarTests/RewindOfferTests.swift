import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What a prompt's menu offers")
struct RewindOfferTests {
  /// A prompt with no message uuid (Codex history) has nothing to fork or rewind to.
  @Test func noUUIDNoFork() {
    let offer = RewindOffer.of(canFork: true, canRewindCode: true).at(nil)
    #expect(!offer.fork)
    #expect(!offer.rewindCode)
    #expect(!offer.offersAnything)
    // Whatever the session offers, during a turn too.
    #expect(
      RewindOffer.of(canFork: true, canRewindCode: true, duringTurn: true).at(nil) == .nothing)
  }

  @Test func forkWithoutCode() {
    let offer = RewindOffer.of(canFork: true, canRewindCode: false).at("u-a")
    #expect(offer.fork)
    #expect(!offer.rewindCode)
    #expect(offer.offersAnything)
  }

  /// No driven process: neither "Rewind code to here" nor "Fork conversation and rewind code".
  @Test func codeNeedsTheProcess() {
    #expect(!RewindOffer.of(canFork: true, canRewindCode: false).at("u-a").rewindCode)
    #expect(!RewindOffer.of(canFork: false, canRewindCode: false).at("u-a").offersAnything)
  }

  @Test func bothWhenBoth() {
    let offer = RewindOffer.of(canFork: true, canRewindCode: true).at("u-a")
    #expect(offer.fork)
    #expect(offer.rewindCode)
    #expect(offer.isEnabled)
  }

  /// While a turn runs the items stay in the menu, disabled: nothing is queued.
  @Test func aTurnDisablesWhatIsOffered() {
    let offer = RewindOffer.of(canFork: true, canRewindCode: true, duringTurn: true).at("u-a")
    #expect(offer.fork)
    #expect(offer.rewindCode)
    #expect(!offer.isEnabled)
  }

  /// Made afresh on each session view update, the action is equal for the same row: the
  /// prompts reading it don't redraw.
  @Test func theActionIsEqualPerRow() {
    let project = Project(folder: FileManager.default.temporaryDirectory)
    let a = project.newSession()
    let b = project.newSession()
    #expect(
      RewindMenuAction(item: a, project: project) == RewindMenuAction(item: a, project: project))
    #expect(
      RewindMenuAction(item: a, project: project) != RewindMenuAction(item: b, project: project))
  }
}
