import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A session's MCP servers, and connecting one again")
struct SessionServersTests {
  /// Stands in for the process: what was asked, in order, and the answers it gives, one per
  /// ask; nil once they run out, as a process that does not answer.
  @MainActor private final class Process {
    var asked: [AgentCommand] = []
    var answers: [SessionSignal?]
    /// Run before an answer is given, to change things while an ask waits.
    var meanwhile: (() -> Void)?

    init(_ answers: [SessionSignal?]) { self.answers = answers }

    func ask(_ command: AgentCommand) async -> SessionSignal? {
      asked.append(command)
      meanwhile?()
      // As a process takes time: what `meanwhile` started runs before the answer.
      await Task.yield()
      return answers.isEmpty ? nil : answers.removeFirst()
    }
  }

  private func servers(_ process: Process) -> SessionServers {
    let servers = SessionServers()
    servers.ask = { await process.ask($0) }
    servers.connectingInterval = .milliseconds(1)
    return servers
  }

  private func listed(_ status: MCPServerStatus, error: String? = nil) -> SessionSignal {
    .serversAnswered(
      requestID: "servers-x", [MCPServerEntry(name: "cadence", status: status, error: error)])
  }

  @Test func aReadListsTheProcessServers() async {
    let process = Process([listed(.failed, error: "Connection closed")])
    let servers = servers(process)
    await servers.read()
    #expect(process.asked == [.readServers])
    #expect(servers.list?.map(\.status) == [.failed])
  }

  /// As the probe does: a server still connecting is read again until it is not.
  @Test func aConnectingServerIsReadAgain() async {
    let process = Process([listed(.pending), listed(.pending), listed(.connected)])
    let servers = servers(process)
    await servers.read()
    #expect(process.asked == [.readServers, .readServers, .readServers])
    #expect(servers.list?.map(\.status) == [.connected])
  }

  @Test func aConnectingServerIsReadAgainOnlySoOften() async {
    let process = Process(Array(repeating: listed(.pending), count: 20))
    let servers = servers(process)
    servers.connectingReads = 3
    await servers.read()
    #expect(process.asked.count == 3)
    #expect(servers.list?.map(\.status) == [.pending])
  }

  /// An unanswered read keeps what was listed.
  @Test func anUnansweredReadKeepsTheList() async {
    let process = Process([listed(.connected)])
    let servers = servers(process)
    await servers.read()
    await servers.read()
    #expect(servers.list?.map(\.status) == [.connected])
  }

  @Test func aReconnectThatTakesIsReadBack() async {
    let process = Process([
      .reconnectAnswered(requestID: "reconnect-x", error: nil), listed(.connected),
    ])
    let servers = servers(process)
    await servers.reconnect("cadence")
    #expect(process.asked == [.reconnectServer(name: "cadence"), .readServers])
    #expect(servers.list?.map(\.status) == [.connected])
    #expect(servers.reconnecting.isEmpty)
    #expect(servers.failures.isEmpty)
  }

  /// The server's own error is kept for its row, and goes with the next attempt.
  @Test func aReconnectThatFailsKeepsTheError() async {
    let process = Process([
      .reconnectAnswered(requestID: "reconnect-x", error: "Connection closed"),
      listed(.failed, error: "Connection closed"),
      .reconnectAnswered(requestID: "reconnect-y", error: nil), listed(.connected),
    ])
    let servers = servers(process)
    await servers.reconnect("cadence")
    #expect(servers.failures == ["cadence": "Connection closed"])
    #expect(servers.reconnecting.isEmpty)
    await servers.reconnect("cadence")
    #expect(servers.failures.isEmpty)
  }

  @Test func anUnansweredReconnectSaysSo() async {
    let process = Process([])
    let servers = servers(process)
    await servers.reconnect("cadence")
    #expect(servers.failures == ["cadence": "Claude Code didn't answer."])
    #expect(servers.reconnecting.isEmpty)
  }

  /// A reconnect is sent once while one for the same server waits.
  @Test func aReconnectIsSentOnceWhileItWaits() async {
    let process = Process([
      .reconnectAnswered(requestID: "reconnect-x", error: nil), listed(.connected),
    ])
    let servers = servers(process)
    process.meanwhile = {
      process.meanwhile = nil
      #expect(servers.reconnecting == ["cadence"])
      Task { await servers.reconnect("cadence") }
    }
    await servers.reconnect("cadence")
    #expect(process.asked.filter { $0 == .reconnectServer(name: "cadence") }.count == 1)
  }

  /// The process going takes its list and what it was asked; an answer from it that comes
  /// late changes nothing.
  @Test func aProcessEndDropsItsAnswers() async {
    let process = Process([listed(.connected)])
    let servers = servers(process)
    await servers.read()
    process.answers = [.reconnectAnswered(requestID: "reconnect-x", error: "Connection closed")]
    process.meanwhile = { servers.processEnded() }
    await servers.reconnect("cadence")
    #expect(servers.list == nil)
    #expect(servers.reconnecting.isEmpty)
    #expect(servers.failures.isEmpty)
    #expect(process.asked.last == .reconnectServer(name: "cadence"))
  }
}
