import DrakarKit
import Foundation
import Testing

@Suite("A skill's batch of sessions")
struct FanOutTests {
  /// Unlimited: every one starts at once.
  @Test func unlimitedStartsAll() {
    var batch = FanOut(ids: [1, 2, 3], limit: nil)
    #expect(batch.start() == [1, 2, 3])
    #expect(batch.count(.running) == 3)
    #expect(!batch.isDone)
  }

  /// 0 or less is unlimited too.
  @Test func aLimitOfZeroIsUnlimited() {
    var batch = FanOut(ids: [1, 2], limit: 0)
    #expect(batch.limit == nil)
    #expect(batch.start() == [1, 2])
  }

  /// With a limit, that many start, then one per finished one, in order.
  @Test func aLimitStartsThatManyThenOneEach() {
    var batch = FanOut(ids: [1, 2, 3, 4], limit: 2)
    #expect(batch.start() == [1, 2])
    #expect(batch.finished(2) == [3])
    #expect(batch.finished(1) == [4])
    #expect(batch.finished(3) == [])
    #expect(batch.finished(4) == [])
    #expect(batch.isDone)
  }

  /// A turn end then a stop for the same session frees one slot, not two.
  @Test func finishingTwiceFreesOneSlot() {
    var batch = FanOut(ids: [1, 2, 3], limit: 1)
    _ = batch.start()
    #expect(batch.finished(1) == [2])
    #expect(batch.finished(1) == [])
    #expect(batch.state(of: 3) == .waiting)
  }

  /// One finished before it was sent (closed while waiting) frees nothing; an unknown id
  /// changes nothing.
  @Test func finishingAWaitingOneFreesNothing() {
    var batch = FanOut(ids: [1, 2, 3], limit: 1)
    _ = batch.start()
    #expect(batch.finished(3) == [])
    #expect(batch.state(of: 3) == .finished)
    #expect(batch.finished(99) == [])
    #expect(batch.finished(1) == [2])
  }

  /// A refused send waits again and frees its slot; a later start sends it, in order. A
  /// refusal for one not running changes nothing.
  @Test func aRefusedOneWaitsAgain() {
    var batch = FanOut(ids: [1, 2, 3], limit: 2)
    #expect(batch.start() == [1, 2])
    batch.refused(1)
    batch.refused(2)
    batch.refused(3)
    #expect(batch.count(.running) == 0)
    #expect(batch.count(.waiting) == 3)
    #expect(batch.summary == "3 waiting")
    #expect(batch.start() == [1, 2])
    #expect(batch.finished(1) == [3])
  }

  /// Refused ones are waiting, so Cancel takes them and the batch is done.
  @Test func cancelTakesTheRefused() {
    var batch = FanOut(ids: [1, 2], limit: nil)
    _ = batch.start()
    batch.refused(1)
    batch.refused(2)
    #expect(batch.cancel() == [1, 2])
    #expect(batch.isDone)
  }

  /// Cancel returns the waiting ones only; the running ones keep running.
  @Test func cancelReturnsTheWaiting() {
    var batch = FanOut(ids: [1, 2, 3], limit: 1)
    _ = batch.start()
    #expect(batch.cancel() == [2, 3])
    #expect(batch.state(of: 1) == .running)
    #expect(!batch.isDone)
    #expect(batch.finished(1) == [])
    #expect(batch.isDone)
  }

  /// The banner's counts, zero ones left out.
  @Test func summary() {
    var batch = FanOut(ids: [1, 2, 3, 4], limit: 2)
    _ = batch.start()
    _ = batch.finished(1)
    #expect(batch.summary == "2 running · 1 waiting · 1 done")
    _ = batch.cancel()
    #expect(batch.summary == "2 running · 1 done")
  }

  /// A batch rebuilt from the states it was stored with carries on from them: the running
  /// one's end sends the next waiting one, the finished one stays done, and an id the states
  /// do not name waits.
  @Test func restoredStatesCarryOn() throws {
    var batch = FanOut(ids: ["a", "b", "c"], limit: 1, states: ["a": .running, "b": .waiting])
    #expect(batch.state(of: "c") == .waiting)
    #expect(batch.finished("a") == ["b"])
    var done = FanOut(ids: [1, 2], limit: nil, states: [1: .finished, 2: .cancelled])
    #expect(done.isDone && done.summary == "1 done")
    #expect(done.finished(1) == [])
  }

  /// The states are stored, so each reads back as it was written.
  @Test func statesRoundTrip() throws {
    let states: [FanOut<Int>.State] = [.waiting, .running, .finished, .cancelled]
    let back = try JSONDecoder().decode(
      [FanOut<Int>.State].self, from: JSONEncoder().encode(states))
    #expect(back == states)
  }
}
