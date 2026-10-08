import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// What the permission sheet's buttons say.
@Suite("Permission sheet")
struct PermissionSheetTests {
  private func title(toolName: String) throws -> String {
    let suggestion = try #require(PermissionSuggestion(CodexPolicy.acceptForSession, id: 0))
    let request = PermissionRequest(
      toolName: toolName, input: .object([:]), description: nil, toolUseID: nil, kind: .other)
    return PermissionSheet.title(suggestion, for: request)
  }

  @Test func aCodexFileChangeNamesTheFilesItAllows() throws {
    #expect(try title(toolName: "Edit") == "Allow, and don't ask again for these files")
  }

  @Test func aCodexCommandNamesTheCommandItAllows() throws {
    #expect(try title(toolName: "Shell") == "Allow, and don't ask again for this command")
  }

  /// A Codex patch over several files shows one diff per file, each under its own path.
  @MainActor @Test func aMultiFilePatchShowsEachFile() {
    let edits = [
      FileEdit(path: "/Users/me/p/a.swift", change: .patch("@@ -1 +1 @@\n-a\n+b\n")),
      FileEdit(path: "/Users/me/p/b.swift", change: .patch("new\n")),
      FileEdit(path: "/Users/me/p/c.swift", change: .delete(content: "gone\n")),
    ]
    let request = PermissionRequest(
      toolName: "Edit", input: .object([:]), description: nil, toolUseID: nil,
      kind: .fileChange(path: "/Users/me/p/a.swift", edits: edits))
    let changes = PermissionSheet.changes(for: request)
    #expect(
      changes.map(\.path) == ["/Users/me/p/a.swift", "/Users/me/p/b.swift", "/Users/me/p/c.swift"])
    #expect(changes.map(\.isDeleted) == [false, false, true])
  }

  /// Claude's Write is diffed against the file as it is on disk.
  @MainActor @Test func aWriteIsDiffedAgainstTheFileOnDisk() throws {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "drakar-sheet-\(UUID().uuidString).txt")
    try Data("one\ntwo\n".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let path = file.path(percentEncoded: false)
    let request = PermissionRequest(
      toolName: "Write", input: .object([:]), description: nil, toolUseID: nil,
      kind: .fileChange(
        path: path, edits: [FileEdit(path: path, change: .write(content: "one\nthree\n"))]))
    let changes = PermissionSheet.changes(for: request)
    #expect(changes.map(\.path) == [path])
    #expect(changes.first?.isNewFile == false)
    #expect(changes.first?.removedCount == 1)
  }
}
