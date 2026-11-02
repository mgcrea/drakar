import DrakarKit
import Foundation
import Testing

/// `pauses` counts every stop the session host lets the Mac sleep at: one per `result`,
/// `can_use_tool` and `elicitation` line a capture holds, so the app marks work going on
/// after each again (the app's `AgentKind.pauses` names the same lines).
@Suite("The transcript counts where the agent stops")
struct TranscriptPausesTests {
  private static func stops(in fixture: Fixture) throws -> Int {
    let stops = [#""type":"result""#, #""subtype":"can_use_tool""#, #""subtype":"elicitation""#]
      .map { Data($0.utf8) }
    return try fixture.lines.count { line in stops.contains { line.range(of: $0) != nil } }
  }

  @Test(arguments: TranscriptGoldenTests.Scenario.allCases.filter { !$0.isHistory })
  func onePausePerStop(_ scenario: TranscriptGoldenTests.Scenario) throws {
    #expect(
      try TranscriptGoldenTests.fold(scenario).running.pauses
        == Self.stops(in: scenario.fixture))
  }

  /// The elicitation capture is not a golden scenario: its questions are stops too.
  @Test func anElicitationIsAPause() throws {
    var feed = ClaudeFeed()
    feed.addPrompt("Ask me", at: .now)
    for message in try Fixture.elicitation.messages { feed.apply(message, at: .now) }
    let asked = try Fixture.elicitation.lines.count {
      $0.range(of: Data(#""subtype":"elicitation""#.utf8)) != nil
    }
    #expect(asked > 0)
    #expect(feed.transcript.pauses == (try Self.stops(in: .elicitation)))
  }
}
