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

  /// A session in a plain subfolder reads the same checkout: nothing to say.
  @Test func aSubfolderSessionIsNotMarked() {
    #expect(
      ComposerView.selectionNote(
        selection("/w/drakar/README.md"),
        sessionFolder: URL(filePath: "/w/drakar/apps/apple"),
        projectFolder: URL(filePath: "/w/drakar")) == nil)
  }

  /// A worktree made outside Claude Code is known by its `.git` file.
  @Test func aFolderWithAGitFileIsAWorktree() throws {
    let project = FileManager.default.temporaryDirectory.appending(
      path: "worktree-\(UUID().uuidString)", directoryHint: .isDirectory)
    let tree = project.appending(path: "trees/x", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: project.appending(path: ".git"), withIntermediateDirectories: true)
    try Data("gitdir: ../../.git/worktrees/x\n".utf8).write(to: tree.appending(path: ".git"))
    defer { try? FileManager.default.removeItem(at: project) }
    let readme = project.appending(path: "README.md").path(percentEncoded: false)
    #expect(
      ComposerView.selectionNote(selection(readme), sessionFolder: tree, projectFolder: project)
        == "from the main checkout")
    #expect(!ComposerView.isWorktree(project.path(percentEncoded: false)))
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
