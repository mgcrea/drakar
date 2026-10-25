import Foundation
import Synchronization
import Testing

@testable import DrakarKit

/// `HostServer` and `HostClient` over a real Unix socket, with the stand-in agents
/// `HostCoreTests` runs.
@Suite struct HostSocketTests {
  private struct TimedOut: Error {}

  /// `body`'s result, or a throw after 5 s: a broken host fails the test, never hangs it.
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

  /// The events up to and including the first `done` accepts.
  private func events(
    _ stream: AsyncStream<HostEvent>, until done: @escaping @Sendable (HostEvent) -> Bool
  ) async throws -> [HostEvent] {
    try await within {
      var seen: [HostEvent] = []
      for await event in stream {
        seen.append(event)
        if done(event) { return seen }
      }
      throw TimedOut()
    }
  }

  private func firstValue<T: Sendable>(_ stream: AsyncStream<T>) async throws -> T {
    try await within {
      for await value in stream { return value }
      throw TimedOut()
    }
  }

  private func isOut(_ text: String) -> @Sendable (HostEvent) -> Bool {
    let bytes = Data(text.utf8)
    return { event in
      if case .record(_, let record) = event {
        record.kind == .out && record.bytes == bytes
      } else {
        false
      }
    }
  }

  @Test func aClientSpawnsAndAttaches() async throws {
    let host = try TestHost()
    defer { host.close() }
    let client = try host.connect()
    let welcome = try await client.hello(appVersion: "1")
    #expect(welcome.protocol == HostWire.major)
    #expect(welcome.hostVersion == "test")
    #expect(welcome.pid == getpid())

    let id = try await client.spawn(host.cat(), meta: Data("m".utf8))
    let stream = client.attach(id, from: 0)
    try client.send(.write(id: id, bytes: Data("a\n".utf8)))
    let seen = try await events(stream, until: isOut("a\n"))
    #expect(seen.first == .caughtUp(id: id, offset: 0))
    let records = seen.compactMap { event -> HostRecord? in
      if case .record(_, let record) = event { return record }
      return nil
    }
    #expect(records.map(\.kind) == [.in, .out])
    let held = try await client.list()
    #expect(held.map(\.id) == [id])
    #expect(held.first?.meta == Data("m".utf8))
    #expect(held.first?.attachedApp == getpid())
  }

  @Test func theSocketIsTheUsersAlone() throws {
    let host = try TestHost()
    defer { host.close() }
    var directory = stat()
    #expect(stat(host.directory.path, &directory) == 0)
    #expect(directory.st_mode & 0o777 == 0o700)
    var socket = stat()
    #expect(stat(try host.socket.path, &socket) == 0)
    #expect(socket.st_mode & S_IFMT == S_IFSOCK)
    #expect(socket.st_mode & 0o777 == 0o600)
    #expect(socket.st_uid == getuid())
  }

  @Test func aSecondServerFindsTheLock() async throws {
    let host = try TestHost()
    defer { host.close() }
    #expect(host.server != nil)
    let second = try HostServer.start(
      directory: host.directory, core: HostCore(directory: host.directory, hostVersion: "2"),
      peerCheck: { _ in true })
    #expect(second == nil)
    let client = try host.connect()
    #expect(try await client.hello(appVersion: "1").hostVersion == "test")
  }

  @Test func aStaleSocketIsReplaced() async throws {
    let name = String(UUID().uuidString.prefix(6))
    let directory = URL(fileURLWithPath: "/tmp/dh-\(name)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socket = try HostWire.socket(in: directory)
    // Bound and never listened on: the file a crashed host leaves.
    Darwin.close(try UnixSocket.bound(at: socket))
    #expect(FileManager.default.fileExists(atPath: socket.path))
    #expect(throws: (any Error).self) { try HostClient.connect(socket: socket) }

    let core = HostCore(directory: directory, hostVersion: "test")
    let server = try #require(
      try HostServer.start(directory: directory, core: core, peerCheck: { _ in true }))
    defer { server.stop() }
    let client = try HostClient.connect(socket: socket)
    defer { client.close() }
    #expect(try await client.hello(appVersion: "1").protocol == HostWire.major)
  }

  @Test func aRefusedPeerLearnsNothing() async throws {
    let asked = Mutex(0)
    let host = try TestHost { _ in
      asked.withLock { $0 += 1 }
      return false
    }
    defer { host.close() }
    let client = try host.connect()
    await #expect(throws: (any Error).self) { try await client.hello(appVersion: "1") }
    #expect(asked.withLock { $0 } == 1)
    #expect(host.core.isIdle)
  }

  @Test func losingTheConnectionDetaches() async throws {
    let host = try TestHost()
    defer { host.close() }
    let first = try host.connect()
    let second = try host.connect()
    _ = try await second.hello(appVersion: "1")
    let id = try await first.spawn(host.cat(), meta: Data())
    _ = try await events(first.attach(id, from: 0)) { $0 == .caughtUp(id: id, offset: 0) }

    first.close()
    #expect(try await firstValue(second.released) == id)
    #expect(try await second.list().first?.attachedApp == nil)
    try await firstValue(first.disconnected)
  }

  /// A line far longer than the socket takes at once arrives whole, byte for byte, both ways.
  @Test func aLongLineArrivesWhole() async throws {
    let host = try TestHost()
    defer { host.close() }
    let client = try host.connect()
    let id = try await client.spawn(host.cat(), meta: Data())
    let stream = client.attach(id, from: 0)
    var line = Data((0..<(1 << 20)).map { UInt8(0x41 + $0 % 26) })
    line[line.count / 3] = 0x00
    line[line.count / 2] = 0xFF
    line.append(0x0A)
    try client.send(.write(id: id, bytes: line))
    let records = try await events(stream) { event in
      if case .record(_, let record) = event { record.kind == .out } else { false }
    }.compactMap { event -> HostRecord? in
      if case .record(_, let record) = event { return record }
      return nil
    }
    #expect(records.map(\.kind) == [.in, .out])
    #expect(records.allSatisfy { $0.bytes == line })
  }

  /// A CLI that never reads its stdin blocks the write sent to it, and nothing else: the
  /// same app's next request to another process is answered meanwhile.
  @Test func aStuckWriteHoldsUpNoOtherRequest() async throws {
    let host = try TestHost()
    defer { host.close() }
    let client = try host.connect()
    let deaf = try await client.spawn(
      AgentProcess.Configuration(
        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
        currentDirectory: host.directory),
      meta: Data())
    try client.send(.write(id: deaf, bytes: Data(repeating: 0x61, count: 1 << 20)))

    let cat = host.cat()
    let listed = try await within {
      let other = try await client.spawn(cat, meta: Data())
      try client.send(.write(id: other, bytes: Data("b\n".utf8)))
      return try await client.list()
    }
    #expect(listed.count == 2)
  }

  @Test func aConnectionToNothingThrows() throws {
    let host = try TestHost()
    host.close()
    #expect(throws: (any Error).self) { try HostClient.connect(socket: host.socket) }
  }
}
