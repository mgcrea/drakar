import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
struct GitStatusTests {
  @Test func readsTheRepositoryFromAProjectSubfolder() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "drakar-git-\(UUID())", directoryHint: .isDirectory)
    let nested = root.appending(path: "nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let initialized = try await ProcessRunner.run(
      URL(filePath: "/usr/bin/git"), ["init", "--initial-branch=work"],
      currentDirectory: root, timeout: .seconds(8))
    try #require(initialized.status == 0)
    try Data("change".utf8).write(to: nested.appending(path: "new file.txt"))

    let result = await GitStatus.read(in: nested)
    guard case .repository(let status) = result else {
      Issue.record("Expected a Git repository")
      return
    }
    #expect(
      status.root.resolvingSymlinksInPath().path(percentEncoded: false)
        == root.resolvingSymlinksInPath().path(percentEncoded: false))
    #expect(status.branch == "work")
    #expect(status.changes.map(\.path) == ["nested/new file.txt"])
  }

  @Test func parsesRenamePathsWithoutTreatingTheSourceAsAnotherChange() {
    let records = [
      "# branch.oid 0123456789abcdef",
      "# branch.head (detached)",
      "2 R. N... 100644 100644 100644 a b R100  new\nname.swift",
      "? old name.swift",
      "1 D. N... 100644 000000 000000 a b restored.swift",
      "? restored.swift",
      "u UU N... 100644 100644 100644 100644 a b c conflict.swift",
    ]
    let status = GitStatus(
      root: URL(filePath: "/repo"), output: Data(records.joined(separator: "\0").utf8) + Data([0]))

    #expect(status.branch == "0123456")
    #expect(
      status.changes.map(\.path) == [
        " new\nname.swift", "restored.swift", "restored.swift", "conflict.swift",
      ])
    #expect(status.changes.map(\.code) == ["R.", "D.", "??", "UU"])
    #expect(status.changes.first?.originalPath == "? old name.swift")
    #expect(status.changes.map(\.canOpen) == [true, false, true, true])
    #expect(Set(status.changes.map(\.id)).count == status.changes.count)
  }

  @Test func marksSubmodulesAndUntrackedDirectoriesAsNotOpenable() {
    let records = [
      "1 .M S.M. 160000 160000 160000 a b vendor/sub",
      "? nested-repo/",
      "1 .M N... 100644 100644 100644 a b file.swift",
    ]
    let status = GitStatus(
      root: URL(filePath: "/repo"), output: Data(records.joined(separator: "\0").utf8) + Data([0]))

    #expect(status.changes.map(\.canOpen) == [false, false, true])
    #expect(status.changes.map(\.existsOnDisk) == [true, true, true])
  }

  @Test func opensResolvedGitPathsInTheSameTabAsSymlinkedWorkspacePaths() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "drakar-symlink-\(UUID())", directoryHint: .isDirectory)
    let realFolder = root.appending(path: "real", directoryHint: .isDirectory)
    let linkFolder = root.appending(path: "link", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createSymbolicLink(at: linkFolder, withDestinationURL: realFolder)
    let initialized = try await ProcessRunner.run(
      URL(filePath: "/usr/bin/git"), ["init", "--initial-branch=work"],
      currentDirectory: realFolder, timeout: .seconds(8))
    try #require(initialized.status == 0)
    try Data("hello\n".utf8).write(to: realFolder.appending(path: "note.txt"))

    let workspace = Workspace(folder: linkFolder)
    let fromTree = try #require(workspace.open(linkFolder.appending(path: "note.txt")))
    guard case .repository(let status) = await GitStatus.read(in: linkFolder) else {
      Issue.record("Expected a Git repository")
      return
    }
    let change = try #require(status.changes.first { $0.path == "note.txt" })
    let fromGit = workspace.open(status.root.appending(path: change.path))

    #expect(fromGit === fromTree)
    #expect(workspace.documents.count == 1)
  }

  @Test func keepsRepositoryStatusAcrossASingleTransientFailure() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "drakar-git-state-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = Workspace(folder: root)
    let repo = GitStatus(root: root, output: Data("# branch.head main\0".utf8))

    await workspace.refreshGitStatus { _ in .repository(repo) }
    guard case .repository(let first) = workspace.gitStatus else {
      Issue.record("Expected repository status")
      return
    }
    #expect(first.branch == "main")

    await workspace.refreshGitStatus { _ in .unavailable }
    guard case .repository(let kept) = workspace.gitStatus else {
      Issue.record("Expected repository status to survive a single transient failure")
      return
    }
    #expect(kept.branch == "main")

    await workspace.refreshGitStatus { _ in .unavailable }
    guard case .unavailable = workspace.gitStatus else {
      Issue.record("Expected unavailable status after consecutive failures")
      return
    }
  }
}
