import Foundation
import Testing

@testable import Drakar

/// The date a release's header shows. Drakar's first section is a version written down
/// before its tag, which the generator emits with an empty date.
@Suite("What's New")
struct WhatsNewPaneTests {

  private func release(dated date: String) -> Changelog.Release {
    Changelog.Release(version: "1.0.0", date: date, sections: [])
  }

  /// An empty date beside a version reads as a missing fact; a pending one says so.
  @Test @MainActor func showsAPendingReleaseAsUnreleased() {
    #expect(WhatsNewPane.dateLine(for: release(dated: "")) == "Unreleased")
  }

  /// The day the CHANGELOG names, in every time zone. The expected value is built from
  /// the components, not by the pane's own parse and format, which would agree with
  /// itself a day early anywhere west of UTC.
  @Test @MainActor func showsADatedReleaseOnTheDayItNames() throws {
    var gmt = Calendar(identifier: .gregorian)
    gmt.timeZone = .gmt
    let day = try #require(gmt.date(from: DateComponents(year: 2026, month: 9, day: 14)))
    #expect(
      WhatsNewPane.dateLine(for: release(dated: "2026-09-14"))
        == day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))
  }

  /// A date the parse cannot read is shown as written rather than dropped.
  @Test @MainActor func showsAnUnreadableDateAsWritten() {
    #expect(WhatsNewPane.dateLine(for: release(dated: "mid-September")) == "mid-September")
  }
}
