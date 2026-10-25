import Foundation

/// What a session asks of its agent's process, wherever the process runs: a child of the app
/// (`AgentProcess`), or one a session host keeps through the app's quits.
public protocol ProcessTransport: AnyObject, Sendable {
  var isRunning: Bool { get }
  /// Launches the process and returns its events, `.lines` stamped with when they were read
  /// from the process. Call once.
  func start() throws -> AsyncStream<AgentProcess.Event>
  func send(line: Data) throws
  /// Ends input; the CLI exits cleanly once its current turn is done.
  func closeInput()
  func terminate()
}

extension ProcessTransport {
  /// `json` as one line, encoded as `ClientMessage` encodes its own (`JSONValue.line()`).
  public func send(_ json: JSONValue) throws {
    try send(line: json.line())
  }

  public func send(_ message: ClientMessage) throws {
    try send(line: message.line())
  }
}
