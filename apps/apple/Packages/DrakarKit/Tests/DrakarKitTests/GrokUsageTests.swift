import DrakarKit
import Foundation
import Testing

@Suite("Grok Build account plan allowance")
struct GrokUsageTests {

  /// Measured against `grok` 1.0.34 on 2026-09-17: `creditUsagePercent`, `currentPeriod`,
  /// `billingPeriodEnd`, and `subscription_tier`.
  private let weeklySample = #"""
    {
      "config": {
        "creditUsagePercent": 13.4,
        "currentPeriod": {
          "type": "USAGE_PERIOD_TYPE_WEEKLY",
          "start": "2026-09-15T21:25:12.584887+00:00",
          "end": "2026-09-22T21:25:12.584887+00:00"
        },
        "onDemandCap": {"val": 0},
        "isUnifiedBillingUser": true,
        "billingPeriodEnd": "2026-09-22T21:25:12.584887+00:00"
      },
      "subscription_tier": "X Premium"
    }
    """#

  @Test func decodesWeeklyAllowanceResetAndTier() throws {
    let now = try #require(AccountUsage.parseISO8601("2026-09-17T12:00:00Z"))
    let grok = try #require(GrokUsage(billingData: Data(weeklySample.utf8), at: now))

    #expect(grok.window.percent == 13)
    #expect(grok.window.resetsAt == AccountUsage.parseISO8601("2026-09-22T21:25:12.584887+00:00"))
    #expect(grok.period == .weekly)
    #expect(grok.periodName == "weekly")
    #expect(grok.shortLabel == "7d")
    #expect(grok.plan == "X Premium")
    #expect(grok.readAt == now)
  }

  @Test func decodesMonthlyAllowanceAndBillingPeriodFallback() throws {
    let payload = #"""
      {
        "config": {
          "creditUsagePercent": 39.6,
          "currentPeriod": {"type": "USAGE_PERIOD_TYPE_MONTHLY"},
          "billingPeriodEnd": "2026-10-01T00:00:00Z"
        },
        "subscription_tier": "  SuperGrok  "
      }
      """#
    let grok = try #require(GrokUsage(billingData: Data(payload.utf8)))
    #expect(grok.window.percent == 40)
    #expect(grok.period == .monthly)
    #expect(grok.shortLabel == "mo")
    #expect(grok.plan == "SuperGrok")
    #expect(grok.window.resetsAt == AccountUsage.parseISO8601("2026-10-01T00:00:00Z"))
  }

  @Test func handlesUnknownPeriodBlankTierAndClampsPercentage() throws {
    let payload = #"""
      {
        "config": {
          "creditUsagePercent": 124.2,
          "currentPeriod": {"type": "USAGE_PERIOD_TYPE_QUARTERLY"}
        },
        "subscription_tier": "   "
      }
      """#
    let grok = try #require(GrokUsage(billingData: Data(payload.utf8)))
    #expect(grok.window.percent == 100)
    #expect(grok.period == nil)
    #expect(grok.periodName == "quarterly")
    #expect(grok.shortLabel == nil)
    #expect(grok.plan == nil)
  }

  @Test func missingCreditUsagePercentReturnsNil() {
    #expect(GrokUsage(billingData: Data(#"{}"#.utf8)) == nil)
    #expect(GrokUsage(billingData: Data(#"{"config":{}}"#.utf8)) == nil)
    #expect(GrokUsage(billingData: Data(#"not json"#.utf8)) == nil)
  }

  @Test func rolloverStalenessAndMerging() throws {
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = Date(timeIntervalSince1970: 1200)
    let first = try #require(
      GrokUsage(
        billingData: Data(
          #"{"config":{"creditUsagePercent":22,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-22T21:25:12Z"}},"subscription_tier":"SuperGrok"}"#
            .utf8), at: t0))
    let second = try #require(
      GrokUsage(
        billingData: Data(#"{"config":{"creditUsagePercent":31}}"#.utf8), at: t1))

    #expect(!first.isStale(at: t0.addingTimeInterval(600)))
    #expect(first.isStale(at: t0.addingTimeInterval(601)))

    let merged = first.merged(second)
    #expect(merged.window.percent == 31)
    #expect(merged.plan == "SuperGrok")
    #expect(merged.periodName == "weekly")
    #expect(merged.readAt == t1)

    let afterReset = try #require(AccountUsage.parseISO8601("2026-09-23T00:00:00Z"))
    #expect(first.window.current(at: afterReset).percent == 0)
    #expect(first.window.current(at: afterReset).resetsAt == nil)
  }
}
