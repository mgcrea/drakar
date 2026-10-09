import Foundation

/// Skill locations on disk, resolved through their links: a folder reached by a link and by
/// its own path is one skill.
public enum SkillPath {
  /// `path` with its links resolved, as `URL.resolvingSymlinksInPath` does (which also drops
  /// `/private` from `/private/var/…`), without a trailing slash.
  public static func real(_ path: String) -> String {
    ProjectPath.normalize(
      URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false))
  }

  /// Whether `path` itself is a symbolic link, whatever it points to.
  public static func isLink(_ path: String) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
  }

  /// Where the link at `path` points, made absolute; nil when `path` is not a link.
  public static func target(ofLink path: String) -> String? {
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    else { return nil }
    if destination.hasPrefix("/") { return ProjectPath.normalize(destination) }
    let parent = URL(filePath: path).deletingLastPathComponent()
    return ProjectPath.normalize(
      parent.appending(path: destination).standardized.path(percentEncoded: false))
  }
}
