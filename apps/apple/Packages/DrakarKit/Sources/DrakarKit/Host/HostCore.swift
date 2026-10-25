import Foundation
import Synchronization

/// The session host without its socket (spec §1–§2): the processes it holds, their logs, and
/// which app is attached to each. A transport feeds it `connected`, `handle` and
/// `disconnected`, and sends on what `deliver` is given.
///
/// Every log append happens under the one lock, so an attach reads its backlog and becomes
/// the live receiver in one step: each record reaches the app once, backlog or live.
public final class HostCore: @unchecked Sendable {
  public typealias Client = Int

  private let directory: URL
  private let hostVersion: String
  private let now: @Sendable () -> Date
  /// Delivery happens here, in the order the events were made, and off the lock.
  private let outbox = DispatchQueue(label: "HostCore.deliver")
  private let state = Mutex(State())

  private struct State {
    var deliver: @Sendable (Client, HostEvent) -> Void = { _, _ in }
    var clients: [Client: Int32] = [:]
    var nextClient: Client = 1
    var held: [String: Held] = [:]
    var readingBacklog: (@Sendable () -> Void)?
  }

  private struct Held {
    let child: HostChild
    let log: HostLog
    var meta: Data
    var attached: Client?
    var exitStatus: Int32?
    /// Writes under way. Output read meanwhile waits in `pending`, so a line the CLI wrote
    /// in answer to a write is never logged before the write's `in`.
    var writes = 0
    var pending: [HostChild.Output] = []
    /// A `terminate` asked for it to be forgotten once it ends (`store`).
    var forgets = false
  }

  public init(
    directory: URL, hostVersion: String, now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.directory = directory
    self.hostVersion = hostVersion
    self.now = now
  }

  /// Events for one connected app. Called on one serial queue, in order, never while the
  /// core's lock is held, so it may call back into the core.
  public var deliver: @Sendable (Client, HostEvent) -> Void {
    get { state.withLock { $0.deliver } }
    set { state.withLock { $0.deliver = newValue } }
  }

  /// Tests only: runs during an attach, once its backlog is read and before the catch-up,
  /// with the lock free, to show the read holds nothing up.
  var readingBacklog: (@Sendable () -> Void)? {
    get { state.withLock { $0.readingBacklog } }
    set { state.withLock { $0.readingBacklog = newValue } }
  }

  public func connected(pid: Int32) -> Client {
    state.withLock { state in
      let client = state.nextClient
      state.nextClient += 1
      state.clients[client] = pid
      return client
    }
  }

  /// Detaches the app from its processes, which carry on, and tells the other apps so.
  public func disconnected(_ client: Client) {
    withState { state, out in
      guard state.clients.removeValue(forKey: client) != nil else { return }
      for (id, held) in state.held where held.attached == client {
        state.held[id]?.attached = nil
        for other in state.clients.keys { out.send(other, .released(id: id)) }
      }
    }
  }

  /// Removes every log in `directory` but those of what the core holds: a host killed
  /// (logout, reboot, a crash) leaves all of its own, which no host holds any more.
  func removeLogsNotHeld(in directory: URL) {
    let held = state.withLock { Set($0.held.keys.map { "\($0).log" }) }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasSuffix(".log") && !held.contains(name) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  /// No process held, running or ended and unacknowledged, and no app connected.
  public var isIdle: Bool { state.withLock { $0.held.isEmpty && $0.clients.isEmpty } }

  /// The direct replies to `request`. What an attach streams (backlog, `caughtUp`, then live
  /// records, stderr and the exit) goes through `deliver` instead, so it stays in order.
  /// A `write` returns once the CLI has taken the bytes, which waits on a CLI slow to read.
  public func handle(_ request: HostRequest, from client: Client) -> [HostEvent] {
    switch request {
    case .hello:
      // The host's major, whatever the app's: an app reading an older host only lists.
      return [.welcome(protocol: HostWire.major, hostVersion: hostVersion, pid: getpid())]
    case .list:
      return [.listed(list())]
    case .spawn(let configuration, let meta):
      return [spawn(configuration, meta: meta)]
    case .attach(let id, let from):
      return attach(id, from: from, client: client)
    case .write(let id, let bytes):
      return write(id, bytes: bytes, from: client)
    case .note(let id, let bytes):
      return update(id, from: client) { held, out in
        self.append(.note, bytes, to: id, &held, &out)
      }
    case .closeInput(let id):
      return withChild(id, from: client) { $0.closeInput() }
    case .terminate(let id, let forget):
      return terminate(id, forgetting: forget == true, from: client)
    case .setMeta(let id, let meta):
      return update(id, from: client) { held, _ in held.meta = meta }
    case .acknowledge(let id):
      return acknowledge(id, from: client)
    case .detach(let id):
      return detach(id, from: client)
    }
  }

  // MARK: - Requests

  private func list() -> [HeldProcess] {
    state.withLock { state in
      state.held.map { id, held in
        HeldProcess(
          id: id, meta: held.meta, running: held.exitStatus == nil,
          exitStatus: held.exitStatus, logLength: held.log.length,
          attachedApp: held.attached.flatMap { state.clients[$0] })
      }
      .sorted { $0.id < $1.id }
    }
  }

  private func spawn(_ configuration: AgentProcess.Configuration, meta: Data) -> HostEvent {
    let id = UUID().uuidString
    let url = directory.appendingPathComponent("\(id).log")
    let child = HostChild(configuration)
    do {
      let log = try HostLog(url: url)
      state.withLock { $0.held[id] = Held(child: child, log: log, meta: meta) }
      try child.start { [weak self] output in self?.received(output, from: id) }
      return .spawned(id: id)
    } catch {
      let log = state.withLock { $0.held.removeValue(forKey: id)?.log }
      try? log?.remove()
      return .refused(reason: "could not start \(configuration.executable.path): \(error)")
    }
  }

  /// The backlog up to where the log ended is read off the lock, so a long log stalls no
  /// other process. Under it, the records logged meanwhile are read, and the app becomes the
  /// live receiver: a record is in the backlog, in that catch-up, or live, exactly once.
  private func attach(_ id: String, from offset: UInt64, client: Client) -> [HostEvent] {
    var found: (log: HostLog, hook: (@Sendable () -> Void)?)?
    let refused = state.withLock { state -> [HostEvent] in
      if let refusal = Self.refusal(attaching: id, by: client, in: state) { return [refusal] }
      found = state.held[id].map { ($0.log, state.readingBacklog) }
      return []
    }
    guard let found else { return refused }
    let snapshot = found.log.length
    let backlog: [HostRecord]
    do {
      backlog = try found.log.records(from: offset, to: snapshot)
    } catch {
      return [Self.unreadable(id, from: offset, error)]
    }
    found.hook?()

    return withState { state, out in
      // Taken by another app or acknowledged meanwhile: this app was sent nothing yet.
      if let refusal = Self.refusal(attaching: id, by: client, in: state) { return [refusal] }
      guard var held = state.held[id] else { return [Self.unknown(id)] }
      let meanwhile: [HostRecord]
      do {
        meanwhile = try held.log.records(from: max(offset, snapshot))
      } catch {
        return [Self.unreadable(id, from: offset, error)]
      }
      held.attached = client
      for record in backlog + meanwhile { out.send(client, .record(id: id, record)) }
      out.send(client, .caughtUp(id: id, offset: held.log.length))
      if let status = held.exitStatus {
        let tail = held.child.stderrTail
        if !tail.isEmpty {
          out.send(client, .stderr(id: id, text: String(decoding: tail, as: UTF8.self)))
        }
        out.send(client, .exited(id: id, status: status))
      }
      state.held[id] = held
      return []
    }
  }

  private static func refusal(attaching id: String, by client: Client, in state: State)
    -> HostEvent?
  {
    guard state.clients[client] != nil else { return .refused(reason: "not connected") }
    guard let held = state.held[id] else { return unknown(id) }
    if let other = held.attached, other != client { return taken(id) }
    return nil
  }

  private static func unreadable(_ id: String, from offset: UInt64, _ error: any Error)
    -> HostEvent
  {
    .refused(reason: "could not read \(id)'s log from \(offset): \(error)")
  }

  /// Written to stdin first, off the lock (a CLI that reads slowly must not stall every
  /// other process), then logged as `in`: only a logged `in` says the bytes were sent.
  private func write(_ id: String, bytes: Data, from client: Client) -> [HostEvent] {
    var child: HostChild?
    let refused = update(id, from: client) { held, _ in
      held.writes += 1
      child = held.child
    }
    guard let child else { return refused }
    var failure: (any Error)?
    do { try child.write(bytes) } catch { failure = error }
    let forgotten = withState { state, out -> HostLog? in
      guard var held = state.held[id] else { return nil }
      held.writes -= 1
      if failure == nil { append(.in, bytes, to: id, &held, &out) }
      if held.writes == 0 {
        let pending = held.pending
        held.pending = []
        for output in pending { take(output, from: id, &held, &out) }
      }
      return store(held, as: id, in: &state, &out)
    }
    try? forgotten?.remove()
    return failure.map { [.refused(reason: "could not write to \(id): \($0)")] } ?? []
  }

  /// Off the lock, as `withChild` does. One that ended already and is to be forgotten is
  /// forgotten now, and sent nothing.
  private func terminate(_ id: String, forgetting: Bool, from client: Client) -> [HostEvent] {
    var child: HostChild?
    var forgotten: HostLog?
    let refused = withState { state, out -> [HostEvent] in
      guard var held = state.held[id] else { return [Self.unknown(id)] }
      if let other = held.attached, other != client { return [Self.taken(id)] }
      if held.exitStatus == nil { child = held.child }
      if forgetting { held.forgets = true }
      forgotten = store(held, as: id, in: &state, &out)
      return []
    }
    try? forgotten?.remove()
    child?.terminate()
    return refused
  }

  /// The other apps are told it is `released`: nobody holds it any more, and it is gone.
  private func acknowledge(_ id: String, from client: Client) -> [HostEvent] {
    var ended: Held?
    let refused = withState { state, out -> [HostEvent] in
      guard let held = state.held[id] else { return [Self.unknown(id)] }
      if let other = held.attached, other != client { return [Self.taken(id)] }
      guard held.exitStatus != nil else { return [.refused(reason: "\(id) is still running")] }
      ended = state.held.removeValue(forKey: id)
      for other in state.clients.keys where other != client { out.send(other, .released(id: id)) }
      return []
    }
    try? ended?.log.remove()
    return refused
  }

  /// Nobody attached already makes it moot; another app's attach is not the caller's to end.
  private func detach(_ id: String, from client: Client) -> [HostEvent] {
    withState { state, out in
      guard state.held[id] != nil else { return [Self.unknown(id)] }
      guard let attached = state.held[id]?.attached else { return [] }
      if attached != client { return [Self.taken(id)] }
      state.held[id]?.attached = nil
      for other in state.clients.keys where other != client { out.send(other, .released(id: id)) }
      return []
    }
  }

  /// Runs `change` on a process the app may act on: one nobody is attached to, or its own.
  private func update(
    _ id: String, from client: Client,
    _ change: (inout Held, _ out: inout Outgoing) -> Void
  ) -> [HostEvent] {
    withState { state, out in
      guard var held = state.held[id] else { return [Self.unknown(id)] }
      if let other = held.attached, other != client { return [Self.taken(id)] }
      change(&held, &out)
      state.held[id] = held
      return []
    }
  }

  /// `action` on the child off the lock: closing stdin waits for a write under way.
  private func withChild(
    _ id: String, from client: Client, _ action: (HostChild) -> Void
  ) -> [HostEvent] {
    var child: HostChild?
    let refused = update(id, from: client) { held, _ in child = held.child }
    child.map(action)
    return refused
  }

  // MARK: - The process's output

  private func received(_ output: HostChild.Output, from id: String) {
    let forgotten = withState { state, out -> HostLog? in
      guard var held = state.held[id] else { return nil }
      if held.writes > 0 {
        held.pending.append(output)
      } else {
        take(output, from: id, &held, &out)
      }
      return store(held, as: id, in: &state, &out)
    }
    try? forgotten?.remove()
  }

  /// Puts `held` back, unless it has ended and is to be forgotten: then it goes as an
  /// `acknowledge` takes it, the apps but the one attached told it is `released`, and its log
  /// is returned to be removed off the lock.
  private func store(
    _ held: Held, as id: String, in state: inout State, _ out: inout Outgoing
  ) -> HostLog? {
    guard held.forgets, held.exitStatus != nil else {
      state.held[id] = held
      return nil
    }
    state.held[id] = nil
    for other in state.clients.keys where other != held.attached {
      out.send(other, .released(id: id))
    }
    return held.log
  }

  private func take(
    _ output: HostChild.Output, from id: String, _ held: inout Held,
    _ out: inout Outgoing
  ) {
    switch output {
    case .line(let bytes):
      append(.out, bytes, to: id, &held, &out)
    case .stderr(let bytes):
      // Past the exit the app has been told all; the tail still keeps it.
      guard held.exitStatus == nil, let client = held.attached else { return }
      out.send(client, .stderr(id: id, text: String(decoding: bytes, as: UTF8.self)))
    case .exited(let status):
      held.exitStatus = status
      if let client = held.attached { out.send(client, .exited(id: id, status: status)) }
    }
  }

  /// A record the log could not take is lost to the replay; the app attached still gets
  /// nothing out of order, since it never had it.
  private func append(
    _ kind: HostRecord.Kind, _ bytes: Data, to id: String, _ held: inout Held,
    _ out: inout Outgoing
  ) {
    guard
      let record = try? held.log.append(
        kind, bytes: bytes, time: now(), attached: held.attached != nil)
    else { return }
    if let client = held.attached { out.send(client, .record(id: id, record)) }
  }

  // MARK: - The lock

  private struct Outgoing {
    var events: [(Client, HostEvent)] = []
    mutating func send(_ client: Client, _ event: HostEvent) { events.append((client, event)) }
  }

  /// `body` under the lock, with `out` queuing an event for delivery. The batch is handed
  /// to the outbox before the lock is let go, so delivery keeps the order the log has.
  private func withState<T>(
    _ body: (inout State, _ out: inout Outgoing) -> T
  ) -> T {
    state.withLock { state in
      var out = Outgoing()
      let result = body(&state, &out)
      if !out.events.isEmpty {
        let deliver = state.deliver
        let events = out.events
        outbox.async { for (client, event) in events { deliver(client, event) } }
      }
      return result
    }
  }

  private static func unknown(_ id: String) -> HostEvent { .refused(reason: "no process \(id)") }

  private static func taken(_ id: String) -> HostEvent {
    .refused(reason: "\(id) is attached to another app")
  }
}
