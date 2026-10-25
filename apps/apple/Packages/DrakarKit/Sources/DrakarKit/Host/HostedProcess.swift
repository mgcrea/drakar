import Foundation
import Synchronization

/// An agent's CLI run through the session host: it yields the events `AgentProcess` does,
/// but the process outlives the app. A new one spawns when `start()` is called, not before.
/// One the host already holds is picked up with `replay()`, which returns the whole log, and
/// then `live()`, which carries on from where the replay ended.
///
/// The host logs every line the CLI writes, so `.lines` carries the time the host read each
/// one, as `AgentProcess` does for a pipe, and `.exited` has no `remainder`: the host logged
/// it as a line of its own.
public final class HostedProcess: ProcessTransport, @unchecked Sendable {
  private let client: HostClient
  private let configuration: AgentProcess.Configuration?
  private let meta: Data
  private let events: AsyncStream<AgentProcess.Event>
  private let sink: AsyncStream<AgentProcess.Event>.Continuation
  private let state: Mutex<State>

  private struct State {
    var id: String?
    var started = false
    var running: Bool
    var detached = false
    /// Requests made while the host is still spawning, sent in order once it has.
    var waiting: [@Sendable (String) -> HostRequest] = []
    var pump: Task<Void, Never>?
  }

  /// A new process; `start()` spawns it.
  public init(client: HostClient, configuration: AgentProcess.Configuration, meta: Data) {
    self.client = client
    self.configuration = configuration
    self.meta = meta
    (events, sink) = AsyncStream.makeStream()
    state = Mutex(State(running: false))
  }

  /// A process the host already holds: `replay()`, then `live()`.
  public init(client: HostClient, held: HeldProcess) {
    self.client = client
    configuration = nil
    meta = held.meta
    (events, sink) = AsyncStream.makeStream()
    state = Mutex(State(id: held.id, running: held.running))
  }

  public var id: String? { state.withLock { $0.id } }

  public var isRunning: Bool { state.withLock { $0.running } }

  /// Spawns the process and returns its events. Call once.
  public func start() throws -> AsyncStream<AgentProcess.Event> {
    guard let configuration else { return events }
    let first = state.withLock { state in
      defer { state.started = true }
      state.running = true
      return !state.started
    }
    guard first else { return events }
    let task = Task {
      do {
        let id = try await client.spawn(configuration, meta: meta)
        try spawned(id)
        pump(client.attach(id, from: 0), replaying: nil)
      } catch {
        // Nothing to run: the session sees the CLI end, with why.
        sink.yield(.stderr("The session host could not start the process: \(error)\n"))
        ended(status: -1)
      }
    }
    state.withLock { $0.pump = task }
    return events
  }

  public func send(line: Data) throws {
    guard isRunning else { throw AgentProcess.Failure.notRunning }
    try request { .write(id: $0, bytes: line) }
  }

  /// A mark for the replay of the log: kept with it, written to nothing.
  public func note(_ bytes: Data) {
    try? request { .note(id: $0, bytes: bytes) }
  }

  public func setMeta(_ meta: Data) {
    try? request { .setMeta(id: $0, meta: meta) }
  }

  /// Lets the host forget the process once it has ended and the app has what it left.
  public func acknowledge() {
    try? request { .acknowledge(id: $0) }
  }

  public func closeInput() {
    guard isRunning else { return }
    try? request { .closeInput(id: $0) }
  }

  public func terminate() {
    guard isRunning else { return }
    try? request { .terminate(id: $0) }
  }

  /// Lets go of the process, which runs on in the host for another app, or this one, to pick up.
  public func detach() {
    try? request { .detach(id: $0) }
    let pump = state.withLock { state in
      state.detached = true
      state.running = false
      defer { state.pump = nil }
      return state.pump
    }
    pump?.cancel()
    sink.finish()
  }

  /// Attaches from the start of the log and returns what it holds up to now. Only for a
  /// process the host held already; `live()` then carries on after it. Throws when the host
  /// refuses the attach or the connection ends first.
  public func replay() async throws -> (records: [HostRecord], offset: UInt64) {
    guard let id else { throw HostClient.Failure.unexpected }
    let stream = client.attach(id, from: 0)
    return try await withCheckedThrowingContinuation { continuation in
      pump(stream, replaying: continuation)
    }
  }

  /// What the process does after `replay()`, and nothing before it.
  public func live() -> AsyncStream<AgentProcess.Event> { events }

  // MARK: -

  /// Sends the request for the process, or holds it until the host has spawned it.
  private func request(_ make: @escaping @Sendable (String) -> HostRequest) throws {
    try state.withLock { state in
      if let id = state.id {
        try client.send(make(id))
      } else if state.started {
        state.waiting.append(make)
      } else {
        throw AgentProcess.Failure.notRunning
      }
    }
  }

  private func spawned(_ id: String) throws {
    try state.withLock { state in
      state.id = id
      let waiting = state.waiting
      state.waiting = []
      for make in waiting { try client.send(make(id)) }
    }
  }

  private func ended(status: Int32) {
    state.withLock { $0.running = false }
    sink.yield(.exited(status: status, remainder: Data()))
    sink.finish()
  }

  /// Turns what an attach streams into events. With `replaying`, the records before
  /// `caughtUp` go to it instead, which resumes at `caughtUp`.
  private func pump(
    _ stream: AsyncStream<HostEvent>,
    replaying: CheckedContinuation<(records: [HostRecord], offset: UInt64), any Error>?
  ) {
    let task = Task {
      var replaying = replaying
      var backlog: [HostRecord] = []
      for await event in stream {
        switch event {
        case .record(_, let record):
          if replaying != nil {
            backlog.append(record)
          } else if let event = Self.event(for: record) {
            sink.yield(event)
          }
        case .caughtUp(_, let offset):
          replaying?.resume(returning: (backlog, offset))
          replaying = nil
        case .stderr(_, let text):
          sink.yield(.stderr(text))
        case .exited(_, let status):
          if let waiting = replaying {
            waiting.resume(throwing: HostClient.Failure.unexpected)
          }
          ended(status: status)
          return
        case .refused(let reason):
          if let waiting = replaying {
            waiting.resume(throwing: HostClient.Failure.refused(reason))
            replaying = nil
            sink.finish()
            return
          }
          sink.yield(.stderr("The session host refused: \(reason)\n"))
        case .welcome, .listed, .spawned, .released:
          break
        }
      }
      // The connection ended: the process carries on in the host, so this is no exit.
      replaying?.resume(throwing: HostClient.Failure.disconnected)
      sink.finish()
    }
    state.withLock { state in
      if state.detached { task.cancel() } else { state.pump = task }
    }
  }

  /// What the CLI wrote, as `AgentProcess` yields it. The host keeps each line's `\n`, which
  /// a pipe's reader would have taken off. What the app sent and its own notes are not the
  /// CLI's output.
  private static func event(for record: HostRecord) -> AgentProcess.Event? {
    guard record.kind == .out else { return nil }
    var bytes = record.bytes
    if bytes.last == 0x0A { bytes.removeLast() }
    return .lines([AgentProcess.parse(bytes)], at: record.time)
  }
}
