import Foundation
import Synchronization

/// The session host's socket (spec §1, §2): it lets in the user's own apps, one connection
/// each, hands their requests to the `HostCore` and sends them what it answers and delivers.
///
/// `stop()` lets go of the socket and the apps, never of the processes: a server started
/// again on the directory with the same core carries on with them.
public final class HostServer: @unchecked Sendable {
  private let core: HostCore
  private let socket: URL
  private let lock: Int32
  private let acceptQueue = DispatchQueue(label: "HostServer.accept")
  private let accepting: DispatchSourceRead
  private let peerCheck: @Sendable (Int32) -> Bool
  private let state = Mutex(State())

  private struct Lane: Hashable {
    var client: HostCore.Client
    var id: String
  }

  private struct State {
    var connections: [HostCore.Client: UnixConnection] = [:]
    /// One per connection and process. Every request naming a process but `terminate` runs
    /// on its lane in the order the app sent them, so a detach never overtakes a write nor
    /// is overtaken by the attach after it. Off the connection, since a write waits on a CLI
    /// slow to read: the app's requests to every other process, and other apps', go on
    /// meanwhile. `terminate` stays inline, since killing a CLI is how a stuck write ends.
    var lanes: [Lane: DispatchQueue] = [:]
    var stopped = false
  }

  /// Takes `host.lock` (flock, non-blocking) in `directory`; nil when another host holds it.
  /// `peerCheck` runs only for a peer of the host's own uid.
  public static func start(
    directory: URL, core: HostCore, peerCheck: @escaping @Sendable (_ fd: Int32) -> Bool
  ) throws -> HostServer? {
    try start(directory: directory, core: core, peerCheck: peerCheck, accept: UnixSocket.accept)
  }

  /// `accept` is `UnixSocket.accept` but in tests, which run out of descriptors through it.
  static func start(
    directory: URL, core: HostCore, peerCheck: @escaping @Sendable (_ fd: Int32) -> Bool,
    accept: @escaping @Sendable (_ listener: Int32) -> UnixSocket.Accepted
  ) throws -> HostServer? {
    let socket = try HostWire.socket(in: directory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try UnixSocket.check(chmod(directory.path, 0o700))

    let path = directory.appendingPathComponent("host.lock").path
    // Close-on-exec: a CLI the host spawns must not keep the lock past the host.
    let lock = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    try UnixSocket.check(lock)
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      let error = errno
      Darwin.close(lock)
      if error == EWOULDBLOCK { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
    }
    // Under the lock no other host runs, so a socket here is one a dead host left.
    unlink(socket.path)
    let listener: Int32
    do {
      listener = try UnixSocket.listening(at: socket)
    } catch {
      Darwin.close(lock)
      throw error
    }
    let server = HostServer(
      core: core, socket: socket, lock: lock, listener: listener, peerCheck: peerCheck)
    server.begin(listener, accept: accept)
    return server
  }

  private init(
    core: HostCore, socket: URL, lock: Int32, listener: Int32,
    peerCheck: @escaping @Sendable (Int32) -> Bool
  ) {
    self.core = core
    self.socket = socket
    self.lock = lock
    self.peerCheck = peerCheck
    accepting = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
  }

  /// How long a host out of descriptors waits before accepting again.
  static let exhaustedRetry = DispatchTimeInterval.milliseconds(100)

  deinit { stop() }

  private func begin(
    _ listener: Int32, accept: @escaping @Sendable (Int32) -> UnixSocket.Accepted
  ) {
    core.deliver = { [weak self] client, event in
      self?.send(HostFrame.Answer(to: nil, events: [event]), to: client)
    }
    let accepting = accepting
    let queue = acceptQueue
    accepting.setEventHandler { [weak self] in
      while true {
        switch accept(listener) {
        case .peer(let fd):
          guard let self else {
            Darwin.close(fd)
            return
          }
          self.admit(fd)
        case .drained:
          return
        case .exhausted:
          // The peer stays queued and the listener readable: trying again at once would
          // spin. Resumed even once stopped, since a suspended source never cancels.
          accepting.suspend()
          queue.asyncAfter(deadline: .now() + Self.exhaustedRetry) {
            accepting.resume()
          }
          return
        }
      }
    }
    accepting.setCancelHandler { Darwin.close(listener) }
    accepting.activate()
  }

  /// Closes the socket and every connection, which detaches each app from its processes.
  /// The processes carry on in the core.
  public func stop() {
    let connections = state.withLock { state -> [HostCore.Client: UnixConnection]? in
      guard !state.stopped else { return nil }
      state.stopped = true
      defer { state.connections = [:] }
      return state.connections
    }
    guard let connections else { return }
    accepting.cancel()
    for (client, connection) in connections {
      core.disconnected(client)
      connection.close()
    }
    // Still under the lock, so this is never another host's socket.
    unlink(socket.path)
    Darwin.close(lock)
  }

  // MARK: - Connections

  /// The uid first: `peerCheck` is never shown another user's program.
  private func admit(_ fd: Int32) {
    guard let peer = UnixSocket.peer(of: fd), peer.uid == getuid(), peerCheck(fd),
      (try? UnixSocket.prepare(fd)) != nil
    else {
      Darwin.close(fd)
      return
    }
    let connection = UnixConnection(fd: fd, label: "HostServer.connection")
    let client = core.connected(pid: peer.pid)
    // In the table before anything is read, so no event for it is ever dropped.
    let admitted = state.withLock { state in
      guard !state.stopped else { return false }
      state.connections[client] = connection
      return true
    }
    guard admitted else {
      core.disconnected(client)
      connection.close()
      return
    }
    connection.start(
      line: { [weak self] line in self?.received(line, from: client) },
      closed: { [weak self] in self?.left(client) })
  }

  private func left(_ client: HostCore.Client) {
    state.withLock { state in
      state.connections.removeValue(forKey: client)
      state.lanes = state.lanes.filter { $0.key.client != client }
    }
    core.disconnected(client)
  }

  private func received(_ line: Data, from client: HostCore.Client) {
    let decoder = JSONDecoder()
    guard let frame = try? decoder.decode(HostFrame.Request.self, from: line) else {
      // A newer minor's request: refused, so the app is not left waiting on it.
      if let head = try? decoder.decode(HostFrame.Head.self, from: line) {
        send(.init(to: head.id, events: [.refused(reason: "unknown request")]), to: client)
      }
      return
    }
    switch frame.request {
    case .attach(let id, _), .write(let id, _), .note(let id, _), .closeInput(let id),
      .setMeta(let id, _), .detach(let id):
      lane(id, of: client).async { self.answer(frame, from: client) }
    case .acknowledge(let id):
      lane(id, of: client).async {
        if self.answer(frame, from: client).isEmpty {
          _ = self.state.withLock { $0.lanes.removeValue(forKey: Lane(client: client, id: id)) }
        }
      }
    case .hello, .list, .spawn, .terminate:
      answer(frame, from: client)
    }
  }

  @discardableResult
  private func answer(_ frame: HostFrame.Request, from client: HostCore.Client) -> [HostEvent] {
    let replies = core.handle(frame.request, from: client)
    send(.init(to: frame.id, events: replies), to: client)
    return replies
  }

  private func lane(_ id: String, of client: HostCore.Client) -> DispatchQueue {
    state.withLock { state in
      let key = Lane(client: client, id: id)
      if let lane = state.lanes[key] { return lane }
      let lane = DispatchQueue(label: "HostServer.lane")
      state.lanes[key] = lane
      return lane
    }
  }

  /// Queues it on the app's connection, never waiting on the app.
  private func send(_ answer: HostFrame.Answer, to client: HostCore.Client) {
    guard let connection = state.withLock({ $0.connections[client] }),
      let line = try? JSONEncoder().encode(answer)
    else { return }
    connection.send(line)
  }
}
