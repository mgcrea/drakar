import Foundation
import Synchronization

/// One process the session host holds: `Process` and its three pipes, bytes unparsed.
///
/// `@unchecked Sendable` for the reason `AgentProcess` is: `Process` and `FileHandle` are
/// not marked Sendable, the calls made across threads are thread-safe, and the mutable state
/// is behind a `Mutex`.
final class HostChild: @unchecked Sendable {
  enum Output: Sendable {
    /// A line of stdout with its `\n`, or the bytes after the last newline at the exit.
    case line(Data)
    case stderr(Data)
    /// Comes last, once every line is out.
    case exited(status: Int32)
  }

  enum Failure: Error {
    case notRunning
  }

  /// What stderr keeps for an app that attaches after the exit: the lines that say why.
  static let stderrLimit = 64 * 1024

  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let errors = Pipe()
  /// One write at a time, so two never interleave on stdin.
  private let writing = NSLock()
  private let state = Mutex(State())

  private struct State {
    var lines = LineBuffer()
    var stderrTail = Data()
    var inputClosed = false
    var stdoutClosed = false
    var stderrClosed = false
    var exitStatus: Int32?
    var isWaitingForStderr = false
    var handler: (@Sendable (Output) -> Void)?
  }

  init(_ configuration: AgentProcess.Configuration) {
    process.executableURL = configuration.executable
    process.arguments = configuration.arguments
    process.environment = configuration.environment
    process.currentDirectoryURL = configuration.currentDirectory
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
  }

  var stderrTail: Data { state.withLock { $0.stderrTail } }

  /// Launches the process. `handler` gets stdout's lines in order from one thread at a time,
  /// stderr as it comes, and the exit last.
  func start(_ handler: @escaping @Sendable (Output) -> Void) throws {
    // As in `AgentProcess`: a write to a CLI that died throws EPIPE instead of killing us.
    signal(SIGPIPE, SIG_IGN)
    state.withLock { $0.handler = handler }

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard let self else { return }
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        self.finish { $0.stdoutClosed = true }
        return
      }
      // Framed as `AgentProcess` frames them (a `\r` and blank lines dropped), so a replay
      // reads the lines a live session did. `LineBuffer` drops the `\n`; the log puts it back.
      let lines = self.state.withLock { $0.lines.append(chunk) }
      for line in lines { handler(.line(line + [0x0A])) }
    }
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard let self else { return }
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        self.finish { $0.stderrClosed = true }
        return
      }
      self.state.withLock { state in
        state.stderrTail.append(chunk)
        if state.stderrTail.count > Self.stderrLimit {
          state.stderrTail = Data(state.stderrTail.suffix(Self.stderrLimit))
        }
      }
      handler(.stderr(chunk))
    }
    process.terminationHandler = { [weak self] process in
      self?.finish { $0.exitStatus = process.terminationStatus }
    }

    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      errors.fileHandleForReading.readabilityHandler = nil
      state.withLock { $0.handler = nil }
      throw error
    }
  }

  func write(_ bytes: Data) throws {
    try writing.withLock {
      guard process.isRunning, !state.withLock({ $0.inputClosed }) else {
        throw Failure.notRunning
      }
      try input.fileHandleForWriting.write(contentsOf: bytes)
    }
  }

  func closeInput() {
    writing.withLock {
      state.withLock { $0.inputClosed = true }
      try? input.fileHandleForWriting.close()
    }
  }

  func terminate() {
    if process.isRunning { process.terminate() }
  }

  /// Reports the exit once stdout has closed, stderr has closed (or 200 ms went by, for a
  /// grandchild that keeps it open) and the status is known: `AgentProcess.finish`'s rule.
  private func finish(_ update: (inout State) -> Void) {
    enum Next {
      case wait, waitForStderr
      case end(@Sendable (Output) -> Void, Int32, Data)
    }
    let next: Next = state.withLock { state in
      update(&state)
      guard state.stdoutClosed, let status = state.exitStatus, let handler = state.handler
      else { return .wait }
      if !state.stderrClosed {
        if state.isWaitingForStderr { return .wait }
        state.isWaitingForStderr = true
        return .waitForStderr
      }
      state.handler = nil
      return .end(handler, status, state.lines.remainder)
    }
    switch next {
    case .wait:
      return
    case .waitForStderr:
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.finish { $0.stderrClosed = true }
      }
    case .end(let handler, let status, let remainder):
      if !remainder.isEmpty { handler(.line(remainder)) }
      handler(.exited(status: status))
    }
  }
}
