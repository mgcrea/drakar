import Foundation
import Synchronization

/// The POSIX calls behind the session host's socket. The server and the client make theirs
/// in the one place, so the network audit finds exactly one `AF_UNIX` socket.
enum UnixSocket {
  /// A socket bound at `url`, not listening: binding is what creates the file.
  static func bound(at url: URL) throws -> Int32 {
    let fd = try make()
    do {
      try withAddress(url) { Darwin.bind(fd, $0, $1) }
    } catch {
      Darwin.close(fd)
      throw error
    }
    return fd
  }

  /// Bound, 0600 before anyone can connect, listening and non-blocking.
  static func listening(at url: URL) throws -> Int32 {
    let fd = try bound(at: url)
    do {
      try check(chmod(url.path, 0o600))
      try check(Darwin.listen(fd, 16))
      try check(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK))
    } catch {
      Darwin.close(fd)
      throw error
    }
    return fd
  }

  /// Throws when nothing listens there: no file, or one a dead host left.
  static func connected(to url: URL) throws -> Int32 {
    let fd = try make()
    do {
      try withAddress(url) { Darwin.connect(fd, $0, $1) }
      try prepare(fd)
    } catch {
      Darwin.close(fd)
      throw error
    }
    return fd
  }

  enum Accepted: Equatable {
    case peer(Int32)
    /// Nobody else is waiting.
    case drained
    /// A peer waits, but no descriptor is left to take it with (EMFILE, ENFILE).
    case exhausted
  }

  /// A peer waiting on `listener`, close-on-exec at once: `peerCheck` takes time, and a CLI
  /// spawned meanwhile must not inherit the connection.
  static func accept(_ listener: Int32) -> Accepted {
    while true {
      let fd = Darwin.accept(listener, nil, nil)
      if fd >= 0 {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
          Darwin.close(fd)
          continue
        }
        return .peer(fd)
      }
      switch errno {
      case EINTR: continue
      case EMFILE, ENFILE: return .exhausted
      default: return .drained
      }
    }
  }

  /// The peer's uid and pid, as the kernel recorded them when it connected.
  static func peer(of fd: Int32) -> (uid: uid_t, pid: pid_t)? {
    var uid = uid_t()
    var gid = gid_t()
    guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
    var pid = pid_t()
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
    return (uid, pid)
  }

  /// Non-blocking, and a write to a peer that left fails with EPIPE rather than raising
  /// SIGPIPE. Already close-on-exec, from `make` or `accept`: not inherited by the CLIs the
  /// host spawns, which would keep the connection open.
  static func prepare(_ fd: Int32) throws {
    var on: Int32 = 1
    try check(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)))
    try check(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK))
  }

  static func check(_ result: Int32) throws {
    guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  private static func make() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try check(fd)
    do {
      try check(fcntl(fd, F_SETFD, FD_CLOEXEC))
    } catch {
      Darwin.close(fd)
      throw error
    }
    return fd
  }

  private static func withAddress(
    _ url: URL, _ call: (UnsafePointer<sockaddr>, socklen_t) -> Int32
  ) throws {
    var address = sockaddr_un()
    let path = Array(url.path.utf8)
    // Never truncated: a cut path would name some other file.
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw HostWire.PathTooLong(path: url.path)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        call($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try check(result)
  }
}

/// One end of a connection on the socket: lines in, lines out, each ended by `\n`.
///
/// `send` only queues: the connection's own queue writes what the socket takes and waits
/// for it to take more, so no sender ever waits on a peer slow to read.
final class UnixConnection: @unchecked Sendable {
  /// A peer that stops reading (hung, or paused in a debugger) is dropped once this much
  /// waits for it: on the host, the drop detaches it like any lost app, and it reattaches
  /// from its offset. Far above what an attach queues at once, its whole backlog.
  static let sendLimit = 512 << 20

  private let fd: Int32
  private let queue: DispatchQueue
  private let state = Mutex(State())

  private struct State {
    var outgoing = Data()
    /// Bytes `send` took that the socket has not: `outgoing` and what is left of `writing`.
    var queued = 0
    /// A flush is on its way to take `outgoing`, so another `send` need not queue one.
    var flushing = false
    var closed = false
  }

  // The rest is the queue's alone.
  private var reader: DispatchSourceRead?
  private var writer: DispatchSourceWrite?
  private var writerState = WriterState.inactive
  private var writing = Data()
  private var written = 0
  private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
  private var incoming = LineBuffer()
  private var ended = false
  private var cancelled = 0
  private var onLine: (@Sendable (Data) -> Void)?
  private var onClose: (@Sendable () -> Void)?

  /// A dispatch source must be running when it is cancelled, or its cancel handler (which
  /// closes the descriptor) never runs.
  private enum WriterState { case inactive, running, suspended }

  /// Takes `fd`, already `UnixSocket.prepare`d; nothing is read until `start`.
  init(fd: Int32, label: String) {
    self.fd = fd
    queue = DispatchQueue(label: label)
  }

  /// `line` gets each line without its `\n`, in order, on the connection's queue; `closed`
  /// comes once, after the last, however the connection ended. Call once.
  func start(
    line: @escaping @Sendable (Data) -> Void, closed: @escaping @Sendable () -> Void
  ) {
    queue.async { [self] in
      onLine = line
      onClose = closed
      guard !state.withLock({ $0.closed }) else { return end() }
      let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
      // The handlers keep the connection alive until it ends.
      reader.setEventHandler { self.read() }
      writer.setEventHandler { self.flush() }
      for source in [reader, writer] as [any DispatchSourceProtocol] {
        source.setCancelHandler {
          self.cancelled += 1
          if self.cancelled == 2 { Darwin.close(self.fd) }
        }
      }
      self.reader = reader
      self.writer = writer
      reader.activate()
      flush()
    }
  }

  /// Queues `line` and a `\n`. False once the connection is closed, or when the peer has
  /// left `sendLimit` unread, which closes it.
  @discardableResult
  func send(_ line: Data) -> Bool {
    enum Outcome {
      case queued(flush: Bool)
      case closed, overLimit
    }
    let outcome = state.withLock { state -> Outcome in
      guard !state.closed else { return .closed }
      state.outgoing.append(line)
      state.outgoing.append(0x0A)
      state.queued += line.count + 1
      guard state.queued <= Self.sendLimit else { return .overLimit }
      defer { state.flushing = true }
      return .queued(flush: !state.flushing)
    }
    switch outcome {
    case .queued(let flush):
      if flush { queue.async { self.flush() } }
      return true
    case .closed:
      return false
    case .overLimit:
      close()
      return false
    }
  }

  /// Sends nothing more and drops what is still queued.
  func close() {
    state.withLock {
      $0.closed = true
      $0.outgoing = Data()
      $0.queued = 0
    }
    queue.async { self.end() }
  }

  // MARK: - On the queue

  private func read() {
    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    if count < 0, errno == EINTR || errno == EAGAIN { return }
    guard count > 0 else { return end() }
    for line in incoming.append(Data(buffer[..<count])) {
      guard !state.withLock({ $0.closed }) else { return end() }
      onLine?(line)
    }
  }

  private func flush() {
    guard !ended, writer != nil else { return }
    while true {
      if written == writing.count {
        let next = state.withLock { state -> Data? in
          guard !state.closed else { return nil }
          state.flushing = false
          defer { state.outgoing = Data() }
          return state.outgoing
        }
        guard let next else { return end() }
        writing = next
        written = 0
        if writing.isEmpty { return pauseWriter() }
      }
      let count = writing.withUnsafeBytes { bytes in
        Darwin.write(fd, bytes.baseAddress! + written, bytes.count - written)
      }
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN { return resumeWriter() }
        return end()
      }
      written += count
      state.withLock { $0.queued -= count }
    }
  }

  private func resumeWriter() {
    switch writerState {
    case .inactive: writer?.activate()
    case .suspended: writer?.resume()
    case .running: return
    }
    writerState = .running
  }

  private func pauseWriter() {
    guard writerState == .running else { return }
    writer?.suspend()
    writerState = .suspended
  }

  private func end() {
    guard !ended else { return }
    ended = true
    state.withLock {
      $0.closed = true
      $0.outgoing = Data()
      $0.queued = 0
    }
    writing = Data()
    written = 0
    if let reader, let writer {
      reader.cancel()
      resumeWriter()
      writer.cancel()
    } else {
      Darwin.close(fd)
    }
    let closed = onClose
    onLine = nil
    onClose = nil
    closed?()
  }
}
