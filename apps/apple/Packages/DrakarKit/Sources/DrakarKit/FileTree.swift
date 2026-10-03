import Foundation

/// The folder a window works in, as the sidebar shows it: folders first, each read only
/// when it is expanded, so a `node_modules` costs one row until someone opens it.
public struct FileTree: Sendable, Equatable {
  public struct Node: Sendable, Equatable, Identifiable {
    public var path: String
    public var isDirectory: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, isDirectory: Bool) {
      self.path = path
      self.isDirectory = isDirectory
    }
  }

  /// A visible line of the tree, in display order.
  public struct Row: Sendable, Equatable, Identifiable {
    public var node: Node
    public var depth: Int
    public var isExpanded: Bool
    public var id: String { node.path }
  }

  /// Never shown: git's own store and the Finder's litter. Every other name is, dotfiles
  /// included, because `.github` and `.gitignore` are part of a project.
  static let hiddenNames: Set<String> = [".git", ".DS_Store"]

  /// The root's path, without a trailing slash.
  public let root: String
  public private(set) var expanded: Set<String> = []
  /// The listing of the root and of every expanded folder, as last read.
  private var listings: [String: [Node]] = [:]

  /// `standardized`, not `standardizedFileURL`: the latter turns `/private/tmp` into
  /// `/tmp`, and a path that no longer matches the lock file's folder is in "another
  /// project" for the `claude` that receives it.
  public init(root: URL) {
    self.root = Self.normalized(root.absoluteURL.standardized.path(percentEncoded: false))
    listings[self.root] = Self.listing(of: self.root)
  }

  public var rows: [Row] {
    var rows: [Row] = []
    func add(_ directory: String, depth: Int) {
      for node in listings[directory] ?? [] {
        let isOpen = node.isDirectory && expanded.contains(node.path)
        rows.append(Row(node: node, depth: depth, isExpanded: isOpen))
        if isOpen { add(node.path, depth: depth + 1) }
      }
    }
    add(root, depth: 0)
    return rows
  }

  public mutating func toggle(_ path: String) {
    if expanded.contains(path) {
      expanded.remove(path)
    } else {
      expand(path)
    }
  }

  public mutating func expand(_ path: String) {
    expanded.insert(path)
    listings[path] = Self.listing(of: path)
  }

  /// Expands every folder between the root and `path`, so the file's row is visible.
  /// False when `path` is not inside the root.
  @discardableResult
  public mutating func reveal(_ path: String) -> Bool {
    guard path.hasPrefix(root + "/") else { return false }
    var folder = (path as NSString).deletingLastPathComponent
    var folders: [String] = []
    while folder.count > root.count {
      folders.append(folder)
      folder = (folder as NSString).deletingLastPathComponent
    }
    for folder in folders.reversed() where !expanded.contains(folder) { expand(folder) }
    return true
  }

  /// Re-reads the folders the changed paths are in, among those on screen. A path is its
  /// own folder when it is one (a folder created or removed changes its parent's listing
  /// and, when expanded, its own).
  public mutating func refresh(changedPaths: [String]) {
    var folders = Set<String>()
    for path in changedPaths {
      let path = Self.normalized(path)
      folders.insert(path)
      folders.insert((path as NSString).deletingLastPathComponent)
    }
    for folder in folders where listings[folder] != nil {
      listings[folder] = Self.listing(of: folder)
    }
  }

  /// Changes worth reacting to: inside the root, and not git's own bookkeeping, which a
  /// `git status` alone rewrites.
  public func isRelevant(_ path: String) -> Bool {
    path.hasPrefix(root + "/") && !path.contains("/.git/") && !path.hasSuffix("/.git")
  }

  public static func listing(of directory: String) -> [Node] {
    let url = URL(filePath: directory, directoryHint: .isDirectory)
    let items =
      (try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    let nodes = items.compactMap { item -> Node? in
      let name = item.lastPathComponent
      guard !hiddenNames.contains(name) else { return nil }
      // Through a symbolic link, so a linked folder expands like the folder it points to.
      let isDirectory =
        (try? item.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
          .isDirectory) ?? false
      return Node(path: directory + "/" + name, isDirectory: isDirectory == true)
    }
    return nodes.sorted { a, b in
      if a.isDirectory != b.isDirectory { return a.isDirectory }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
  }

  /// Without a trailing slash, as every path in the tree is.
  public static func normalized(_ path: String) -> String {
    path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }
}
