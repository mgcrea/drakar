import DrakarKit
import Testing

@testable import Drakar

@MainActor
@Suite("A session another app runs, as its footer says")
struct ElsewhereStatusTests {

  private func live(_ status: String?, waitingFor: String? = nil) -> LiveSession {
    LiveSession(pid: 1, sessionID: "s", status: status, waitingFor: waitingFor)
  }

  @Test func readsTheOtherProcesssRecord() {
    #expect(ElsewhereStatus(live("busy")) == .working)
    #expect(ElsewhereStatus(live("idle")) == .ready)
    #expect(
      ElsewhereStatus(live("waiting", waitingFor: "permission prompt"))
        == .waiting("permission prompt"))
    #expect(ElsewhereStatus(live("something new")) == .open)
    #expect(ElsewhereStatus(nil) == .open)
  }

  @Test func namesTheApp() {
    #expect(ElsewhereStatus.working.text(in: "VS Code") == "Working in VS Code")
    #expect(ElsewhereStatus.ready.text(in: "a terminal") == "Ready in a terminal")
    #expect(
      ElsewhereStatus.waiting("permission prompt").text(in: "VS Code") == "Waiting in VS Code")
    #expect(ElsewhereStatus.open.text(in: "another app") == "Open in another app")
  }
}
