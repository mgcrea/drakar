import Foundation
import Synchronization
import Testing

@testable import DrakarKit

/// What `HostedProcess` adds to the behaviours `AgentProcessTests` runs over both transports:
/// nothing spawned until `start()`, and a process found again by a new one.
@Suite struct HostedProcessTests {
  private struct TimedOut: Error {}

  private func within<T: Sendable>(_ body: @escaping @Sendable () async throws -> T)
    async throws -> T
  {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await body() }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw TimedOut()
      }
      defer { group.cancelAll() }
      return try #require(try await group.next())
    }
  }

  private func connected(_ host: TestHost) async throws -> HostClient {
    let client = try host.connect()
    _ = try await client.hello(appVersion: "test")
    return client
  }

  @Test func initSpawnsNothing() async throws {
    let host = try TestHost()
    defer { host.close() }
    let client = try await connected(host)
    let process = HostedProcess(client: client, configuration: host.cat(), meta: Data())
    #expect(try await client.list().isEmpty)
    #expect(process.id == nil)

    _ = try process.start()
    try await within {
      while try await client.list().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(process.id == (try await client.list()).first?.id)
    process.terminate()
  }

  @Test func reattachReplaysThenGoesLive() async throws {
    let host = try TestHost()
    defer { host.close() }
    let client = try await connected(host)
    let first = HostedProcess(client: client, configuration: host.cat(), meta: Data("m".utf8))
    let events = try first.start()
    try first.send(line: Data("one\n".utf8))
    first.note(Data("mark".utf8))
    // Its echo is the event that says the host logged the write and the note before it.
    try await within {
      for await event in events {
        if case .lines(let lines, _) = event, lines == [.invalid("one")] { return }
      }
      throw TimedOut()
    }
    first.detach()
    // The connection stays open, yet the process is free for another app to take.
    let other = try await connected(host)
    let held = try #require(try await client.list().first)
    #expect(held.attachedApp == nil)
    let taken = HostedProcess(client: other, held: held)
    _ = try await within { try await taken.replay() }
    #expect(try await client.list().first?.attachedApp == getpid())
    taken.detach()
    try await within {
      while try await client.list().first?.attachedApp != nil {
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    #expect(held.id == first.id)
    #expect(held.meta == Data("m".utf8))
    let second = HostedProcess(client: client, held: held)
    #expect(second.isRunning)
    let (records, offset) = try await within { try await second.replay() }
    // The note and the echo race, so the order of those two is not the test's to fix.
    #expect(records.map(\.kind).first == .in)
    #expect(Set(records.map(\.kind)) == [.in, .note, .out])
    #expect(records.count == 3)
    let echoed = try #require(records.first { $0.kind == .out })
    #expect(records.first { $0.kind == .note }?.bytes == Data("mark".utf8))
    #expect(offset == held.logLength)

    let live = second.live()
    try second.send(line: Data("two\n".utf8))
    second.closeInput()
    let seen = try await within {
      var seen: [AgentProcess.Event] = []
      for await event in live { seen.append(event) }
      return seen
    }
    // Only what came after the replay, the note and the writes left out.
    guard case .lines(let lines, let time) = seen.first else {
      Issue.record("got \(seen)")
      return
    }
    #expect(lines == [.invalid("two")])
    #expect(time > echoed.time)
    #expect(seen.last == .exited(status: 0, remainder: Data()))
    #expect(!second.isRunning)

    second.acknowledge()
    try await within {
      while try await !client.list().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }
  }

  @Test func aProcessThatEndedWhileAwayExitsOnTheLiveStream() async throws {
    let host = try TestHost()
    defer { host.close() }
    let client = try await connected(host)
    let id = try await client.spawn(
      AgentProcess.Configuration(
        executable: URL(filePath: "/bin/sh"), arguments: ["-c", "echo done; exit 4"],
        environment: [:], currentDirectory: host.directory),
      meta: Data())
    try await within {
      while try await client.list().first?.running != false {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    let held = try #require(try await client.list().first { $0.id == id })
    let process = HostedProcess(client: client, held: held)
    #expect(!process.isRunning)
    let (records, _) = try await process.replay()
    #expect(records.map(\.bytes) == [Data("done\n".utf8)])
    let seen = try await within {
      var seen: [AgentProcess.Event] = []
      for await event in process.live() { seen.append(event) }
      return seen
    }
    #expect(seen == [.exited(status: 4, remainder: Data())])
  }

  private func events(of process: HostedProcess) async throws -> [AgentProcess.Event] {
    let events = try process.start()
    return try await within {
      var seen: [AgentProcess.Event] = []
      for await event in events { seen.append(event) }
      return seen
    }
  }

  /// A spawn the host refuses ends the events at once, and says why as a start that threw.
  @Test func aSpawnTheHostRefusesSaysWhy() async throws {
    let host = try TestHost()
    defer { host.close() }
    let client = try await connected(host)
    var missing = host.cat()
    missing.executable = host.directory.appending(path: "missing")
    let process = HostedProcess(client: client, configuration: missing, meta: Data())
    #expect(try await events(of: process) == [.exited(status: -1, remainder: Data())])
    #expect(!process.isRunning)
    guard case .refused? = process.startFailure as? HostClient.Failure else {
      Issue.record("startFailure is \(String(describing: process.startFailure))")
      return
    }
  }

  /// A host that takes the connection but never says it spawned the process fails the
  /// start once the limit has gone by, rather than leaving it starting for good.
  @Test func aSpawnNobodyAnswersFails() async throws {
    let name = String(UUID().uuidString.prefix(6))
    let directory = URL(fileURLWithPath: "/tmp/dh-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socket = directory.appending(path: "s")
    let listener = try UnixSocket.listening(at: socket)
    let client = try HostClient.connect(socket: socket)
    defer {
      client.close()
      close(listener)
      try? FileManager.default.removeItem(at: directory)
    }
    let process = HostedProcess(
      client: client,
      configuration: AgentProcess.Configuration(
        executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
        currentDirectory: directory),
      meta: Data(), spawnLimit: .milliseconds(100))
    #expect(try await events(of: process) == [.exited(status: -1, remainder: Data())])
    #expect(process.startFailure as? HostedProcess.Failure == .noAnswer)
    #expect(!process.isRunning)
  }

  /// A spawn the host answers only after the limit is ended and forgotten: the app gave up
  /// on it, so nothing may be left running, or held, for nobody.
  @Test func aSpawnAnsweredLateIsEndedAndForgotten() async throws {
    let host = try TestHost()
    defer { host.close() }
    let proxy = try SlowSpawnProxy(to: host.socket, in: host.directory, delay: .milliseconds(300))
    defer { proxy.close() }
    let client = try HostClient.connect(socket: proxy.socket)
    defer { client.close() }
    let process = HostedProcess(
      client: client, configuration: host.cat(), meta: Data(), spawnLimit: .milliseconds(50))
    #expect(try await events(of: process) == [.exited(status: -1, remainder: Data())])
    #expect(process.startFailure as? HostedProcess.Failure == .noAnswer)

    let observer = try await connected(host)
    try await within {
      // Spawned, once the reply the app gave up on has gone by…
      while !proxy.spawned { try await Task.sleep(for: .milliseconds(10)) }
      // …then ended and acknowledged.
      while try await !observer.list().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }
  }

  @Test func replayOfAProcessTheHostDoesNotKnowIsRefused() async throws {
    let host = try TestHost()
    defer { host.close() }
    let client = try await connected(host)
    let process = HostedProcess(
      client: client, held: HeldProcess(id: "nope", meta: Data(), running: true, logLength: 0))
    await #expect(throws: HostClient.Failure.self) { try await process.replay() }
  }
}

/// Stands between an app and a host, passing every line on at once except a `spawned` reply,
/// which it holds back for `delay`.
private final class SlowSpawnProxy: @unchecked Sendable {
  let socket: URL
  private let listener: Int32
  private let upstream: UnixConnection
  private let downstream = Mutex<UnixConnection?>(nil)
  private let sawSpawned = Mutex(false)

  var spawned: Bool { sawSpawned.withLock { $0 } }

  init(to host: URL, in directory: URL, delay: Duration) throws {
    socket = directory.appending(path: "proxy")
    listener = try UnixSocket.listening(at: socket)
    let upstreamFD = try UnixSocket.connected(to: host)
    upstream = UnixConnection(fd: upstreamFD, label: "proxy-up")
    let (listener, upstream) = (listener, upstream)
    let seconds = Double(delay.components.attoseconds) / 1e18 + Double(delay.components.seconds)
    Thread.detachNewThread { [self] in
      var accepted: Int32 = -1
      while accepted < 0 {
        if case .peer(let fd) = UnixSocket.accept(listener) { accepted = fd } else { usleep(1000) }
      }
      try? UnixSocket.prepare(accepted)
      let down = UnixConnection(fd: accepted, label: "proxy-down")
      downstream.withLock { $0 = down }
      down.start(line: { upstream.send($0) }, closed: { upstream.close() })
      upstream.start(
        line: { [self] line in
          guard String(decoding: line, as: UTF8.self).contains("spawned") else {
            down.send(line)
            return
          }
          DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            self.sawSpawned.withLock { $0 = true }
            down.send(line)
          }
        },
        closed: { down.close() })
    }
  }

  func close() {
    upstream.close()
    downstream.withLock { $0 }?.close()
    Darwin.close(listener)
  }
}
