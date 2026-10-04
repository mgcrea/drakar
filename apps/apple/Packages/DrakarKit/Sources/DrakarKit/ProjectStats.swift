import Foundation

/// One transcript folder (`<config>/projects/<encoded cwd>/`), read enough to count a
/// project's sessions without opening each transcript: its session ids from the file
/// names, its newest file's date, and the `cwd` that newest file records. Every session in
/// a folder started in the same `cwd`, since the folder's name is an encoding of it.
public struct TranscriptFolder: Sendable, Equatable {
  public var account: ClaudeAccount
  public var folder: URL
  public var sessionIDs: Set<String>
  public var newest: URL
  public var newestModified: Date
  public var cwd: String?
  /// `cwd` as it sits in its main checkout: itself, unless it is in a linked worktree.
  public var checkout: String?
  /// The main checkout's top level, when `cwd` is in a git repository.
  public var repository: String?

  public init(
    account: ClaudeAccount, folder: URL, sessionIDs: Set<String>, newest: URL,
    newestModified: Date, cwd: String?, checkout: String? = nil, repository: String? = nil
  ) {
    self.account = account
    self.folder = folder
    self.sessionIDs = sessionIDs
    self.newest = newest
    self.newestModified = newestModified
    self.cwd = cwd
    self.checkout = checkout ?? cwd
    self.repository = repository
  }

  /// The path projects are matched against.
  public var projectPath: String? { checkout ?? cwd }
}

extension SessionIndex {
  /// Every transcript folder across `accounts`. A folder whose newest file is unchanged
  /// since `previous` keeps its `cwd` and checkout without a read, so a rescan after a
  /// write lists directories and opens one file.
  public static func folders(
    accounts: [ClaudeAccount], previous: [TranscriptFolder] = [],
    locate: (String) -> GitCheckout? = { GitCheckout.locate($0) }
  ) -> [TranscriptFolder] {
    let known = Dictionary(
      previous.map { ($0.folder.path(percentEncoded: false), $0) },
      uniquingKeysWith: { first, _ in first })
    var checkouts: [String: GitCheckout?] = [:]
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    var found: [TranscriptFolder] = []
    for account in accounts {
      let projects = account.directory.appending(path: "projects", directoryHint: .isDirectory)
      let folders =
        (try? manager.contentsOfDirectory(
          at: projects, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
      for folder in folders {
        let files =
          (try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        var ids: Set<String> = []
        var newest: (URL, Date)?
        for file in files where file.pathExtension == "jsonl" {
          guard let values = try? file.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true
          else { continue }
          ids.insert(file.deletingPathExtension().lastPathComponent)
          let modified = values.contentModificationDate ?? .distantPast
          if newest.map({ modified > $0.1 }) ?? true { newest = (file, modified) }
        }
        guard let (file, modified) = newest else { continue }
        var entry = TranscriptFolder(
          account: account, folder: folder, sessionIDs: ids, newest: file,
          newestModified: modified, cwd: nil)
        if let old = known[folder.path(percentEncoded: false)], old.newest == file,
          old.newestModified == modified
        {
          (entry.cwd, entry.checkout, entry.repository) = (old.cwd, old.checkout, old.repository)
        } else if let data = try? Data(contentsOf: file, options: .alwaysMapped),
          let cwd = lastValue(of: "cwd", inLineOfType: nil, in: data)
        {
          let checkout = checkouts[cwd] ?? locate(cwd)
          checkouts[cwd] = checkout
          entry.cwd = cwd
          entry.checkout = checkout?.inMain(cwd) ?? ProjectPath.normalize(cwd)
          entry.repository = checkout?.main
        }
        found.append(entry)
      }
    }
    return found
  }
}

/// What a project's row on home says about it.
public struct ProjectStats: Sendable, Equatable {
  /// Distinct session ids: one resumed under a second account is still one session.
  public var sessionCount = 0
  public var lastActivity: Date?
  /// The most recently written transcript, for the row's gauge.
  public var newest: URL?
  public var newestAccount: ClaudeAccount?
  /// Live sessions the registry reports busy, and waiting for the person.
  public var running = 0
  public var waiting = 0

  public init() {}

  /// Every project's stats, a project with no session included. A session belongs to the
  /// deepest project containing its folder, after a linked worktree's folder is moved into
  /// its main checkout by `checkout`.
  public static func compute(
    projects: [String], folders: [TranscriptFolder], live: [LiveSession],
    checkout: (String) -> String = { $0 }
  ) -> [String: ProjectStats] {
    let owners = ProjectPath.Owners(projects)
    var stats: [String: ProjectStats] = [:]
    var ids: [String: Set<String>] = [:]
    for project in projects { stats[ProjectPath.normalize(project)] = ProjectStats() }
    for folder in folders {
      guard let path = folder.projectPath, let owner = owners.owner(of: path) else { continue }
      ids[owner, default: []].formUnion(folder.sessionIDs)
      if stats[owner]?.lastActivity.map({ folder.newestModified > $0 }) ?? true {
        stats[owner]?.lastActivity = folder.newestModified
        stats[owner]?.newest = folder.newest
        stats[owner]?.newestAccount = folder.account
      }
    }
    for (owner, set) in ids { stats[owner]?.sessionCount = set.count }
    var seen: Set<String> = []
    for session in live where seen.insert(session.sessionID).inserted {
      guard let cwd = session.cwd, let owner = owners.owner(of: checkout(cwd)) else { continue }
      switch session.status {
      case "busy": stats[owner]?.running += 1
      case "waiting": stats[owner]?.waiting += 1
      default: break
      }
      if let updated = session.updatedAt, stats[owner]?.lastActivity.map({ updated > $0 }) ?? true {
        stats[owner]?.lastActivity = updated
      }
    }
    return stats
  }
}

/// A folder with recent sessions that no tracked project owns, offered on home.
public struct FolderSuggestion: Sendable, Equatable, Identifiable {
  public var path: String
  public var lastActivity: Date
  public var sessionCount: Int

  public var id: String { path }
}

public enum FolderSuggestions {
  /// Folders no project should be: the home folder and the root.
  public static let defaultExcluded: Set<String> = [
    ProjectPath.normalize(
      FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)),
    "/",
  ]

  /// Where scratch work runs, both ways each is spelled.
  public static let defaultTemporary: [String] =
    ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    + Array(LiveSession.defaultTemporaryDirectories)

  /// Folders with a session in the last `maxAge`, as their repository's top level (or
  /// their own `cwd` outside one), newest first. Not suggested: what a tracked project
  /// owns, temporary folders, the home folder, and one hidden since its last session.
  public static func compute(
    folders: [TranscriptFolder], tracked: [String], hidden: [String: Date], now: Date,
    maxAge: TimeInterval = 30 * 24 * 3600,
    temporary: [String] = defaultTemporary, excluded: Set<String> = defaultExcluded
  ) -> [FolderSuggestion] {
    let owners = ProjectPath.Owners(tracked)
    var ids: [String: Set<String>] = [:]
    var latest: [String: Date] = [:]
    for folder in folders where folder.newestModified >= now.addingTimeInterval(-maxAge) {
      guard let path = folder.projectPath, owners.owner(of: path) == nil,
        !temporary.contains(where: { ProjectPath.contains($0, path) })
      else { continue }
      let suggested = ProjectPath.normalize(folder.repository ?? path)
      guard !excluded.contains(suggested), owners.owner(of: suggested) == nil else { continue }
      ids[suggested, default: []].formUnion(folder.sessionIDs)
      latest[suggested] = max(latest[suggested] ?? .distantPast, folder.newestModified)
    }
    return latest.compactMap { path, date in
      if let hiddenAt = hidden[path], hiddenAt >= date { return nil }
      return FolderSuggestion(path: path, lastActivity: date, sessionCount: ids[path]?.count ?? 0)
    }
    .sorted {
      $0.lastActivity == $1.lastActivity ? $0.path < $1.path : $0.lastActivity > $1.lastActivity
    }
  }
}

/// The projects the person tracks, as Drakar stores them: app-wide, by folder.
public struct TrackedProjects: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var added: Date

    public var id: String { path }
  }

  public var projects: [Entry] = []
  /// Suggestions hidden, with when: one comes back once a newer session appears in it.
  public var hidden: [String: Date] = [:]

  public init(projects: [Entry] = [], hidden: [String: Date] = [:]) {
    self.projects = projects
    self.hidden = hidden
  }

  /// The stored value, or an empty list when there is none or it does not decode: a broken
  /// value must not stop home from opening.
  public static func decode(_ data: Data?) -> TrackedProjects {
    guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
      return TrackedProjects()
    }
    return decoded
  }

  public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

  public var paths: [String] { projects.map(\.path) }

  public func contains(_ path: String) -> Bool { paths.contains(ProjectPath.normalize(path)) }

  /// Tracks `path`; false when it already was.
  @discardableResult public mutating func track(_ path: String, at date: Date = .now) -> Bool {
    let path = ProjectPath.normalize(path)
    guard !contains(path) else { return false }
    projects.append(Entry(path: path, added: date))
    hidden[path] = nil
    return true
  }

  public mutating func remove(_ path: String) {
    let path = ProjectPath.normalize(path)
    projects.removeAll { $0.path == path }
  }

  public mutating func hide(_ path: String, at date: Date = .now) {
    hidden[ProjectPath.normalize(path)] = date
  }

  /// Most recently active first; a project with no session by when it was added.
  public func ordered(by stats: [String: ProjectStats]) -> [Entry] {
    projects.sorted { a, b in
      let left = stats[a.path]?.lastActivity ?? a.added
      let right = stats[b.path]?.lastActivity ?? b.added
      return left == right ? a.path < b.path : left > right
    }
  }
}
