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

  @Test @MainActor func showsADatedReleaseAsAnAbsoluteDate() throws {
    let date = try Date("2026-09-14", strategy: .iso8601.year().month().day().dateSeparator(.dash))
    #expect(
      WhatsNewPane.dateLine(for: release(dated: "2026-09-14"))
        == date.formatted(date: .abbreviated, time: .omitted))
  }

  /// A date the parse cannot read is shown as written rather than dropped.
  @Test @MainActor func showsAnUnreadableDateAsWritten() {
    #expect(WhatsNewPane.dateLine(for: release(dated: "mid-September")) == "mid-September")
  }
}
