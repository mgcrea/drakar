import Foundation
import Testing

@testable import Drakar

/// The working indicator adapts its glyph animation and verbs to the active provider while
/// keeping Claude Code's original starburst untouched.
@MainActor
@Suite("WorkingIndicator")
struct WorkingIndicatorTests {
  @Test func keepsClaudeStyleIntact() {
    let style = WorkingIndicator.style(for: .claude)
    #expect(style.frames == ["·", "✢", "*", "✶", "✻", "✽", "✽", "✻", "✶", "*", "✢", "·"])
    #expect(style.frameInterval == 0.12)
    #expect(style.verbs.contains("Clauding"))
    #expect(!style.verbs.contains("Codexing"))
    #expect(!style.verbs.contains("Antigraviting"))
  }

  @Test func adaptsFramesForCodexAndAntigravity() {
    let claude = WorkingIndicator.style(for: .claude)
    let codex = WorkingIndicator.style(for: .codex)
    let agy = WorkingIndicator.style(for: .agy)

    #expect(codex.frames != claude.frames)
    #expect(agy.frames != claude.frames)
    #expect(codex.frames != agy.frames)
    #expect(codex.verbs.contains("Codexing"))
    #expect(!codex.verbs.contains("Clauding"))
    #expect(!codex.verbs.contains("Antigraviting"))
    #expect(agy.verbs.contains("Antigraviting"))
    #expect(!agy.verbs.contains("Clauding"))
    #expect(!agy.verbs.contains("Codexing"))
  }

  @Test func keepsGroksOnlyVerbWhenRotationIsDue() {
    let style = WorkingIndicator.style(for: .grok)

    #expect(style.nextVerb(after: "Thinking") == "Working")
    #expect(style.nextVerb(after: "Working") == nil)
  }

  @Test func cyclesThroughEveryFrameForEachAgent() {
    for agent in AgentKind.allCases {
      let style = WorkingIndicator.style(for: agent)
      let seen = (0..<style.frames.count).map { step in
        style.frame(at: Date(timeIntervalSinceReferenceDate: Double(step) * style.frameInterval))
      }
      #expect(seen == style.frames, "\(agent)")
      // Wraps cleanly even for timestamps before the reference date.
      let before = style.frame(at: Date(timeIntervalSinceReferenceDate: -style.frameInterval))
      #expect(before == style.frames.last, "\(agent)")
    }
  }
}
