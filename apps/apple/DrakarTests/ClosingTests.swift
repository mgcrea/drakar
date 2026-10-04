import AppKit
import Testing

@testable import Drakar

@MainActor
@Suite("Closing with sessions at work")
struct ClosingTests {

  @Test func saysHowManyAndWhatClosingDoes() {
    #expect(RunningSessions.note(count: 1) == "A session is still working. Closing stops it.")
    #expect(RunningSessions.note(count: 3) == "3 sessions are still working. Closing stops them.")
  }

  @Test func theAlertOffersCloseThenCancel() {
    let alert = RunningSessions.alert(count: 2)
    #expect(alert.buttons.map(\.title) == ["Close", "Cancel"])
    #expect(alert.informativeText == RunningSessions.note(count: 2))
  }
}
