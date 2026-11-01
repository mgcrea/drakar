import Foundation
import Synchronization

/// The runner's relay once its facts are out (spec §1): bytes from ssh's stdin to the host's
/// socket and from the socket to ssh's stdout, never parsed, so the host's protocol can move
/// without the relay knowing.
public enum Relay {
  public enum End: Equatable, Sendable {
    /// The ssh side ended: stdin reached EOF, or stdout no longer takes bytes.
    case inputClosed
    /// The host's socket reached EOF or failed.
    case socketClosed
  }

  /// A descriptor connected to the host's socket at `url`, for `pump`: non-blocking, writes
  /// to a host that left fail rather than raise SIGPIPE, and close-on-exec, so the `open`
  /// the relay may spawn does not keep the connection. Throws when nothing listens there,
  /// and `HostWire.PathTooLong` for a path `sun_path` cannot hold. The caller closes it.
  public static func connectedSocket(to url: URL) throws -> Int32 {
    try UnixSocket.connected(to: url)
  }

  /// Copies `input` → `socket` and `socket` → `output` until either side ends, and says
  /// which ended first. The socket's write side is shut as soon as it does, so the host sees
  /// the app leave even before the caller closes it.
  ///
  /// Returns once both directions have stopped, so nothing touches the three descriptors
  /// after it returns; the caller still owns and closes them. They may be blocking or not,
  /// pipes or sockets: ssh hands the relay either. A write to a reader that left fails
  /// rather than raising SIGPIPE, whatever the process does with that signal; for an output
  /// that is not a socket, that is `F_SETNOSIGPIPE`, which stays set on its file description
  /// after the pump returns.
  public static func pump(input: Int32, output: Int32, socket: Int32) async -> End {
    await withCheckedContinuation { continuation in
      guard let pump = Pump(socket: socket, done: { continuation.resume(returning: $0) }) else {
        // No descriptor left for the wake pipe, which a relay holding a handful never sees.
        shutdown(socket, SHUT_RDWR)
        return continuation.resume(returning: .socketClosed)
      }
      let up = Destination(socket)
      let down = Destination(output)
      Thread.detachNewThread {
        pump.stopped(
          pump.copy(from: input, to: up).map { $0 == .source ? .inputClosed : .socketClosed })
      }
      Thread.detachNewThread {
        pump.stopped(
          pump.copy(from: socket, to: down).map { $0 == .source ? .socketClosed : .inputClosed })
      }
    }
  }

  /// Where a direction writes. A pipe takes `F_SETNOSIGPIPE`, but a socket refuses it, and
  /// refuses `SO_NOSIGPIPE` once its peer has gone, so a socket is written with
  /// `MSG_NOSIGNAL` instead.
  private struct Destination: Sendable {
    let fd: Int32
    let isSocket: Bool

    init(_ fd: Int32) {
      self.fd = fd
      var info = stat()
      isSocket = fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
      if !isSocket { _ = fcntl(fd, F_SETNOSIGPIPE, 1) }
    }

    func write(_ bytes: UnsafeRawPointer, _ count: Int) -> Int {
      isSocket ? send(fd, bytes, count, MSG_NOSIGNAL) : Darwin.write(fd, bytes, count)
    }
  }

  /// The two directions' threads. Each blocks only in `poll`, which also waits on the wake
  /// pipe, or in a write; the first to stop shuts the socket's write side, which fails a
  /// write blocked on the socket, and wakes the other.
  private final class Pump: Sendable {
    enum Stop { case source, destination }

    private let socket: Int32
    /// Readable once the first direction stops; closed when both have.
    private let wake: (read: Int32, write: Int32)
    private let state = Mutex<(first: End?, running: Int)>((nil, 2))
    private let done: @Sendable (End) -> Void

    init?(socket: Int32, done: @escaping @Sendable (End) -> Void) {
      var fds: [Int32] = [0, 0]
      guard pipe(&fds) == 0 else { return nil }
      // Not inherited by anything the relay spawns.
      for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
      self.socket = socket
      wake = (fds[0], fds[1])
      self.done = done
    }

    /// One direction's end: what stopped it, or nil when the other direction's end woke it.
    ///
    /// The first end shuts the socket and wakes the other direction under the lock, so the
    /// other cannot be the last to stop, close the wake pipe and let `pump` return in
    /// between: nothing may touch the caller's socket after that. Neither call blocks: one
    /// byte into an empty pipe, and a shutdown.
    func stopped(_ end: End?) {
      let (first, isLast) = state.withLock { state in
        if state.first == nil, let end {
          state.first = end
          shutdown(socket, SHUT_WR)
          var byte: UInt8 = 0
          _ = Darwin.write(wake.write, &byte, 1)
        }
        state.running -= 1
        return (state.first, state.running == 0)
      }
      if isLast {
        Darwin.close(wake.read)
        Darwin.close(wake.write)
        // A direction stops without an end only once the other has had one.
        done(first ?? .socketClosed)
      }
    }

    /// Copies until `source` ends or fails, or `destination` fails; nil when woken first.
    func copy(from source: Int32, to destination: Destination) -> Stop? {
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      return buffer.withUnsafeMutableBytes { buffer -> Stop? in
        while true {
          switch wait(for: source, Int16(POLLIN)) {
          case .ready: break
          case .woken: return nil
          case .failed: return .source
          }
          let count = read(source, buffer.baseAddress, buffer.count)
          if count < 0, errno == EINTR || errno == EAGAIN { continue }
          guard count > 0 else { return .source }
          var written = 0
          while written < count {
            let wrote = destination.write(buffer.baseAddress! + written, count - written)
            if wrote > 0 {
              written += wrote
            } else if wrote < 0, errno == EAGAIN {
              switch wait(for: destination.fd, Int16(POLLOUT)) {
              case .ready: break
              case .woken: return nil
              case .failed: return .destination
              }
            } else if wrote == 0 || errno != EINTR {
              // A failure, or a write that took nothing and would only repeat.
              return .destination
            }
          }
        }
      }
    }

    private enum Wait { case ready, woken, failed }

    /// Until `fd` is ready for `events`, or the wake pipe is readable first. A failed poll
    /// ends the direction rather than going on to a read that could block past the wake.
    private func wait(for fd: Int32, _ events: Int16) -> Wait {
      var fds = [
        pollfd(fd: fd, events: events, revents: 0),
        pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0),
      ]
      while poll(&fds, 2, -1) < 0 {
        guard errno == EINTR else { return .failed }
      }
      return fds[1].revents == 0 ? .ready : .woken
    }
  }
}
