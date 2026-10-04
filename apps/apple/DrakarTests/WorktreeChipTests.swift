import DrakarKit
import Foundation
import Testing

@testable import Drakar

@Suite("A selection sent to a session in a worktree")
struct WorktreeChipTests {

  private func selection(_ path: String) -> EditorSelection {
    EditorSelection(
      filePath: path, text: "",
      start: TextPosition(line: 0, character: 0), end: TextPosition(line: 0, character: 0))
  }

  @Test func aFileOfTheMainCheckoutIsMarked() {
    let note = ComposerView.selectionNote(
      selection("/w/drakar/README.md"),
      sessionFolder: URL(filePath: "/w/drakar/.claude/worktrees/x"),
      projectFolder: URL(filePath: "/w/drakar"))
    #expect(note == "from the main checkout")
  }

  @Test func aFileOfTheSessionsOwnFolderIsNot() {
    #expect(
      ComposerView.selectionNote(
        selection("/w/drakar/.claude/worktrees/x/README.md"),
        sessionFolder: URL(filePath: "/w/drakar/.claude/worktrees/x"),
        projectFolder: URL(filePath: "/w/drakar")) == nil)
    #expect(
      ComposerView.selectionNote(
        selection("/w/drakar/README.md"), sessionFolder: URL(filePath: "/w/drakar"),
        projectFolder: URL(filePath: "/w/drakar")) == nil)
  }
}

@Suite("The ⌘⌥K menu title")
struct MentionTitleTests {

  private func summary(pid: Int32?) -> SessionSummary? {
    guard let pid else { return nil }
    let liveSession = LiveSession(
      pid: pid, sessionID: "test", entrypoint: "cli", status: "idle",
      cwd: nil, waitingFor: nil, updatedAt: Date())
    // Create a minimal SessionSummary with the live session
    var summary = SessionSummary(
      sessionID: "test", account: ClaudeAccount(directory: URL(filePath: "/tmp"), isDefault: true),
      file: URL(filePath: "/tmp/test.jsonl"), modified: Date(), size: 0)
    summary.live = liveSession
    return summary
  }

  @Test func showsSessionNameWhenOnlyOneTerminalConnected() {
    let title = MentionTitle.make(connected: [123], session: summary(pid: 123))
    #expect(title == String(localized: "Mention in \u{201C}Untitled session\u{201D}"))
  }

  @Test func showsGenericWhenMultipleTerminalsConnected() {
    let title = MentionTitle.make(connected: [123, 456], session: summary(pid: 123))
    #expect(title == String(localized: "Mention in Terminal Session"))
  }

  @Test func showsGenericWhenSessionPidDoesNotMatch() {
    let title = MentionTitle.make(connected: [123], session: summary(pid: 456))
    #expect(title == String(localized: "Mention in Terminal Session"))
  }

  @Test func showsGenericWhenNoSessionConnected() {
    let title = MentionTitle.make(connected: [123], session: nil)
    #expect(title == String(localized: "Mention in Terminal Session"))
  }
}
