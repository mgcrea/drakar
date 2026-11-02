import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// What the session host waits for to let the Mac sleep again: read against every line the
/// kit's fixtures captured from the real CLIs.
@MainActor
@Suite("Keeping the Mac awake")
struct KeepAwakeTests {
  /// Every fixture line, with the agent that wrote it: Codex's files are named for it.
  private static func fixtureLines() throws -> [(AgentKind, String)] {
    let folder = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Packages/DrakarKit/Tests/DrakarKitTests/Fixtures")
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      .filter { $0.hasSuffix(".jsonl") }
    return try files.flatMap { name in
      let agent: AgentKind = name.hasPrefix("codex-") ? .codex : .claude
      let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
      return text.split(separator: "\n").map { (agent, String($0)) }
    }
  }

  /// Claude Code's `result`, `can_use_tool` and `elicitation`, or Codex's `turn/completed`
  /// and approval requests, and nothing else: not a tool's result, an elicitation's end, nor
  /// a line quoting one.
  @Test func thePausesMarkTheLinesWhereTheAgentStopsAndNoOther() throws {
    var stops: [AgentKind: Int] = [:]
    for (agent, line) in try Self.fixtureLines() {
      let json = try #require(
        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      let request = (json["request"] as? [String: Any])?["subtype"] as? String
      let stopsWork =
        switch agent {
        case .claude:
          json["type"] as? String == "result"
            || (json["type"] as? String == "control_request"
              && ["can_use_tool", "elicitation"].contains(request))
        case .codex:
          [
            "turn/completed", "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
          ].contains(json["method"] as? String)
        }
      let marked = agent.pauses.contains { Data(line.utf8).range(of: $0) != nil }
      #expect(marked == stopsWork, "\(line.prefix(120))")
      if stopsWork { stops[agent, default: 0] += 1 }
    }
    #expect(stops[.claude, default: 0] > 0)
    #expect(stops[.codex, default: 0] > 0)
  }

  @Test func theAssertionSaysHowManySessionsWork() {
    #expect(KeepAwake.name(working: 1) == "Drakar: a session is working")
    #expect(KeepAwake.name(working: 3) == "Drakar: 3 sessions are working")
  }
}
