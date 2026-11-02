import DrakarKit
import Foundation
import Observation

/// The MCP servers of a session's running process, for the Skills & MCP tab, and Reconnect
/// for a failed one. The project's probe lists what a new process would connect; this one's
/// can differ, since a server that failed as it started stays failed until it is connected
/// again (docs/claude-stream-json.md, "Reconnecting an MCP server").
@Observable
final class SessionServers {
  /// The process's servers as last read; nil until a read listed them, and again once the
  /// process is gone.
  private(set) var list: [MCPServerEntry]?
  /// Servers a reconnect was sent for, until it is answered and the list read again.
  private(set) var reconnecting: Set<String> = []
  /// Server name to why its last reconnect failed, until the next one.
  private(set) var failures: [String: String] = [:]

  /// Sends a read or a reconnect to the process and waits for its answer: nil without a
  /// process to ask, or with no answer. Set by the session once it exists.
  @ObservationIgnored var ask: (AgentCommand) async -> SessionSignal? = { _ in nil }
  /// While a server is still connecting, the list is read again this often, as the probe
  /// does, at most `connectingReads` times.
  @ObservationIgnored var connectingInterval = CapabilityProbe.statusInterval
  @ObservationIgnored var connectingReads = 10
  /// Bumped with each process: an answer for the one before is dropped.
  @ObservationIgnored private var generation = 0

  /// Reads the list, again while a server is connecting. One unanswered keeps the list shown.
  func read() async {
    let generation = generation
    for attempt in 1...connectingReads {
      guard case .serversAnswered(_, let servers?)? = await ask(.readServers),
        generation == self.generation
      else { return }
      list = servers
      guard attempt < connectingReads, servers.contains(where: { $0.status == .pending })
      else { return }
      try? await Task.sleep(for: connectingInterval)
    }
  }

  /// Nothing goes while a reconnect of the server waits. The list is read again either way:
  /// a failure is listed with the server's own error.
  func reconnect(_ name: String) async {
    guard !reconnecting.contains(name) else { return }
    let generation = generation
    reconnecting.insert(name)
    failures[name] = nil
    let answer = await ask(.reconnectServer(name: name))
    guard generation == self.generation else { return }
    switch answer {
    case .reconnectAnswered(_, let error)?: failures[name] = error
    default: failures[name] = String(localized: "Claude Code didn't answer.")
    }
    await read()
    guard generation == self.generation else { return }
    reconnecting.remove(name)
  }

  /// The process went: its list and what was asked of it with it.
  func processEnded() {
    generation += 1
    list = nil
    reconnecting = []
    failures = [:]
  }
}
