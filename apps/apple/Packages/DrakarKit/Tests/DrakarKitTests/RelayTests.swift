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
      // The test's own writes to the socket must fail rather than kill the runner.
      var on: Int32 = 1
      setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
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

  /// `body`'s result, or a throw after 5 s: a pump that never ends fails the test.
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

  /// Runs blocking `body` on its own thread, off the cooperative pool.
  private static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread { continuation.resume(returning: body()) }
    }
  }

  private static func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
    var sent = 0
    while sent < data.count {
      let count = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, $0.count - sent) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return false }
      sent += count
    }
    return true
  }

  /// Reads until `count` bytes or EOF.
  private static func read(_ fd: Int32, count: Int) -> [UInt8] {
    var data: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count < count {
      let got = buffer.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress, min($0.count, count - data.count))
      }
      if got < 0, errno == EINTR { continue }
      guard got > 0 else { break }
      data += buffer[..<got]
    }
    return data
  }

  /// Zero once the other end has closed, with nothing left to read.
  private static func readsEOF(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    return Darwin.read(fd, &byte, 1) == 0
  }

  private static func random(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  @Test func bytesCrossBothWays() async throws {
    let wiring = try Wiring()
    let pump = wiring.pump()
    let up = Self.random(1 << 20)
    let down = Self.random(1 << 20)

    let (wroteUp, arrivedUp, wroteDown, arrivedDown) = try await within {
      async let wroteUp = Self.onThread { Self.writeAll(wiring.input.write, up) }
      async let readUp = Self.onThread { Self.read(wiring.peer, count: up.count) }
      async let wroteDown = Self.onThread { Self.writeAll(wiring.peer, down) }
      async let readDown = Self.onThread { Self.read(wiring.output.read, count: down.count) }
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
    #expect(ContinuousClock.now - start < .seconds(1))
    #expect(await Self.onThread { Self.readsEOF(wiring.peer) })
  }

  @Test func socketEOFEndsThePump() async throws {
    let wiring = try Wiring()
    let pump = wiring.pump()

    wiring.close(wiring.peer)
    #expect(try await within { await pump.value } == .socketClosed)
    wiring.close(wiring.output.write)
    #expect(await Self.onThread { Self.readsEOF(wiring.output.read) })
  }

  /// ssh no longer takes stdout: the pump ends as for stdin's EOF, without a SIGPIPE.
  @Test func outputGoneEndsThePump() async throws {
    let wiring = try Wiring()
    let pump = wiring.pump()

    wiring.close(wiring.output.read)
    #expect(Self.writeAll(wiring.peer, [1, 2, 3]))
    #expect(try await within { await pump.value } == .inputClosed)
    #expect(await Self.onThread { Self.readsEOF(wiring.peer) })
  }
}
