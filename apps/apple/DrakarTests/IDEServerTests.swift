import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// The editor bridge's socket, on a real loopback port: what the licence gate's
/// `stopListening` keeps and what quitting's `stop` ends. The server alone, never
/// `IDEBridge`, which would write lock files into the accounts on this Mac.
@MainActor
@Suite("The editor bridge's socket", .serialized)
struct IDEServerTests {
  @MainActor private final class Log {
    var port: UInt16?
    var methods: [String] = []
    var closes = 0
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<50 where !condition() {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// A server listening, its port, and what it heard.
  private func listening() async throws -> (IDEServer, Log) {
    let log = Log()
    let server = IDEServer(
      onMessage: { _, message in
        if case .notification(let method, _) = message { log.methods.append(method) }
      },
      onClose: { _ in log.closes += 1 })
    try server.start(ready: { log.port = $0 }, failed: { _ in })
    try await waitFor { log.port != nil }
    try #require(log.port != nil)
    return (server, log)
  }

  private func client(_ port: UInt16, token: String) -> URLSessionWebSocketTask {
    var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
    request.setValue(token, forHTTPHeaderField: "x-claude-code-ide-authorization")
    request.setValue("mcp", forHTTPHeaderField: "Sec-WebSocket-Protocol")
    let task = URLSession.shared.webSocketTask(with: request)
    task.resume()
    return task
  }

  private func notify(_ task: URLSessionWebSocketTask, _ method: String) async throws {
    try await task.send(.string(#"{"jsonrpc":"2.0","method":"\#(method)"}"#))
  }

  /// Refused by the gate: nothing new connects, the `claude` already connected goes on
  /// being heard and is never told it closed, and listening again keeps it. Only `stop`
  /// hangs up.
  @Test func stopListeningKeepsTheConnectionsMade() async throws {
    let (server, log) = try await listening()
    defer { server.stop() }
    let first = try #require(log.port)
    let connected = client(first, token: server.token)
    defer { connected.cancel() }
    try await notify(connected, "before")
    try await waitFor { log.methods == ["before"] }
    #expect(server.connectionCount == 1)

    server.stopListening()
    #expect(!server.isListening)
    try await notify(connected, "after")
    try await waitFor { log.methods == ["before", "after"] }
    #expect(log.methods == ["before", "after"])
    #expect(server.connectionCount == 1)
    #expect(log.closes == 0)

    // The port is closed to anyone new.
    let late = client(first, token: server.token)
    defer { late.cancel() }
    await #expect(throws: (any Error).self) { try await late.receive() }
    #expect(server.connectionCount == 1)

    try server.start(ready: { _ in }, failed: { _ in })
    #expect(server.isListening)
    try await notify(connected, "again")
    try await waitFor { log.methods.count == 3 }
    #expect(server.connectionCount == 1)

    server.stop()
    #expect(server.connectionCount == 0)
    await #expect(throws: (any Error).self) { try await connected.receive() }
  }
}
