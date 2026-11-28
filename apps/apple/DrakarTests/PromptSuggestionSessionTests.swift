import DrakarKit
import Foundation
import Synchronization
import Testing

@testable import Drakar

/// A process the test writes for: what the session sent it, and lines fed back by hand.
private nonisolated final class ScriptedTransport: ProcessTransport {
  private let state = Mutex<
    (sent: [String], output: AsyncStream<AgentProcess.Event>.Continuation?)
  >(
    ([], nil))

  var sent: [String] { state.withLock { $0.sent } }
  var isRunning: Bool { true }

  func start() throws -> AsyncStream<AgentProcess.Event> {
    let (stream, continuation) = AsyncStream.makeStream(of: AgentProcess.Event.self)
    state.withLock { $0.output = continuation }
    return stream
  }

  func send(line: Data) throws {
    state.withLock { $0.sent.append(String(decoding: line, as: UTF8.self)) }
  }

  func write(_ line: String) throws {
    let json = try JSONValue.parse(Data(line.utf8))
    _ = state.withLock { $0.output?.yield(.lines([.json(json)], at: .now)) }
  }

  func closeInput() {}
  func terminate() { state.withLock { $0.output?.finish() } }
}

/// The session's side of the CLI's next-prompt guesses: asked for at the start, paused while
/// nobody sees the composer, and offered until the next prompt.
@MainActor
@Suite("Prompt suggestions in a session")
struct PromptSuggestionSessionTests {

  private func session() async -> (AgentSession, ScriptedTransport) {
    let transport = ScriptedTransport()
    let session = AgentSession(folder: FileManager.default.temporaryDirectory, agent: .claude)
    session.executableOverride = URL(filePath: "/usr/bin/true")
    session.accounts = { [] }
    session.makeTransport = { _ in transport }
    await session.spawn()
    return (session, transport)
  }

  private func pauses(_ transport: ScriptedTransport) -> [Bool] {
    transport.sent.compactMap { line in
      guard line.contains(#""set_prompt_suggestions_paused""#) else { return nil }
      return line.contains(#""paused":true"#)
    }
  }

  @Test func pausesOnceAViewSaysItIsOutOfSight() async throws {
    let (session, transport) = await session()
    defer { session.stop() }
    let initialize = try #require(transport.sent.first)
    #expect(initialize.contains(#""promptSuggestions":true"#))
    // No view has said where the composer is: the process is left guessing, as it starts.
    #expect(pauses(transport) == [])
    session.setComposerOnScreen(true)
    session.setComposerOnScreen(true)
    #expect(pauses(transport) == [])
    session.setComposerOnScreen(false)
    session.setComposerOnScreen(true)
    #expect(pauses(transport) == [true, false])
  }

  @Test func aProcessStartedOutOfSightIsPausedAtOnce() async throws {
    let transport = ScriptedTransport()
    let session = AgentSession(folder: FileManager.default.temporaryDirectory, agent: .claude)
    session.executableOverride = URL(filePath: "/usr/bin/true")
    session.accounts = { [] }
    session.makeTransport = { _ in transport }
    session.setComposerOnScreen(false)
    await session.spawn()
    defer { session.stop() }
    #expect(pauses(transport) == [true])
  }

  @Test func offersTheGuessUntilThePrompt() async throws {
    let (session, transport) = await session()
    defer { session.stop() }
    session.setComposerOnScreen(true)
    try transport.write(
      #"{"type":"prompt_suggestion","suggestion":"run the tests","uuid":"u-1","session_id":"s-1"}"#)
    for _ in 0..<100 where session.suggestedPrompt == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(session.suggestedPrompt == "run the tests")
    session.send("run the tests")
    #expect(session.suggestedPrompt == nil)
  }
}
