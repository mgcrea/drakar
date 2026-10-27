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

  /// A folder opened through a link names its resolved sessions as its own: none for the
  /// folder itself, the path down from it for a subfolder, whichever side is resolved.
  @Test func aFolderOpenedThroughALinkLabelsItsResolvedSessions() throws {
    let real = FileManager.default.temporaryDirectory.appending(path: "real-\(UUID())")
    let link = FileManager.default.temporaryDirectory.appending(path: "link-\(UUID())")
    try FileManager.default.createDirectory(
      at: real.appending(path: "web/alpha"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.removeItem(at: real)
    }
    let resolved = ProjectPath.resolved(real.path(percentEncoded: false))
    let folder = link.path(percentEncoded: false)
    #expect(ProjectPath.label(of: resolved, in: folder) == nil)
    #expect(ProjectPath.label(of: resolved + "/web/alpha", in: folder) == "web/alpha")
    #expect(ProjectPath.label(of: folder + "/web/alpha", in: resolved) == "web/alpha")
  }

  @Test func transcriptFoldersBeginWithTheFoldersEncoding() {
    #expect(
      ProjectPath.encodedPrefixes(for: "/Users/me/my.app") == [
        "-Users-me-my.app", "-Users-me-my-app",
      ])
    #expect(ProjectPath.encodedPrefixes(for: "/Users/me/app") == ["-Users-me-app"])
  }

  /// Claude Code cuts a name over 200 characters to 200 and adds a hash of the whole path:
  /// the prefix is those 200, which the folder's sessions and its subfolders' all share.
  @Test func aLongFoldersPrefixIsTheCLIsFirst200Characters() {
    let folder = "/Users/me/" + String(repeating: "a", count: 250)
    let encoded = "-Users-me-" + String(repeating: "a", count: 250)
    #expect(ProjectPath.encodedPrefixes(for: folder) == [String(encoded.prefix(200))])
    let subfolder = ProjectPath.encodedPrefixes(for: folder + "/sub")
    #expect(subfolder == [String(encoded.prefix(200))])
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
