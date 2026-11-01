import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A runner's host as the Mac reaches it, through `ssh` (spec §3): here a fake `ssh` of each
/// test's own, which runs this test host's binary as the relay on a host directory of the
/// test's own under `/tmp` (`sun_path` holds 104 bytes), its opt-in read from a defaults suite
/// of the test's own. Never the person's runner, host or settings: the relay always gets
/// `--directory` and `--defaults-suite`, and every helper is killed by its pid.
///
/// Serialized: `RunnerSettings.sshExecutable` and `SessionHost.runner` are one for the whole
/// app, and this is the only suite that changes either; keep it so, or put every suite that
/// does under one serialized parent.
@MainActor
@Suite("A runner's host, through ssh", .serialized, .timeLimit(.minutes(2)))
struct RunnerHostTests {
  /// Where the runner's environment file goes, beside the host's directory.
  private let root: URL
  private let directory: URL
  private let ssh: URL
  private let folder: URL
  private let fake: URL
  private let suite = "drakar-tests-\(UUID().uuidString)"
  private let settings = RunnerSettings(name: "Studio", destination: "studio.local")

  init() throws {
    root = URL(fileURLWithPath: "/tmp/dr-\(UUID().uuidString.prefix(6))", isDirectory: true)
    directory = root.appending(path: "host", directoryHint: .isDirectory)
    folder = root.appending(path: "project", directoryHint: .isDirectory)
    for directory in [directory, folder] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    ssh = root.appending(path: "ssh")
    fake = root.appending(path: "claude")
    // A stand-in `claude` that logs what it is sent and ends a turn on "quick".
    let claude = """
      #!/bin/sh
      while read -r line; do
        printf '%s\\n' "$line" >> "$0.stdin"
        case "$line" in *quick*) echo '\(Self.result)';; esac
      done

      """
    try Data(claude.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    // The GUI session's environment, as the runner's app writes it: the relay then reads no
    // login shell.
    try RunnerEnvironment.write(["PATH": "/usr/bin:/bin"], to: RunnerEnvironment.file(in: root))
    UserDefaults(suiteName: suite)?.set(true, forKey: RunnerRole.acceptsKey)
  }

  private static let result =
    #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","stop_reason":"end_turn","session_id":"s-runner"}"#

  private func finish(_ helpers: [pid_t] = []) {
    for pid in helpers where SessionHost.isRunning(pid) { kill(pid, SIGKILL) }
    RunnerSettings.sshExecutable = URL(filePath: "/usr/bin/ssh")
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }

  /// `ssh` as the test has it: a script of `body`.
  private func fakeSSH(_ body: String) throws {
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: ssh)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    RunnerSettings.sshExecutable = ssh
  }

  /// An `ssh` that runs the relay as the runner's sshd would: this test host's binary, in the
  /// environment sshd gives a command, not the test host's, whose XCTest variables would have
  /// it load the tests as well.
  /// Each run is a line in `runs`.
  private func relayingSSH() throws {
    let drakar = try #require(Bundle.main.executableURL).path(percentEncoded: false)
    try fakeSSH(
      """
      echo run >> '\(runs.path(percentEncoded: false))'
      exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$USER" \
        LOGNAME="$LOGNAME" TMPDIR="$TMPDIR" '\(drakar)' --relay \
        --directory '\(directory.path(percentEncoded: false))' --defaults-suite '\(suite)'
      """)
  }

  private var runs: URL { root.appending(path: "ssh.runs") }

  /// How many times the fake ssh ran.
  private func sshRuns() -> Int {
    ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count
  }

  /// An `ssh` whose relay states `facts`, then says nothing more.
  private func statingSSH(_ facts: RunnerFacts) throws {
    let line = String(decoding: try facts.line(), as: UTF8.self)
      .trimmingCharacters(in: .newlines)
    try fakeSSH("printf '%s\\n' '\(line)'\nexec sleep 30")
  }

  private func facts(relay: Int = RunnerFacts.relayVersion, majors: [Int] = [HostWire.major])
    -> RunnerFacts
  {
    RunnerFacts(
      relay: relay, drakar: "9.9", build: "999", hostMajors: majors, home: "/Users/runner",
      user: "runner", hostname: "studio", environment: [:], environmentFrom: .gui,
      claude: [], accounts: [])
  }

  /// A connection of the test's own to its host, as another app's.
  private func watcher() async throws -> HostClient {
    let client = try HostClient.connect(socket: try HostWire.socket(in: directory))
    _ = await answer(within: .seconds(5)) { try await client.hello(appVersion: "test") }
    return client
  }

  private func attached(_ id: String, on watcher: HostClient) async -> Int32? {
    await answer(within: .seconds(2)) { try await watcher.list() }?
      .first { $0.id == id }?.attachedApp
  }

  /// `body`'s result, or nil after `limit`.
  private func answer<T: Sendable>(
    within limit: Duration, _ body: @escaping @Sendable () async throws -> T
  ) async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask { try? await body() }
      group.addTask {
        try? await Task.sleep(for: limit)
        return nil
      }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }
  }

  private func eventually(
    within limit: Duration = .seconds(20), _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
  }

  /// The first thing an attach streams: a refusal, or what the log holds.
  private func firstEvent(of stream: AsyncStream<HostEvent>) async -> HostEvent? {
    await answer(within: .seconds(5)) {
      var events = stream.makeAsyncIterator()
      return await events.next()
    } ?? nil
  }

  private func isRefusal(_ event: HostEvent?) -> Bool {
    if case .refused? = event { return true }
    return false
  }

  @Test func settingsAreKeptInTheirDefaults() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { finish() }
    #expect(RunnerSettings.read(from: defaults) == nil)
    let studio = RunnerSettings(name: "Studio", destination: "me@studio")
    RunnerSettings.write(studio, to: defaults)
    #expect(RunnerSettings.read(from: defaults) == studio)
    #expect(RunnerSettings.read(from: defaults)?.drakarPath == "/Applications/Drakar.app")
    // Settings kept before runners had an id are given one, the same at every read.
    defaults.set(
      Data(#"{"name":"Studio","destination":"me@studio"}"#.utf8), forKey: RunnerSettings.key)
    let older = try #require(RunnerSettings.read(from: defaults))
    #expect(older.name == "Studio" && older.drakarPath == "/Applications/Drakar.app")
    #expect(RunnerSettings.read(from: defaults)?.id == older.id)
    // No destination, no runner.
    RunnerSettings.write(RunnerSettings(name: "Studio", destination: " "), to: defaults)
    #expect(RunnerSettings.read(from: defaults) == nil)
  }

  /// ssh hands the command to the runner's shell as one line: a path with a space is quoted
  /// for it, the default one is not.
  @Test func sshIsAskedForTheRelay() {
    #expect(
      RunnerConnection.arguments(settings) == [
        "-T", "-o", "BatchMode=yes", "studio.local",
        "/Applications/Drakar.app/Contents/MacOS/Drakar", "--relay",
      ])
    var spaced = settings
    spaced.drakarPath = "/Users/me/Apps/Drakar Beta.app"
    #expect(
      RunnerConnection.arguments(spaced)[4]
        == "'/Users/me/Apps/Drakar Beta.app/Contents/MacOS/Drakar'")
    // A leading `~/` is left for the runner's shell to expand.
    var home = settings
    home.drakarPath = "~/Applications/Drakar.app"
    #expect(
      RunnerConnection.arguments(home)[4] == "~/Applications/Drakar.app/Contents/MacOS/Drakar")
    home.drakarPath = "~/My Apps/Drakar.app"
    #expect(
      RunnerConnection.arguments(home)[4] == "~/'My Apps/Drakar.app/Contents/MacOS/Drakar'")
  }

  @Test func aRunnerHostConnectsThroughSSH() async throws {
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    #expect(host.isRunner)

    let client = await host.client()
    defer { client?.close() }
    #expect(client != nil)
    #expect(host.facts?.relay == 1)
    #expect(host.facts?.hostMajors.contains(HostWire.major) == true)
    #expect(host.failure == nil)
    #expect(host.hostPID == nil)
    #expect(host.started == nil)
    #expect(await host.heldIfRunning() == [])
    #expect(await host.heldByOlderHosts() == [])
  }

  @Test func sshFailuresCarryTheirStderr() async throws {
    defer { finish() }
    try fakeSSH("echo 'Permission denied (publickey).' >&2\nexit 255")
    let host = SessionHost(endpoint: .runner(settings))
    #expect(await host.client() == nil)
    #expect(host.failure?.stderr.contains("Permission denied") == true)
    #expect(host.failure?.message.isEmpty == false)
    #expect(host.facts == nil)
  }

  /// The Mac that is behind is named: the runner when it is older, this Mac when it is newer.
  @Test func aRelayOfAnotherVersionAsksForAnUpdate() async throws {
    defer { finish() }
    func failure(stating facts: RunnerFacts) async throws -> String? {
      try statingSSH(facts)
      let host = SessionHost(endpoint: .runner(settings))
      #expect(await host.client() == nil)
      return host.failure?.message
    }
    let relay = RunnerFacts.relayVersion
    #expect(try await failure(stating: facts(relay: relay + 1)) == "Update Drakar on this Mac")
    #expect(try await failure(stating: facts(relay: relay - 1)) == "Update Drakar on Studio")
    // A relay of ours, whose Drakar speaks none of our host majors.
    #expect(
      try await failure(stating: facts(majors: [HostWire.major + 1]))
        == "Update Drakar on this Mac")
    #expect(
      try await failure(stating: facts(majors: [HostWire.major - 1]))
        == "Update Drakar on Studio")
  }

  @Test func aSilentSSHGivesUp() async throws {
    defer { finish() }
    try fakeSSH("exec sleep 60")
    let host = SessionHost(endpoint: .runner(settings))
    let start = ContinuousClock.now
    #expect(await host.client() == nil)
    #expect(ContinuousClock.now - start < .seconds(11))
    #expect(host.failure != nil)
  }

  /// An `ssh` like `relayingSSH`'s that lingers once its relay has gone, as one on a network
  /// that has dropped does, until it is ended. Each run's pid and destination are a line of
  /// `sshPIDs` and `destinations`.
  private func lingeringSSH() throws {
    let drakar = try #require(Bundle.main.executableURL).path(percentEncoded: false)
    try fakeSSH(
      """
      echo $$ >> '\(sshPIDs.path(percentEncoded: false))'
      echo "$4" >> '\(destinations.path(percentEncoded: false))'
      echo run >> '\(runs.path(percentEncoded: false))'
      /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$USER" \
        LOGNAME="$LOGNAME" TMPDIR="$TMPDIR" '\(drakar)' --relay \
        --directory '\(directory.path(percentEncoded: false))' --defaults-suite '\(suite)'
      exec sleep 30
      """)
  }

  private var sshPIDs: URL { root.appending(path: "ssh.pids") }
  private var destinations: URL { root.appending(path: "ssh.destinations") }

  private func lines(of file: URL) -> [String] {
    ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }

  /// `SessionHost.runner` as Settings › Runner leaves it, put back as it was found.
  private func withRunner(_ body: () async throws -> Void) async rethrows {
    let before = SessionHost.runner
    defer {
      SessionHost.runner?.close()
      SessionHost.runner = before
    }
    try await body()
  }

  /// A rename is for show: the same host, its connection kept.
  @Test func aRenamedRunnerKeepsItsConnection() async throws {
    try lingeringSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    try await withRunner {
      SessionHost.useRunner(settings, keptIn: try #require(UserDefaults(suiteName: suite)))
      let host = try #require(SessionHost.runner)
      let client = try #require(await host.client())
      var renamed = settings
      renamed.name = "Studio upstairs"
      SessionHost.useRunner(renamed)
      #expect(SessionHost.runner === host)
      #expect(host.endpoint == .runner(renamed))
      #expect(!host.isClosed)
      try await Task.sleep(for: .milliseconds(300))
      #expect(!client.isClosed)
      #expect(await host.client() === client)
      #expect(sshRuns() == 1)
    }
  }

  /// Another destination is the same host on another target: the old connection and its ssh
  /// go, and the next connection is to the new destination.
  @Test func aRetargetedRunnerReachesItsNewDestination() async throws {
    try lingeringSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    try await withRunner {
      SessionHost.useRunner(settings, keptIn: try #require(UserDefaults(suiteName: suite)))
      let host = try #require(SessionHost.runner)
      let old = try #require(await host.client())
      let oldSSH = try #require(lines(of: sshPIDs).first.flatMap { pid_t($0) })
      var moved = settings
      moved.destination = "studio.tail.ts.net"
      SessionHost.useRunner(moved)
      #expect(SessionHost.runner === host)
      #expect(!host.isClosed)
      #expect(host.endpoint == .runner(moved))
      #expect(await eventually(within: .seconds(5)) { old.isClosed })
      #expect(await eventually(within: .seconds(5)) { kill(oldSSH, 0) != 0 })
      let new = try #require(await host.client())
      #expect(new !== old)
      #expect(lines(of: destinations) == ["studio.local", "studio.tail.ts.net"])
    }
  }

  /// No runner closes the host for good: its connection and its ssh, even one that would
  /// linger after its relay has gone, and it never connects again.
  @Test func aClearedRunnerEndsItsSSH() async throws {
    try lingeringSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    try await withRunner {
      SessionHost.useRunner(settings, keptIn: try #require(UserDefaults(suiteName: suite)))
      let host = try #require(SessionHost.runner)
      let client = try #require(await host.client())
      let ssh = try #require(lines(of: sshPIDs).first.flatMap { pid_t($0) })
      #expect(kill(ssh, 0) == 0)

      SessionHost.useRunner(nil)
      #expect(SessionHost.runner == nil)
      #expect(host.isClosed)
      #expect(await eventually(within: .seconds(5)) { client.isClosed })
      #expect(!host.isAvailable)
      #expect(await eventually(within: .seconds(5)) { kill(ssh, 0) != 0 })
      #expect(await host.client() == nil)
      #expect(sshRuns() == 1)
    }
  }

  /// A runner saved without a name, as one saved without a Test is, takes its hostname the
  /// first time it is reached, where it is kept too, and keeps its host.
  @Test func anUnnamedRunnerIsNamedAfterItsHostname() async throws {
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let defaults = try #require(UserDefaults(suiteName: suite))
    let unnamed = RunnerSettings(name: "", destination: "studio.local")
    RunnerSettings.write(unnamed, to: defaults)
    try await withRunner {
      SessionHost.useRunner(unnamed, keptIn: defaults)
      let host = try #require(SessionHost.runner)
      let client = try #require(await host.client())
      let hostname = try #require(host.facts?.hostname)
      #expect(!hostname.isEmpty)
      guard case .runner(let named) = host.endpoint else { throw CancellationError() }
      #expect(named.name == hostname)
      #expect(named.id == unnamed.id)
      #expect(RunnerSettings.read(from: defaults)?.name == hostname)
      #expect(SessionHost.runner === host)
      #expect(!client.isClosed)
    }
  }

  /// A stale relay (spec §3): the Mac's old connection still holds the process on the runner
  /// until the runner's sshd hangs it up. Its refusal of the new connection's attach is "still
  /// releasing" only for a process this Mac owns, and an attach after the old relay has gone
  /// is taken.
  @Test func aRefusedReattachIsRetriedWhileTheMacOwnsIt() async throws {
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let owned = Data("owner: this Mac".utf8)
    let stale = SessionHost(endpoint: .runner(settings))
    let fresh = SessionHost(endpoint: .runner(settings))
    let old = try #require(await stale.client())
    defer { old.close() }
    let cat = AgentProcess.Configuration(
      executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
      currentDirectory: folder)
    let id = try #require(
      await answer(within: .seconds(5)) { try await old.spawn(cat, meta: owned) })
    _ = old.attach(id, from: 0)
    let watcher = try await watcher()
    defer { watcher.close() }
    #expect(await eventually { await attached(id, on: watcher) != nil })

    let new = try #require(await fresh.client())
    defer { new.close() }
    #expect(isRefusal(await firstEvent(of: new.attach(id, from: 0))))
    fresh.ownsProcess = { _ in false }
    #expect(await fresh.reattachRefused(id) == false)
    fresh.ownsProcess = { $0.meta == owned }
    #expect(await fresh.reattachRefused(id) == true)
    // Owned, but a local host's refusal is never a relay's.
    let local = SessionHost(endpoint: .local)
    local.ownsProcess = { _ in true }
    #expect(await local.reattachRefused(id) == false)

    // The runner's sshd hangs the old relay up: the host sees it leave.
    old.close()
    #expect(
      await eventually {
        !isRefusal(await firstEvent(of: new.attach(id, from: 0)))
      })
    try? new.send(.terminate(id: id, forget: true))
  }

  /// The same, as a session lives it: its connection to the runner drops while the runner's
  /// end of it hangs on, and the session waits, reconnecting, until the stale relay has gone,
  /// then carries on with the same process.
  @Test func aSessionOnARunnerWaitsOutAStaleRelay() async throws {
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    host.ownsProcess = { _ in true }
    let session = try await startedSession(on: host)
    defer { session.stop() }
    let id = try #require(session.hostID)
    let watcher = try await watcher()
    defer { watcher.close() }
    let relay = try #require(await attached(id, on: watcher))

    // The network drops: the runner's relay hangs on, and the Mac's ssh goes.
    kill(relay, SIGSTOP)
    // Killed once, never again: once reaped, its pid may be another process's.
    var hungUp = false
    defer { if !hungUp { kill(relay, SIGKILL) } }
    await host.client()?.close()
    #expect(await eventually { session.isReconnecting })
    // Refused while the stale relay holds it: reconnecting still, not lost.
    try await Task.sleep(for: .seconds(2))
    #expect(session.isReconnecting)
    #expect(session.phase == .ready)
    #expect(await attached(id, on: watcher) == relay)

    // The runner's sshd hangs the stale relay up.
    kill(relay, SIGKILL)
    hungUp = true
    #expect(await eventually { !session.isReconnecting })
    #expect(session.phase == .ready)
    #expect(session.isHosted && session.hostID == id)
    #expect(await eventually { await attached(id, on: watcher).map { $0 != relay } ?? false })
    session.send("quick again")
    #expect(await eventually { sent("quick again") == 1 })
  }

  /// Stopped while it waits out a stale relay, a session asks the runner nothing more: no
  /// listing, so no ssh started for one once the connection has gone.
  @Test func aStoppedSessionStopsWaitingOnTheRunner() async throws {
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    host.ownsProcess = { _ in true }
    let session = try await startedSession(on: host)
    let id = try #require(session.hostID)
    let watcher = try await watcher()
    defer { watcher.close() }
    let relay = try #require(await attached(id, on: watcher))
    kill(relay, SIGSTOP)
    defer { kill(relay, SIGKILL) }
    await host.client()?.close()
    #expect(await eventually { session.isReconnecting })
    try await Task.sleep(for: .seconds(1))
    #expect(session.isReconnecting)

    session.stop()
    // What the stop itself asks of the host is done before its connection goes.
    try await Task.sleep(for: .milliseconds(500))
    await host.client()?.close()
    let before = sshRuns()
    // Longer than the loop's longest wait, twice over.
    try await Task.sleep(for: .seconds(4.5))
    #expect(sshRuns() == before)
  }

  /// A process this Mac does not own, refused as attached to another app, is lost as it
  /// always was: no waiting on it.
  @Test func aSessionOnARunnerItDoesNotOwnIsLost() async throws {
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    let session = try await startedSession(on: host)
    defer { session.stop() }
    let id = try #require(session.hostID)
    let watcher = try await watcher()
    defer { watcher.close() }
    let relay = try #require(await attached(id, on: watcher))

    kill(relay, SIGSTOP)
    defer { kill(relay, SIGKILL) }
    await host.client()?.close()
    #expect(
      await eventually {
        if case .failed = session.phase { return true }
        return false
      })
    #expect(!session.isReconnecting)
  }

  /// A session on `host`, its first turn over.
  private func startedSession(on host: SessionHost) async throws -> AgentSession {
    _ = await AgentSession.environment.value
    let session = AgentSession(folder: folder)
    session.executableOverride = fake
    session.accounts = { [] }
    session.sessionHost = host
    session.send("quick")
    #expect(await eventually { session.phase == .ready && !session.transcript.isRunning })
    try #require(session.isHosted)
    return session
  }

  /// The lines the stand-in was sent that hold `text`.
  private func sent(_ text: String) -> Int {
    let log =
      (try? String(contentsOf: fake.appendingPathExtension("stdin"), encoding: .utf8)) ?? ""
    return log.split(separator: "\n").count { $0.contains(text) }
  }
}
