import DrakarKit
import Foundation
import Testing

@Suite("Antigravity account plan limits")
struct AgyUsageTests {

  /// Measured against `agy` 1.5.18 on 2026-11-27: four quota buckets plus `plan_tier`.
  private let sample = #"""
    {"plan_tier":"Google AI Pro",
     "email":"ignored@example.com",
     "quota":{
       "3p-weekly":{"remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z","reset_in_seconds":0},
       "gemini-weekly":{"remaining_fraction":0.82,"reset_time":"2026-12-03T09:00:00Z","reset_in_seconds":500000},
       "3p-5h":{"remaining_fraction":0.6,"reset_time":"2026-11-27T17:00:00Z","reset_in_seconds":12000},
       "gemini-5h":{"remaining_fraction":0.72,"reset_time":"2026-11-27T15:30:00Z","reset_in_seconds":7200}}}
    """#

  @Test func decodesBucketsPlanTierAndSorting() throws {
    let now = try #require(AccountUsage.parseISO8601("2026-11-27T13:30:00Z"))
    let agy = try #require(AgyUsage(statusLineData: Data(sample.utf8), at: now))

    #expect(agy.plan == "Google AI Pro")
    #expect(agy.readAt == now)
    #expect(agy.buckets.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])

    #expect(agy.buckets[0].window.percent == 28)
    #expect(agy.buckets[0].window.resetsAt == AccountUsage.parseISO8601("2026-11-27T15:30:00Z"))
    #expect(agy.buckets[1].window.percent == 18)
    #expect(agy.buckets[2].window.percent == 40)
    // Untouched bucket with epoch-0 reset_time and reset_in_seconds: 0 has nil resetsAt.
    #expect(agy.buckets[3].window.percent == 0)
    #expect(agy.buckets[3].window.resetsAt == nil)

    // Groups preserve order: Gemini first, Partner models second.
    let groups = agy.groups
    #expect(groups.map(\.name) == ["Gemini", "Partner models"])
    #expect(groups[0].fiveHour?.percent == 28)
    #expect(groups[0].sevenDay?.percent == 18)
    #expect(groups[1].fiveHour?.percent == 40)
    #expect(groups[1].sevenDay?.percent == 0)
  }

  @Test func peakWindowPicksHighestAndHandlesRollover() throws {
    let now = try #require(AccountUsage.parseISO8601("2026-11-27T13:30:00Z"))
    let agy = try #require(AgyUsage(statusLineData: Data(sample.utf8), at: now))

    // At 13:30: 3p-5h (40%) > gemini-5h (28%); gemini-weekly (18%) > 3p-weekly (0%).
    let summary = agy.summary(at: now)
    #expect(summary.source == .probe)
    #expect(summary.fiveHour?.percent == 40)
    #expect(summary.sevenDay?.percent == 18)

    // At 18:00: both 5h pools have reset past their reset_time, so peak 5h is 0%.
    let later = try #require(AccountUsage.parseISO8601("2026-11-27T18:00:00Z"))
    #expect(agy.summary(at: later).fiveHour?.percent == 0)
    #expect(agy.summary(at: later).fiveHour?.resetsAt == nil)
    #expect(agy.summary(at: later).sevenDay?.percent == 18)
  }

  @Test func skipsDisabledAndClampsFractions() throws {
    let payload = #"""
      {"plan_tier":"   ",
       "quota":{
         "gemini-5h":{"remaining_fraction":-0.2,"reset_time":"2026-11-27T15:00:00Z","reset_in_seconds":600},
         "3p-5h":{"remaining_fraction":0.5,"disabled":true,"reset_in_seconds":600},
         "custom-weekly":{"remaining_fraction":1.4,"reset_in_seconds":0}}}
      """#
    let agy = try #require(AgyUsage(statusLineData: Data(payload.utf8)))
    #expect(agy.plan == nil)
    #expect(agy.buckets.map(\.id) == ["gemini-5h", "custom-weekly"])
    #expect(agy.buckets[0].window.percent == 100)
    #expect(agy.buckets[1].groupName == "Custom")
    #expect(agy.buckets[1].window.percent == 0)
    #expect(agy.buckets[1].window.resetsAt == nil)
  }

  @Test func emptyOrInvalidQuotaReturnsNil() {
    #expect(AgyUsage(statusLineData: Data(#"{}"#.utf8)) == nil)
    #expect(AgyUsage(statusLineData: Data(#"{"quota":{}}"#.utf8)) == nil)
    #expect(
      AgyUsage(
        statusLineData: Data(
          #"{"quota":{"gemini-5h":{"remaining_fraction":0.5,"disabled":true}}}"#.utf8))
        == nil)
  }

  @Test func stalenessAndMerging() throws {
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = Date(timeIntervalSince1970: 1200)
    let first = try #require(
      AgyUsage(
        statusLineData: Data(
          #"{"plan_tier":"Google AI Ultra","quota":{"gemini-5h":{"remaining_fraction":0.9,"reset_in_seconds":300}}}"#
            .utf8), at: t0))
    let second = try #require(
      AgyUsage(
        statusLineData: Data(
          #"{"quota":{"gemini-5h":{"remaining_fraction":0.5,"reset_in_seconds":300}}}"#.utf8),
        at: t1))

    #expect(!first.isStale(at: t0.addingTimeInterval(600)))
    #expect(first.isStale(at: t0.addingTimeInterval(601)))

    let merged = first.merged(second)
    #expect(merged.buckets.first?.window.percent == 50)
    #expect(merged.plan == "Google AI Ultra")
    #expect(merged.readAt == t1)
  }
}
