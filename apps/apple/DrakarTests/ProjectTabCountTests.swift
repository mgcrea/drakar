import Testing

@testable import Drakar

/// The badge on a project's window tab: every session counted, those that want the person
/// counted apart, and only those.
@Suite("Project tab badge")
struct ProjectTabCountTests {
  @Test func countsSessionsAndThoseWantingThePerson() {
    let count = ProjectTabCount([.needsYou, .working, .unread, .none, .needsYou])
    #expect(count == ProjectTabCount(sessions: 5, waiting: 2))
  }

  @Test func helpNamesTheWaitingOnlyWhenThereAreAny() {
    #expect(ProjectTabCount(sessions: 3, waiting: 0).help == "3 sessions")
    #expect(ProjectTabCount(sessions: 3, waiting: 1).help == "3 sessions, 1 needs you")
    #expect(ProjectTabCount(sessions: 3, waiting: 2).help == "3 sessions, 2 need you")
  }
}
