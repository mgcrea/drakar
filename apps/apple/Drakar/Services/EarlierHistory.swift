import DrakarKit
import Foundation

/// A conversation a session continues after it moved from another provider: shown read-only
/// above the session's own transcript, as it stood when it moved.
struct EarlierPart: Identifiable {
  let id = UUID()
  let agent: AgentKind
  /// Where its history is read from again after a relaunch; nil when it was never saved,
  /// which leaves it in this launch only.
  let target: ResumeTarget?
  /// Nil until read.
  var transcript: Transcript?
  /// Its history could not be read.
  var isMissing = false

  init(agent: AgentKind, target: ResumeTarget?, transcript: Transcript? = nil) {
    self.agent = agent
    self.target = target
    self.transcript = transcript
  }

  init(target: ResumeTarget) {
    self.init(agent: target.agentKind, target: target)
  }
}

/// Which sessions continue which other provider's, app-wide in `UserDefaults` by the new
/// session's id: a moved tab shows what came before it after a relaunch, or reopened from
/// Home, as it did when it moved. The other providers' own files are never touched.
enum ProviderMoveLinks {
  static let key = "drakar.providerMoves"
  /// The newest links kept: an old one goes before the list grows without end.
  static let limit = 500

  struct Link: Codable, Equatable {
    /// Oldest first.
    var earlier: [ResumeTarget]
    var date: Date
  }

  static func earlier(of sessionID: String, in defaults: UserDefaults = .standard)
    -> [ResumeTarget]
  {
    all(in: defaults)[sessionID]?.earlier ?? []
  }

  static func remember(
    _ earlier: [ResumeTarget], for sessionID: String, now: Date = .now,
    in defaults: UserDefaults = .standard
  ) {
    var links = all(in: defaults)
    guard links[sessionID]?.earlier != earlier else { return }
    links[sessionID] = earlier.isEmpty ? nil : Link(earlier: earlier, date: now)
    if links.count > limit {
      let kept = links.sorted { $0.value.date > $1.value.date }.prefix(limit)
      links = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
    defaults.set(try? JSONEncoder().encode(links), forKey: key)
  }

  private static func all(in defaults: UserDefaults) -> [String: Link] {
    defaults.data(forKey: key).flatMap {
      try? JSONDecoder().decode([String: Link].self, from: $0)
    } ?? [:]
  }
}
