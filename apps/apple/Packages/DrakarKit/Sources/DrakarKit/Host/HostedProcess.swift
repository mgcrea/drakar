import Foundation
import Synchronization

/// An agent's CLI run through the session host: it yields the events `AgentProcess` does,
/// but the process outlives the app. A new one spawns when `start()` is called, not before.
/// One the host already holds is picked up with `replay()`, which returns the whole log, and
/// then `live()`, which carries on from where the replay ended. A connection that ends ends
/// the events but not the process: `reattach(on:)` carries on, on a new one, from where the
/// last left off.
///
/// The host logs every line the CLI writes, so `.lines` carries the time the host read each
/// one, as `AgentProcess` does for a pipe, and `.exited` has no `remainder`: the host logged
/// it as a line of its own.
public final class HostedProcess: ProcessTransport, @unchecked Sendable {
  public enum Failure: Error, Equatable {
    /// The host did not say it spawned the process within the spawn limit.
    case noAnswer
    /// The host would not attach the process again: it no longer holds it, or another app has.
    case lost(String)
    /// The host stopped sending a replay's log before the end of it.
    case quiet
  }

  private let configuration: AgentProcess.Configuration?
  private let meta: Data
  private let spawnLimit: Duration
  private let state: Mutex<State>

  private struct State {
    /// The connection now: a new one after `reattach(on:)`.
    var client: HostClient
    /// The events of the attach now.
    var events: AsyncStream<AgentProcess.Event>
    var sink: AsyncStream<AgentProcess.Event>.Continuation
    /// Where the log ended at the last `caughtUp`, and the last record delivered since: an
    /// attach on a new connection starts at the later, which sends that record again.
    var caughtUp: UInt64 = 0
    var delivered: UInt64?
    var id: String?
    var started = false
    var running: Bool
    var detached = false
    var startFailure: (any Error)?
    /// The live stream brought the process's exit.
    var exited = false
    /// `forgetWhenEnded()` was asked: the exit is acknowledged as it comes.
    var forgets = false
    /// Requests made while the host is still spawning, sent in order once it has.
    var waiting: [@Sendable (String) -> HostRequest] = []
    var pump: Task<Void, Never>?
  }

  /// A new process; `start()` spawns it, and gives up on a host that has not spawned it
  /// within `spawnLimit`.
  public init(
    client: HostClient, configuration: AgentProcess.Configuration, meta: Data,
    spawnLimit: Duration = .seconds(10)
  ) {
    self.configuration = configuration
    self.meta = meta
    self.spawnLimit = spawnLimit
    let (events, sink) = AsyncStream.makeStream(of: AgentProcess.Event.self)
    state = Mutex(State(client: client, events: events, sink: sink, running: false))
  }

  /// A process the host already holds: `replay()`, then `live()`.
  public init(client: HostClient, held: HeldProcess) {
    configuration = nil
    meta = held.meta
    spawnLimit = .zero
    let (events, sink) = AsyncStream.makeStream(of: AgentProcess.Event.self)
    state = Mutex(
      State(client: client, events: events, sink: sink, id: held.id, running: held.running))
  }

  public var id: String? { state.withLock { $0.id } }

  public var isRunning: Bool { state.withLock { $0.running } }

  /// Why the host never started the process, once its events have ended for that reason:
  /// what `AgentProcess.start()` would have thrown, which no event says.
  public var startFailure: (any Error)? { state.withLock { $0.startFailure } }

  /// Spawns the process and returns its events. Call once.
  public func start() throws -> AsyncStream<AgentProcess.Event> {
    let (events, client) = state.withLock { ($0.events, $0.client) }
    guard let configuration else { return events }
    let first = state.withLock { state in
      defer { state.started = true }
      state.running = true
      return !state.started
    }
    guard first else { return events }
    let task = Task {
      do {
        let id = try await spawn(configuration, on: client)
        try spawned(id)
        guard !state.withLock({ $0.detached }) else { return }
        pump(client.attach(id, from: 0), on: client, replaying: nil)
      } catch {
        state.withLock { $0.startFailure = error }
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

  /// Lets the host forget the process and its log once it has ended: now if its exit has
  /// come, else when it does, even with nobody reading `start()`'s events any more. For an
  /// app done with the process, never one handing it over. A `terminate()` after it asks the
  /// host to forget it by itself, for an app that may be gone by the exit.
  public func forgetWhenEnded() {
    let now = state.withLock { state in
      defer { state.forgets = true }
      return state.exited && !state.forgets
    }
    if now { acknowledge() }
  }

  public func closeInput() {
    guard isRunning else { return }
    try? request { .closeInput(id: $0) }
  }

  public func terminate() {
    guard isRunning else { return }
    let forget = state.withLock { $0.forgets } ? true : nil
    try? request { .terminate(id: $0, forget: forget) }
  }

  /// Lets go of the process, which runs on in the host for another app, or this one, to pick up.
  public func detach() {
    try? request { .detach(id: $0) }
    let (pump, sink) = state.withLock { state in
      state.detached = true
      state.running = false
      defer { state.pump = nil }
      return (state.pump, state.sink)
    }
    pump?.cancel()
    sink.finish()
  }

  /// Attaches from the start of the log and returns what it holds up to now. Only for a
  /// process the host held already; `live()` then carries on after it. Throws when the host
  /// refuses the attach or the connection ends first, and `Failure.quiet` when the host sends
  /// nothing of the log for `quietLimit`: bounded by silence, not by time, as a long log takes
  /// seconds. A quiet host's process is let go of, for the next launch to take.
  public func replay(quietLimit: Duration = .seconds(10)) async throws -> (
    records: [HostRecord], offset: UInt64
  ) {
    let (id, client) = state.withLock { ($0.id, $0.client) }
    guard let id else { throw HostClient.Failure.unexpected }
    let stream = client.attach(id, from: 0)
    return try await withCheckedThrowingContinuation { continuation in
      let replaying = Replaying(continuation)
      pump(stream, on: client, replaying: replaying)
      Task { [weak self] in
        while !replaying.isDone {
          try? await Task.sleep(for: min(quietLimit / 4, .seconds(1)))
          guard replaying.quietFor >= quietLimit, replaying.resume(with: .failure(Failure.quiet))
          else { continue }
          self?.detach()
        }
      }
    }
  }

  /// What the process does after `replay()`, and nothing before it.
  public func live() -> AsyncStream<AgentProcess.Event> { state.withLock { $0.events } }

  /// Attaches again on `client`, the connection the events came on having ended: what the
  /// process did meanwhile and after, each line once. Requests go on `client` from now on.
  public func reattach(on client: HostClient) -> AsyncStream<AgentProcess.Event> {
    let (events, sink) = AsyncStream.makeStream(of: AgentProcess.Event.self)
    let (id, from, before) = state.withLock { state in
      state.client = client
      state.events = events
      state.sink = sink
      defer { state.pump = nil }
      return (state.id, max(state.caughtUp, state.delivered ?? 0), state.pump)
    }
    before?.cancel()
    guard let id else {
      sink.finish()
      return events
    }
    pump(client.attach(id, from: from), on: client, replaying: nil)
    return events
  }

  // MARK: -

  /// The new process's id, or `Failure.noAnswer` once `spawnLimit` has gone by. A spawn the
  /// host answers after that is ended at once, for nobody holds it.
  private func spawn(_ configuration: AgentProcess.Configuration, on client: HostClient)
    async throws -> String
  {
    let (meta, limit) = (meta, spawnLimit)
    let once = Once()
    return try await withCheckedThrowingContinuation { continuation in
      let timer = Task {
        guard (try? await Task.sleep(for: limit)) != nil, once.claim() else { return }
        continuation.resume(throwing: Failure.noAnswer)
      }
      Task {
        do {
          let id = try await client.spawn(configuration, meta: meta)
          timer.cancel()
          if once.claim() {
            continuation.resume(returning: id)
          } else {
            Self.end(id, on: client)
          }
        } catch {
          timer.cancel()
          if once.claim() { continuation.resume(throwing: error) }
        }
      }
    }
  }

  /// A process nobody holds, ended and then forgotten once its exit has come.
  private static func end(_ id: String, on client: HostClient) {
    let events = client.attach(id, from: 0)
    try? client.send(.terminate(id: id))
    Task {
      for await event in events {
        guard case .exited = event else { continue }
        try? client.send(.acknowledge(id: id))
        return
      }
    }
  }

  /// Sends the request for the process, or holds it until the host has spawned it.
  private func request(_ make: @escaping @Sendable (String) -> HostRequest) throws {
    try state.withLock { state in
      if let id = state.id {
        try state.client.send(make(id))
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
      for make in waiting { try state.client.send(make(id)) }
    }
  }

  private func ended(status: Int32, sink: AsyncStream<AgentProcess.Event>.Continuation) {
    state.withLock { $0.running = false }
    sink.yield(.exited(status: status, remainder: Data()))
    sink.finish()
  }

  private func ended(status: Int32) {
    ended(status: status, sink: state.withLock { $0.sink })
  }

  /// Turns what an attach on `client` streams into events. With `replaying`, the records
  /// before `caughtUp` go to it instead, which resumes at `caughtUp`.
  private func pump(
    _ stream: AsyncStream<HostEvent>, on client: HostClient,
    replaying: Replaying?
  ) {
    let sink = state.withLock { $0.sink }
    let task = Task {
      var replaying = replaying
      var backlog: [HostRecord] = []
      var refusal: String?
      for await event in stream {
        switch event {
        case .record(_, let record):
          // A reattach starts at the last record delivered, which it sends again.
          let isNew = state.withLock { state in
            guard state.delivered.map({ record.offset > $0 }) ?? true else { return false }
            state.delivered = record.offset
            return true
          }
          guard isNew else { continue }
          replaying?.heard()
          if replaying != nil {
            backlog.append(record)
          } else if let event = Self.event(for: record) {
            sink.yield(event)
          }
        case .caughtUp(_, let offset):
          state.withLock { $0.caughtUp = max($0.caughtUp, offset) }
          replaying?.resume(with: .success((backlog, offset)))
          replaying = nil
        case .stderr(_, let text):
          sink.yield(.stderr(text))
        case .exited(_, let status):
          replaying?.resume(with: .failure(HostClient.Failure.unexpected))
          let forgets = state.withLock { state in
            state.exited = true
            return state.forgets
          }
          ended(status: status, sink: sink)
          if forgets { acknowledge() }
          return
        case .refused(let reason):
          if let waiting = replaying {
            waiting.resume(with: .failure(HostClient.Failure.refused(reason)))
            replaying = nil
            sink.finish()
            return
          }
          refusal = reason
          sink.yield(.stderr("The session host refused: \(reason)\n"))
        case .welcome, .listed, .spawned, .released:
          break
        }
      }
      replaying?.resume(with: .failure(HostClient.Failure.disconnected))
      // Let go of, or attached again: these events are no longer the process's.
      guard !Task.isCancelled else { return sink.finish() }
      // The connection ended: the process carries on in the host, so this is no exit.
      guard !client.isClosed else { return sink.finish() }
      // The connection is up, so the host ended the attach: refused, and nothing will come.
      state.withLock { $0.startFailure = Failure.lost(refusal ?? "the attach ended") }
      ended(status: -1, sink: sink)
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

/// A replay's caller, resumed once, by the pump or by a host gone quiet, and when the log was
/// last heard of.
private final class Replaying: Sendable {
  typealias Replay = (records: [HostRecord], offset: UInt64)

  private let state:
    Mutex<(waiting: CheckedContinuation<Replay, any Error>?, heard: ContinuousClock.Instant)>

  init(_ continuation: CheckedContinuation<Replay, any Error>) {
    state = Mutex((continuation, .now))
  }

  var isDone: Bool { state.withLock { $0.waiting == nil } }

  var quietFor: Duration { .now - state.withLock { $0.heard } }

  func heard() {
    state.withLock { $0.heard = .now }
  }

  /// False when it was resumed already.
  @discardableResult func resume(with result: Result<Replay, any Error>) -> Bool {
    let waiting = state.withLock { state in
      defer { state.waiting = nil }
      return state.waiting
    }
    waiting?.resume(with: result)
    return waiting != nil
  }
}

/// True for the first caller only.
private final class Once: Sendable {
  private let claimed = Mutex(false)

  func claim() -> Bool {
    claimed.withLock { claimed in
      defer { claimed = true }
      return !claimed
    }
  }
}
