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

  /// A Claude Code `result`, or a Codex `turn/completed`, and nothing else: not a tool's
  /// result, nor a line quoting one.
  @Test func theTurnEndMarksTheLinesThatEndATurnAndNoOther() throws {
    var ends: [AgentKind: Int] = [:]
    for (agent, line) in try Self.fixtureLines() {
      let json = try #require(
        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      let endsTurn =
        switch agent {
        case .claude: json["type"] as? String == "result"
        case .codex: json["method"] as? String == "turn/completed"
        }
      #expect((Data(line.utf8).range(of: agent.turnEnd) != nil) == endsTurn, "\(line.prefix(120))")
      if endsTurn { ends[agent, default: 0] += 1 }
    }
    #expect(ends[.claude, default: 0] > 0)
    #expect(ends[.codex, default: 0] > 0)
  }

  @Test func theAssertionSaysHowManySessionsWork() {
    #expect(KeepAwake.name(working: 1) == "Drakar: a session is working")
    #expect(KeepAwake.name(working: 3) == "Drakar: 3 sessions are working")
  }
}
