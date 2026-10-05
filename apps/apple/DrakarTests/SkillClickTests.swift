import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A click on a skill row")
struct SkillClickTests {

  private let interval: TimeInterval = 0.5

  @Test func theFirstClickRuns() {
    #expect(SkillClick(name: "check", time: 10).runs(after: nil, within: interval))
  }

  /// A double-click's second click is not a second run.
  @Test func theSameSkillAgainWithinTheIntervalDoesNotRun() {
    let last = SkillClick(name: "check", time: 10)
    #expect(!SkillClick(name: "check", time: 10.2).runs(after: last, within: interval))
    #expect(!SkillClick(name: "check", time: 10).runs(after: last, within: interval))
  }

  @Test func theSameSkillOnceTheIntervalHasPassedRuns() {
    let last = SkillClick(name: "check", time: 10)
    #expect(SkillClick(name: "check", time: 10.5).runs(after: last, within: interval))
    #expect(SkillClick(name: "check", time: 12).runs(after: last, within: interval))
  }

  @Test func anotherSkillRunsAtOnce() {
    let last = SkillClick(name: "check", time: 10)
    #expect(SkillClick(name: "marketing:seo-audit", time: 10.1).runs(after: last, within: interval))
  }
}
