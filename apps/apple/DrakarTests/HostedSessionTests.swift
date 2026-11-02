import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Sessions spawned through the bundled `DrakarHost`, started for real on a short directory of
/// each test's own under `/tmp`, against a stand-in `claude` that logs what it is sent, ends
/// a turn whose prompt says "quick" and exits on "bye". Every helper a test starts is killed
/// by its pid, which ends the stand-ins it holds. Serialized: `SessionHost.testDirectory` and
/// `AppLifecycle.isTerminating` are one for the whole app.
@MainActor
@Suite("Sessions run through the session host", .serialized, .timeLimit(.minutes(1)))
struct HostedSessionTests {
  private let directory: URL
  private let folder: URL
  private let fake: URL

  private static let result =
    #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","stop_reason":"end_turn","session_id":"s-hosted"}"#

  init() throws {
    let name = String(UUID().uuidString.prefix(6))
    directory = URL(fileURLWithPath: "/tmp/dh-\(name)", isDirectory: true)
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-hosted-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fake = folder.appending(path: "claude")
    let script = """
      #!/bin/sh
      while read -r line; do
        printf '%s\\n' "$line" >> "$0.stdin"
        case "$line" in *quick*) echo '\(Self.result)';; *bye*) exit 0;; esac
      done

      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  private func cleanUp(_ host: SessionHost) {
    if let pid = host.started, SessionHost.isRunning(pid) { kill(pid, SIGKILL) }
    SessionHost.testDirectory = nil
    AppLifecycle.isTerminating = false
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: folder)
  }

  private func session(on host: SessionHost) -> AgentSession {
    let session = AgentSession(folder: folder)
    session.executableOverride = fake
    session.accounts = { [] }
    session.sessionHost = host
    return session
  }

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
  }

  /// A meta a host kept from before runners (remote sessions spec §4) has no runner, origin
  /// or owner, and still rebuilds its session; one that has them keeps them.
  @Test func anOlderMetaStillDecodes() throws {
    var meta = SessionMeta(
      start: AgentStart(folder: folder, environment: [:], allowsBypass: false),
      windowFolder: folder.path(percentEncoded: false), history: .none)
    var older = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])
    for key in ["runner", "origin", "owner"] { older[key] = nil }
    let decoded = try JSONDecoder().decode(
      SessionMeta.self, from: JSONSerialization.data(withJSONObject: older))
    #expect(decoded == meta)
    #expect(decoded.runner == nil && decoded.origin == nil && decoded.owner == nil)

    meta.runner = UUID().uuidString
    meta.origin = "Olivier's MacBook"
    meta.owner = "Olivier's MacBook"
    #expect(try JSONDecoder().decode(SessionMeta.self, from: JSONEncoder().encode(meta)) == meta)
  }

  /// The process lives in the host, and its meta names the window it belongs to, not only
  /// the folder it runs in.
  @Test func aSessionRunsThroughTheHost() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let project = Project(folder: folder)
    project.executableOverride = fake
    defer { project.stopAll() }
    let subfolder = folder.appending(path: "sub", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
    let session = project.newSession(agent: .claude, folder: subfolder).session
    session.accounts = { [] }
    session.sessionHost = host

    session.send("hi")
    #expect(await eventually { session.phase == .ready })
    #expect(session.isHosted)
    #expect(await eventually { await host.held().count == 1 })
    let held = try #require(await host.held().first)
    let meta = try JSONDecoder().decode(SessionMeta.self, from: held.meta)
    #expect(meta.windowFolder == folder.path(percentEncoded: false))
    #expect(meta.start.folder == subfolder)
    #expect(meta.history == HistoryMark.none)
  }

  /// Mid-turn at a quit, the session is let go, not ended: its process carries on in the
  /// host. The quit question does not count it.
  @Test func quittingHandsOverASessionAtWork() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    session.send("hi")
    #expect(await eventually { session.phase == .ready })
    #expect(session.isAtWork)
    #expect(RunningSessions.stoppedByLeaving([session]) == 0)

    AppLifecycle.isTerminating = true
    session.stop()
    try await Task.sleep(for: .milliseconds(500))
    let held = await host.held()
    #expect(held.count == 1)
    #expect(held.first?.running == true)
    #expect(held.first?.attachedApp == nil)
  }

  /// An idle session has nothing in flight: a quit ends its process, as it always did, and
  /// the host forgets it once it has ended, the app being gone by then. No later launch
  /// shows it again.
  @Test func quittingStopsAnIdleSession() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    session.send("quick")
    #expect(await eventually { session.phase == .ready && !session.transcript.isRunning })
    #expect(session.isHosted)
    #expect(!session.isAtWork)

    #expect(await eventually { await host.held().count == 1 })
    AppLifecycle.isTerminating = true
    session.stop()
    #expect(await eventually { await host.held().isEmpty })
  }

  /// Mid-turn when its window closes, the session is let go as at a quit: its process carries
  /// on in the host, for the project's next window.
  @Test func closingTheWindowHandsOverASessionAtWork() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    session.send("hi")
    #expect(await eventually { session.phase == .ready })
    #expect(session.isAtWork)

    session.stop(handingOver: true)
    try await Task.sleep(for: .milliseconds(500))
    let held = await host.held()
    #expect(held.count == 1)
    #expect(held.first?.running == true)
    #expect(held.first?.attachedApp == nil)
  }

  /// An idle session has nothing in flight: closing its window ends it, and the host
  /// forgets it.
  @Test func closingTheWindowStopsAnIdleSession() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    session.send("quick")
    #expect(await eventually { session.phase == .ready && !session.transcript.isRunning })
    #expect(await eventually { await host.held().count == 1 })

    session.stop(handingOver: true)
    #expect(await eventually { await host.held().isEmpty })
  }

  /// End Session and a removed row are about the session, not its window: they end the
  /// turn, host or not, and the host forgets the process once it has ended.
  @Test func endingTheSessionStillStops() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    session.send("hi")
    #expect(await eventually { session.phase == .ready })
    #expect(session.isAtWork)
    #expect(await eventually { await host.held().count == 1 })

    session.stop()
    #expect(await eventually { await host.held().isEmpty })
  }

  /// A CLI that exits on its own while the app runs leaves the host nothing to keep.
  @Test func anEndedSessionIsForgotten() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    session.send("hi")
    #expect(await eventually { await host.held().count == 1 })
    #expect(session.isHosted)

    session.send("bye")
    #expect(await eventually { session.phase == .exited(status: 0) })
    #expect(await eventually { await host.held().isEmpty })
  }

  /// No host to be had: the session is the app's own child, as before the host, and the quit
  /// question counts it.
  @Test func withoutAHostSessionsRunAsBefore() async throws {
    SessionHost.testDirectory = nil
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    session.send("hi")
    #expect(await eventually { session.phase == .ready })
    #expect(session.process is AgentProcess)
    #expect(!session.isHosted)
    #expect(RunningSessions.stoppedByLeaving([session]) == 1)
    session.stop()
  }

  /// A runner project whose runner this Mac cannot reach runs nothing here: its session is
  /// left with this Mac's host, which is not its runner's, and fails saying so, where a
  /// session of this Mac's would have run its own `claude`.
  @Test func aRunnerProjectItCannotReachRunsNothingHere() async throws {
    let project = Project(folder: folder, runner: UUID().uuidString)
    project.runnerHost = { nil }
    project.executableOverride = fake
    defer { project.stopAll() }
    let session = project.newSession().session
    session.accounts = { [] }
    session.send("quick")
    #expect(
      await eventually {
        if case .failed = session.phase { return true }
        return false
      })
    #expect(
      session.phase
        == .failed(
          "Drakar can't reach this session's runner: it is no longer set up in Settings › Runner."
        ))
    #expect(!session.isProcessRunning)
    #expect(
      !FileManager.default.fileExists(
        atPath: fake.appendingPathExtension("stdin").path(percentEncoded: false)))
  }

  /// A process the host cannot start fails the session as a child's failed start does,
  /// with why, rather than showing it stopped.
  @Test func aStartTheHostRefusesFailsTheSession() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fake.path)
    session.send("hi")
    #expect(
      await eventually {
        if case .failed = session.phase { true } else { false }
      })
    #expect(!session.isProcessRunning)
    #expect(!session.transcript.isRunning)
  }
}
