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

  /// Quitting asks in its own words.
  @Test func quittingAsksToQuit() {
    let alert = RunningSessions.alert(count: 2, action: .quit)
    #expect(alert.messageText == "Quit while sessions are working?")
    #expect(alert.buttons.map(\.title) == ["Quit", "Cancel"])
    #expect(alert.informativeText == "2 sessions are still working. Quitting stops them.")
    #expect(
      RunningSessions.note(count: 1, action: .quit)
        == "A session is still working. Quitting stops it.")
  }

  /// End Session on a runner's session says what ending it costs: nothing resumes it here.
  @Test func endingARunnerSessionSaysItCannotBeResumed() {
    let one = EndingOnRunner.alert(titles: ["Refactor"])
    #expect(one.messageText == "End “Refactor”?")
    #expect(one.informativeText == "This conversation can't be resumed from this Mac.")
    #expect(one.buttons.map(\.title) == ["End Session", "Cancel"])
    let two = EndingOnRunner.alert(titles: ["Refactor", "Tests"])
    #expect(two.messageText == "End 2 sessions?")
    #expect(two.informativeText == "These conversations can't be resumed from this Mac.")
    #expect(two.buttons.map(\.title) == ["End Sessions", "Cancel"])
  }
}
