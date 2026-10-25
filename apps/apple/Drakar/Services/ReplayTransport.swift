import DrakarKit
import Foundation
import Synchronization

/// What a replayed session writes to: nothing reaches a process. The replies the backend
/// writes to the process's own lines are kept until a logged write matches one, the reply
/// having gone out then; what no logged write matched is owed, for the caller to send once
/// the replay ends.
nonisolated final class ReplayTransport: ProcessTransport {
  /// `owed` keeps what is written; `muted` drops it, as for a note's writes, which went out
  /// when the note was taken.
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

  /// A write the log holds: the first reply kept with the same bytes was sent.
  func logged(_ line: Data) {
    state.withLock { state in
      if let index = state.owed.firstIndex(of: line) { state.owed.remove(at: index) }
    }
  }

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
