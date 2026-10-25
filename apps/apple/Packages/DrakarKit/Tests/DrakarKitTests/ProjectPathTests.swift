import DrakarKit
import Foundation
import Testing

@Suite("Which project a folder is in")
struct ProjectPathTests {

  @Test func containsOnWholeComponents() {
    #expect(ProjectPath.contains("/work/drakar", "/work/drakar"))
    #expect(ProjectPath.contains("/work/drakar/", "/work/drakar/apps/apple"))
    #expect(!ProjectPath.contains("/work/drakar", "/work/drakar-old"))
    #expect(!ProjectPath.contains("/work/drakar", "/work"))
  }

  @Test func theDeepestOpenFolderOwnsASession() {
    let folders = ["/work/drakar", "/work/drakar/apps/apple"]
    #expect(
      ProjectPath.owner(of: "/work/drakar/apps/apple/Drakar", among: folders)
        == "/work/drakar/apps/apple")
    #expect(
      ProjectPath.owner(of: "/work/drakar/.claude/worktrees/x", among: folders) == "/work/drakar")
    #expect(ProjectPath.owner(of: "/work/other", among: folders) == nil)
  }

  /// Claude Code records the resolved cwd; a folder opened through a link still owns it.
  @Test func aFolderOpenedThroughALinkOwnsItsResolvedSessions() throws {
    let real = FileManager.default.temporaryDirectory.appending(path: "real-\(UUID())")
    let link = FileManager.default.temporaryDirectory.appending(path: "link-\(UUID())")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.removeItem(at: real)
    }
    let cwd = ProjectPath.resolved(real.path(percentEncoded: false)) + "/sub"
    let folder = link.path(percentEncoded: false)
    #expect(ProjectPath.owner(of: cwd, among: [folder]) == ProjectPath.normalize(folder))
    #expect(ProjectPath.Owners([folder]).owner(of: cwd) == ProjectPath.normalize(folder))
  }

  @Test func transcriptFoldersBeginWithTheFoldersEncoding() {
    #expect(
      ProjectPath.encodedPrefixes(for: "/Users/me/my.app") == [
        "-Users-me-my.app", "-Users-me-my-app",
      ])
    #expect(ProjectPath.encodedPrefixes(for: "/Users/me/app") == ["-Users-me-app"])
  }

  /// Claude Code keeps ASCII letters and digits only (`replace(/[^a-zA-Z0-9]/g,"-")`, in
  /// 2.1.308): an accented letter is a `-` too.
  @Test func anAccentedLetterIsADashLikeAnyOtherCharacter() {
    #expect(
      ProjectPath.encodedPrefixes(for: "/Users/me/Développement/app") == [
        "-Users-me-Développement-app", "-Users-me-D-veloppement-app",
      ])
  }
}
