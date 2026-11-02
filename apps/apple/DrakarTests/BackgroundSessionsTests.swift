import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
struct BackgroundSessionsTests {
  private let owners = ProjectPath.Owners(["/w/drakar", "/w/parcelle"])

  private func held(
    _ id: String, window: String, session: String? = nil, running: Bool = true,
    attachedApp: Int32? = nil
  ) throws -> HeldProcess {
    var meta = SessionMeta(
      start: AgentStart(
        folder: URL(filePath: window), environment: [:], executableOverride: nil,
        allowsBypass: false),
      windowFolder: window, history: .none)
    meta.sessionID = session
    return HeldProcess(
      id: id, meta: try JSONEncoder().encode(meta), running: running, logLength: 0,
      attachedApp: attachedApp)
  }

  private func live(_ session: String, _ status: String) -> LiveSession {
    LiveSession(pid: 1, sessionID: session, status: status, cwd: "/w/parcelle")
  }

  @Test func aProcessNoAppHoldsCountsUnderItsWindowsProject() throws {
    let counts = BackgroundSessions.count(
      held: [
        try held("a", window: "/w/parcelle", session: "s1"),
        try held("b", window: "/w/drakar/apps/apple", session: "s2"),
      ],
      live: [live("s1", "idle")], owners: owners)
    #expect(counts == ["/w/parcelle": 1, "/w/drakar": 1])
  }

  /// A window shows it, here or in another app: it is not in the background.
  @Test func aProcessAnAppHoldsIsNotCounted() throws {
    let counts = BackgroundSessions.count(
      held: [try held("a", window: "/w/parcelle", attachedApp: 42)], live: [], owners: owners)
    #expect(counts.isEmpty)
  }

  @Test func anEndedProcessIsNotCounted() throws {
    let counts = BackgroundSessions.count(
      held: [try held("a", window: "/w/parcelle", running: false)], live: [], owners: owners)
    #expect(counts.isEmpty)
  }

  /// Running or waiting, the registry counts it already.
  @Test func aTurnAtWorkIsLeftToTheRegistry() throws {
    let counts = BackgroundSessions.count(
      held: [
        try held("a", window: "/w/parcelle", session: "busy"),
        try held("b", window: "/w/parcelle", session: "waiting"),
      ],
      live: [live("busy", "busy"), live("waiting", "waiting")], owners: owners)
    #expect(counts.isEmpty)
  }

  /// A process a Mac started on this Mac as its runner, and holds still, is that Mac's: it is
  /// no session of the local project at its path, which never takes it back (remote sessions
  /// spec §4, §5). Once the runner's own Drakar has it, it is one of this Mac's like any other.
  @Test func runnerProcessesAreNotCountedForALocalProjectAtTheSamePath() throws {
    var meta = SessionMeta(
      start: AgentStart(
        folder: URL(filePath: "/w/parcelle"), environment: [:], allowsBypass: false,
        runner: "R"),
      windowFolder: "/w/parcelle", history: .none, runner: "R", origin: "MacBook",
      owner: "MacBook")
    let owned = HeldProcess(
      id: "a", meta: try JSONEncoder().encode(meta), running: true, logLength: 0)
    #expect(BackgroundSessions.count(held: [owned], live: [], owners: owners).isEmpty)
    meta.owner = nil
    let handedOver = HeldProcess(
      id: "b", meta: try JSONEncoder().encode(meta), running: true, logLength: 0)
    #expect(
      BackgroundSessions.count(held: [owned, handedOver], live: [], owners: owners)
        == ["/w/parcelle": 1])
  }

  @Test func aProcessOutsideEveryProjectIsNotCounted() throws {
    let counts = BackgroundSessions.count(
      held: [try held("a", window: "/w/elsewhere")], live: [], owners: owners)
    #expect(counts.isEmpty)
  }
}
