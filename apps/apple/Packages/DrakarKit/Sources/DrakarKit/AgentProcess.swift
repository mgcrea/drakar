import Foundation
import Synchronization

/// An agent's CLI speaking JSON lines over its pipes.
///
/// Start it, read `events` (decoded off the main thread, in batches as the pipe delivers
/// them), `send` messages. The stream ends after `.exited`, which comes only once stdout and
/// stderr have been drained, so no message and no last error line is lost.
///
/// `@unchecked Sendable` because `Process` and `FileHandle` are not marked Sendable; the
/// operations used across threads here (`write`, `terminate`, `isRunning`) are thread-safe,
/// and the mutable state is behind a `Mutex`.
public final class AgentProcess: ProcessTransport, @unchecked Sendable {
  public struct Configuration: Codable, Sendable {
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

  /// One line of stdout: JSON, or text kept as it was (a warning printed to stdout).
  public enum Line: Sendable, Equatable {
    case json(JSONValue)
    case invalid(String)
  }

  public enum Event: Sendable, Equatable {
    /// What the process wrote, a line each, parsed off the main thread, and when it was read
    /// off the pipe: the one clock a live session and a replay of its log both time lines by.
    case lines([Line], at: Date)
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
    var stderrClosed = false
    var exitStatus: Int32?
    var isWaitingForStderr = false
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
      let time = Date()
      let lines = self.state.withLock { $0.lines.append(chunk) }
      if !lines.isEmpty { continuation.yield(.lines(lines.map(Self.parse), at: time)) }
    }
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        self?.finish { $0.stderrClosed = true }
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

  public func send(line: Data) throws {
    guard process.isRunning else { throw Failure.notRunning }
    try input.fileHandleForWriting.write(contentsOf: line)
  }

  /// Ends input; the CLI exits cleanly once its current turn is done.
  public func closeInput() {
    try? input.fileHandleForWriting.close()
  }

  public func terminate() {
    if process.isRunning { process.terminate() }
  }

  /// Emits `.exited` once stdout has closed, stderr has closed and the exit status is
  /// known, whichever comes last, then ends the stream.
  ///
  /// Stderr is waited for because its last chunk can still be in flight when the exit is
  /// seen, and it is the line that says why (a flaky test caught it: `echo oops >&2; exit 3`
  /// lost the `oops` about one run in two). But a child the CLI started may hold stderr
  /// open after the CLI itself is gone, so that wait ends after 200 ms.
  private func finish(_ update: (inout State) -> Void) {
    enum Next {
      case wait, waitForStderr
      case end(AsyncStream<Event>.Continuation, Int32, Data)
    }
    let next: Next = state.withLock { state in
      update(&state)
      guard state.stdoutClosed, let status = state.exitStatus,
        let continuation = state.continuation
      else { return .wait }
      if !state.stderrClosed {
        if state.isWaitingForStderr { return .wait }
        state.isWaitingForStderr = true
        return .waitForStderr
      }
      state.continuation = nil
      return .end(continuation, status, state.lines.remainder)
    }
    switch next {
    case .wait: return
    case .waitForStderr:
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.finish { $0.stderrClosed = true }
      }
      return
    case .end: break
    }
    guard case .end(let continuation, let status, let remainder) = next else { return }
    continuation.yield(.exited(status: status, remainder: remainder))
    continuation.finish()
  }

  /// A line of stdout without its terminator, as `events` parses each.
  public static func parse(_ line: Data) -> Line {
    (try? JSONValue.parse(line)).map(Line.json) ?? .invalid(String(decoding: line, as: UTF8.self))
  }
}
