import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Home's runner section, as far as it is worked out from what the runner's host lists
/// (remote sessions spec §4 "Closing, quitting, ending", §5 "What the Mac shows"). The
/// hosted half, through ssh, is in `RunnerHostTests`, the one suite that may set the runner up.
@MainActor
struct RunnerSectionTests {
  private static let mac = "Test MacBook"

  private func held(
    _ id: String, folder: String = "/Users/runner/w/drakar", name: String? = nil,
    owner: String?, running: Bool = true, attachedApp: Int32? = nil
  ) throws -> HeldProcess {
    var meta = SessionMeta(
      start: AgentStart(
        folder: URL(filePath: folder), environment: [:], allowsBypass: false, runner: "R"),
      windowFolder: folder, history: .none, runner: "R", origin: Self.mac, owner: owner)
    meta.name = name
    return HeldProcess(
      id: id, meta: try JSONEncoder().encode(meta), running: running, logLength: 0,
      attachedApp: attachedApp)
  }

  /// Held by this Mac's app, free and this Mac's to take, or the runner's own Drakar's
  /// (owner absent) or another Mac's: the three ways a row is shown.
  @Test func rowsSortThreeWays() throws {
    let rows = RunnerSection.rows(
      held: [
        try held("here", name: "Shown", owner: Self.mac, attachedApp: 7),
        try held("idle", folder: "/Users/runner/w/parcelle/", owner: Self.mac),
        try held("runner", owner: nil),
        try held("other", owner: "Other Mac", running: false),
      ],
      mac: Self.mac)
    #expect(
      rows == [
        RunnerRow(
          id: "here", folder: "/Users/runner/w/drakar", name: "Shown", running: true,
          state: .here),
        RunnerRow(
          id: "idle", folder: "/Users/runner/w/parcelle", name: nil, running: true, state: .idle),
        RunnerRow(
          id: "runner", folder: "/Users/runner/w/drakar", name: nil, running: true,
          state: .onTheRunner),
        RunnerRow(
          id: "other", folder: "/Users/runner/w/drakar", name: nil, running: false,
          state: .onTheRunner),
      ])
  }

  /// A process this app is ending is not shown while the end is under way: held by an app
  /// (the end on its way, or a stale relay it waits out) or ended already. One that runs on
  /// with nobody holding it is not being ended, whatever `SessionHost.ended` says, and shows.
  @Test func onlyWhatIsBeingEndedIsHidden() throws {
    let shown = RunnerSection.shown(
      [
        try held("attached", owner: Self.mac, attachedApp: 7),
        try held("exited", owner: Self.mac, running: false),
        try held("free", owner: Self.mac),
        try held("other", owner: Self.mac),
      ],
      ended: ["attached", "exited", "free"])
    #expect(shown.map(\.id) == ["free", "other"])
  }

  /// An end still waiting for the host to let go (`SessionHost.endsUnderWay`) is shown as
  /// ending, held by its stale relay or free, never as one to take back.
  @Test func anEndUnderWayShowsAsEnding() throws {
    let held = [
      try held("stale", owner: Self.mac, attachedApp: 7),
      try held("freed", owner: Self.mac),
    ]
    let underWay: Set<String> = ["stale", "freed"]
    let shown = RunnerSection.shown(held, ended: underWay, underWay: underWay)
    let rows = RunnerSection.rows(held: shown, mac: Self.mac, ending: underWay)
    #expect(rows.map(\.id) == ["stale", "freed"])
    #expect(rows.allSatisfy { $0.state == .ending })
  }

  /// New Session on Runner…'s recent folders: each folder a process of the runner's host was
  /// started for, once, as it was first listed.
  @Test func recentFoldersAreEachFolderOnce() throws {
    let folders = RunnerSection.recentFolders(
      of: [
        try held("a", folder: "/Users/runner/w/drakar", owner: Self.mac),
        try held("b", folder: "/Users/runner/w/parcelle", owner: nil),
        try held("c", folder: "/Users/runner/w/drakar/", owner: "Other Mac"),
      ])
    #expect(folders == ["/Users/runner/w/drakar", "/Users/runner/w/parcelle"])
  }

  /// A path typed for the runner is the runner's: `~` is its home when its facts are in,
  /// never this Mac's, and a relative path or a bare `~` with no home known is no path.
  @Test func aTypedPathIsTheRunners() {
    let home = "/Users/runner"
    #expect(
      NewRunnerSession.path(from: " /Users/runner/w/drakar/ ", home: home)
        == "/Users/runner/w/drakar")
    #expect(NewRunnerSession.path(from: "~/w/drakar", home: home) == "/Users/runner/w/drakar")
    #expect(NewRunnerSession.path(from: "~", home: home) == "/Users/runner")
    #expect(NewRunnerSession.path(from: "~/w/drakar", home: nil) == nil)
    #expect(NewRunnerSession.path(from: "w/drakar", home: home) == nil)
    #expect(NewRunnerSession.path(from: "  ", home: home) == nil)
  }
}
