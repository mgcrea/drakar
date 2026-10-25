import Foundation

/// One folder directly inside a parent, as a batch of sessions can start in it.
public struct Subfolder: Sendable, Hashable, Identifiable {
  public var url: URL
  public var name: String
  /// It holds a `.git` folder, or a `.git` file as a linked worktree does.
  public var isGitRepository: Bool

  public var id: URL { url }

  public init(url: URL, name: String, isGitRepository: Bool) {
    self.url = url
    self.name = name
    self.isGitRepository = isGitRepository
  }
}

/// A parent folder's immediate subfolders (docs/superpowers/specs/2026-10-12-skill-fanout-design.md
/// §1): folders and links to folders, hidden ones left out, in Finder's order. Reads the
/// listing and one entry per child, nothing deeper.
public enum SubfolderScan {
  public static func children(of parent: URL) -> [Subfolder] {
    let manager = FileManager.default
    let root = ProjectPath.normalize(parent)
    let names = (try? manager.contentsOfDirectory(atPath: root)) ?? []
    return names.filter { !$0.hasPrefix(".") }
      .compactMap { name -> Subfolder? in
        let path = root + "/" + name
        var isFolder: ObjCBool = false
        // `fileExists` follows links: a link to a folder is one, a dangling link is nothing.
        guard manager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue
        else { return nil }
        return Subfolder(
          url: URL(filePath: path, directoryHint: .isDirectory), name: name,
          isGitRepository: manager.fileExists(atPath: path + "/.git"))
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
