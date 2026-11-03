import Testing

@testable import Drakar

/// The sessions the deck keeps built: the most recently shown first, the oldest let go past
/// the capacity.
@Suite("Recently shown")
struct RecentlyShownTests {
  @Test func showingPastCapacityEvictsTheOldest() {
    var recent = RecentlyShown<Int>(capacity: 3)
    #expect(recent.show(1) == [])
    #expect(recent.show(2) == [])
    #expect(recent.show(3) == [])
    #expect(recent.show(4) == [1])
    #expect(recent.ids == [4, 3, 2])
  }

  @Test func showingAgainMovesToFront() {
    var recent = RecentlyShown<Int>(capacity: 3)
    for id in [1, 2, 3] { recent.show(id) }
    #expect(recent.show(1) == [])
    #expect(recent.ids == [1, 3, 2])
  }

  @Test func removeForgets() {
    var recent = RecentlyShown<Int>(capacity: 3)
    for id in [1, 2, 3] { recent.show(id) }
    recent.remove(2)
    #expect(!recent.ids.contains(2))
    #expect(recent.ids == [3, 1])
    // Room for one more before anything goes, then the oldest left goes first.
    #expect(recent.show(4) == [])
    #expect(recent.show(5) == [1])
    #expect(recent.ids == [5, 4, 3])
    // Forgetting what was never shown changes nothing.
    recent.remove(9)
    #expect(recent.ids == [5, 4, 3])
  }
}
