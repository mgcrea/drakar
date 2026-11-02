import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// `Drakar --relay`: the test host's own binary started as sshd would start it, on a host
/// directory of each test's own under `/tmp` (`sun_path` holds 104 bytes), with its opt-in
/// read from a defaults suite of the test's own. Never the person's host, settings or home:
/// every relay here gets `--directory`, `--defaults-suite` and `--home`, and every helper is
/// killed by its pid.
///
/// Off the main actor, which the hosted suite keeps busy: a relay's timings are its own.
@Suite("The relay a runner's sshd starts", .timeLimit(.minutes(1)))
struct RelayCommandTests {
  /// Where the runner's environment file goes, beside the host's directory.
  private let root: URL
  private let directory: URL
  /// The runner's home its facts are found in, never the person's.
  private let home: URL
  private let suite = "drakar-tests-\(UUID().uuidString)"

  init() throws {
    root = URL(fileURLWithPath: "/tmp/dr-\(UUID().uuidString.prefix(6))", isDirectory: true)
    directory = root.appending(path: "host", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    for directory in [directory, home] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  private func finish(_ helpers: [pid_t] = []) {
    for pid in helpers where SessionHost.isRunning(pid) { kill(pid, SIGKILL) }
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }

  private func accept(_ accepts: Bool) {
    UserDefaults(suiteName: suite)?.set(accepts, forKey: RunnerRole.acceptsKey)
  }

  /// The GUI session's environment, as the runner's app writes it: the relay then never
  /// reads a login shell.
  private func writeEnvironment() throws {
    try RunnerEnvironment.write(["PATH": "/usr/bin:/bin"], to: RunnerEnvironment.file(in: root))
  }

  /// The relay, not started. Its environment is what sshd gives a command, not the test
  /// host's, whose XCTest variables would have it load the tests as well.
  private func relay(stdin: FileHandle, stdout: FileHandle, stderr: Pipe) throws -> Process {
    let process = Process()
    process.executableURL = try #require(Bundle.main.executableURL)
    process.arguments = [
      "--relay", "--directory", directory.path(percentEncoded: false), "--defaults-suite", suite,
      "--home", home.path(percentEncoded: false),
    ]
    let inherited = ProcessInfo.processInfo.environment
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR"] {
      environment[key] = inherited[key]
    }
    process.environment = environment
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    return process
  }

  /// The relay's exit status, or nil (and the relay killed) once `limit` has gone by.
  private func status(of process: Process, within limit: Duration) async -> Int32? {
    let deadline = ContinuousClock.now + limit
    while process.isRunning {
      guard ContinuousClock.now < deadline else {
        process.terminate()
        return nil
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return process.terminationStatus
  }

  private func text(_ pipe: Pipe) -> String {
    String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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

  private func eventually(within limit: Duration, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
  }

  /// The facts line, read a byte at a time so that not one of the host's bytes after it is
  /// taken; nil on EOF or after `limit`.
  private static func line(from fd: Int32, within limit: Duration) async -> Data? {
    await Task.detached {
      let deadline = ContinuousClock.now + limit
      var line = Data()
      var byte: UInt8 = 0
      while true {
        let left = deadline - .now
        guard left > .zero else { return nil }
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, Int32(left / .milliseconds(1))) > 0, read(fd, &byte, 1) == 1 else {
          return nil
        }
        if byte == 0x0A { return line }
        line.append(byte)
      }
    }.value
  }

  /// A relay started with the runner's host up: one end of a socket pair is its stdin and
  /// stdout, as ssh's would be, and the other is returned with the facts read off it.
  private func connectedRelay(stderr: Pipe) async throws -> (Process, fd: Int32, RunnerFacts) {
    var fds: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    // Neither is inherited by what another suite spawns meanwhile, and ours not by the relay,
    // where it would hold the connection open from inside; the relay gets its end as stdio.
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    let theirs = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    let process = try relay(stdin: theirs, stdout: theirs, stderr: stderr)
    do {
      try process.run()
    } catch {
      close(fds[0])
      close(fds[1])
      throw error
    }
    close(fds[1])
    guard let line = await Self.line(from: fds[0], within: .seconds(20)) else {
      close(fds[0])
      process.terminate()
      Issue.record("no facts: \(text(stderr))")
      throw CancellationError()
    }
    do {
      return (process, fds[0], try RunnerFacts.parse(line))
    } catch {
      close(fds[0])
      process.terminate()
      throw error
    }
  }

  @Test func refusesWhenTheRunnerHasNotOptedIn() async throws {
    defer { finish() }
    accept(false)
    let stdout = Pipe()
    let stderr = Pipe()
    let process = try relay(
      stdin: .nullDevice, stdout: stdout.fileHandleForWriting, stderr: stderr)
    try process.run()
    #expect(await status(of: process, within: .seconds(10)) == 64)
    try stdout.fileHandleForWriting.close()
    #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
    #expect(text(stderr).contains("Let my other Macs start sessions here"))
  }

  @Test func statesItsFactsThenRelays() async throws {
    accept(true)
    try writeEnvironment()
    let helper = try #require(await SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let stderr = Pipe()
    let (process, fd, facts) = try await connectedRelay(stderr: stderr)
    defer { if process.isRunning { process.terminate() } }

    #expect(facts.relay == 1)
    #expect(facts.hostMajors.contains(HostWire.major))
    #expect(facts.environmentFrom == .gui)
    #expect(facts.environment["PATH"] == "/usr/bin:/bin")

    let client = HostClient.connect(fd: fd)
    let welcome = await answer(within: .seconds(10)) {
      try await client.hello(appVersion: "test")
    }
    #expect(welcome?.protocol == HostWire.major)
    #expect(welcome?.pid == helper)
    #expect(await answer(within: .seconds(5)) { try await client.list() } == [])

    // The Mac leaving is ssh's stdin closing: the relay ends as the pump does.
    client.close()
    #expect(await status(of: process, within: .seconds(5)) == 0)
  }

  /// ssh lost without a clean close: the relay goes at once on the hang-up, and the host
  /// sees the app leave the process it was attached to.
  @Test func aHangUpEndsItAndTheHostSeesItLeave() async throws {
    accept(true)
    try writeEnvironment()
    let helper = try #require(await SessionHost.startHelper(in: directory))
    defer { finish([helper]) }
    let stderr = Pipe()
    let (process, fd, _) = try await connectedRelay(stderr: stderr)
    defer { if process.isRunning { process.terminate() } }
    let client = HostClient.connect(fd: fd)
    defer { client.close() }
    _ = await answer(within: .seconds(10)) { try await client.hello(appVersion: "test") }
    let cat = AgentProcess.Configuration(
      executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:],
      currentDirectory: root)
    let id = try #require(
      await answer(within: .seconds(5)) { try await client.spawn(cat, meta: Data()) })
    _ = client.attach(id, from: 0)

    let watcher = try HostClient.connect(socket: try HostWire.socket(in: directory))
    defer { watcher.close() }
    _ = await answer(within: .seconds(5)) { try await watcher.hello(appVersion: "test") }
    func attached() async -> Int32? {
      await answer(within: .seconds(2)) { try await watcher.list() }?.first?.attachedApp
    }
    let relay = process.processIdentifier
    #expect(await eventually(within: .seconds(5)) { await attached() == relay })

    kill(relay, SIGHUP)
    #expect(await status(of: process, within: .seconds(5)) == 0)
    #expect(process.terminationReason == .exit)
    #expect(await eventually(within: .seconds(5)) { await attached() == nil })
    try? watcher.send(.terminate(id: id, forget: true))
  }

  @Test func withNoHostItGivesUp() async throws {
    defer { finish() }
    accept(true)
    try writeEnvironment()
    let stdout = Pipe()
    let stderr = Pipe()
    let process = try relay(
      stdin: .nullDevice, stdout: stdout.fileHandleForWriting, stderr: stderr)
    let start = ContinuousClock.now
    try process.run()
    #expect(await status(of: process, within: .seconds(16)) == 69)
    #expect(ContinuousClock.now - start >= .seconds(14))
    #expect(!text(stderr).isEmpty)
  }

  @Test func factsPreferTheGUIEnvironment() async throws {
    defer { finish() }
    // A `claude` on the environment's PATH, and an account in its CLAUDE_CONFIG_DIR.
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let claude = bin.appending(path: "claude")
    try Data("#!/bin/sh\necho '2.1.300 (Claude Code)'\n".utf8).write(to: claude)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    let account = root.appending(path: ".claude-work", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: account.appending(path: "projects"), withIntermediateDirectories: true)
    let environment = [
      "MARK": "gui", "PATH": bin.path(percentEncoded: false) + ":/usr/bin:/bin",
      "CLAUDE_CONFIG_DIR": account.path(percentEncoded: false),
    ]
    let file = RunnerEnvironment.file(in: root)
    try RunnerEnvironment.write(environment, to: file)

    let gui = await RelayCommand.facts(environmentFile: file, home: home)
    #expect(gui.environmentFrom == .gui)
    #expect(gui.environment["MARK"] == "gui")
    #expect(gui.claude.first == ClaudeCandidate(path: claude.path, version: "2.1.300"))
    #expect(gui.accounts.contains(ProjectPath.normalize(account)))
    #expect(gui.hostMajors == [HostWire.major])
    #expect(gui.home == ProjectPath.normalize(home))
    #expect(gui.user == NSUserName())
    #expect(!gui.hostname.isEmpty)

    // Without the file: the login shell's, less what belongs to the ssh session.
    try FileManager.default.removeItem(at: file)
    let session = ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY", "SSH_AUTH_SOCK"]
    var shell = ["MARK": "shell", "PATH": "/usr/bin:/bin"]
    for key in session { shell[key] = "x" }
    let ssh = await RelayCommand.facts(environmentFile: file, home: home) { [shell] in shell }
    #expect(ssh.environmentFrom == .ssh)
    #expect(ssh.environment["MARK"] == "shell")
    for key in session { #expect(ssh.environment[key] == nil) }
  }

  /// What tests give the relay is taken only with a host directory of theirs.
  @Test func testOptionsNeedADirectory() {
    let alone = RelayCommand.Options(arguments: [
      "--relay", "--defaults-suite", "suite", "--home", "/tmp/home",
    ])
    #expect(alone.directory == nil && alone.defaultsSuite == nil && alone.home == nil)
    let given = RelayCommand.Options(arguments: [
      "--relay", "--directory", "/tmp/host", "--defaults-suite", "suite", "--home", "/tmp/home",
    ])
    #expect(given.directory?.path(percentEncoded: false) == "/tmp/host/")
    #expect(given.defaultsSuite == "suite")
    #expect(given.home?.path(percentEncoded: false) == "/tmp/home/")
  }
}
