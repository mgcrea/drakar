import Darwin
import DrakarKit
import Foundation
import SQLite3

/// Lists ended sessions from provider metadata without opening or modifying their transcripts.
nonisolated enum ProviderSessionIndex {
  static func list(codex: URL, grok: URL, antigravity: URL) -> [SessionSummary] {
    codexSessions(in: codex) + grokSessions(in: grok) + antigravitySessions(in: antigravity)
  }

  /// Reads metadata for one restored session without spawning its CLI.
  static func summary(sessionID: String, provider: String, home: URL, file: String) -> SessionSummary? {
    switch provider {
    case "codex":
      return codexSummary(sessionID: sessionID, home: home, fallbackFile: URL(filePath: file))
    case "grok":
      return grokSummary(sessionID: sessionID, home: home, file: file)
    case "agy":
      return antigravitySummary(sessionID: sessionID, home: home)
    default:
      return nil
    }
  }

  private static func codexDatabase(in home: URL) -> URL? {
    // Use the newest schema installed in this home.
    let databases = children(home).compactMap { file -> (Int, URL)? in
      let stem = file.deletingPathExtension().lastPathComponent
      guard file.pathExtension == "sqlite", stem.hasPrefix("state_"),
        let version = Int(stem.dropFirst("state_".count))
      else { return nil }
      return (version, file)
    }
    return databases.max(by: { $0.0 < $1.0 })?.1
  }

  private static func codexSessions(in home: URL) -> [SessionSummary] {
    let locks = children(home.appending(path: "thread-writer-locks"))
    let active = Set(
      locks.filter { $0.pathExtension == "lock" }.map {
        $0.deletingPathExtension().lastPathComponent
      })
    guard let database = codexDatabase(in: home) else { return [] }
    // Only select columns shared by the thread databases, and leave Codex's own archived
    // threads in Codex.
    let threads = """
      FROM threads WHERE archived = 0 AND source NOT LIKE '%"subagent"%'
      """
    return read(
      database,
      "SELECT id, cwd, rollout_path, coalesce(nullif(trim(name), ''), title), updated_at \(threads)",
      fallbackSQL: "SELECT id, cwd, rollout_path, title, updated_at \(threads)"
    ) { row in
      let id = column(row, 0)
      let cwd = column(row, 1)
      let path = column(row, 2)
      guard !active.contains(id), !path.isEmpty else { return nil }
      return summary(
        id: id, cwd: cwd, title: column(row, 3), home: home,
        file: URL(filePath: path),
        modified: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)),
        provider: "codex")
    }
  }

  private static func codexSummary(sessionID: String, home: URL, fallbackFile: URL) -> SessionSummary? {
    guard let database = codexDatabase(in: home) else { return nil }
    return read(
      database,
      "SELECT id, cwd, rollout_path, coalesce(nullif(trim(name), ''), title), updated_at FROM threads WHERE id = ?",
      fallbackSQL: "SELECT id, cwd, rollout_path, title, updated_at FROM threads WHERE id = ?",
      bind: { bindText($0, 1, sessionID) }
    ) { row in
      let id = column(row, 0)
      let cwd = column(row, 1)
      let path = column(row, 2)
      let file = path.isEmpty ? fallbackFile : URL(filePath: path)
      return restoredSummary(
        id: id, cwd: cwd, title: column(row, 3), home: home, file: file,
        modified: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)), provider: "codex")
    }.first
  }

  private static func grokSessions(in home: URL) -> [SessionSummary] {
    let registry = try? Data(contentsOf: home.appending(path: "active_sessions.json"))
    let entries =
      registry.flatMap { try? JSONSerialization.jsonObject(with: $0) }
      as? [[String: Any]] ?? []
    let active = Set(
      entries.compactMap { entry -> String? in
        guard let pid = (entry["pid"] as? NSNumber)?.int32Value, pid > 0,
          LiveSession.isAlive(pid)
        else { return nil }
        return (entry["session_id"] as? String)?.lowercased()
      })
    return children(home.appending(path: "sessions")).flatMap { project in
      children(project).compactMap { directory in
        guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
        return grokSummary(
          from: directory.appending(path: "summary.json"), home: home, excluding: active)
      }
    }
  }

  private static func grokSummary(sessionID: String, home: URL, file: String) -> SessionSummary? {
    if !file.isEmpty {
      let url = URL(filePath: file)
      if FileManager.default.fileExists(atPath: url.path),
        let parsed = grokSummary(from: url, home: home, excluding: [], requireValidCwd: false)
      {
        return parsed
      }
    }
    let target = sessionID.lowercased()
    for project in children(home.appending(path: "sessions")) {
      for directory in children(project)
      where directory.lastPathComponent.lowercased() == target {
        let summaryFile = directory.appending(path: "summary.json")
        if let parsed = grokSummary(
          from: summaryFile, home: home, excluding: [], requireValidCwd: false)
        {
          return parsed
        }
      }
    }
    return nil
  }

  private static func grokSummary(
    from file: URL, home: URL, excluding active: Set<String>, requireValidCwd: Bool = true
  ) -> SessionSummary? {
    guard let data = try? Data(contentsOf: file),
      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let info = metadata["info"] as? [String: Any],
      let id = (info["id"] as? String)?.lowercased(), !active.contains(id)
    else { return nil }
    let cwd = info["cwd"] as? String ?? ""
    if requireValidCwd && !cwd.hasPrefix("/") { return nil }
    let timestamp =
      (metadata["last_active_at"] as? String) ?? (metadata["updated_at"] as? String)
    let modified =
      timestamp.flatMap(date)
      ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
    guard let modified else { return nil }
    let title =
      (metadata["generated_title"] as? String).flatMap(nonEmpty)
      ?? metadata["session_summary"] as? String
    if requireValidCwd {
      return summary(
        id: id, cwd: cwd, title: title, home: home, file: file, modified: modified, provider: "grok")
    }
    return restoredSummary(
      id: id, cwd: cwd, title: title, home: home, file: file, modified: modified, provider: "grok")
  }

  private static func antigravitySessions(in home: URL) -> [SessionSummary] {
    let lastFile = home.appending(path: "cache/last_conversations.json")
    let data = try? Data(contentsOf: lastFile)
    let last =
      data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
      ?? [:]
    let folders = Dictionary(
      last.sorted(by: { $0.key < $1.key }).map { ($0.value.lowercased(), $0.key) },
      uniquingKeysWith: { first, _ in first })
    let active = antigravityHolders(in: home.appending(path: "presence"))
    return read(
      home.appending(path: "conversation_summaries.db"),
      """
      SELECT conversation_id, workspace_uris, title, preview, last_modified_time
      FROM conversation_summaries
      """
    ) { row in
      let id = column(row, 0).lowercased()
      guard !active.contains(id) else { return nil }
      return antigravitySummary(from: row, id: id, home: home, folders: folders, requireFile: true)
    }
  }

  private static func antigravitySummary(sessionID: String, home: URL) -> SessionSummary? {
    read(
      home.appending(path: "conversation_summaries.db"),
      """
      SELECT conversation_id, workspace_uris, title, preview, last_modified_time
      FROM conversation_summaries
      WHERE lower(conversation_id) = ?
      """,
      bind: { bindText($0, 1, sessionID.lowercased()) }
    ) { row in
      let id = column(row, 0).lowercased()
      return antigravitySummary(from: row, id: id, home: home, folders: [:], requireFile: false)
    }.first
  }

  private static func antigravitySummary(
    from row: OpaquePointer, id: String, home: URL, folders: [String: String], requireFile: Bool
  ) -> SessionSummary? {
    let parsedDate = date(column(row, 4))
    if requireFile && parsedDate == nil { return nil }
    let data = Data(column(row, 1).utf8)
    let workspaces = (try? JSONSerialization.jsonObject(with: data)) as? [String] ?? []
    let workspace = workspaces.lazy.compactMap(URL.init(string:)).first(where: \.isFileURL)
    let file = home.appending(path: "conversations/\(id).db")
    let cwd = workspace?.path(percentEncoded: false) ?? folders[id] ?? ""
    let title = nonEmpty(column(row, 2)) ?? column(row, 3)
    if requireFile {
      return summary(
        id: id, cwd: cwd, title: title, home: home, file: file,
        modified: parsedDate ?? .distantPast, provider: "agy")
    }
    return restoredSummary(
      id: id, cwd: cwd, title: title, home: home, file: file,
      modified: parsedDate ?? .distantPast, provider: "agy")
  }

  /// Antigravity keeps presence files after exit. Match the files actually open by agy
  /// without taking a lock the CLI needs to open a conversation.
  private static func antigravityHolders(in directory: URL) -> Set<String> {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let prefix = directory.resolvingSymlinksInPath().path(percentEncoded: false) + "/"
    let capacity = Int(proc_listallpids(nil, 0))
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: capacity + 32)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    var active: Set<String> = []
    for pid in pids.prefix(max(0, Int(count))) {
      var executable = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
      guard proc_pidpath(pid, &executable, UInt32(executable.count)) > 0,
        String(decoding: executable.prefix { $0 != 0 }, as: UTF8.self).hasSuffix("/agy")
      else { continue }
      let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
      guard bytes > 0 else { continue }
      let stride = MemoryLayout<proc_fdinfo>.stride
      var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
      let filled = fds.withUnsafeMutableBytes {
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
      }
      guard filled > 0 else { continue }
      for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
          continue
        }
        let path = withUnsafeBytes(of: info.pvip.vip_path) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        if path.hasPrefix(prefix), path.hasSuffix(".lock") {
          active.insert(String(path.dropFirst(prefix.count).dropLast(5)).lowercased())
        }
      }
    }
    return active
  }

  private static func summary(
    id: String, cwd: String, title: String?, home: URL, file: URL, modified: Date, provider: String
  ) -> SessionSummary? {
    guard UUID(uuidString: id) != nil, cwd.hasPrefix("/"),
      FileManager.default.fileExists(atPath: file.path)
    else { return nil }
    return restoredSummary(
      id: id, cwd: cwd, title: title, home: home, file: file, modified: modified, provider: provider
    )
  }

  private static func restoredSummary(
    id: String, cwd: String, title: String?, home: URL, file: URL, modified: Date, provider: String
  ) -> SessionSummary {
    var summary = SessionSummary(
      sessionID: id, account: ClaudeAccount(directory: home, isDefault: true),
      file: file, modified: modified, size: 0)
    summary.cwd = cwd.isEmpty ? nil : cwd
    summary.title = title.flatMap(nonEmpty).map { String($0.prefix(120)) }
    summary.provider = provider
    return summary
  }

  private static func children(_ directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
  }

  private static func nonEmpty(_ text: String) -> String? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private static func date(_ text: String) -> Date? {
    let timestamp = text.replacingOccurrences(of: " ", with: "T")
    return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp))
      ?? (try? Date.ISO8601FormatStyle().parse(timestamp))
  }

  private static func column(_ row: OpaquePointer, _ index: Int32) -> String {
    sqlite3_column_text(row, index).map { String(cString: $0) } ?? ""
  }

  private static func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, index, value, -1, transient)
  }

  private static func read(
    _ file: URL, _ sql: String, fallbackSQL: String? = nil,
    bind: ((OpaquePointer) -> Void)? = nil,
    row: (OpaquePointer) -> SessionSummary?
  ) -> [SessionSummary] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    var database: OpaquePointer?
    // A closed WAL database may have no shared-memory file. Immutable mode reads it
    // without creating one. When a writer has a WAL open, read the live snapshot.
    let immutable = !FileManager.default.fileExists(atPath: file.path + "-wal")
    let source = immutable ? file.absoluteString + "?immutable=1" : file.path
    let result = sqlite3_open_v2(source, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    defer { sqlite3_close(database) }
    guard result == SQLITE_OK else { return [] }
    sqlite3_busy_timeout(database, 250)
    var statement: OpaquePointer?
    if sqlite3_prepare_v2(database, sql, -1, &statement, nil) != SQLITE_OK,
      let fallbackSQL
    {
      sqlite3_prepare_v2(database, fallbackSQL, -1, &statement, nil)
    }
    guard let statement else { return [] }
    defer { sqlite3_finalize(statement) }
    bind?(statement)
    var summaries: [SessionSummary] = []
    var step = sqlite3_step(statement)
    while step == SQLITE_ROW {
      if let summary = row(statement) { summaries.append(summary) }
      step = sqlite3_step(statement)
    }
    return step == SQLITE_DONE ? summaries : []
  }
}
