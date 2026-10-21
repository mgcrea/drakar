import Foundation

/// How the sidebar lists the window's own sessions and those live elsewhere, kept with the
/// window. Ended stays newest first whatever this says.
enum SessionOrder: String, Codable, CaseIterable, Identifiable {
  /// The window's own in the order they came, Elsewhere newest activity first: no sort.
  case opened
  /// What wants the person on top, most urgent first, the longest waiting first in a level.
  case needsMe
  case recent
  case folder

  var id: Self { self }

  var label: String {
    switch self {
    case .opened: String(localized: "Opened")
    case .needsMe: String(localized: "Needs Me First")
    case .recent: String(localized: "Recent Activity")
    case .folder: String(localized: "Folder A–Z")
    }
  }

  /// What a row is sorted by.
  struct Key {
    var state: RowState
    /// When the transcript was last written; nil before it was.
    var activity: Date?
    var folder: String
  }

  /// `rows`, which come in the list's own order: what a sort leaves undecided keeps it.
  func sorted<Row>(_ rows: [Row], by key: (Row) -> Key) -> [Row] {
    guard self != .opened else { return rows }
    let keyed = rows.enumerated().map { (index: $0.offset, key: key($0.element), row: $0.element) }
    return keyed.sorted { a, b in comes(a.key, before: b.key) ?? (a.index < b.index) }.map(\.row)
  }

  /// Whether `a` goes above `b`; nil when this order cannot tell them apart.
  private func comes(_ a: Key, before b: Key) -> Bool? {
    switch self {
    case .opened:
      return nil
    case .needsMe:
      if a.state.need != b.state.need { return a.state.need < b.state.need }
      // A busy row is not waiting on anyone: its level keeps the list's order.
      guard a.state.need <= RowState.stopped.need else { return nil }
      return Self.compare(a.activity, b.activity, newestFirst: false)
    case .recent:
      return Self.compare(a.activity, b.activity, newestFirst: true)
    case .folder:
      switch a.folder.localizedStandardCompare(b.folder) {
      case .orderedAscending: return true
      case .orderedDescending: return false
      case .orderedSame: return nil
      }
    }
  }

  /// An undated row goes below the dated ones either way.
  private static func compare(_ a: Date?, _ b: Date?, newestFirst: Bool) -> Bool? {
    switch (a, b) {
    case (nil, nil): return nil
    case (nil, _): return false
    case (_, nil): return true
    case (let a?, let b?): return a == b ? nil : (a > b) == newestFirst
    }
  }
}
