import Foundation
import Synchronization
import Testing

@testable import DrakarKit

/// `HostCore` against stand-in agents, as `AgentProcessTests` runs them: `cat` echoes what it
/// is sent, `sh` prints on its own. Real pipes, a log directory of its own, no socket.
@Suite(.timeLimit(.minutes(1))) struct HostCoreTests {
  /// What `deliver` handed each client, in order.
  private final class Inbox: Sendable {
    private let events = Mutex<[HostCore.Client: [HostEvent]]>([:])

    func receive(_ client: HostCore.Client, _ event: HostEvent) {
      events.withLock { $0[client, default: []].append(event) }
    }

    func of(_ client: HostCore.Client) -> [HostEvent] { events.withLock { $0[client] ?? [] } }

    func records(_ client: HostCore.Client) -> [HostRecord] {
      of(client).compactMap { event in
        if case .record(_, let record) = event { return record }
        return nil
      }
    }
  }

  private final class Host {
    let directory: URL
    let core: HostCore
    let inbox = Inbox()

    init() throws {
      let name = String(UUID().uuidString.prefix(6))
      directory = URL(fileURLWithPath: "/tmp/dh-\(name)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      core = HostCore(directory: directory, hostVersion: "test")
      let inbox = inbox
      core.deliver = { inbox.receive($0, $1) }
    }

    private let clients = Mutex<[HostCore.Client]>([])

    func connect(pid: Int32) -> HostCore.Client {
      let client = core.connected(pid: pid)
      clients.withLock { $0.append(client) }
      return client
    }

    /// Ends whatever is still running, so no test leaves a process behind.
    func close() {
      for client in clients.withLock({ $0 }) { core.disconnected(client) }
      let client = core.connected(pid: 0)
      for process in held() { _ = core.handle(.terminate(id: process.id), from: client) }
      try? FileManager.default.removeItem(at: directory)
    }

    func spawn(_ executable: String, _ arguments: [String] = [], from client: HostCore.Client)
      throws -> String
    {
      let configuration = AgentProcess.Configuration(
        executable: URL(fileURLWithPath: executable), arguments: arguments, environment: [:],
        currentDirectory: directory)
      let replies = core.handle(.spawn(configuration, meta: Data("m".utf8)), from: client)
      guard case .spawned(let id) = replies.first else { throw Failed(replies) }
      return id
    }

    func held() -> [HeldProcess] {
      guard case .listed(let processes) = core.handle(.list, from: 0).first else { return [] }
      return processes
    }

    func held(_ id: String) -> HeldProcess? { held().first { $0.id == id } }

    func log(_ id: String) -> URL { directory.appendingPathComponent("\(id).log") }

    func logged(_ id: String) -> [HostRecord] {
      (try? HostLog(url: log(id)).records(from: 0)) ?? []
    }

    func hasExited(_ id: String) -> Bool { held(id)?.running == false }
  }

  private struct Failed: Error {
    var replies: [HostEvent]
    init(_ replies: [HostEvent]) { self.replies = replies }
  }

  private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  private func bytes(_ text: String) -> Data { Data(text.utf8) }

  @Test func spawnLogsAndForwards() async throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 42)
    let id = try host.spawn("/bin/cat", from: client)
    #expect(host.core.handle(.attach(id: id, from: 0), from: client).isEmpty)
    #expect(host.core.handle(.write(id: id, bytes: bytes("a\n")), from: client).isEmpty)
    #expect(await eventually { host.inbox.records(client).count == 2 })
    let records = host.inbox.records(client)
    #expect(records.map(\.kind) == [.in, .out])
    #expect(records.map(\.bytes) == [bytes("a\n"), bytes("a\n")])
    #expect(records.allSatisfy { $0.attached })
    #expect(host.held(id)?.attachedApp == 42)
    #expect(host.logged(id) == records)
  }

  /// `logged` is what the log keeps in place of what went to stdin, which `cat` echoes.
  @Test func aWriteLogsWhatItIsToldToInPlaceOfItsBytes() async throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 42)
    let id = try host.spawn("/bin/cat", from: client)
    let write = HostRequest.write(id: id, bytes: bytes("typed\n"), logged: bytes("hidden\n"))
    #expect(host.core.handle(write, from: client).isEmpty)
    #expect(await eventually { host.logged(id).count == 2 })
    let records = host.logged(id)
    #expect(records.map(\.kind) == [.in, .out])
    #expect(records.map(\.bytes) == [bytes("hidden\n"), bytes("typed\n")])
  }

  @Test func attachReplaysThenCaughtUp() async throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 42)
    let id = try host.spawn("/bin/cat", from: client)
    _ = host.core.handle(.write(id: id, bytes: bytes("a\n")), from: client)
    _ = host.core.handle(.write(id: id, bytes: bytes("b\n")), from: client)
    #expect(await eventually { host.logged(id).count == 4 })
    #expect(host.inbox.of(client).isEmpty)

    #expect(host.core.handle(.attach(id: id, from: 0), from: client).isEmpty)
    #expect(await eventually { host.inbox.of(client).count == 5 })
    let events = host.inbox.of(client)
    #expect(host.inbox.records(client).count == 4)
    #expect(host.inbox.records(client) == host.logged(id))
    #expect(host.inbox.records(client).allSatisfy { !$0.attached })
    let length = try #require(host.held(id)?.logLength)
    #expect(events.last == .caughtUp(id: id, offset: length))
  }

  /// The child writes a line every few milliseconds while the app attaches: each record
  /// reaches it exactly once, backlog or live, in the log's order.
  @Test func attachHandsOverWithoutLosingOrDoubling() async throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 42)
    let id = try host.spawn(
      "/bin/sh", ["-c", "i=0; while [ $i -lt 150 ]; do echo $i; i=$((i+1)); sleep 0.002; done"],
      from: client)
    #expect(await eventually { host.logged(id).count >= 20 })
    _ = host.core.handle(.attach(id: id, from: 0), from: client)
    #expect(await eventually { host.inbox.of(client).last == .exited(id: id, status: 0) })

    let seen = host.inbox.records(client).map(\.offset)
    #expect(seen == host.logged(id).map(\.offset))
    #expect(seen.count == 150)
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 })
    let backlog = host.inbox.of(client).firstIndex {
      if case .caughtUp = $0 { true } else { false }
    }
    #expect(try #require(backlog) >= 20)
    #expect(host.inbox.records(client).contains { $0.attached })
  }

  /// The backlog is read off the core's lock: another request is answered meanwhile, and
  /// what is logged then comes before `caughtUp`, once.
  @Test func anAttachReadsItsBacklogWithoutHoldingTheHost() async throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 42)
    let id = try host.spawn("/bin/cat", from: client)
    _ = host.core.handle(.write(id: id, bytes: bytes("a\n")), from: client)
    #expect(await eventually { host.logged(id).count == 2 })
    let core = host.core
    let answered = Mutex(false)
    core.readingBacklog = {
      let listed = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        _ = core.handle(.list, from: client)
        listed.signal()
      }
      answered.withLock { $0 = listed.wait(timeout: .now() + 2) == .success }
      _ = core.handle(.write(id: id, bytes: Data("b\n".utf8)), from: client)
    }
    #expect(core.handle(.attach(id: id, from: 0), from: client).isEmpty)
    core.readingBacklog = nil
    #expect(answered.withLock { $0 })

    #expect(await eventually { host.inbox.records(client).count == 4 })
    let records = host.inbox.records(client)
    #expect(records == host.logged(id))
    #expect(records.map(\.bytes) == [bytes("a\n"), bytes("a\n"), bytes("b\n"), bytes("b\n")])
    let events = host.inbox.of(client)
    #expect(events[2] == .record(id: id, records[2]))
  }

  @Test func anAttachTakenMeanwhileIsRefused() async throws {
    let host = try Host()
    defer { host.close() }
    let first = host.connect(pid: 1)
    let second = host.connect(pid: 2)
    let id = try host.spawn("/bin/cat", from: first)
    let core = host.core
    core.readingBacklog = {
      core.readingBacklog = nil
      _ = core.handle(.attach(id: id, from: 0), from: second)
    }
    let refused = core.handle(.attach(id: id, from: 0), from: first)
    guard case .refused = refused.first else {
      Issue.record("got \(refused)")
      return
    }
    #expect(host.held(id)?.attachedApp == 2)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(host.inbox.of(first).isEmpty)
    #expect(host.inbox.of(second) == [.caughtUp(id: id, offset: 0)])
  }

  @Test func anAttachToAProcessAcknowledgedMeanwhileIsRefused() async throws {
    let host = try Host()
    defer { host.close() }
    let first = host.connect(pid: 1)
    let second = host.connect(pid: 2)
    let id = try host.spawn("/bin/sh", ["-c", "echo out"], from: first)
    #expect(await eventually { host.hasExited(id) })
    let core = host.core
    core.readingBacklog = { _ = core.handle(.acknowledge(id: id), from: second) }
    let refused = core.handle(.attach(id: id, from: 0), from: first)
    guard case .refused = refused.first else {
      Issue.record("got \(refused)")
      return
    }
    try? await Task.sleep(for: .milliseconds(50))
    // Nothing of the attach; only that another app let it go.
    #expect(host.inbox.of(first) == [.released(id: id)])
  }

  @Test func aRecordWhileNobodyIsAttachedSaysSo() async throws {
    let host = try Host()
    defer { host.close() }
    let first = host.connect(pid: 1)
    let id = try host.spawn("/bin/cat", from: first)
    _ = host.core.handle(.attach(id: id, from: 0), from: first)
    _ = host.core.handle(.write(id: id, bytes: bytes("a\n")), from: first)
    #expect(await eventually { host.logged(id).count == 2 })
    host.core.disconnected(first)

    let second = host.connect(pid: 2)
    _ = host.core.handle(.write(id: id, bytes: bytes("b\n")), from: second)
    #expect(await eventually { host.logged(id).count == 4 })
    let records = host.logged(id)
    #expect(records.map(\.attached) == [true, true, false, false])
    #expect(records.last?.kind == .out)
    #expect(records.last?.bytes == bytes("b\n"))
  }

  @Test func exitWhileUnattachedIsKept() async throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 42)
    let id = try host.spawn("/bin/sh", ["-c", "echo done; printf tail"], from: client)
    host.core.disconnected(client)
    #expect(await eventually { host.hasExited(id) })
    let held = try #require(host.held(id))
    #expect(!held.running)
    #expect(held.exitStatus == 0)
    #expect(held.attachedApp == nil)
    #expect(FileManager.default.fileExists(atPath: host.log(id).path))
    #expect(host.logged(id).map(\.bytes) == [bytes("done\n"), bytes("tail")])

    let other = host.connect(pid: 43)
    #expect(host.core.handle(.acknowledge(id: id), from: other).isEmpty)
    #expect(host.held(id) == nil)
    #expect(!FileManager.default.fileExists(atPath: host.log(id).path))
  }

  @Test func attachingToAnEndedProcessGivesItsEnd() async throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 42)
    let id = try host.spawn("/bin/sh", ["-c", "echo out; echo why >&2; exit 3"], from: client)
    #expect(await eventually { host.hasExited(id) })
    _ = host.core.handle(.attach(id: id, from: 0), from: client)
    #expect(await eventually { host.inbox.of(client).count == 4 })
    let events = host.inbox.of(client)
    #expect(events[1] == .caughtUp(id: id, offset: try #require(host.held(id)?.logLength)))
    #expect(events[2] == .stderr(id: id, text: "why\n"))
    #expect(events[3] == .exited(id: id, status: 3))
  }

  @Test func attachIsRefusedWhileAnotherAppHolds() async throws {
    let host = try Host()
    defer { host.close() }
    let first = host.connect(pid: 1)
    let second = host.connect(pid: 2)
    let id = try host.spawn("/bin/cat", from: first)
    #expect(host.core.handle(.attach(id: id, from: 0), from: first).isEmpty)

    let refused = host.core.handle(.attach(id: id, from: 0), from: second)
    #expect(refused.count == 1)
    guard case .refused = refused.first else {
      Issue.record("got \(refused)")
      return
    }
    guard case .refused = host.core.handle(.write(id: id, bytes: bytes("x\n")), from: second).first
    else {
      Issue.record("a write from another app went through")
      return
    }
    #expect(host.inbox.of(second).isEmpty)

    host.core.disconnected(first)
    #expect(await eventually { host.inbox.of(second) == [.released(id: id)] })
    #expect(host.held(id)?.attachedApp == nil)
    #expect(host.core.handle(.attach(id: id, from: 0), from: second).isEmpty)
    #expect(host.held(id)?.attachedApp == 2)
  }

  /// A process forgotten is released too: the other apps showing it learn it is gone.
  @Test func acknowledgingTellsTheOtherApps() async throws {
    let host = try Host()
    defer { host.close() }
    let first = host.connect(pid: 1)
    let second = host.connect(pid: 2)
    let id = try host.spawn("/bin/sh", ["-c", "exit 0"], from: first)
    #expect(host.core.handle(.attach(id: id, from: 0), from: first).isEmpty)
    #expect(await eventually { host.hasExited(id) })
    #expect(host.core.handle(.acknowledge(id: id), from: first).isEmpty)
    #expect(await eventually { host.inbox.of(second) == [.released(id: id)] })
    #expect(!host.inbox.of(first).contains(.released(id: id)))
  }

  /// A quitting app ends an idle process and is gone before its exit: the host forgets it by
  /// itself once it ends, as an acknowledge would, and tells the other apps.
  @Test func aTerminateThatForgetsLeavesNothingOnceEnded() async throws {
    let host = try Host()
    defer { host.close() }
    let first = host.connect(pid: 1)
    let second = host.connect(pid: 2)
    let id = try host.spawn("/bin/cat", from: first)
    #expect(host.core.handle(.terminate(id: id, forget: true), from: first).isEmpty)
    host.core.disconnected(first)

    #expect(await eventually { host.held(id) == nil })
    #expect(!FileManager.default.fileExists(atPath: host.log(id).path))
    #expect(await eventually { host.inbox.of(second) == [.released(id: id)] })
  }

  /// One that had ended already is forgotten at once; a plain terminate keeps what ended.
  @Test func onlyATerminateThatForgetsForgets() async throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 1)
    let kept = try host.spawn("/bin/cat", from: client)
    let ended = try host.spawn("/bin/sh", ["-c", "exit 0"], from: client)
    #expect(host.core.handle(.terminate(id: kept), from: client).isEmpty)
    #expect(await eventually { host.hasExited(kept) && host.hasExited(ended) })

    #expect(host.core.handle(.terminate(id: ended, forget: true), from: client).isEmpty)
    #expect(host.held(ended) == nil)
    #expect(!FileManager.default.fileExists(atPath: host.log(ended).path))
    #expect(host.held(kept)?.running == false)
  }

  @Test func detachingLetsAnotherAppHaveIt() async throws {
    let host = try Host()
    defer { host.close() }
    let first = host.connect(pid: 1)
    let second = host.connect(pid: 2)
    let id = try host.spawn("/bin/cat", from: first)
    #expect(host.core.handle(.attach(id: id, from: 0), from: first).isEmpty)
    guard case .refused = host.core.handle(.detach(id: id), from: second).first else {
      Issue.record("an app detached another's process")
      return
    }

    #expect(host.core.handle(.detach(id: id), from: first).isEmpty)
    #expect(host.held(id)?.attachedApp == nil)
    #expect(await eventually { host.inbox.of(second) == [.released(id: id)] })
    // Nothing the process does now reaches the app that let go, and a second detach is moot.
    let before = host.inbox.of(first).count
    #expect(host.core.handle(.detach(id: id), from: first).isEmpty)
    #expect(host.core.handle(.attach(id: id, from: 0), from: second).isEmpty)
    _ = host.core.handle(.write(id: id, bytes: bytes("later\n")), from: second)
    let later = bytes("later\n")
    #expect(await eventually { host.inbox.records(second).contains { $0.bytes == later } })
    #expect(host.inbox.of(first).count == before)
    #expect(host.held(id)?.attachedApp == 2)
  }

  @Test func idleOnlyWithNothingHeld() async throws {
    let host = try Host()
    defer { host.close() }
    #expect(host.core.isIdle)
    let client = host.connect(pid: 42)
    #expect(!host.core.isIdle)
    let id = try host.spawn("/bin/cat", from: client)
    host.core.disconnected(client)
    #expect(!host.core.isIdle)

    let other = host.connect(pid: 43)
    _ = host.core.handle(.closeInput(id: id), from: other)
    #expect(await eventually { host.hasExited(id) })
    host.core.disconnected(other)
    #expect(!host.core.isIdle)

    let last = host.connect(pid: 44)
    _ = host.core.handle(.acknowledge(id: id), from: last)
    #expect(!host.core.isIdle)
    host.core.disconnected(last)
    #expect(host.core.isIdle)
  }

  @Test func notesAreLoggedNotWritten() async throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 42)
    let id = try host.spawn("/bin/cat", from: client)
    _ = host.core.handle(.attach(id: id, from: 0), from: client)
    #expect(host.core.handle(.note(id: id, bytes: bytes("mark\n")), from: client).isEmpty)
    _ = host.core.handle(.closeInput(id: id), from: client)
    #expect(await eventually { host.inbox.of(client).last == .exited(id: id, status: 0) })
    #expect(host.logged(id).map(\.kind) == [.note])
    #expect(host.logged(id).first?.bytes == bytes("mark\n"))
    #expect(host.inbox.records(client) == host.logged(id))
  }

  @Test func metaIsKeptAsSent() throws {
    let host = try Host()
    defer { host.close() }
    let client = host.connect(pid: 42)
    let id = try host.spawn("/bin/cat", from: client)
    #expect(host.held(id)?.meta == bytes("m"))
    #expect(host.core.handle(.setMeta(id: id, meta: bytes("n")), from: client).isEmpty)
    #expect(host.held(id)?.meta == bytes("n"))
    #expect(
      host.core.handle(.hello(protocol: HostWire.major, appVersion: "1"), from: client).first
        == .welcome(
          protocol: HostWire.major, hostVersion: "test", pid: getpid(), minor: HostWire.minor))
  }
}
