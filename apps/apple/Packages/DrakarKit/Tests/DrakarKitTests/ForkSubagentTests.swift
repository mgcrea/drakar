import DrakarKit
import Foundation
import Testing

/// A fork subagent, on by default in headless sessions since Claude Code 2.1.302: it always
/// runs in the background, its lines arrive after the turn that started it ended, and its
/// notification starts a turn nobody prompted (docs/claude-stream-json.md, "2.1.308").
@Suite("Fork subagents")
struct ForkSubagentTests {

  private let agentID = "toolu_013rNB1wKZcngWYsN2CqLH2y"

  /// The transcript after the first `count` lines, the prompt sent first.
  private func transcript(upTo count: Int? = nil) throws -> ClaudeFeed {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Fork it")
    let messages = try Fixture.forkSubagent.messages
    for message in messages.prefix(count ?? messages.count) { transcript.apply(message) }
    return transcript
  }

  /// Where the second `system/init` is: the turn the CLI starts on its own.
  private func unpromptedTurnStart() throws -> Int {
    let messages = try Fixture.forkSubagent.messages
    let starts = messages.indices.filter {
      if case .system(.initialized) = messages[$0] { return true }
      return false
    }
    return try #require(starts.dropFirst().first)
  }

  @Test func decodesEveryCapturedLine() throws {
    for message in try Fixture.forkSubagent.messages {
      if case .unknown(let type, _) = message { Issue.record("unmodelled line: \(type)") }
    }
  }

  /// The fork's call, result and text, sent after its turn ended, go inside its card.
  @Test func itsLinesGoUnderItsCall() throws {
    let transcript = try transcript()
    let children = transcript.entries.filter { $0.parentToolUseID == agentID }
    #expect(children.count == 2)
    guard case .tool(let call)? = children.first?.kind else {
      Issue.record("not a tool call: \(String(describing: children.first?.kind))")
      return
    }
    #expect(call.name == "Bash")
    #expect(call.result?.content == "fork-ok")
    #expect(children.last?.kind == .text("Output: `fork-ok`"))
    #expect(transcript.agentTasks[agentID]?.status == .completed)
  }

  /// The turn that started it ends while the fork still runs.
  @Test func itsTurnEndsWhileItRuns() throws {
    let transcript = try transcript(upTo: try unpromptedTurnStart())
    #expect(!transcript.isRunning)
    #expect(transcript.agentTasks[agentID]?.status == .completed)
  }

  /// The CLI answers the fork's notification in a turn nobody prompted: the session is at
  /// work until it ends, so Stop and the queue apply, and the row does not read idle.
  @Test func theNotificationTurnRuns() throws {
    let started = try transcript(upTo: try unpromptedTurnStart() + 1)
    #expect(started.isRunning)
    #expect(started.turnEnd == nil)
    let ended = try transcript()
    #expect(!ended.isRunning)
    #expect(ended.turnEnd == .completed)
    #expect(ended.closingText?.text.hasPrefix("The fork agent completed.") == true)
  }
}
