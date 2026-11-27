import DrakarKit
import Foundation
import Testing

@Suite("Codex account plan limits")
struct CodexUsageTests {

  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  @Test func decodesAppServerRateLimits() throws {
    let payload = #"""
      {"limitId":"codex","planType":"plus",
       "primary":{"usedPercent":2,"windowDurationMins":300,"resetsAt":1791317294},
       "secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1791792475},
       "rateLimitReachedType":null}
      """#
    let now = Date(timeIntervalSince1970: 1_791_300_000)
    let codex = try #require(CodexUsage(appServer: json(payload), at: now))
    #expect(codex.plan == "Plus")
    #expect(codex.usage.source == .live)
    #expect(codex.usage.readAt == now)
    #expect(
      codex.usage.fiveHour
        == UsageWindow(percent: 2, resetsAt: Date(timeIntervalSince1970: 1_791_317_294)))
    #expect(
      codex.usage.sevenDay
        == UsageWindow(percent: 7, resetsAt: Date(timeIntervalSince1970: 1_791_792_475)))
  }

  @Test func mapsWindowsByDurationNotKeyName() throws {
    let swapped = #"""
      {"planType":"pro",
       "primary":{"usedPercent":44.6,"windowDurationMins":10080,"resetsAt":2000},
       "secondary":{"usedPercent":12.4,"windowDurationMins":300,"resetsAt":1000}}
      """#
    let codex = try #require(
      CodexUsage(appServer: json(swapped), at: Date(timeIntervalSince1970: 0)))
    #expect(codex.plan == "Pro")
    #expect(codex.usage.fiveHour?.percent == 12)
    #expect(codex.usage.sevenDay?.percent == 45)
  }

  @Test func marksReachedWindowRejected() throws {
    let payload = #"""
      {"planType":"plus","rateLimitReachedType":"primary",
       "primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1000},
       "secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000}}
      """#
    let codex = try #require(CodexUsage(appServer: json(payload)))
    #expect(codex.usage.fiveHour?.isRejected == true)
    #expect(codex.usage.fiveHour?.level == .critical)
    #expect(codex.usage.sevenDay?.isRejected == false)

    let generic = #"""
      {"planType":"plus","rateLimitReachedType":"rate_limit_reached",
       "primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1000},
       "secondary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":2000}}
      """#
    let live = try #require(CodexUsage(appServer: json(generic)))
    #expect(live.usage.fiveHour?.isRejected == true)
    #expect(live.usage.sevenDay?.isRejected == false)
  }

  @Test func decodesRolloutTokenCountLine() throws {
    let line = #"""
      {"timestamp":"2026-11-27T10:15:30.123456Z","type":"event_msg",
       "payload":{"type":"token_count","rate_limits":{
         "plan_type":"plus",
         "primary":{"used_percent":61.0,"window_minutes":300,"resets_at":1795695330},
         "secondary":{"used_percent":28.4,"window_minutes":10080,"resets_at":1796200000}}}}
      """#
    let codex = try #require(CodexUsage(rolloutLine: json(line)))
    #expect(codex.plan == "Plus")
    #expect(codex.usage.source == .sessionLog)
    #expect(codex.usage.fiveHour?.percent == 61)
    #expect(codex.usage.sevenDay?.percent == 28)
    #expect(codex.usage.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_795_695_330))
    #expect(!codex.usage.isStale(at: codex.usage.readAt.addingTimeInterval(7200)))
  }

  @Test func ignoresNonTokenCountAndEmptyLimits() throws {
    #expect(
      CodexUsage(rolloutLine: try json(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#))
        == nil)
    #expect(CodexUsage(appServer: try json(#"{"planType":"plus"}"#)) == nil)
  }

  @Test func mergeKeepsNewerAndPreservesPlan() {
    let older = CodexUsage(
      usage: AccountUsage(
        fiveHour: UsageWindow(percent: 10, resetsAt: nil), sevenDay: nil,
        readAt: Date(timeIntervalSince1970: 100), source: .sessionLog),
      plan: "Plus")
    let newerWithoutPlan = CodexUsage(
      usage: AccountUsage(
        fiveHour: UsageWindow(percent: 42, resetsAt: nil), sevenDay: nil,
        readAt: Date(timeIntervalSince1970: 200), source: .live),
      plan: nil)
    let merged = older.merged(newerWithoutPlan)
    #expect(merged.usage.fiveHour?.percent == 42)
    #expect(merged.plan == "Plus")
  }

  @Test func resolvesCodexHomeFromEnvironmentOrDefault() {
    let home = URL(filePath: "/Users/alice", directoryHint: .isDirectory)
    #expect(
      CodexRolloutLimits.resolveHome(environment: [:], home: home).path(percentEncoded: false)
        == "/Users/alice/.codex/")
    #expect(
      CodexRolloutLimits.resolveHome(
        environment: ["CODEX_HOME": " /tmp/custom-codex "], home: home
      ).path(percentEncoded: false) == "/tmp/custom-codex/")
  }

  @Test func readsNewestRolloutAndFallsBackPastEmptyOne() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-codex-limits-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(AccountUsage.parseISO8601("2026-11-27T12:00:00Z"))

    let todayDir = root.appending(path: "sessions/2026/11/27", directoryHint: .isDirectory)
    let yesterdayDir = root.appending(path: "sessions/2026/11/26", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: todayDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: yesterdayDir, withIntermediateDirectories: true)

    // Yesterday's rollout has a >64KB prefix before its final token_count event.
    let olderFile = yesterdayDir.appending(path: "rollout-2026-11-26T10-00-00-aaa.jsonl")
    let padding = String(repeating: "{\"type\":\"noise\",\"text\":\"xxxxxxxxxx\"}\n", count: 2500)
    let tokenLine =
      #"{"timestamp":"2026-11-26T10:30:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":35.0,"window_minutes":300,"resets_at":1795695330},"secondary":{"used_percent":14.0,"window_minutes":10080,"resets_at":1796200000}}}}"#
      + "\n"
    try Data((padding + tokenLine).utf8).write(to: olderFile)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_795_600_000)],
      ofItemAtPath: olderFile.path(percentEncoded: false))

    // Today's brand-new rollout has only session_meta and no token_count yet.
    let emptyNewFile = todayDir.appending(path: "rollout-2026-11-27T11-59-00-bbb.jsonl")
    try Data("{\"timestamp\":\"2026-11-27T11:59:00Z\",\"type\":\"session_meta\"}\n".utf8).write(
      to: emptyNewFile)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_795_694_340)],
      ofItemAtPath: emptyNewFile.path(percentEncoded: false))

    let read = try #require(CodexRolloutLimits.read(in: root, from: now, calendar: calendar))
    #expect(read.plan == "Plus")
    #expect(read.usage.fiveHour?.percent == 35)
    #expect(read.usage.sevenDay?.percent == 14)

    // Once today's rollout writes a token_count, it wins.
    let newerLine =
      #"{"timestamp":"2026-11-27T12:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":77.0,"window_minutes":300,"resets_at":1795700000}}}}"#
      + "\n"
    try Data(newerLine.utf8).write(to: emptyNewFile)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_795_694_400)],
      ofItemAtPath: emptyNewFile.path(percentEncoded: false))

    let updated = try #require(CodexRolloutLimits.read(in: root, from: now, calendar: calendar))
    #expect(updated.plan == "Pro")
    #expect(updated.usage.fiveHour?.percent == 77)
  }

  @Test func comparesAcrossRolloutsAndMarksUsageLimitExceededRejected() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-codex-refusal-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(AccountUsage.parseISO8601("2026-11-27T17:30:00Z"))
    let todayDir = root.appending(path: "sessions/2026/11/27", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: todayDir, withIntermediateDirectories: true)

    // Rollout A (older mtime): 99% at 13:22:46Z, then refused.
    let rolloutA = todayDir.appending(path: "rollout-2026-11-27T14-18-38-aaa.jsonl")
    let linesA = """
      {"timestamp":"2026-11-27T13:22:46Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","plan_type":"plus","primary":{"used_percent":99.0,"window_minutes":300,"resets_at":1795798785},"secondary":{"used_percent":16.0,"window_minutes":10080,"resets_at":1796385585}}}}
      {"timestamp":"2026-11-27T13:22:47Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"plan_type":"plus"}}}
      {"timestamp":"2026-11-27T13:22:47Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"You’ve hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}}
      """
    try Data(linesA.utf8).write(to: rolloutA)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_795_785_778)],
      ofItemAtPath: rolloutA.path(percentEncoded: false))

    // Rollout B (newer mtime, e.g. retried later): 96% at 13:22:26Z, then refused at 13:28:25Z.
    let rolloutB = todayDir.appending(path: "rollout-2026-11-27T13-01-21-bbb.jsonl")
    let linesB = """
      {"timestamp":"2026-11-27T13:22:26Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","plan_type":"plus","primary":{"used_percent":96.0,"window_minutes":300,"resets_at":1795798786},"secondary":{"used_percent":15.0,"window_minutes":10080,"resets_at":1796385586}}}}
      {"timestamp":"2026-11-27T13:28:25Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"plan_type":"plus"}}}
      {"timestamp":"2026-11-27T13:28:25Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"You’ve hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}}
      """
    try Data(linesB.utf8).write(to: rolloutB)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_795_786_105)],
      ofItemAtPath: rolloutB.path(percentEncoded: false))

    // Rollout C (newest mtime): only a failed turn with null premium limits and refusal at 16:30:45Z.
    let rolloutC = todayDir.appending(path: "rollout-2026-11-27T17-30-42-ccc.jsonl")
    let linesC = """
      {"timestamp":"2026-11-27T16:30:45Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"plan_type":null}}}
      {"timestamp":"2026-11-27T16:30:45Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"You’ve hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}}
      """
    try Data(linesC.utf8).write(to: rolloutC)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_795_797_045)],
      ofItemAtPath: rolloutC.path(percentEncoded: false))

    let read = try #require(CodexRolloutLimits.read(in: root, from: now, calendar: calendar))
    #expect(read.plan == "Plus")
    // Newer 13:22:46Z reading from Rollout A beats Rollout B's 13:22:26Z, and Rollout C's
    // refusal marks the active 5h window rejected while keeping the 7d window intact.
    #expect(read.usage.fiveHour?.isRejected == true)
    #expect(read.usage.fiveHour?.level == .critical)
    #expect(read.usage.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_795_798_785))
    #expect(read.usage.sevenDay?.percent == 16)
    #expect(read.usage.sevenDay?.isRejected == false)
    #expect(read.usage.readAt == AccountUsage.parseISO8601("2026-11-27T16:30:45Z"))
  }

  @Test func refusalTargetsSevenDayWhenFiveHourIsLowOrRolled() throws {
    let base = CodexUsage(
      usage: AccountUsage(
        fiveHour: UsageWindow(percent: 12, resetsAt: Date(timeIntervalSince1970: 1_795_798_785)),
        sevenDay: UsageWindow(percent: 98, resetsAt: Date(timeIntervalSince1970: 1_796_385_585)),
        readAt: Date(timeIntervalSince1970: 1_795_785_000),
        source: .sessionLog),
      plan: "Plus")
    let refused = base.corrected(by: Date(timeIntervalSince1970: 1_795_786_000))
    #expect(refused.usage.fiveHour?.isRejected == false)
    #expect(refused.usage.sevenDay?.isRejected == true)

    // Older refusal before a newer successful token_count does not override it.
    let stale = base.corrected(by: Date(timeIntervalSince1970: 1_795_784_000))
    #expect(stale.usage.sevenDay?.isRejected == false)
  }
}
