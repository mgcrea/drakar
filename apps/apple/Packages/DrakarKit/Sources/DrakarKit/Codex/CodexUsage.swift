import Foundation

/// A Codex account's plan limits and plan tier, from either a live `codex app-server`
/// `account/rateLimits/updated` notification or the newest `token_count` event in a rollout
/// log under `~/.codex/sessions/`.
///
/// Codex names its windows `primary` and `secondary` and identifies each by its duration in
/// minutes (`300` for 5 hours, `10080` for 7 days), rather than by key name. `auth.json` is
/// never opened: `planType` rides along with the rate limits.
public struct CodexUsage: Sendable, Equatable {
  public var usage: AccountUsage
  /// `"Plus"`, `"Pro"`, `"Team"` — nil until an event reports `planType` / `plan_type`.
  public var plan: String?

  public init(usage: AccountUsage, plan: String?) {
    self.usage = usage
    self.plan = plan
  }

  /// Decodes `codex app-server`'s `rateLimits` object (from `account/rateLimits/updated` or
  /// `account/rateLimits/read`): camelCase fields (`usedPercent`, `windowDurationMins`,
  /// `resetsAt`, `planType`, `rateLimitReachedType`).
  public init?(
    appServer json: JSONValue, at now: Date = .now, source: AccountUsage.Source = .live
  ) {
    let windows = Self.parseWindows(
      from: json,
      percentKey: "usedPercent",
      minutesKey: "windowDurationMins",
      resetsKey: "resetsAt",
      reached: json["rateLimitReachedType"]?.stringValue)
    guard windows.fiveHour != nil || windows.sevenDay != nil else { return nil }
    self.init(
      usage: AccountUsage(
        fiveHour: windows.fiveHour, sevenDay: windows.sevenDay, readAt: now, source: source),
      plan: Self.formatPlan(json["planType"]?.stringValue))
  }

  /// Decodes one JSONL line from a Codex rollout file: `payload.type == "token_count"`,
  /// snake_case fields (`used_percent`, `window_minutes`, `resets_at`, `plan_type`), and the
  /// line's ISO-8601 `timestamp`.
  public init?(rolloutLine json: JSONValue, fallbackDate: Date = .now) {
    guard let payload = json["payload"], payload["type"]?.stringValue == "token_count",
      let limits = payload["rate_limits"]
    else { return nil }
    let windows = Self.parseWindows(
      from: limits,
      percentKey: "used_percent",
      minutesKey: "window_minutes",
      resetsKey: "resets_at",
      reached: limits["rate_limit_reached_type"]?.stringValue)
    guard windows.fiveHour != nil || windows.sevenDay != nil else { return nil }
    let observedAt =
      json["timestamp"]?.stringValue.flatMap(AccountUsage.parseISO8601) ?? fallbackDate
    self.init(
      usage: AccountUsage(
        fiveHour: windows.fiveHour, sevenDay: windows.sevenDay, readAt: observedAt,
        source: .sessionLog),
      plan: Self.formatPlan(limits["plan_type"]?.stringValue))
  }

  /// Applies a newer `usage_limit_exceeded` refusal from a rollout log when the refused turn
  /// happened after this reading and before the active window reset.
  public func corrected(by refusalAt: Date?) -> CodexUsage {
    guard let refusalAt, refusalAt > usage.readAt else { return self }
    let target = Self.refusedWindowKind(
      fiveHour: usage.fiveHour, sevenDay: usage.sevenDay, at: refusalAt)
    guard let target else { return self }
    var next = usage
    next.readAt = refusalAt
    switch target {
    case .fiveHour:
      if var w = next.fiveHour {
        w.isRejected = true
        next.fiveHour = w
      }
    case .sevenDay:
      if var w = next.sevenDay {
        w.isRejected = true
        next.sevenDay = w
      }
    }
    return CodexUsage(usage: next, plan: plan)
  }

  /// The newer reading wins; if the winner carries no plan label, the older one's is kept.
  public func merged(_ other: CodexUsage?) -> CodexUsage {
    guard let other else { return self }
    if other.usage.readAt > usage.readAt {
      return CodexUsage(usage: other.usage, plan: other.plan ?? plan)
    }
    return CodexUsage(usage: usage, plan: plan ?? other.plan)
  }

  /// `"plus"` → `"Plus"`. Codex sends plan types lowercase.
  public static func formatPlan(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
  }

  private enum WindowKind {
    case fiveHour
    case sevenDay
  }

  private static func parseWindows(
    from object: JSONValue,
    percentKey: String,
    minutesKey: String,
    resetsKey: String,
    reached: String?
  ) -> (fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    for key in ["primary", "secondary"] {
      guard let entry = object[key],
        let percent = entry[percentKey]?.numberValue,
        let minutes = entry[minutesKey]?.intValue
      else { continue }
      let resets = entry[resetsKey]?.numberValue.map { Date(timeIntervalSince1970: $0) }
      let kind = windowKind(minutes: minutes)
      let rejected =
        reached == key
        || (kind == .fiveHour && reached == "five_hour")
        || (kind == .sevenDay && reached == "seven_day")
      let window = UsageWindow(
        percent: Int(percent.rounded()), resetsAt: resets, isRejected: rejected)
      switch kind {
      case .fiveHour: if fiveHour == nil { fiveHour = window }
      case .sevenDay: if sevenDay == nil { sevenDay = window }
      case nil: break
      }
    }
    // `codex app-server` sends `rateLimitReachedType: "rate_limit_reached"` without naming a
    // specific window.
    if reached == "rate_limit_reached",
      fiveHour?.isRejected != true, sevenDay?.isRejected != true
    {
      if fiveHour?.percent == 100 { fiveHour?.isRejected = true }
      if sevenDay?.percent == 100 { sevenDay?.isRejected = true }
      if fiveHour?.isRejected != true, sevenDay?.isRejected != true {
        switch refusedWindowKind(fiveHour: fiveHour, sevenDay: sevenDay, at: nil) {
        case .fiveHour: fiveHour?.isRejected = true
        case .sevenDay: sevenDay?.isRejected = true
        case nil: break
        }
      }
    }
    return (fiveHour, sevenDay)
  }

  /// Picks which window a generic refusal applies to: among windows not yet rolled at `at`,
  /// the higher-utilization one (preferring `fiveHour` on ties).
  private static func refusedWindowKind(
    fiveHour: UsageWindow?, sevenDay: UsageWindow?, at refusalAt: Date?
  ) -> WindowKind? {
    func isLive(_ window: UsageWindow?) -> Bool {
      guard let window else { return false }
      guard let refusalAt, let resetsAt = window.resetsAt else { return true }
      return resetsAt > refusalAt
    }
    let fiveLive = isLive(fiveHour) ? fiveHour : nil
    let sevenLive = isLive(sevenDay) ? sevenDay : nil
    switch (fiveLive, sevenLive) {
    case (let five?, let seven?):
      return seven.percent > five.percent ? .sevenDay : .fiveHour
    case (.some, .none):
      return .fiveHour
    case (.none, .some):
      return .sevenDay
    case (.none, .none):
      return nil
    }
  }

  /// Measured on Codex: 300 minutes (5 hours) and 10080 minutes (7 days).
  private static func windowKind(minutes: Int) -> WindowKind? {
    switch minutes {
    case ...600: .fiveHour
    case ...20160: .sevenDay
    default: nil
    }
  }
}

/// Reads the newest plan limits from Codex rollout logs on disk (`$CODEX_HOME/sessions/YYYY/MM/DD/`),
/// bounded to the last 64 KB of the newest files so megabyte rollouts are never read in full.
public enum CodexRolloutLimits {
  /// Measured across Codex rollouts: the last 64 KB always contains recent `token_count` events.
  public static let tailBytes = 64 * 1024

  /// Covers the full 7-day plan window: any rollout older than 7 days has already had both
  /// its 5-hour and 7-day windows reset.
  public static let defaultDaysBack = 7

  /// Identifies the newest rollout file so polling skips disk reads when nothing changed.
  public struct Stamp: Sendable, Equatable {
    public var url: URL
    public var modified: Date
    public var size: UInt64

    public init(url: URL, modified: Date, size: UInt64) {
      self.url = url
      self.modified = modified
      self.size = size
    }
  }

  /// `$CODEX_HOME` when set and non-empty, else `~/.codex`.
  public static func resolveHome(
    environment: [String: String],
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let custom = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !custom.isEmpty
    {
      return URL(
        filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }
    return home.appending(path: ".codex", directoryHint: .isDirectory)
  }

  /// Day directories `sessions/YYYY/MM/DD` in local calendar order, newest first.
  public static func dayDirectories(
    in codexHome: URL, back days: Int = defaultDaysBack, from now: Date = .now,
    calendar: Calendar = .current
  ) -> [URL] {
    let sessionsDir = codexHome.appending(path: "sessions", directoryHint: .isDirectory)
    let fileManager = FileManager.default
    return (0...max(0, days)).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
      let url = sessionsDir.appending(
        path: String(format: "%04d/%02d/%02d", year, month, day), directoryHint: .isDirectory)
      return fileManager.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }
  }

  /// The most recently modified rollout file in the last `days` day directories.
  public static func newestRollout(
    in codexHome: URL, back days: Int = defaultDaysBack, from now: Date = .now,
    calendar: Calendar = .current
  ) -> Stamp? {
    rollouts(in: codexHome, back: days, from: now, calendar: calendar).first
  }

  /// Reads the newest `token_count` rate limits across the most recently written rollouts
  /// (comparing event timestamps across files rather than stopping at the first file's mtime)
  /// and applies any newer `usage_limit_exceeded` refusal recorded before the active window
  /// resets.
  public static func read(
    in codexHome: URL, back days: Int = defaultDaysBack, from now: Date = .now,
    calendar: Calendar = .current, maxFiles: Int = 8
  ) -> CodexUsage? {
    let candidates = rollouts(in: codexHome, back: days, from: now, calendar: calendar)
    var newest: CodexUsage?
    var newestRefusal: Date?
    for candidate in candidates.prefix(max(0, maxFiles)) {
      let reading = readTail(of: candidate.url, fallbackDate: candidate.modified)
      if let usage = reading.usage {
        newest = usage.merged(newest)
      }
      if let refusalAt = reading.refusalAt,
        refusalAt > (newestRefusal ?? .distantPast)
      {
        newestRefusal = refusalAt
      }
    }
    if let newest {
      return newest.corrected(by: newestRefusal)
    }
    if let newestRefusal, now.timeIntervalSince(newestRefusal) < 5 * 3600 {
      return CodexUsage(
        usage: AccountUsage(
          fiveHour: UsageWindow(percent: 100, resetsAt: nil, isRejected: true),
          sevenDay: nil, readAt: newestRefusal, source: .sessionLog),
        plan: nil)
    }
    return nil
  }

  /// Reads up to `tailBytes` from the end of `url` and returns the newest `token_count`
  /// rate limits and newest `usage_limit_exceeded` refusal in that tail.
  public static func readTail(
    of url: URL, tailBytes: Int = tailBytes, fallbackDate: Date = .now
  ) -> (usage: CodexUsage?, refusalAt: Date?) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return (nil, nil) }
    let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    do {
      try handle.seek(toOffset: start)
      guard let chunk = try handle.readToEnd(), !chunk.isEmpty else { return (nil, nil) }
      return parseTailChunk(chunk, droppingFirstLine: start > 0, fallbackDate: fallbackDate)
    } catch {
      return (nil, nil)
    }
  }

  /// Scans lines newest-first in `chunk`, dropping the potentially partial first line when
  /// the read began mid-file.
  static func parseTailChunk(
    _ chunk: Data, droppingFirstLine: Bool, fallbackDate: Date = .now
  ) -> (usage: CodexUsage?, refusalAt: Date?) {
    let lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: true)
    let complete = droppingFirstLine ? lines.dropFirst() : lines[...]
    let tokenNeedle = Data(#""token_count""#.utf8)
    let limitNeedle = Data(#""usage_limit_exceeded""#.utf8)
    var newestUsage: CodexUsage?
    var newestRefusal: Date?
    for line in complete.reversed() {
      let hasToken = line.range(of: tokenNeedle) != nil
      let hasLimit = line.range(of: limitNeedle) != nil
      guard hasToken || hasLimit, let json = try? JSONValue.parse(line) else { continue }
      if newestRefusal == nil, hasLimit,
        let refusalAt = refusalDate(rolloutLine: json, fallbackDate: fallbackDate)
      {
        newestRefusal = refusalAt
      }
      if newestUsage == nil, hasToken,
        let usage = CodexUsage(rolloutLine: json, fallbackDate: fallbackDate)
      {
        newestUsage = usage
        // Lines are reverse-chronological; once we have a valid `token_count`, any earlier
        // refusal in this file predates it.
        break
      }
    }
    return (newestUsage, newestRefusal)
  }

  private static func refusalDate(rolloutLine json: JSONValue, fallbackDate: Date) -> Date? {
    guard json["type"]?.stringValue == "event_msg",
      let payload = json["payload"]
    else { return nil }
    let type = payload["type"]?.stringValue
    let isRefusal =
      (type == "task_complete"
        && payload["error"]?["codex_error_info"]?.stringValue == "usage_limit_exceeded")
      || (type == "error"
        && (payload["codex_error_info"]?.stringValue == "usage_limit_exceeded"
          || payload["error"]?["codex_error_info"]?.stringValue == "usage_limit_exceeded"))
    guard isRefusal else { return nil }
    return json["timestamp"]?.stringValue.flatMap(AccountUsage.parseISO8601) ?? fallbackDate
  }

  private static func rollouts(
    in codexHome: URL, back days: Int, from now: Date, calendar: Calendar
  ) -> [Stamp] {
    let fileManager = FileManager.default
    var found: [Stamp] = []
    for day in dayDirectories(in: codexHome, back: days, from: now, calendar: calendar) {
      let names =
        (try? fileManager.contentsOfDirectory(atPath: day.path(percentEncoded: false))) ?? []
      for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
        let url = day.appending(path: name, directoryHint: .notDirectory)
        let attributes =
          (try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))) ?? [:]
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        let size = (attributes[.size] as? UInt64) ?? 0
        found.append(Stamp(url: url, modified: modified, size: size))
      }
    }
    return found.sorted {
      ($0.modified, $0.url.lastPathComponent) > ($1.modified, $1.url.lastPathComponent)
    }
  }
}
