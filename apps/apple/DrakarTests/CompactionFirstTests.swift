import DrakarKit
import Testing

@testable import Drakar

/// Which command the Compact buttons run first: Settings names a Claude Code command, which
/// another agent runs only when it lists one of that name.
@Suite("The command run before compacting")
struct CompactionFirstTests {
  private let distill = [SkillEntry(name: "distill")]

  @Test func claudeCodeAlwaysRunsIt() {
    #expect(
      CompactionFirst.command(setting: "/distill", agent: .claude, commands: []) == "/distill")
  }

  @Test func anotherAgentRunsItOnlyWhenItListsTheCommand() {
    #expect(
      CompactionFirst.command(setting: "/distill now", agent: .grok, commands: distill)
        == "/distill now")
    #expect(CompactionFirst.command(setting: "/distill", agent: .codex, commands: []) == nil)
    #expect(
      CompactionFirst.command(
        setting: "/distiller", agent: .agy, commands: distill) == nil)
  }

  @Test func wordsGoToAnyAgentAndBlankIsNone() {
    #expect(
      CompactionFirst.command(setting: "Write NOTES.md", agent: .codex, commands: [])
        == "Write NOTES.md")
    #expect(CompactionFirst.command(setting: "  ", agent: .claude, commands: distill) == nil)
  }

  @Test func theButtonSaysWhatItRunsFirst() {
    #expect(CompactionFirst.title(first: "/distill") == "Run /distill, then Compact")
    #expect(CompactionFirst.title(first: nil) == "Compact")
  }
}
