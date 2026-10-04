import DrakarKit
import Foundation
import Observation

/// The projects home lists, app-wide: every window sees the same list, kept in
/// `UserDefaults`. A folder is tracked when it is added, when a suggestion is accepted, and
/// when it opens in a project window by any route, so every window restored at launch is
/// on home.
@Observable
final class ProjectList {
  static let shared = ProjectList()

  static let key = "drakar.projects"

  private(set) var tracked: TrackedProjects
  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    tracked = TrackedProjects.decode(defaults.data(forKey: Self.key))
  }

  func track(_ folder: URL) {
    update { $0.track(folder.path(percentEncoded: false)) }
  }

  /// Off the list, and nothing else: its files, transcripts and windows stay.
  func remove(_ path: String) {
    update { $0.remove(path) }
  }

  func hide(_ path: String) {
    update { $0.hide(path) }
  }

  private func update(_ change: (inout TrackedProjects) -> Void) {
    var next = tracked
    change(&next)
    guard next != tracked else { return }
    tracked = next
    defaults.set(next.encoded, forKey: Self.key)
  }
}
