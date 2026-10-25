import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Sessions spawned through the bundled `DrakarHost`, started for real on a short directory of
/// each test's own under `/tmp`, against a stand-in `claude` that logs what it is sent and
/// ends a turn whose prompt says "quick". Every helper a test starts is killed by its pid,
/// which ends the stand-ins it holds. Serialized: `SessionHost.testDirectory` and
/// `AppLifecycle.isTerminating` are one for the whole app.
@MainActor
@Suite("Sessions run through the session host", .serialized)
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
        case "$line" in *quick*) echo '\(Self.result)';; esac
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
    #expect(RunningSessions.stoppedByQuitting([session]) == 0)

    AppLifecycle.isTerminating = true
    session.stop()
    try await Task.sleep(for: .milliseconds(500))
    let held = await host.held()
    #expect(held.count == 1)
    #expect(held.first?.running == true)
    #expect(held.first?.attachedApp == nil)
  }

  /// An idle session has nothing in flight: a quit ends its process, as it always did.
  @Test func quittingStopsAnIdleSession() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    session.send("quick")
    #expect(await eventually { session.phase == .ready && !session.transcript.isRunning })
    #expect(session.isHosted)
    #expect(!session.isAtWork)

    AppLifecycle.isTerminating = true
    session.stop()
    #expect(await eventually { await host.held().first?.running == false })
  }

  /// Closing a window is about the session, not the app: it ends the turn, host or not.
  @Test func closingTheWindowStillStops() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { cleanUp(host) }
    let session = session(on: host)
    session.send("hi")
    #expect(await eventually { session.phase == .ready })
    #expect(session.isAtWork)

    session.stop()
    #expect(await eventually { await host.held().first?.running == false })
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
    #expect(RunningSessions.stoppedByQuitting([session]) == 1)
    session.stop()
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
