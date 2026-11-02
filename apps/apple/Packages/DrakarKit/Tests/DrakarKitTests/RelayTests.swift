import Foundation
import Synchronization
import Testing

@testable import DrakarKit

/// `Relay.pump` between two pipes, standing in for ssh's stdin and stdout, and a
/// `socketpair`, standing in for the host's socket.
@Suite(.timeLimit(.minutes(1))) struct RelayTests {
  private struct TimedOut: Error {}

  /// The descriptors of one pump: the pump gets `input.read`, `output.write` and `socket`;
  /// the test plays ssh on the other pipe ends and the host on `peer`.
  private final class Wiring: Sendable {
    let input: (read: Int32, write: Int32)
    let output: (read: Int32, write: Int32)
    let socket: Int32
    let peer: Int32
    /// Each closed once: tests run in parallel, and a second close could take another
    /// test's descriptor that reused the number.
    private let open: Mutex<Set<Int32>>

    init() throws {
      var input: [Int32] = [0, 0]
      var output: [Int32] = [0, 0]
      var socket: [Int32] = [0, 0]
      try #require(pipe(&input) == 0)
      try #require(pipe(&output) == 0)
      try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &socket) == 0)
      self.input = (input[0], input[1])
      self.output = (output[0], output[1])
      self.socket = socket[0]
      peer = socket[1]
      open = Mutex(Set(input + output + socket))
      // The test's own ends: a write to a reader that left fails rather than killing the
      // runner, and nothing blocks, so a broken pump fails the test instead of hanging it.
      var on: Int32 = 1
      setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
      for fd in [input[1], output[0], peer] {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      }
    }

    func pump() -> Task<Relay.End, Never> {
      let (input, output, socket) = (input.read, output.write, socket)
      return Task { await Relay.pump(input: input, output: output, socket: socket) }
    }

    func close(_ fd: Int32) {
      guard open.withLock({ $0.remove(fd) }) != nil else { return }
      Darwin.close(fd)
    }

    deinit {
      for fd in open.withLock({ $0 }) { Darwin.close(fd) }
    }
  }

  /// `body`'s result, or a throw after 5 s: a pump that never ends fails the test. `body` is
  /// not awaited past that, since `pump` cannot be cancelled.
  private func within<T: Sendable>(_ body: @escaping @Sendable () async throws -> T)
    async throws -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      let race = Race(continuation)
      Task {
        do { race.finish(.success(try await body())) } catch { race.finish(.failure(error)) }
      }
      Task {
        try? await Task.sleep(for: .seconds(5))
        race.finish(.failure(TimedOut()))
      }
    }
  }

  /// The first result `within` gets resumes it; the other is dropped.
  private final class Race<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
      self.continuation = Mutex(continuation)
    }

    func finish(_ result: Result<T, any Error>) {
      continuation.withLock { $0.take() }?.resume(with: result)
    }
  }

  /// Runs `body`, which waits in `poll`, on its own thread, off the cooperative pool.
  private static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread { continuation.resume(returning: body()) }
    }
  }

  /// Until the test's non-blocking `fd` is ready for `events`; false after 5 s.
  private static func ready(_ fd: Int32, _ events: Int16) -> Bool {
    var ready = pollfd(fd: fd, events: events, revents: 0)
    while true {
      let count = poll(&ready, 1, 5000)
      if count < 0, errno == EINTR { continue }
      return count > 0
    }
  }

  private static func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
    var sent = 0
    while sent < data.count {
      let count = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, $0.count - sent) }
      if count > 0 {
        sent += count
      } else if count < 0, errno == EAGAIN {
        guard ready(fd, Int16(POLLOUT)) else { return false }
      } else if count == 0 || errno != EINTR {
        return false
      }
    }
    return true
  }

  /// Reads until `count` bytes, EOF, or 5 s without a byte.
  private static func read(_ fd: Int32, count: Int) -> [UInt8] {
    var data: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count < count {
      let got = buffer.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress, min($0.count, count - data.count))
      }
      if got > 0 {
        data += buffer[..<got]
      } else if got < 0, errno == EAGAIN {
        guard ready(fd, Int16(POLLIN)) else { break }
      } else if got == 0 || errno != EINTR {
        break
      }
    }
    return data
  }

  /// Zero once the other end has closed, with nothing left to read.
  private static func readsEOF(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    return ready(fd, Int16(POLLIN)) && Darwin.read(fd, &byte, 1) == 0
  }

  private static func random(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  /// Non-blocking, the socket is as Task 4's relay gets it from `UnixSocket.connected`: the
  /// pump then meets `EAGAIN` and waits for room.
  @Test(arguments: [false, true]) func bytesCrossBothWays(nonBlockingSocket: Bool) async throws {
    let wiring = try Wiring()
    if nonBlockingSocket {
      let flags = fcntl(wiring.socket, F_GETFL)
      try #require(fcntl(wiring.socket, F_SETFL, flags | O_NONBLOCK) == 0)
    }
    let pump = wiring.pump()
    let up = Self.random(1 << 20)
    let down = Self.random(1 << 20)

    let (input, peer, output) = (wiring.input.write, wiring.peer, wiring.output.read)
    let (wroteUp, arrivedUp, wroteDown, arrivedDown) = try await within {
      async let wroteUp = Self.onThread { Self.writeAll(input, up) }
      async let readUp = Self.onThread { Self.read(peer, count: up.count) }
      async let wroteDown = Self.onThread { Self.writeAll(peer, down) }
      async let readDown = Self.onThread { Self.read(output, count: down.count) }
      return await (wroteUp, readUp, wroteDown, readDown)
    }
    #expect(wroteUp)
    #expect(wroteDown)
    #expect(arrivedUp == up)
    #expect(arrivedDown == down)

    wiring.close(wiring.input.write)
    #expect(try await within { await pump.value } == .inputClosed)
  }

  @Test func inputEOFEndsThePump() async throws {
    let wiring = try Wiring()
    let pump = wiring.pump()

    let start = ContinuousClock.now
    wiring.close(wiring.input.write)
    let end = try await within { await pump.value }
    #expect(end == .inputClosed)
    // Prompt, not a hang (`within` catches that): CI's runner once took 1.19 s.
    #expect(ContinuousClock.now - start < .seconds(3))
    let peer = wiring.peer
    #expect(try await within { await Self.onThread { Self.readsEOF(peer) } })
  }

  @Test func socketEOFEndsThePump() async throws {
    let wiring = try Wiring()
    let pump = wiring.pump()

    wiring.close(wiring.peer)
    #expect(try await within { await pump.value } == .socketClosed)
    wiring.close(wiring.output.write)
    let output = wiring.output.read
    #expect(try await within { await Self.onThread { Self.readsEOF(output) } })
  }

  /// ssh no longer takes stdout: the pump ends as for stdin's EOF, without a SIGPIPE.
  @Test func outputGoneEndsThePump() async throws {
    let wiring = try Wiring()
    let pump = wiring.pump()

    wiring.close(wiring.output.read)
    let peer = wiring.peer
    #expect(Self.writeAll(peer, [1, 2, 3]))
    #expect(try await within { await pump.value } == .inputClosed)
    #expect(try await within { await Self.onThread { Self.readsEOF(peer) } })
  }

  /// The relay's way to the host: a connected descriptor no `open` it spawns inherits, and a
  /// throw when nothing listens there.
  @Test func connectsToTheHostsSocket() throws {
    let name = String(UUID().uuidString.prefix(6))
    let directory = URL(fileURLWithPath: "/tmp/dr-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = try HostWire.socket(in: directory)
    #expect(throws: (any Error).self) { try Relay.connectedSocket(to: socket) }

    let listener = try UnixSocket.listening(at: socket)
    defer { close(listener) }
    let fd = try Relay.connectedSocket(to: socket)
    defer { close(fd) }
    #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
    guard case .peer(let peer) = UnixSocket.accept(listener) else {
      Issue.record("nobody connected")
      return
    }
    close(peer)
  }
}
