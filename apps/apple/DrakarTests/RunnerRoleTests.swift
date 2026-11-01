import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// The runner's opt-in (spec §2), on a directory of each test's own under `/tmp` (`sun_path`
/// holds 104 bytes) with the host's beneath it, as the app's is beneath Application Support,
/// and its setting in a defaults suite of the test's own. Every helper a test starts is
/// killed by its pid.
///
/// Serialized, and given minutes: two of these outlast the host's 30-second idle exit.
@MainActor
@Suite("A runner's opt-in", .serialized, .timeLimit(.minutes(2)))
struct RunnerRoleTests {
  private let root: URL
  private let suite = "drakar-tests-\(UUID().uuidString)"
  private let defaults: UserDefaults

  init() throws {
    root = URL(fileURLWithPath: "/tmp/dr-\(UUID().uuidString.prefix(6))", isDirectory: true)
    defaults = try #require(UserDefaults(suiteName: suite))
  }

  /// A role over this test's directory, and the host it keeps up, made on the host's
  /// directory beneath it: `testDirectory` is read as the host is made, and put back at once
  /// so no other suite's host is made on it.
  private func role() -> (RunnerRole, SessionHost) {
    SessionHost.testDirectory = root.appending(path: "host", directoryHint: .isDirectory)
    let host = SessionHost()
    SessionHost.testDirectory = nil
    return (RunnerRole(defaults: defaults, directory: root, host: host), host)
  }

  private func finish(_ role: RunnerRole, _ host: SessionHost) {
    role.accepts = false
    role.apply()
    if let pid = host.started, SessionHost.isRunning(pid) { kill(pid, SIGKILL) }
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }

  private func eventually(within limit: Duration, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
  }

  @Test func offByDefault() {
    let (role, host) = role()
    defer { finish(role, host) }
    #expect(!role.accepts)
    role.accepts = true
    #expect(defaults.bool(forKey: RunnerRole.acceptsKey))
  }

  /// The login shell's, for the relay to hand the Mac (spec §1), the owner's alone: it holds
  /// whatever secrets the person's shell exports.
  @Test func acceptingWritesTheEnvironmentFile() async throws {
    let (role, host) = role()
    defer { finish(role, host) }
    role.accepts = true
    role.apply()
    let file = RunnerEnvironment.file(in: root)
    #expect(
      await eventually(within: .seconds(15)) {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
      })
    let attributes = try FileManager.default.attributesOfItem(
      atPath: file.path(percentEncoded: false))
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let environment = try #require(RunnerEnvironment.read(from: file))
    #expect(environment["PATH"]?.isEmpty == false)
  }

  @Test func notAcceptingWritesNothing() async throws {
    let (role, host) = role()
    defer { finish(role, host) }
    role.apply()
    try await Task.sleep(for: .seconds(1))
    #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    #expect(host.started == nil)
  }

  /// Past the host's idle exit: the app's connection is what keeps it.
  @Test func acceptingKeepsAHostUp() async throws {
    let (role, host) = role()
    defer { finish(role, host) }
    role.accepts = true
    role.apply()
    #expect(await eventually(within: .seconds(10)) { host.isAvailable })
    let pid = try #require(host.started)
    try await Task.sleep(for: .seconds(35))
    #expect(SessionHost.isRunning(pid))
  }

  /// Turned off, nothing but the opt-in holding the connection: it closes, and the host
  /// leaves as it does once the app has gone.
  @Test func notAcceptingLetsTheHostLeave() async throws {
    let (role, host) = role()
    defer { finish(role, host) }
    role.accepts = true
    role.apply()
    #expect(await eventually(within: .seconds(10)) { host.isAvailable })
    let pid = try #require(host.started)
    role.accepts = false
    role.apply()
    #expect(!host.isAvailable)
    #expect(await eventually(within: .seconds(40)) { !SessionHost.isRunning(pid) })
  }

  /// A connection a session took is the session's: turning the opt-in off leaves it open.
  @Test func notAcceptingLeavesASessionsConnection() async throws {
    let (role, host) = role()
    defer { finish(role, host) }
    role.accepts = true
    role.apply()
    #expect(await eventually(within: .seconds(10)) { host.isAvailable })
    let client = try #require(await host.client())
    role.accepts = false
    role.apply()
    #expect(host.isAvailable)
    #expect(!client.isClosed)
  }

  /// A window waiting on the connection for a `released` keeps it too.
  @Test func notAcceptingLeavesAWatchedConnection() async throws {
    let (role, host) = role()
    defer { finish(role, host) }
    let owner = NSObject()
    host.watchReleases(for: owner, takes: { _ in false }, connected: {})
    role.accepts = true
    role.apply()
    #expect(await eventually(within: .seconds(10)) { host.isAvailable })
    role.accepts = false
    role.apply()
    #expect(host.isAvailable)
    withExtendedLifetime(owner) {}
  }

  /// A host that never answers (here: a helper that exits at once): off stops the tries,
  /// and no other helper is started however many cooldowns go by. Only the attempt under
  /// way when it went off, bounded by `SessionHost`'s patience, may finish.
  @Test func notAcceptingStopsTryingAHostThatDoesNotAnswer() async throws {
    SessionHost.testDirectory = root.appending(path: "host", directoryHint: .isDirectory)
    let host = SessionHost(cooldown: .milliseconds(100), helper: URL(filePath: "/usr/bin/true"))
    SessionHost.testDirectory = nil
    let role = RunnerRole(defaults: defaults, directory: root, host: host)
    defer { finish(role, host) }
    role.accepts = true
    role.apply()
    #expect(await eventually(within: .seconds(5)) { host.started != nil })
    role.accepts = false
    role.apply()
    let last = host.started
    try await Task.sleep(for: .seconds(8))
    #expect(host.started == last)
    #expect(!host.isAvailable)
  }

  /// The connection drops (here: its host killed); the opt-in connects again, which starts
  /// another.
  @Test func aDroppedConnectionIsMadeAgain() async throws {
    let (role, host) = role()
    defer { finish(role, host) }
    role.accepts = true
    role.apply()
    #expect(await eventually(within: .seconds(10)) { host.isAvailable })
    let first = try #require(host.started)
    kill(first, SIGKILL)
    #expect(
      await eventually(within: .seconds(15)) {
        host.started != first && host.started.map(SessionHost.isRunning) == true
          && host.isAvailable
      })
  }
}
