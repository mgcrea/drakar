import DrakarKit
import Foundation
import Testing

/// The transcript's own rules, driven by neutral events: what any agent's translator can
/// rely on (docs/superpowers/specs/2026-10-06-agent-backend-design.md, "AgentEvent").
@Suite("Applying agent events")
struct AgentEventTests {
  let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func text(_ id: String, _ s: String) -> AgentEvent.Item {
    AgentEvent.Item(id: id, parent: nil, kind: .text(s))
  }

  private func shell(_ id: String) -> AgentEvent.Item {
    AgentEvent.Item(
      id: id, parent: nil,
      kind: .tool(.init(id: id, name: "Shell", input: .object([:]), kind: .shell(command: "ls"))))
  }

  @Test func streamsThenCompletesOneEntry() {
    var t = Transcript()
    t.apply(.itemStarted(text("m#0", "")))
    t.apply(.itemDelta(id: "m#0", .text("Hel")))
    t.apply(.itemDelta(id: "m#0", .text("lo")))
    #expect(t.entries.map(\.kind) == [.text("Hello")])
    t.apply(.itemCompleted(text("m#0", "Hello!")))
    #expect(t.entries.map(\.kind) == [.text("Hello!")])
  }

  /// Review Focus 2: a block that lands with its text withheld keeps what streamed.
  @Test func aCompletionNeverBlanksStreamedText() {
    var t = Transcript()
    t.apply(.itemStarted(AgentEvent.Item(id: "m#0", parent: nil, kind: .thinking(""))), at: start)
    t.apply(.itemDelta(id: "m#0", .thinking("Weighing")))
    t.apply(
      .itemCompleted(AgentEvent.Item(id: "m#0", parent: nil, kind: .thinking(""))),
      at: start.addingTimeInterval(3))
    #expect(t.entries.first?.kind == .thinking("Weighing"))
    #expect(t.entries.first?.thinkingDuration == 3)
  }

  /// Review Focus 1: Codex completes an interrupted turn's command during a later turn.
  @Test func anItemCompletesAfterItsTurnEnded() {
    var t = Transcript()
    t.addPrompt("first")
    t.apply(.itemStarted(shell("c1")))
    t.apply(.turnEnded(TurnSummary(outcome: .interrupted)))
    t.addPrompt("second")
    t.apply(.toolResult(callID: "c1", .init(content: "done", isError: false)))
    guard case .tool(let call) = t.entries[1].kind else {
      Issue.record("\(t.entries)")
      return
    }
    #expect(call.result?.content == "done")
    #expect(t.isRunning)
  }

  @Test func aResultForNoCallIsDropped() {
    var t = Transcript()
    t.apply(.toolResult(callID: "nobody", .init(content: "x", isError: false)))
    #expect(t.entries.isEmpty)
  }

  @Test func aCompletedCallKeepsAResultThatCameFirst() {
    var t = Transcript()
    t.apply(.itemStarted(shell("c1")))
    t.apply(.toolResult(callID: "c1", .init(content: "out", isError: false)))
    t.apply(.itemCompleted(shell("c1")))
    guard case .tool(let call) = t.entries.first?.kind else { return }
    #expect(call.result?.content == "out")
  }

  @Test func theEndOfATurnClearsWhatWaited() {
    var t = Transcript()
    t.addPrompt("go")
    t.apply(.itemStarted(AgentEvent.Item(id: "m#0", parent: nil, kind: .thinking(""))))
    t.apply(.retrying(APIRetry(attempt: 1, maxRetries: 3, delayMS: 500)))
    t.apply(.turnEnded(TurnSummary(outcome: .failed, failureText: "Overloaded")))
    #expect(!t.isRunning)
    #expect(t.turnEnd == .failed)
    #expect(t.entries.last?.kind == .failure("Overloaded"))
    #expect(t.entries[1].thinkingSince == nil)
    #expect(t.lastTurn?.outcome == .failed)
  }

  @Test func aQueuedPromptJoinsWhenTaken() {
    var t = Transcript()
    t.addPrompt("first")
    t.queue(QueuedPrompt(uuid: "q", text: "second"))
    t.apply(.queue(id: "q", .started))
    #expect(t.queuedPrompts.isEmpty)
    #expect(t.lastPrompt?.kind == .prompt("second"))
    t.queue(QueuedPrompt(uuid: "r", text: "third"))
    t.apply(.queue(id: "r", .dropped(agent: "Codex")))
    #expect(t.entries.last?.kind == .notice("Codex did not take a queued message: third"))
  }

  @Test func usageCarriesTheWindowWhenTheAgentSaysIt() {
    var t = Transcript()
    let usage = TokenUsage(input: 10, cacheCreation: 0, cacheRead: 5, output: 1)
    t.apply(.usage(.init(messageID: "turn-1", usage: usage, model: nil, window: 258_400, at: nil)))
    #expect(t.contextUsage == usage)
    #expect(t.contextWindow == 258_400)
  }
}
