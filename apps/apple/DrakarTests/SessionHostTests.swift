import DrakarKit
import Foundation
import Security
import Testing

@testable import Drakar

/// The bundled `DrakarHost`, started for real on a short directory of each test's own under
/// `/tmp` (`sun_path` holds 104 bytes). Every helper a test starts is killed by its pid.
/// Serialized: `SessionHost.testDirectory` is one for the whole app.
@MainActor
@Suite("The session host the app bundles and starts", .serialized)
struct SessionHostTests {
  private let directory: URL

  init() {
    let name = String(UUID().uuidString.prefix(6))
    directory = URL(fileURLWithPath: "/tmp/dh-\(name)", isDirectory: true)
  }

  private func stop(_ pids: [pid_t?]) {
    for case let pid? in pids where SessionHost.isRunning(pid) { kill(pid, SIGKILL) }
    SessionHost.testDirectory = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private func eventually(within limit: Duration, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
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

  private func team(of code: SecStaticCode) -> String? {
    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess else {
      return nil
    }
    return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
  }

  @Test func theHelperIsBundledAndSigned() throws {
    let helper = SessionHost.helper
    #expect(FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)))
    var helperCode: SecStaticCode?
    #expect(SecStaticCodeCreateWithPath(helper as CFURL, [], &helperCode) == errSecSuccess)
    var appCode: SecStaticCode?
    #expect(
      SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &appCode) == errSecSuccess)
    let app = try #require(appCode)
    let appTeam = try #require(team(of: app))
    let bundled = try #require(helperCode)
    #expect(team(of: bundled) == appTeam)
  }

  @Test func aClientStartsTheHelper() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { stop([host.started]) }
    let client = try #require(await host.client())
    #expect(host.started != nil)
    #expect(host.isAvailable)
    let welcome = try await client.hello(appVersion: "test")
    #expect(welcome.protocol == HostWire.major)
    #expect(welcome.pid == host.started)
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
    #expect(welcome.hostVersion == appVersion as? String)
  }

  /// Started at the 256 an app launched from the Finder has (these tests inherit more), it
  /// still takes 300 apps: each process held takes about four descriptors, and 256 would run
  /// out near sixty sessions.
  @Test(.timeLimit(.minutes(1))) func theHelperRaisesItsDescriptorLimit() async throws {
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = [
      "-c", "ulimit -Sn 256 && exec \"$0\" --directory \"$1\"",
      SessionHost.helper.path(percentEncoded: false), directory.path(percentEncoded: false),
    ]
    try helper.run()
    var clients: [HostClient] = []
    defer {
      for client in clients { client.close() }
      helper.terminate()
      helper.waitUntilExit()
      stop([])
    }
    let socket = try HostWire.socket(in: directory)
    #expect(
      await eventually(within: .seconds(5)) { FileManager.default.fileExists(atPath: socket.path) })
    for _ in 0..<300 {
      let client = try HostClient.connect(socket: socket)
      clients.append(client)
      let welcome = await answer(within: .seconds(2)) {
        try await client.hello(appVersion: "test")
      }
      try #require(welcome != nil, "\(clients.count) apps connected")
    }
  }

  @Test func twoHostsStartingAtOnceLeaveOne() async throws {
    let first = SessionHost.startHelper(in: directory)
    var second: pid_t?
    defer { stop([first, second]) }
    try await Task.sleep(for: .seconds(1))
    second = SessionHost.startHelper(in: directory)
    let pids = try [#require(first), #require(second)]
    #expect(await eventually(within: .seconds(5)) { pids.filter(SessionHost.isRunning).count == 1 })
    let left = try #require(pids.first(where: SessionHost.isRunning))

    let socket = try HostWire.socket(in: directory)
    let clients = try [HostClient.connect(socket: socket), HostClient.connect(socket: socket)]
    defer { for client in clients { client.close() } }
    for client in clients {
      #expect(try await client.hello(appVersion: "test").pid == left)
    }
  }

  /// `nc` is Apple's, not the team's: the helper closes on it before reading a line, where
  /// an app it lets in has a line it cannot decode refused.
  @Test func aProgramOfAnotherTeamIsRefused() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { stop([host.started]) }
    let client = try #require(await host.client())
    let socket = try HostWire.socket(in: directory)

    let nc = Process()
    nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    nc.arguments = ["-U", "-w", "5", socket.path(percentEncoded: false)]
    let input = Pipe()
    let output = Pipe()
    nc.standardInput = input
    nc.standardOutput = output
    try nc.run()
    try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":1}\n".utf8))
    let answer = output.fileHandleForReading.readDataToEndOfFile()
    nc.waitUntilExit()
    #expect(answer.isEmpty)
    // Still serving the app it let in.
    #expect(try await client.list().isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func theHelperLeavesWhenIdle() async throws {
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer { stop([host.started]) }
    let client = try #require(await host.client())
    let pid = try #require(host.started)
    client.close()
    #expect(await eventually(within: .seconds(40)) { !SessionHost.isRunning(pid) })
    #expect(await eventually(within: .seconds(1)) { !host.isAvailable })
  }

  @Test func noHostUnderTestsUnlessAsked() async {
    SessionHost.testDirectory = nil
    let host = SessionHost()
    #expect(await host.client() == nil)
    #expect(host.started == nil)
    #expect(!host.isAvailable)
  }

  /// A host that takes the connection and never says hello (here: one stuck admitting it)
  /// holds the app up for the bounded wait, not for good.
  @Test(.timeLimit(.minutes(1))) func aHostThatNeverAnswersIsGivenUp() async throws {
    let core = HostCore(directory: directory, hostVersion: "deaf")
    let release = DispatchSemaphore(value: 0)
    let server = try #require(
      try HostServer.start(directory: directory, core: core) { _ in
        // Each waiter lets the next through once the test lets the first.
        release.wait()
        release.signal()
        return false
      })
    SessionHost.testDirectory = directory
    let host = SessionHost()
    defer {
      release.signal()
      server.stop()
      stop([host.started])
    }
    let began = ContinuousClock.now
    #expect(await host.client() == nil)
    #expect(ContinuousClock.now - began < .seconds(8))
    #expect(!host.isAvailable)
  }
}
