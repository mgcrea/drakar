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
/// does under one serialized parent. `AppLifecycle.isTerminating`, `HostedSessionTests`'
/// own, is set here only around a stop and put back before anything is awaited.
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

  /// The runner's `claude`, for `aRunnerSessionRunsThroughTheRelay`: it answers `--version`,
  /// writes down the environment it was started with, answers `initialize` with a command and
  /// a model list, and runs a turn on "quick" that starts the session, reports a rate limit
  /// and says something.
  private static let runnerClaude = #"""
    #!/bin/sh
    case "$1" in --version) echo '2.1.0 (Claude Code)'; exit 0;; esac
    env > "$0.env"
    while read -r line; do
      printf '%s\n' "$line" >> "$0.stdin"
      case "$line" in
        *'"subtype":"initialize"'*)
          id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
          printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"'"$id"'","response":{"commands":[{"name":"runner-only","description":"","argumentHint":""}],"models":[{"value":"default","displayName":"Default"}]}}}'
          ;;
        *quick*)
          printf '%s\n' '{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s-runner","model":"m","permissionMode":"default"}'
          printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":4070908800}}}}'
          printf '%s\n' '{"type":"assistant","message":{"id":"m-1","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"From the runner."}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-runner"}'
          printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done.","stop_reason":"end_turn","session_id":"s-runner"}'
          ;;
      esac
    done

    """#

  /// A session of a runner's project (remote sessions spec §4): its `claude` is the one the
  /// relay found on the PATH of the runner's environment file, started by the runner's host
  /// with that environment and nothing of this Mac's. It reads no history and follows no
  /// transcript here, though an account of this Mac's holds one of the same id, and what its
  /// process says of the account stays with it.
  /// `runnerClaude` where the relay finds it first: in the first directory of the PATH the
  /// runner's environment file gives, ahead of any `claude` the person has.
  private func installRunnerClaude() throws -> URL {
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let claude = bin.appending(path: "claude")
    try Data(Self.runnerClaude.utf8).write(to: claude)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    try RunnerEnvironment.write(
      ["PATH": "\(bin.path(percentEncoded: false)):/usr/bin:/bin", "DRAKAR_RUNNER_MARK": "1"],
      to: RunnerEnvironment.file(in: root))
    return claude
  }

  @Test func aRunnerSessionRunsThroughTheRelay() async throws {
    let claude = try installRunnerClaude()
    let macAccount = root.appending(path: "mac-account", directoryHint: .isDirectory)
    let projects = macAccount.appending(path: "projects/p", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: projects.appending(path: "s-runner.jsonl"))
    let mine = ClaudeAccount(directory: macAccount, isDefault: false)
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }

    let host = SessionHost(endpoint: .runner(settings))
    let store = AccountStore(discover: { (accounts: [mine], shell: mine) })
    let catalog = ModelCatalog()
    // Picked from this Mac's accounts, as a window hands its own to a session made for it.
    let session = AgentSession(folder: folder, account: mine)
    session.accounts = { [mine] }
    session.accountStore = store
    session.catalog = catalog
    // This Mac's stand-in, which a runner's session never runs.
    session.executableOverride = fake
    session.sessionHost = host
    session.runner = settings.id.uuidString
    session.send("quick")
    #expect(
      await eventually {
        session.phase == .ready && !session.transcript.isRunning
          && session.transcript.entries.contains { $0.kind == .text("From the runner.") }
      })
    defer { session.stop() }
    #expect(session.isHosted)
    #expect(session.executable == claude)
    #expect(sent("quick") == 0)
    let environment = try String(
      contentsOf: claude.appendingPathExtension("env"), encoding: .utf8
    ).split(separator: "\n").map(String.init)
    #expect(environment.contains("DRAKAR_RUNNER_MARK=1"))
    let macTMPDIR = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
    #expect(!environment.contains { $0.hasSuffix("=\(macTMPDIR)") })
    // Not this Mac's account: the runner shell's own, which names none.
    #expect(!environment.contains { $0.hasPrefix("CLAUDE_CONFIG_DIR=") })

    // Its meta says where it runs and whose it is, here and as the runner's host keeps it.
    let meta = try #require(session.meta())
    #expect(meta.runner == settings.id.uuidString)
    #expect(meta.origin == ThisMac.name && meta.owner == ThisMac.name)
    #expect(meta.history == HistoryMark.none)
    #expect(meta.start.runner == settings.id.uuidString)
    #expect(meta.start.account?.isDefault == true)
    #expect(meta.start.account != mine)
    let id = try #require(session.hostID)
    let watcher = try await watcher()
    defer { watcher.close() }
    let held = try #require(
      await answer(within: .seconds(5)) { try await watcher.list() }?.first { $0.id == id })
    let kept = try JSONDecoder().decode(SessionMeta.self, from: held.meta)
    #expect(kept.origin == ThisMac.name && kept.owner == ThisMac.name)
    #expect(kept.runner == settings.id.uuidString)

    // The account's limits and models are the session's, and its commands come from its own
    // process.
    let account = try #require(session.account)
    #expect(session.usage?.fiveHour?.percent == 50)
    #expect(store.usage(for: account) == nil)
    #expect(store.usage(for: mine) == nil)
    #expect(session.models?.map(\.value) == ["default"])
    #expect(catalog.models(for: account) == nil)
    #expect(session.reportedCommands?.map(\.name) == ["runner-only"])

    // No transcript of this Mac's is looked for, nor followed once the process has gone.
    #expect(session.hasLoadedHistory)
    #expect(session.savedTarget == nil)
    session.stop()
    #expect(session.follower == nil)
  }

  /// A runner's session never runs on this Mac: a runner that cannot be reached, or a host
  /// that is not this session's runner's, fails it by name, and this Mac's own `claude` is
  /// never started in its place.
  @Test func anUnreachableRunnerFailsItsSession() async throws {
    defer { finish() }
    try fakeSSH(
      """
      echo run >> '\(runs.path(percentEncoded: false))'
      echo 'ssh: connect to host studio.local port 22: Connection refused' >&2
      exit 255
      """)
    func failure(on host: SessionHost) async throws -> String {
      let session = AgentSession(folder: folder)
      session.accounts = { [] }
      session.executableOverride = fake
      session.sessionHost = host
      session.runner = settings.id.uuidString
      session.send("quick")
      #expect(
        await eventually {
          if case .failed = session.phase { return true }
          return false
        })
      #expect(!session.isProcessRunning)
      guard case .failed(let message) = session.phase else { return "" }
      return message
    }

    let studio = SessionHost(endpoint: .runner(settings))
    let unreachable = try await failure(on: studio)
    let why = try #require(studio.failure).message
    #expect(unreachable == "Drakar can't reach Studio right now. \(why)")
    #expect(sshRuns() == 1)
    let notSetUp =
      "Drakar can't reach this session's runner: it is no longer set up in Settings › Runner."
    // Another runner's host, as a session made before its runner was set up again would hold:
    // not asked at all.
    let other = SessionHost(
      endpoint: .runner(RunnerSettings(name: "Other", destination: "other.local")))
    #expect(try await failure(on: other) == notSetUp)
    // This Mac's own host, as a runner project's session it could not reach is left with.
    #expect(try await failure(on: SessionHost()) == notSetUp)
    #expect(sshRuns() == 1)
    #expect(sent("quick") == 0)
  }

  /// A runner session runs only what v1 runs there: one of another agent fails before the
  /// runner is asked anything, and one made to resume a transcript of this Mac's starts new
  /// on the runner, its history none.
  @Test func aRunnerSessionNeverResumesNorRunsCodex() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))

    let codex = AgentSession(folder: folder, agent: .codex)
    codex.sessionHost = host
    codex.runner = settings.id.uuidString
    codex.send("quick")
    #expect(await eventually { codex.phase == .failed(AgentSession.claudeOnlyOnRunner) })
    #expect(!codex.isProcessRunning)
    #expect(sshRuns() == 0)

    let transcript = root.appending(path: "mac-account/projects/p/s-mac.jsonl")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: transcript)
    let target = ResumeTarget(
      sessionID: "s-mac", cwd: folder.path(percentEncoded: false),
      file: transcript.path(percentEncoded: false),
      accountDirectory: root.appending(path: "mac-account").path(percentEncoded: false),
      accountIsDefault: false)
    let resumed = AgentSession(folder: folder, resuming: target)
    resumed.accounts = { [] }
    resumed.sessionHost = host
    resumed.runner = settings.id.uuidString
    resumed.send("quick")
    #expect(await eventually { resumed.phase == .ready && !resumed.transcript.isRunning })
    defer { resumed.stop() }
    #expect(resumed.isHosted)
    let meta = try #require(resumed.meta())
    #expect(meta.history == HistoryMark.none)
    #expect(meta.start.resuming == nil)
  }

  /// A runner project's window on `host`, as `Project` makes one for a runner's folder.
  private func runnerProject(on host: SessionHost) -> Project {
    let project = Project(folder: folder, runner: settings.id.uuidString)
    project.sessionHost = host
    return project
  }

  /// A new session of `project` on its runner, sent `prompt`: "quick" leaves it idle, any
  /// other prompt at work.
  private func startedRow(in project: Project, prompt: String = "quick") async throws
    -> ProjectSession
  {
    let item = project.newSession()
    item.session.accounts = { [] }
    item.session.send(prompt)
    #expect(
      await eventually {
        item.session.phase == .ready && item.session.hostID != nil
          && item.session.transcript.isRunning == (prompt != "quick")
      })
    try #require(item.session.isOnRunner && item.session.isHosted)
    return item
  }

  private func held(_ id: String, on watcher: HostClient) async -> HeldProcess? {
    await answer(within: .seconds(2)) { try await watcher.list() }?.first { $0.id == id }
  }

  /// Kept by the runner's host, running, and no app's.
  private func isLetGo(_ id: String, on watcher: HostClient) async -> Bool {
    guard let held = await held(id, on: watcher) else { return false }
    return held.running && held.attachedApp == nil
  }

  /// A runner's session cannot be resumed from this Mac (remote sessions spec §4): closing
  /// its row, or its window, lets an idle one go as one at work is, and the runner's host
  /// keeps it.
  @Test func closingAnIdleRunnerSessionDetachesIt() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    let project = runnerProject(on: host)
    defer { project.stopAll() }
    let removed = try await startedRow(in: project)
    let closed = try await startedRow(in: project)
    let ids = try [removed, closed].map { try #require($0.session.hostID) }
    let watcher = try await watcher()
    defer { watcher.close() }

    project.remove(removed)
    project.stopAll(handingOver: true)
    #expect(!removed.session.isProcessRunning && !closed.session.isProcessRunning)
    for id in ids { #expect(await eventually { await isLetGo(id, on: watcher) }) }
    // Let go, not ended: still there a moment later.
    try await Task.sleep(for: .milliseconds(500))
    for id in ids { #expect(await isLetGo(id, on: watcher)) }
    #expect(host.ended.isEmpty)
  }

  /// Quitting lets a runner's sessions go, idle or at work: the runner's host keeps both.
  @Test func quittingDetachesRunnerSessions() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    let project = runnerProject(on: host)
    let idle = try await startedRow(in: project)
    let working = try await startedRow(in: project, prompt: "hi")
    #expect(!idle.session.isAtWork && working.session.isAtWork)
    let ids = try [idle, working].map { try #require($0.session.hostID) }
    let watcher = try await watcher()
    defer { watcher.close() }

    // Set and put back with nothing awaited between: no other suite's stop sees it.
    AppLifecycle.isTerminating = true
    project.stopAll()
    AppLifecycle.isTerminating = false
    for id in ids { #expect(await eventually { await isLetGo(id, on: watcher) }) }
    try await Task.sleep(for: .milliseconds(500))
    for id in ids { #expect(await isLetGo(id, on: watcher)) }
  }

  /// End Session ends a runner's session: its process, and the host's record of it.
  @Test func endSessionEndsARunnerSession() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    let project = runnerProject(on: host)
    defer { project.stopAll() }
    let item = try await startedRow(in: project)
    let id = try #require(item.session.hostID)
    let watcher = try await watcher()
    defer { watcher.close() }

    project.end(item)
    #expect(!item.session.isProcessRunning)
    #expect(host.ended.contains(id))
    #expect(
      await eventually {
        await answer(within: .seconds(2)) { try await watcher.list() }?
          .contains { $0.id == id } == false
      })
  }

  /// End Session while the session waits out its own stale relay on the runner: the host
  /// refuses anything of the process until that relay has gone, so the end waits for it, then
  /// ends the process.
  @Test func endSessionDuringAStaleRelayEndsItOnceFree() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    host.ownsProcess = { _ in true }
    let project = runnerProject(on: host)
    defer { project.stopAll() }
    let item = try await startedRow(in: project)
    let id = try #require(item.session.hostID)
    let watcher = try await watcher()
    defer { watcher.close() }
    let relay = try #require(await attached(id, on: watcher))
    kill(relay, SIGSTOP)
    var hungUp = false
    defer { if !hungUp { kill(relay, SIGKILL) } }
    await host.client()?.close()
    #expect(await eventually { item.session.isReconnecting })

    project.end(item)
    #expect(!item.session.isProcessRunning)
    #expect(host.ended.contains(id))
    try await Task.sleep(for: .seconds(1))
    // Still the stale relay's: nothing could end it yet.
    #expect(await held(id, on: watcher)?.running == true)

    kill(relay, SIGKILL)
    hungUp = true
    #expect(
      await eventually {
        await answer(within: .seconds(2)) { try await watcher.list() }?
          .contains { $0.id == id } == false
      })
  }

  /// An End Session given up on, its runner no longer set up mid-wait, leaves the process
  /// running there and no longer counted ended, for Home and a take-back to see.
  @Test func anEndGivenUpOnIsNotKeptEnded() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    host.ownsProcess = { _ in true }
    let project = runnerProject(on: host)
    defer { project.stopAll() }
    let item = try await startedRow(in: project)
    let id = try #require(item.session.hostID)
    let watcher = try await watcher()
    defer { watcher.close() }
    let relay = try #require(await attached(id, on: watcher))
    kill(relay, SIGSTOP)
    defer { kill(relay, SIGKILL) }
    await host.client()?.close()
    #expect(await eventually { item.session.isReconnecting })

    project.end(item)
    #expect(host.ended.contains(id))
    host.close()
    #expect(await eventually { !host.ended.contains(id) })
    #expect(await held(id, on: watcher)?.running == true)
  }

  /// A runner's process taken back after a relaunch, through the runner, is the runner's from
  /// its replay: what it reported stays on the session, and a stop before any window adopts it
  /// (the window closed during the replay) lets it go rather than ending it.
  @Test func aRunnerSessionTakenBackIsLetGoOnAStop() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    let project = runnerProject(on: host)
    let item = try await startedRow(in: project)
    let id = try #require(item.session.hostID)
    // The runner's default account, which this Mac's own may share a key with: what this
    // Mac's stores hold for it must be the same after the replay.
    let account = try #require(item.session.account)
    let usage = AccountStore.shared.usage(for: account)
    let models = ModelCatalog.shared.models(for: account)
    let watcher = try await watcher()
    defer { watcher.close() }
    project.stopAll(handingOver: true)
    #expect(await eventually { await isLetGo(id, on: watcher) })

    let client = try #require(await host.client())
    let process = try #require(await held(id, on: watcher))
    let session = try #require(
      await AgentSession(reattaching: process, client: client, throughRunner: true))
    #expect(session.isOnRunner)
    #expect(session.runner == settings.id.uuidString)
    // The replayed rate limit and models are the session's, not this Mac's records.
    #expect(session.account == account)
    #expect(session.usage?.fiveHour?.percent == 50)
    #expect(session.models?.map(\.value) == ["default"])
    #expect(AccountStore.shared.usage(for: account) == usage)
    #expect(ModelCatalog.shared.models(for: account) == models)
    #expect(await eventually { await held(id, on: watcher)?.attachedApp != nil })

    session.stop()
    #expect(await eventually { await isLetGo(id, on: watcher) })
    try await Task.sleep(for: .milliseconds(500))
    #expect(await isLetGo(id, on: watcher))
  }

  /// Closed while it waits out a stale relay, a runner's session is let go: nothing ends it,
  /// and once the relay has gone the host keeps it, no app's.
  @Test func closingDuringAStaleRelayLeavesTheSessionToItsHost() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let host = SessionHost(endpoint: .runner(settings))
    host.ownsProcess = { _ in true }
    let project = runnerProject(on: host)
    let item = try await startedRow(in: project)
    let id = try #require(item.session.hostID)
    let watcher = try await watcher()
    defer { watcher.close() }
    let relay = try #require(await attached(id, on: watcher))
    kill(relay, SIGSTOP)
    var hungUp = false
    defer { if !hungUp { kill(relay, SIGKILL) } }
    await host.client()?.close()
    #expect(await eventually { item.session.isReconnecting })

    project.stopAll(handingOver: true)
    // Long enough for anything the close sent to have reached the host before the relay goes.
    try await Task.sleep(for: .seconds(1))
    kill(relay, SIGKILL)
    hungUp = true
    #expect(await eventually { await isLetGo(id, on: watcher) })
    try await Task.sleep(for: .seconds(2.5))
    #expect(await isLetGo(id, on: watcher))
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

  // MARK: - Owner, and the handoff (spec §5)

  /// The runner's own Drakar beside this Mac's: an app on the test's host socket itself, as
  /// that Drakar reaches its host, where this Mac's goes through ssh and the relay. One test
  /// process plays both, so their attached apps are told apart by pid: this one's, or the
  /// relay's. `SessionHost.testDirectory` is put back as it was at once: other suites set it.
  private func runnersOwnDrakar() -> Project {
    let previous = SessionHost.testDirectory
    SessionHost.testDirectory = directory
    let host = SessionHost(cooldown: .milliseconds(100), helper: URL(filePath: "/usr/bin/true"))
    SessionHost.testDirectory = previous
    let project = Project(folder: folder)
    project.sessionHost = host
    return project
  }

  /// This Mac named as the test has it, whatever the test machine is called.
  private func namingThisMac() -> String {
    let name = ThisMac.name
    ThisMac.name = "Test MacBook"
    return name
  }

  /// What the runner's host keeps of `id`, as a meta.
  private func meta(_ id: String, on watcher: HostClient) async -> SessionMeta? {
    guard let held = await held(id, on: watcher) else { return nil }
    return try? JSONDecoder().decode(SessionMeta.self, from: held.meta)
  }

  /// A runner's window takes back, at a launch or a new connection, only what this Mac owns,
  /// and shows nothing of the rest, of which it has no transcript to follow: not a read-only
  /// row, as a local window would.
  @Test func aRunnerWindowTakesOnlyWhatThisMacOwns() async throws {
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    let name = namingThisMac()
    defer {
      ThisMac.name = name
      finish([helper])
    }
    let host = SessionHost(endpoint: .runner(settings))
    let client = try #require(await host.client())
    let cat = AgentProcess.Configuration(
      executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
      currentDirectory: folder)
    var ids: [String?: String] = [:]
    for owner in ["Test MacBook", "Other Mac", nil] as [String?] {
      let meta = SessionMeta(
        start: AgentStart(
          folder: folder, environment: [:], allowsBypass: false,
          runner: settings.id.uuidString),
        windowFolder: folder.path(percentEncoded: false), history: .none,
        runner: settings.id.uuidString, origin: owner ?? "Test MacBook", owner: owner)
      ids[owner] = try await client.spawn(cat, meta: try JSONEncoder().encode(meta))
    }
    let watcher = try await watcher()
    defer {
      for id in ids.values { try? watcher.send(.terminate(id: id, forget: true)) }
      watcher.close()
    }

    let project = runnerProject(on: host)
    defer { project.stopAll() }
    await project.takeBackHeld().value
    #expect(project.sessions.count == 1)
    let row = try #require(project.sessions.first)
    #expect(row.session.hostID == ids["Test MacBook"])
    #expect(row.session.isOnRunner)
    #expect(project.sessions.allSatisfy { $0.session.heldElsewhere == nil })
    for owner in ["Other Mac", nil] as [String?] {
      #expect(await held(try #require(ids[owner]), on: watcher)?.attachedApp == nil)
    }
  }

  /// Open on the Runner: the Mac's window lets the session go to the runner's own Drakar and
  /// closes its row; that Drakar, showing it read-only as a Mac's, attaches on `released`,
  /// and the Mac takes it back no more.
  @Test func openOnTheRunnerHandsItOver() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    let name = namingThisMac()
    defer {
      ThisMac.name = name
      finish([helper])
    }
    let host = SessionHost(endpoint: .runner(settings))
    let mac = runnerProject(on: host)
    defer { mac.stopAll() }
    let item = try await startedRow(in: mac)
    let id = try #require(item.session.hostID)
    let runner = runnersOwnDrakar()
    defer { runner.stopAll() }
    await runner.takeBackHeld().value
    let shown = try #require(runner.sessions.first { $0.session.heldElsewhere == id })
    #expect(shown.session.belongsTo == "Test MacBook")
    #expect(runner.canTakeOver(shown))
    #expect(mac.canOpenOnRunner(item))
    #expect(Handoff(item, in: mac) == .openOnRunner)
    #expect(Handoff(shown, in: runner) == .takeOver)

    mac.openOnRunner(item)
    #expect(!mac.sessions.contains { $0.id == item.id })
    #expect(
      await eventually {
        runner.sessions.contains { $0.session.hostID == id && $0.session.heldElsewhere == nil }
      })
    let taken = try #require(runner.sessions.first { $0.session.hostID == id }?.session)
    #expect(!taken.isOnRunner)
    let watcher = try await watcher()
    defer { watcher.close() }
    #expect(await held(id, on: watcher)?.attachedApp == getpid())
    let meta = try #require(await meta(id, on: watcher))
    #expect(meta.owner == nil)
    #expect(meta.origin == "Test MacBook")
    #expect(meta.runner == settings.id.uuidString)

    // The Mac's window, coming back to the runner, takes nothing and shows nothing of it.
    await mac.adoptHeld(await host.held())
    #expect(!mac.sessions.contains { $0.session.hostID == id || $0.session.heldElsewhere == id })
  }

  /// Bring Back: the runner's own Drakar gives the session back to the Mac that started it,
  /// whose window attaches on `released`; the runner's shows it read-only again.
  @Test func bringBackReturnsIt() async throws {
    _ = try installRunnerClaude()
    try relayingSSH()
    let helper = try #require(SessionHost.startHelper(in: directory))
    let name = namingThisMac()
    defer {
      ThisMac.name = name
      finish([helper])
    }
    let host = SessionHost(endpoint: .runner(settings))
    let mac = runnerProject(on: host)
    defer { mac.stopAll() }
    // The window as a launch opens it: listening to the runner from then on.
    await mac.takeBackHeld().value
    let item = try await startedRow(in: mac)
    let id = try #require(item.session.hostID)
    mac.openOnRunner(item)
    let runner = runnersOwnDrakar()
    defer { runner.stopAll() }
    // Handed over and free: the runner's own Drakar takes it at its launch.
    await runner.takeBackHeld().value
    let local = try #require(runner.sessions.first { $0.session.hostID == id })
    #expect(await eventually { local.session.phase == .ready })
    #expect(runner.bringBackDestination(local) == "Test MacBook")
    #expect(Handoff(local, in: runner) == .bringBack(to: "Test MacBook"))

    runner.bringBack(local)
    #expect(
      await eventually {
        mac.sessions.contains { $0.session.hostID == id && $0.session.phase == .ready }
      })
    let back = try #require(mac.sessions.first { $0.session.hostID == id })
    #expect(back.session.isOnRunner)
    #expect(mac.canOpenOnRunner(back))
    #expect(
      await eventually {
        runner.sessions.contains { $0.session.heldElsewhere == id }
      })
    #expect(!runner.sessions.contains { $0.session.hostID == id })
    let watcher = try await watcher()
    defer { watcher.close() }
    let held = try #require(await held(id, on: watcher))
    #expect(held.attachedApp != nil && held.attachedApp != getpid())
    #expect(await meta(id, on: watcher)?.owner == "Test MacBook")
  }
}
