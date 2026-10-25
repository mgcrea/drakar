import DrakarKit
import Foundation
import Testing

@Suite("A parent folder's subfolders")
struct SubfolderScanTests {
  private let parent: URL

  init() throws {
    parent = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-subfolders-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  }

  private func folder(_ name: String) throws -> URL {
    let url = parent.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Folders only, hidden ones skipped, in Finder's order (2 before 10).
  @Test func listsVisibleFoldersInFinderOrder() throws {
    _ = try folder("app10")
    _ = try folder("app2")
    _ = try folder(".cache")
    try Data().write(to: parent.appending(path: "README.md"))
    #expect(SubfolderScan.children(of: parent).map(\.name) == ["app2", "app10"])
  }

  /// A `.git` folder, or a `.git` file (a linked worktree), makes a repository.
  @Test func marksGitRepositories() throws {
    try FileManager.default.createDirectory(
      at: try folder("repo").appending(path: ".git"), withIntermediateDirectories: true)
    try Data("gitdir: /elsewhere\n".utf8).write(to: try folder("worktree").appending(path: ".git"))
    _ = try folder("plain")
    let found = Dictionary(
      uniqueKeysWithValues: SubfolderScan.children(of: parent).map { ($0.name, $0.isGitRepository) }
    )
    #expect(found == ["plain": false, "repo": true, "worktree": true])
  }

  /// A link to a folder is a folder; a link to a file, or to nothing, is not.
  @Test func followsLinksToFolders() throws {
    let target = try folder("target")
    try FileManager.default.createSymbolicLink(
      at: parent.appending(path: "linked"), withDestinationURL: target)
    try FileManager.default.createSymbolicLink(
      at: parent.appending(path: "dangling"),
      withDestinationURL: parent.appending(path: "gone"))
    #expect(SubfolderScan.children(of: parent).map(\.name) == ["linked", "target"])
  }

  /// A parent that can't be read has no subfolders.
  @Test func aMissingParentHasNone() {
    #expect(SubfolderScan.children(of: parent.appending(path: "nope")).isEmpty)
  }

  /// The first component below the project, for a session in a subfolder.
  @Test func childOfASessionFolder() {
    #expect(ProjectPath.child(of: "/p/apps/drakar/src", below: "/p/apps") == "drakar")
    #expect(ProjectPath.child(of: "/p/apps/drakar/", below: "/p/apps/") == "drakar")
    #expect(ProjectPath.child(of: "/p/other", below: "/p/apps") == nil)
  }

  /// None for the project itself, nor below a hidden folder (a worktree has its own label).
  @Test func noChildForTheRootOrAHiddenFolder() {
    #expect(ProjectPath.child(of: "/p/apps", below: "/p/apps") == nil)
    #expect(ProjectPath.child(of: "/p/apps/.claude/worktrees/x", below: "/p/apps") == nil)
  }

  /// The toolbar's name for a session's folder: none for the project's own, the path down
  /// from the project, a worktree's name, or the folder's name outside the project.
  @Test func folderLabels() {
    #expect(ProjectPath.label(of: "/p/apps/", in: "/p/apps") == nil)
    #expect(ProjectPath.label(of: "/p/apps/alpha", in: "/p/apps") == "alpha")
    #expect(ProjectPath.label(of: "/p/apps/web/alpha/", in: "/p/apps/") == "web/alpha")
    #expect(ProjectPath.label(of: "/p/apps/.claude/worktrees/fix-x", in: "/p/apps") == "fix-x")
    #expect(ProjectPath.label(of: "/p/apps/.claude/worktrees/fix-x/src", in: "/p/apps") == "fix-x")
    #expect(ProjectPath.label(of: "/p/other/beta", in: "/p/apps") == "beta")
  }
}
