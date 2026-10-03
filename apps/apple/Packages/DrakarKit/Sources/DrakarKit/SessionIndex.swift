import Foundation

/// A Claude Code configuration directory: `~/.claude`, or another one selected with
/// `CLAUDE_CONFIG_DIR` (`~/.claude-work`). Each holds its own login, settings and
/// sessions, so a session has to be resumed under the directory that wrote it.
public struct ClaudeAccount: Sendable, Hashable {
  public var directory: URL
  public var isDefault: Bool

  public init(directory: URL, isDefault: Bool) {
    self.directory = directory
    self.isDefault = isDefault
  }

  /// `default`, or what follows `.claude-` in the directory's name.
  public var name: String {
    if isDefault { return "default" }
    let folder = directory.lastPathComponent
    return folder.hasPrefix(".claude-") ? String(folder.dropFirst(8)) : folder
  }

  /// The environment a `claude` for this account runs with. The default directory is
  /// selected by leaving `CLAUDE_CONFIG_DIR` unset rather than naming it, because the CLI
  /// keys its keychain item by the variable, not by the path it resolves to.
  public func environment(_ base: [String: String]) -> [String: String] {
    var environment = base
    environment["CLAUDE_CONFIG_DIR"] = isDefault ? nil : directory.path(percentEncoded: false)
    return environment
  }

  /// `~/.claude`, every `~/.claude-*` holding a `projects` folder, and any `extra`
  /// directories (the shell's own `CLAUDE_CONFIG_DIR`), without duplicates.
  public static func discover(
    home: URL = FileManager.default.homeDirectoryForCurrentUser, extra: [URL] = []
  ) -> [ClaudeAccount] {
    let manager = FileManager.default
    let standard = home.appending(path: ".claude", directoryHint: .isDirectory)
    let others =
      ((try? manager.contentsOfDirectory(atPath: home.path(percentEncoded: false))) ?? [])
      .filter { $0.hasPrefix(".claude-") }
      .sorted()
      .map { home.appending(path: $0, directoryHint: .isDirectory) }
    var seen = Set<String>()
    return ([standard] + others + extra).compactMap { directory in
      let key = directory.standardizedFileURL.path(percentEncoded: false)
      let projects = directory.appending(path: "projects").path(percentEncoded: false)
      guard seen.insert(key).inserted, manager.fileExists(atPath: projects) else { return nil }
      return ClaudeAccount(
        directory: directory,
        isDefault: key == standard.standardizedFileURL.path(percentEncoded: false))
    }
  }
}

/// One session on disk, read enough to list it.
public struct SessionSummary: Sendable, Hashable, Identifiable {
  public var sessionID: String
  public var account: ClaudeAccount
  public var file: URL
  /// The folder the session worked in, from inside the transcript: the project folder's
  /// name is an encoding of it that cannot be reversed (every `/` and `.` became `-`).
  public var cwd: String?
  public var title: String?
  public var lastPrompt: String?
  public var modified: Date
  public var size: Int
  /// Set when a `claude` process has the session open right now.
  public var live: LiveSession?

  /// The transcript's path, not the session id: one id can have a transcript under two
  /// accounts, when a session was resumed after switching `CLAUDE_CONFIG_DIR`.
  public var id: String { file.path(percentEncoded: false) }

  public var displayTitle: String {
    title ?? lastPrompt.map { String($0.prefix(120)) } ?? String(localized: "Untitled session")
  }
}

public enum SessionIndex {
  /// The `limit` most recently written sessions across `accounts`, newest first.
  ///
  /// Ordered by file date before any file is opened, so only the sessions shown are read.
  /// A session that was never prompted has no file and is not listed.
  public static func list(
    accounts: [ClaudeAccount], limit: Int = 200,
    isAlive: (Int32) -> Bool = LiveSession.isAlive
  ) -> [SessionSummary] {
    // Per account: one id can have a transcript under two accounts, and a process has
    // only the one its own registry is in open.
    var live: [ClaudeAccount: [String: LiveSession]] = [:]
    for account in accounts {
      for session in LiveSession.read(account: account, isAlive: isAlive) {
        live[account, default: [:]][session.sessionID] = session
      }
    }
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
    var found: [(URL, ClaudeAccount, Date, Int)] = []
    for account in accounts {
      let projects = account.directory.appending(path: "projects", directoryHint: .isDirectory)
      let folders =
        (try? manager.contentsOfDirectory(
          at: projects, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
      for folder in folders {
        // Only `<session id>.jsonl` directly inside: subagent transcripts live in a
        // folder named after their parent session, and memory in its own.
        let files =
          (try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        for file in files where file.pathExtension == "jsonl" {
          guard let values = try? file.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true
          else { continue }
          found.append(
            (file, account, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
      }
    }
    return found.sorted { $0.2 > $1.2 }.prefix(limit).map { file, account, modified, size in
      var summary = summarize(file: file, account: account, modified: modified, size: size)
      summary.live = live[account]?[summary.sessionID]
      return summary
    }
  }

  static func summarize(file: URL, account: ClaudeAccount, modified: Date, size: Int)
    -> SessionSummary
  {
    var summary = SessionSummary(
      sessionID: file.deletingPathExtension().lastPathComponent, account: account, file: file,
      modified: modified, size: size)
    guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return summary }
    summary.title = lastValue(of: "aiTitle", inLineOfType: "ai-title", in: data)
    summary.lastPrompt = lastValue(of: "lastPrompt", inLineOfType: "last-prompt", in: data)
    summary.cwd = lastValue(of: "cwd", inLineOfType: nil, in: data)
    return summary
  }

  /// The string at `key` in the last line that has it (and, if `type` is given, has that
  /// `type`), searching the mapped file backwards from its end: the newest title is
  /// usually near the end, so usually only the last pages are read.
  static func lastValue(of key: String, inLineOfType type: String?, in data: Data) -> String? {
    let needle = Data("\"\(key)\":\"".utf8)
    var end = data.endIndex
    while let match = data.range(of: needle, options: .backwards, in: data.startIndex..<end) {
      let lineStart =
        data[..<match.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
      let lineEnd = data[match.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
      if let json = try? JSONValue.parse(data[lineStart..<lineEnd]),
        type == nil || json["type"]?.stringValue == type,
        let value = json[key]?.stringValue, !value.isEmpty
      {
        return value
      }
      end = lineStart
    }
    return nil
  }
}

/// A `claude` process that has a session open, from the registry it keeps at
/// `<config>/sessions/<pid>.json` (Armada's `docs/claude-code-sessions.md`). The registry
/// prunes itself, but a crashed process can leave its file, so the pid is checked too.
public struct LiveSession: Sendable, Hashable {
  public var pid: Int32
  public var sessionID: String
  /// `claude-vscode`, `cli`, or `sdk-cli` for a headless one (Drakar's own among them).
  public var entrypoint: String?
  /// `busy`, `waiting` or `idle`.
  public var status: String?

  public static func read(account: ClaudeAccount, isAlive: (Int32) -> Bool = isAlive)
    -> [LiveSession]
  {
    let folder = account.directory.appending(path: "sessions", directoryHint: .isDirectory)
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { file in
      guard let data = try? Data(contentsOf: file), let json = try? JSONValue.parse(data),
        let pid = json["pid"]?.intValue.flatMap(Int32.init(exactly:)),
        let id = json["sessionId"]?.stringValue, isAlive(pid)
      else { return nil }
      return LiveSession(
        pid: pid, sessionID: id, entrypoint: json["entrypoint"]?.stringValue,
        status: json["status"]?.stringValue)
    }
  }

  /// Whether a process with this pid exists, including one we may not signal.
  public static func isAlive(_ pid: Int32) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
  }
}
