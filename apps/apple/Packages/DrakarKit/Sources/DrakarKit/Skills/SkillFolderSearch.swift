import Foundation

/// The skills a folder offers for an install: the folder chosen in Install from Folder…, or
/// a git clone.
public enum SkillFolderSearch {
  /// `folder` itself when it holds a SKILL.md; else its folders that do, `depth` levels down
  /// at most, in path order. Hidden folders, `node_modules` and linked folders are skipped, so
  /// the search never leaves `folder` nor finds a skill twice; a skill's own folders are not
  /// searched.
  public static func skills(in folder: URL, depth: Int) -> [URL] {
    let manager = FileManager.default
    func holdsSkill(_ url: URL) -> Bool {
      manager.fileExists(atPath: url.appending(path: "SKILL.md").path(percentEncoded: false))
    }
    if holdsSkill(folder) { return [folder] }
    var found: [URL] = []
    var level = [folder]
    for _ in 0..<depth {
      var next: [URL] = []
      for parent in level {
        let names =
          ((try? manager.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) ?? [])
          .filter { !$0.hasPrefix(".") && $0 != "node_modules" }.sorted()
        for name in names {
          let child = parent.appending(path: name, directoryHint: .isDirectory)
          // The item itself, not what a link leads to: no trailing slash, which lstat follows.
          let item = parent.appending(path: name, directoryHint: .notDirectory)
          let type = try? manager.attributesOfItem(atPath: item.path(percentEncoded: false))[.type]
          guard type as? FileAttributeType == .typeDirectory else { continue }
          if holdsSkill(child) { found.append(child) } else { next.append(child) }
        }
      }
      level = next
    }
    return found.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
  }
}
