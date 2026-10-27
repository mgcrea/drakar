import Foundation
import Synchronization

@testable import DrakarKit

/// A host on a real Unix socket, in a short directory of its own under `/tmp` (`sun_path`
/// holds 104 bytes), with `cat` as a stand-in agent.
final class TestHost {
  let directory: URL
  let core: HostCore
  private(set) var server: HostServer?
  private let peerCheck: @Sendable (Int32) -> Bool
  private let clients = Mutex<[HostClient]>([])

  /// `minor`: what the host's `welcome` says; nil stands in for a host older than minor 3.
  init(
    peerCheck: @escaping @Sendable (Int32) -> Bool = { _ in true },
    accept: @escaping @Sendable (Int32) -> UnixSocket.Accepted = UnixSocket.accept,
    minor: Int? = HostWire.minor
  ) throws {
    let name = String(UUID().uuidString.prefix(6))
    directory = URL(fileURLWithPath: "/tmp/dh-\(name)", isDirectory: true)
    core = HostCore(directory: directory, hostVersion: "test", minor: minor)
    self.peerCheck = peerCheck
    server = try HostServer.start(
      directory: directory, core: core, peerCheck: peerCheck, accept: accept)
  }

  var socket: URL { get throws { try HostWire.socket(in: directory) } }

  func connect() throws -> HostClient {
    let client = try HostClient.connect(socket: socket)
    clients.withLock { $0.append(client) }
    return client
  }

  /// Drops every app's connection, as a host that lost them would, and takes new ones on
  /// the same core: the processes carry on. A child another test spawns that moment can hold
  /// the lock's descriptor until it execs, so the new server waits for it.
  func restart() throws {
    server?.stop()
    server = nil
    for _ in 0..<100 where server == nil {
      server = try HostServer.start(directory: directory, core: core, peerCheck: peerCheck)
      if server == nil { usleep(10_000) }
    }
  }

  /// Ends whatever is still running, so no test leaves a process or a socket behind.
  func close() {
    for client in clients.withLock({ $0 }) { client.close() }
    server?.stop()
    let client = core.connected(pid: 0)
    if case .listed(let held) = core.handle(.list, from: client).first {
      for process in held { _ = core.handle(.terminate(id: process.id), from: client) }
    }
    core.disconnected(client)
    try? FileManager.default.removeItem(at: directory)
  }

  func cat() -> AgentProcess.Configuration {
    AgentProcess.Configuration(
      executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:],
      currentDirectory: directory)
  }
}
