import Foundation

/// What `drakar_wait` waits for.
enum WaitUntil: String, CaseIterable {
  /// A session newly in `drakar_needs_attention`'s set, whatever the kind.
  case attention
  /// A session that was working is not any more.
  case turnEnd = "turn_end"
  /// A session's state changed, or a session appeared or went.
  case change
}

/// Telling what moved between two looks at the sessions. Pure, so each `until` can be argued
/// about without a clock.
enum Waiting {

  /// What moved between two snapshots, for `until`, restricted to `watched` (nil = all). Each
  /// session as it is now, in the new snapshot's order; a session gone from the live ones
  /// follows, as it was last seen with its state `ended`.
  static func moved(
    from old: [SessionRow], attention oldAttention: Set<String>,
    to new: [SessionRow], attention newAttention: Set<String>,
    until: WaitUntil, watched: Set<String>?
  ) -> [SessionRow] {
    let before = Dictionary(old.map { ($0.id, $0) }) { first, _ in first }
    let nowIDs = Set(new.map(\.id))
    var gone = old.filter { !nowIDs.contains($0.id) }
    for index in gone.indices { gone[index].state = .ended }

    let candidates: [SessionRow]
    switch until {
    case .attention:
      candidates = new.filter { newAttention.contains($0.id) && !oldAttention.contains($0.id) }
    case .turnEnd:
      candidates =
        (new + gone).filter { row in
          before[row.id]?.state == .working && row.state != .working
        }
    case .change:
      candidates = new.filter { before[$0.id]?.state != $0.state } + gone
    }
    guard let watched else { return candidates }
    return candidates.filter { watched.contains($0.id) }
  }
}
