import Foundation
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

  @Test func replayOfAProcessTheHostDoesNotKnowIsRefused() async throws {
    let host = try TestHost()
    defer { host.close() }
    let client = try await connected(host)
    let process = HostedProcess(
      client: client, held: HeldProcess(id: "nope", meta: Data(), running: true, logLength: 0))
    await #expect(throws: HostClient.Failure.self) { try await process.replay() }
  }
}
