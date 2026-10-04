import Foundation

/// What a folder's `.git` is: a repository's own directory, a file pointing at one (a
/// linked worktree, or a submodule), or nothing.
public enum GitEntry: Sendable, Equatable {
  case none
  case directory
  case file(String)
}

/// The git working tree a path is in, and the main checkout behind it: a linked worktree
/// (`git worktree add ../repo-feature`) counts as its main repo, so a project shows its
/// worktrees' sessions as its own.
public struct GitCheckout: Sendable, Equatable {
  /// The working tree's top level: the folder holding `.git`.
  public var root: String
  /// The main checkout's top level: `root` itself, unless `root` is a linked worktree.
  public var main: String

  public init(root: String, main: String) {
    self.root = root
    self.main = main
  }

  /// The working tree containing `path`, found by walking up to the first `.git`. `entry`
  /// reads one `.git`; tests pass a dictionary instead of a repository on disk.
  public static func locate(
    _ path: String, entry: (String) -> GitEntry = GitCheckout.entry
  ) -> GitCheckout? {
    var folder = ProjectPath.normalize(path)
    while true {
      switch entry(folder == "/" ? "/.git" : folder + "/.git") {
      case .directory:
        return GitCheckout(root: folder, main: folder)
      case .file(let text):
        return GitCheckout(root: folder, main: main(of: folder, gitFile: text) ?? folder)
      case .none:
        guard folder != "/", !folder.isEmpty else { return nil }
        folder = (folder as NSString).deletingLastPathComponent
      }
    }
  }

  /// `path` as it sits in the main checkout: `<worktree>/apps` → `<main>/apps`.
  public func inMain(_ path: String) -> String {
    let path = ProjectPath.normalize(path)
    guard root != main, ProjectPath.contains(root, path) else { return path }
    return main + path.dropFirst(root.count)
  }

  /// The main checkout a `gitdir:` line names, when it names a worktree's: a worktree's
  /// git directory is `<main>/.git/worktrees/<name>`. A submodule's
  /// (`<super>/.git/modules/<name>`) is its own repository, and answers nil.
  static func main(of folder: String, gitFile text: String) -> String? {
    guard
      let line = text.split(whereSeparator: \.isNewline).first(where: {
        $0.hasPrefix("gitdir:")
      })
    else { return nil }
    let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    let gitDir = ProjectPath.normalize(raw.hasPrefix("/") ? raw : folder + "/" + raw)
    guard let range = gitDir.range(of: "/.git/worktrees/") else { return nil }
    let main = String(gitDir[..<range.lowerBound])
    return main.isEmpty ? "/" : main
  }

  /// The `.git` at `path` on disk. Only a small file is read: a `gitdir:` line is a path.
  public static func entry(_ path: String) -> GitEntry {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
      return .none
    }
    if isDirectory.boolValue { return .directory }
    guard let handle = FileHandle(forReadingAtPath: path) else { return .none }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 4096)) ?? Data()
    return .file(String(decoding: data, as: UTF8.self))
  }
}
