import DrakarKit
import Foundation
import Testing

/// A history cut where a process took over: what a replayed Codex session shows of its
/// thread before the turns its log holds.
@Suite("Cutting a history at a turn")
struct AgentEventHistoryTests {
  private let events: [AgentEvent] = [
    .sessionStarted(SessionInfo(sessionID: "t-1")),
    .turnStarted, .prompt(.init(text: "one"), running: false), .turnEnded(TurnSummary(outcome: .completed)),
    .turnStarted, .prompt(.init(text: "two"), running: false), .turnEnded(TurnSummary(outcome: .completed)),
  ]

  @Test func cutsAtTheNthTurnEnd() {
    #expect(events.throughTurns(1) == Array(events.prefix(4)))
    #expect(events.throughTurns(5) == events)
    #expect(events.throughTurns(0) == [.sessionStarted(SessionInfo(sessionID: "t-1"))])
  }

  /// Codex's stored thread opens each turn with its prompt and closes it with an outcome.
  @Test func cutsAStoredThread() throws {
    let items = try JSONValue.parse(
      Data(
        #"""
        [{"turnId":"turn-1","item":{"type":"userMessage","id":"u1","content":[{"type":"text","text":"one"}]}},
         {"turnId":"turn-2","item":{"type":"userMessage","id":"u2","content":[{"type":"text","text":"two"}]}}]
        """#.utf8))
    let stored = CodexTranslator.history(items.arrayValue ?? [])
    #expect(stored.turnsEnded == 2)
    let first = stored.throughTurns(1)
    #expect(first.turnsEnded == 1)
    #expect(first.last == .turnOutcome(.completed))
    #expect(!first.contains(.prompt(.init(text: "two"), running: false)))
    #expect(!stored.throughTurns(0).contains { if case .prompt = $0 { true } else { false } })
  }
}
