import Foundation
import Synchronization

/// A `claude` process speaking stream-json over its pipes.
///
/// Start it, read `events` (decoded off the main thread, in batches as the pipe delivers
/// them), `send` messages. The stream ends after `.exited`, which comes only once stdout has
/// been drained, so no message the process wrote before dying is lost.
///
/// `@unchecked Sendable` because `Process` and `FileHandle` are not marked Sendable; the
/// operations used across threads here (`write`, `terminate`, `isRunning`) are thread-safe,
/// and the mutable state is behind a `Mutex`.
public final class AgentProcess: @unchecked Sendable {
  public struct Configuration: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL

    public init(
      executable: URL, arguments: [String], environment: [String: String],
      currentDirectory: URL
    ) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.currentDirectory = currentDirectory
    }
  }

  public enum Event: Sendable, Equatable {
    case messages([StreamMessage])
    /// Diagnostics: the CLI's stderr is never protocol.
    case stderr(String)
    /// The process ended. `remainder` holds bytes it wrote after its last newline.
    case exited(status: Int32, remainder: Data)
  }

  public enum Failure: Error, Equatable {
    case notRunning
  }

  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let errors = Pipe()
  private let state = Mutex(State())

  private struct State {
    var lines = LineBuffer()
    var stdoutClosed = false
    var exitStatus: Int32?
    var continuation: AsyncStream<Event>.Continuation?
  }

  public init(_ configuration: Configuration) {
    process.executableURL = configuration.executable
    process.arguments = configuration.arguments
    process.environment = configuration.environment
    process.currentDirectoryURL = configuration.currentDirectory
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
  }

  public var isRunning: Bool { process.isRunning }

  /// Launches the process and returns its events. Call once.
  public func start() throws -> AsyncStream<Event> {
    // Writing to a pipe whose reader has died raises SIGPIPE, which kills the app. Ignored,
    // the write throws EPIPE instead, which `send` reports. Process-wide and idempotent.
    signal(SIGPIPE, SIG_IGN)

    let (events, continuation) = AsyncStream.makeStream(of: Event.self)
    state.withLock { $0.continuation = continuation }

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard let self else { return }
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        self.finish { $0.stdoutClosed = true }
        return
      }
      let lines = self.state.withLock { $0.lines.append(chunk) }
      let messages = lines.map(Self.decode)
      if !messages.isEmpty { continuation.yield(.messages(messages)) }
    }
    errors.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      continuation.yield(.stderr(String(decoding: chunk, as: UTF8.self)))
    }
    process.terminationHandler = { [weak self] process in
      self?.finish { $0.exitStatus = process.terminationStatus }
    }

    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      errors.fileHandleForReading.readabilityHandler = nil
      continuation.finish()
      throw error
    }
    return events
  }

  public func send(_ message: ClientMessage) throws {
    guard process.isRunning else { throw Failure.notRunning }
    try input.fileHandleForWriting.write(contentsOf: message.line())
  }

  /// Ends input; the CLI exits cleanly once its current turn is done.
  public func closeInput() {
    try? input.fileHandleForWriting.close()
  }

  public func terminate() {
    if process.isRunning { process.terminate() }
  }

  /// Emits `.exited` once both stdout has closed and the exit status is known, whichever
  /// comes last, then ends the stream.
  private func finish(_ update: (inout State) -> Void) {
    let ended: (AsyncStream<Event>.Continuation, Int32, Data)? = state.withLock { state in
      update(&state)
      guard state.stdoutClosed, let status = state.exitStatus,
        let continuation = state.continuation
      else { return nil }
      state.continuation = nil
      return (continuation, status, state.lines.remainder)
    }
    guard let (continuation, status, remainder) = ended else { return }
    continuation.yield(.exited(status: status, remainder: remainder))
    continuation.finish()
  }

  /// A line that is not protocol (a warning printed to stdout) is kept, not dropped.
  private static func decode(_ line: Data) -> StreamMessage {
    (try? StreamMessage(line: line))
      ?? .unknown(type: "invalid-line", raw: .string(String(decoding: line, as: UTF8.self)))
  }
}
