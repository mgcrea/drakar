import Foundation
import Synchronization

/// The app's side of the session host's socket: one connection for every process the app
/// holds there. Each request carries an id its answer names; what an attach streams is
/// routed by the process's id to that attach's stream.
public final class HostClient: @unchecked Sendable {
  public enum Failure: Error, Equatable {
    /// The connection ended before the answer came.
    case disconnected
    case refused(String)
    /// The host answered with something the request does not ask for.
    case unexpected
  }

  /// `released {id}` as the host sends it: the app attached to `id` left.
  public let released: AsyncStream<String>
  /// Yields once, when the connection ends, whoever ended it.
  public let disconnected: AsyncStream<Void>

  private let connection: UnixConnection
  private let releasedSink: AsyncStream<String>.Continuation
  private let disconnectedSink: AsyncStream<Void>.Continuation
  private let state = Mutex(State())

  private struct State {
    var nextID = 1
    var waiting: [Int: Waiting] = [:]
    var streams: [String: AsyncStream<HostEvent>.Continuation] = [:]
    var closed = false
  }

  private enum Waiting {
    case reply(CheckedContinuation<[HostEvent], any Error>)
    /// An attach or a `send` naming a process: a refusal goes to that process's stream, and
    /// ends it for an attach.
    case process(String, isAttach: Bool)
    case nothing
  }

  /// Throws when nothing answers: no socket, or one a dead host left.
  public static func connect(socket: URL) throws -> HostClient {
    HostClient(UnixConnection(fd: try UnixSocket.connected(to: socket), label: "HostClient"))
  }

  private init(_ connection: UnixConnection) {
    self.connection = connection
    (released, releasedSink) = AsyncStream.makeStream()
    (disconnected, disconnectedSink) = AsyncStream.makeStream()
    connection.start(
      line: { [weak self] line in self?.received(line) },
      closed: { [weak self] in self?.ended() })
  }

  deinit { connection.close() }

  public func hello(appVersion: String) async throws -> (
    protocol: Int, hostVersion: String, pid: Int32
  ) {
    let replies = try await ask(.hello(protocol: HostWire.major, appVersion: appVersion))
    guard case .welcome(let major, let hostVersion, let pid)? = replies.first else {
      throw Self.failure(replies)
    }
    return (major, hostVersion, pid)
  }

  public func list() async throws -> [HeldProcess] {
    let replies = try await ask(.list)
    guard case .listed(let held)? = replies.first else { throw Self.failure(replies) }
    return held
  }

  /// The new process's id.
  public func spawn(_ configuration: AgentProcess.Configuration, meta: Data) async throws
    -> String
  {
    let replies = try await ask(.spawn(configuration, meta: meta))
    guard case .spawned(let id)? = replies.first else { throw Self.failure(replies) }
    return id
  }

  /// The log from `offset`, `caughtUp`, then live records, stderr and the exit, which ends
  /// the stream. A refused attach yields the `refused` and ends; so does the connection's
  /// end. Attaching again to `id` ends the stream before.
  public func attach(_ id: String, from offset: UInt64) -> AsyncStream<HostEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: HostEvent.self)
    let registered = state.withLock { state -> (Int, AsyncStream<HostEvent>.Continuation?)? in
      guard !state.closed else { return nil }
      let before = state.streams.updateValue(continuation, forKey: id)
      return (Self.register(.process(id, isAttach: true), in: &state), before)
    }
    guard let (request, before) = registered else {
      continuation.finish()
      return stream
    }
    before?.finish()
    // A failed write means the connection is ending, which ends the stream.
    write(.init(id: request, request: .attach(id: id, from: offset)))
    return stream
  }

  /// For write, note, closeInput, terminate, setMeta and acknowledge: queued, not awaited.
  /// A refusal shows up in the process's `attach` stream, if it has one. Throws once the
  /// connection has ended.
  public func send(_ request: HostRequest) throws {
    // What the host streams after a detach is not for this app: the attach ends here.
    if case .detach(let id) = request {
      state.withLock { $0.streams.removeValue(forKey: id) }?.finish()
    }
    let waiting = request.process.map { Waiting.process($0, isAttach: false) } ?? .nothing
    let id = state.withLock { state -> Int? in
      guard !state.closed else { return nil }
      return Self.register(waiting, in: &state)
    }
    guard let id, write(.init(id: id, request: request)) else { throw Failure.disconnected }
  }

  /// Hands the socket what `send` queued before returning: an app that is quitting would
  /// otherwise exit with it unsent.
  public func flush() {
    connection.flushNow()
  }

  public func close() {
    connection.close()
  }

  // MARK: - Requests

  private func ask(_ request: HostRequest) async throws -> [HostEvent] {
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      return state.nextID
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let registered = state.withLock { state in
          guard !state.closed else { return false }
          state.waiting[id] = .reply(continuation)
          return true
        }
        guard registered else { return continuation.resume(throwing: Failure.disconnected) }
        if Task.isCancelled { return resolve(id, with: .failure(CancellationError())) }
        if !write(.init(id: id, request: request)) {
          resolve(id, with: .failure(Failure.disconnected))
        }
      }
    } onCancel: {
      resolve(id, with: .failure(CancellationError()))
    }
  }

  private static func register(_ waiting: Waiting, in state: inout State) -> Int {
    let id = state.nextID
    state.nextID += 1
    state.waiting[id] = waiting
    return id
  }

  /// Whoever takes the continuation out of `waiting` resumes it: the answer, the end of the
  /// connection, or a cancellation.
  private func resolve(_ id: Int, with result: Result<[HostEvent], any Error>) {
    guard case .reply(let continuation)? = state.withLock({ $0.waiting.removeValue(forKey: id) })
    else { return }
    continuation.resume(with: result)
  }

  @discardableResult
  private func write(_ frame: HostFrame.Request) -> Bool {
    guard let line = try? JSONEncoder().encode(frame) else { return false }
    return connection.send(line)
  }

  private static func failure(_ replies: [HostEvent]) -> Failure {
    if case .refused(let reason)? = replies.first { return .refused(reason) }
    return .unexpected
  }

  // MARK: - What the host sends, on the connection's queue

  private func received(_ line: Data) {
    guard let answer = try? JSONDecoder().decode(HostFrame.Answer.self, from: line) else {
      return
    }
    guard let id = answer.to else {
      for event in answer.events { route(event) }
      return
    }
    switch state.withLock({ $0.waiting.removeValue(forKey: id) }) {
    case .reply(let continuation):
      continuation.resume(returning: answer.events)
    case .process(let process, let isAttach):
      let refusals = answer.events.filter {
        if case .refused = $0 { true } else { false }
      }
      if !refusals.isEmpty { yield(refusals, to: process, finishing: isAttach) }
    case .nothing, nil:
      break
    }
  }

  private func route(_ event: HostEvent) {
    switch event {
    case .record(let id, _), .caughtUp(let id, _), .stderr(let id, _):
      yield([event], to: id, finishing: false)
    case .exited(let id, _):
      yield([event], to: id, finishing: true)
    case .released(let id):
      releasedSink.yield(id)
    case .welcome, .listed, .spawned, .refused:
      break
    }
  }

  private func yield(_ events: [HostEvent], to id: String, finishing: Bool) {
    let stream = state.withLock { state in
      finishing ? state.streams.removeValue(forKey: id) : state.streams[id]
    }
    for event in events { stream?.yield(event) }
    if finishing { stream?.finish() }
  }

  private func ended() {
    let (waiting, streams) = state.withLock { state in
      state.closed = true
      defer {
        state.waiting = [:]
        state.streams = [:]
      }
      return (state.waiting, state.streams)
    }
    for case .reply(let continuation) in waiting.values {
      continuation.resume(throwing: Failure.disconnected)
    }
    for stream in streams.values { stream.finish() }
    releasedSink.finish()
    disconnectedSink.yield()
    disconnectedSink.finish()
  }
}

extension HostRequest {
  /// The process the request is about, if it names one.
  fileprivate var process: String? {
    switch self {
    case .attach(let id, _), .write(let id, _), .note(let id, _), .closeInput(let id),
      .terminate(let id), .setMeta(let id, _), .acknowledge(let id), .detach(let id):
      id
    case .hello, .list, .spawn:
      nil
    }
  }
}
