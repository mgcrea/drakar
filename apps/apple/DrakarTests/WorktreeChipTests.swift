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
