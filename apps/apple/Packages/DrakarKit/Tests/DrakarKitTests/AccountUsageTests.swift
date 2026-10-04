import DrakarKit
import Foundation
import Testing

@Suite("An account's plan usage")
struct AccountUsageTests {

  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  /// `cachedUsageUtilization` as Claude Code 2.1.288 wrote it on 2026-10-04: whole percents,
  /// ISO-8601 resets with six fractional digits.
  private let cache = #"""
    {"accountUuid":"a","fetchedAtMs":1791023000000,"utilization":{
      "five_hour":{"utilization":37,"resets_at":"2026-10-03T10:30:00.633102+00:00","limit_dollars":null},
      "seven_day":{"utilization":83,"resets_at":"2026-10-05T13:59:59.633120+00:00"},
      "seven_day_oauth_apps":null}}
    """#

  /// `rate_limit_info` from the turn-with-tool capture: fractions, epoch seconds.
  private let live = #"""
    {"status":"allowed","resetsAt":1791023400,"rateLimitType":"five_hour","overageStatus":"rejected",
     "isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.32,"resetsAt":1791023400},
     "seven_day":{"utilization":0.54,"resetsAt":1791208800}}}
    """#

  @Test func readsTheCache() throws {
    let usage = try #require(AccountUsage(cache: json(cache)))
    #expect(usage.source == .cache)
    #expect(usage.readAt == Date(timeIntervalSince1970: 1_791_023_000))
    #expect(usage.fiveHour?.percent == 37)
    #expect(usage.fiveHour?.resetsAt.map { Int($0.timeIntervalSince1970) } == 1_791_023_400)
    #expect(usage.sevenDay?.percent == 83)
  }

  @Test func readsALiveEvent() throws {
    let now = Date(timeIntervalSince1970: 1_791_023_100)
    let usage = try #require(AccountUsage(live: json(live), at: now))
    #expect(usage.source == .live)
    #expect(usage.readAt == now)
    #expect(
      usage.fiveHour
        == UsageWindow(percent: 32, resetsAt: Date(timeIntervalSince1970: 1_791_023_400)))
    #expect(usage.sevenDay?.percent == 54)
    #expect(usage.fiveHour?.isRejected == false)
  }

  /// The two shapes differ in units, not in meaning.
  @Test func bothShapesMeanTheSame() throws {
    let fromCache = try #require(
      AccountUsage(
        cache: json(
          #"{"fetchedAtMs":0,"utilization":{"five_hour":{"utilization":32,"resets_at":"2026-10-03T10:30:00+00:00"}}}"#
        )))
    let fromLive = try #require(
      AccountUsage(
        live: json(#"{"unifiedWindows":{"five_hour":{"utilization":0.32,"resetsAt":1791023400}}}"#))
    )
    #expect(fromCache.fiveHour == fromLive.fiveHour)
  }

  @Test func aRejectedEventMarksTheWindowItNames() throws {
    let usage = try #require(
      AccountUsage(
        live: json(
          #"{"status":"rejected","rateLimitType":"seven_day","unifiedWindows":{"five_hour":{"utilization":0.4,"resetsAt":1},"seven_day":{"utilization":0.97,"resetsAt":2}}}"#
        )))
    #expect(usage.sevenDay?.isRejected == true)
    #expect(usage.fiveHour?.isRejected == false)
    #expect(usage.sevenDay?.level == .critical)
  }

  /// A shape change drops the reading; it must not read as an empty plan.
  @Test func aLiveEventWithoutWindowsIsNoReading() throws {
    #expect(AccountUsage(live: try json(#"{"status":"allowed","resetsAt":1791023400}"#)) == nil)
    #expect(AccountUsage(live: .null) == nil)
  }

  @Test func aCacheWithoutWindowsIsNoReading() throws {
    #expect(AccountUsage(cache: try json(#"{"fetchedAtMs":1,"utilization":{}}"#)) == nil)
  }

  @Test func theNewerReadingWins() {
    let old = AccountUsage(
      fiveHour: UsageWindow(percent: 10, resetsAt: nil), sevenDay: nil,
      readAt: Date(timeIntervalSince1970: 100), source: .cache)
    let new = AccountUsage(
      fiveHour: UsageWindow(percent: 20, resetsAt: nil), sevenDay: nil,
      readAt: Date(timeIntervalSince1970: 200), source: .live)
    #expect(old.merged(new) == new)
    #expect(new.merged(old) == new)
    #expect(new.merged(nil) == new)
  }

  /// A cache read before the window reset describes a window that has since been emptied.
  @Test func aWindowPastItsResetIsEmpty() {
    let window = UsageWindow(
      percent: 83, resetsAt: Date(timeIntervalSince1970: 1000), isRejected: true)
    #expect(window.current(at: Date(timeIntervalSince1970: 999)) == window)
    #expect(window.current(at: Date(timeIntervalSince1970: 1000)).percent == 0)
    #expect(window.current(at: Date(timeIntervalSince1970: 1000)).isRejected == false)
  }

  @Test(arguments: [
    (0, UsageWindow.Level.normal), (69, .normal), (70, .high), (89, .high), (90, .critical),
    (100, .critical),
  ])
  func tintsByThreshold(_ percent: Int, _ level: UsageWindow.Level) {
    #expect(UsageWindow(percent: percent, resetsAt: nil).level == level)
  }

  @Test func isStaleAfterTenMinutes() {
    let usage = AccountUsage(
      fiveHour: nil, sevenDay: nil, readAt: Date(timeIntervalSince1970: 0), source: .cache)
    #expect(!usage.isStale(at: Date(timeIntervalSince1970: 600)))
    #expect(usage.isStale(at: Date(timeIntervalSince1970: 601)))
  }

  @Test func clampsPercentages() throws {
    let usage = try #require(
      AccountUsage(
        live: json(#"{"unifiedWindows":{"five_hour":{"utilization":1.4,"resetsAt":1}}}"#)))
    #expect(usage.fiveHour?.percent == 100)
  }
}
