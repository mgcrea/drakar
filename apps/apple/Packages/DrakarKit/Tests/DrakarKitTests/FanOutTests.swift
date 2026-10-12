import DrakarKit
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
}
