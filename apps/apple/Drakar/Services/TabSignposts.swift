import Foundation
import os

/// The tabs' intervals, read in Instruments (os_signpost, subsystem io.mgcrea.Drakar,
/// category tabs) against the session tabs spec's budgets: a switch from the click to the
/// new session laid out in the window, a session's history read in, a tab closed.
nonisolated enum TabSignposts {
  static let signposter = OSSignposter(subsystem: "io.mgcrea.Drakar", category: "tabs")

  /// Where the selection changes (`Project.select`); ended by `switchDrawn` once the deck
  /// has the session in the window and laid out.
  static func switchBegan(to id: ProjectSession.ID) -> OSSignpostIntervalState {
    signposter.beginInterval(
      "Tab switch", id: signposter.makeSignpostID(), "\(id.uuidString, privacy: .public)")
  }

  static func switchDrawn(_ state: OSSignpostIntervalState) {
    signposter.endInterval("Tab switch", state)
  }

  /// A switch that never drew: another took its place before the deck showed it.
  static func switchSuperseded(_ state: OSSignpostIntervalState) {
    signposter.endInterval("Tab switch", state, "superseded")
  }

  /// A session's history, from a cold tab asking for it until it is in.
  static func historyLoad(_ load: () async -> Void) async {
    let state = signposter.beginInterval("History load", id: signposter.makeSignpostID())
    await load()
    signposter.endInterval("History load", state)
  }

  /// A tab closing, on the main thread: what is left for the next frame.
  static func closeTab<Result>(_ close: () throws -> Result) rethrows -> Result {
    try signposter.withIntervalSignpost("Close tab", id: signposter.makeSignpostID(), around: close)
  }
}
