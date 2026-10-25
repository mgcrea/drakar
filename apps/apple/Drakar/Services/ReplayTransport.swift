import DrakarKit
import Foundation
import Synchronization

/// What a replayed session writes to: nothing reaches a process. A reply to a line the
/// process wrote while no app was attached was never written, so it is kept, owed, for the
/// caller to send once the replay ends.
nonisolated final class ReplayTransport: ProcessTransport {
  enum Mode { case muted, owed }

  private struct State {
    var mode = Mode.muted
    var owed: [Data] = []
    var isRunning = true
  }

  private let state = Mutex(State())

  var mode: Mode {
    get { state.withLock { $0.mode } }
    set { state.withLock { $0.mode = newValue } }
  }

  var owed: [Data] { state.withLock { $0.owed } }

  /// Running until terminated, as the process it stands for is.
  var isRunning: Bool { state.withLock { $0.isRunning } }

  /// Never started: the process it stands for already runs.
  func start() throws -> AsyncStream<AgentProcess.Event> {
    AsyncStream { $0.finish() }
  }

  func send(line: Data) throws {
    state.withLock { if $0.mode == .owed { $0.owed.append(line) } }
  }

  func closeInput() {}

  func terminate() {
    state.withLock { $0.isRunning = false }
  }
}
