import DrakarKit
import Foundation
import Testing

@Suite("Claude Code's stream as agent events")
struct ClaudeTranslatorTests {
  private func lines(_ json: String...) throws -> [StreamMessage] {
    try json.map { try StreamMessage(line: Data($0.utf8)) }
  }

  /// Per-block `assistant` lines share a message id: block n is `<id>#n`; a tool call is
  /// keyed by its own id.
  @Test func keysBlocksByMessageAndToolsByTheirOwnID() throws {
    var translator = ClaudeTranslator()
    let messages = try lines(
      #"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"a"}]}}"#,
      #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls"}}]}}"#
    )
    let events = messages.flatMap { translator.translate($0, at: nil) }
    let items = events.compactMap { event -> String? in
      if case .itemCompleted(let item) = event { return item.id }
      return nil
    }
    #expect(items == ["m#0", "t"])
  }

  /// Review Focus 4: a control response or a rate-limit line leaves a retry standing.
  @Test func clearsTheRetryOnAnythingButAnswersAndLimits() throws {
    var translator = ClaudeTranslator()
    let messages = try lines(
      #"{"type":"control_response","response":{"subtype":"success","request_id":"r"}}"#,
      #"{"type":"rate_limit_event","rate_limit_info":{}}"#,
      #"{"type":"system","subtype":"status","status":"requesting"}"#)
    #expect(!translator.translate(messages[0], at: nil).contains(.retrying(nil)))
    #expect(!translator.translate(messages[1], at: nil).contains(.retrying(nil)))
    #expect(translator.translate(messages[2], at: nil).first == .retrying(nil))
  }

  /// Review Focus 3: history and a live turn fold side by side, each with its translator.
  @Test func historyThenALiveTurnStayApart() throws {
    var feed = ClaudeFeed()
    for line in try Fixture.historyWithTool.lines {
      feed.applyHistory(try JSONValue.parse(line))
    }
    let before = feed.entries.count
    feed.addPrompt("again")
    for message in try Fixture.turnWithTool.messages { feed.apply(message) }
    #expect(feed.entries.count == before + 5)
    #expect(feed.entries.last?.kind == .text("Amiral."))
  }
}
