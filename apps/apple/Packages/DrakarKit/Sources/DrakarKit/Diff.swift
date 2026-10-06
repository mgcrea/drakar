import Foundation

/// One line of a line diff.
public struct DiffLine: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case context
    case added
    case removed
    /// Unchanged lines left out between two hunks.
    case gap(Int)
  }

  public var kind: Kind
  public var text: String

  public init(_ kind: Kind, _ text: String) {
    self.kind = kind
    self.text = text
  }
}

public enum LineDiff {
  /// Above this many cells the table is not built and the change shows as everything
  /// removed then everything added: correct, only less precise, and never a stall on a
  /// rewritten file.
  static let maximumCells = 4_000_000

  /// The lines of `old` and `new`, unchanged, removed and added, in order: common ends
  /// trimmed, then a longest common subsequence over what is left.
  public static func lines(old: String, new: String) -> [DiffLine] {
    let a = split(old)
    let b = split(new)
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix,
      a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
    {
      suffix += 1
    }
    let middleA = Array(a[prefix..<(a.count - suffix)])
    let middleB = Array(b[prefix..<(b.count - suffix)])

    var result = a[..<prefix].map { DiffLine(.context, $0) }
    result += middle(middleA, middleB)
    result += a[(a.count - suffix)...].map { DiffLine(.context, $0) }
    return result
  }

  /// Only the changes, each with `context` unchanged lines around it; longer unchanged
  /// runs become one `.gap`.
  public static func hunks(old: String, new: String, context: Int = 3) -> [DiffLine] {
    let all = lines(old: old, new: new)
    let changed = all.indices.filter { all[$0].kind != .context }
    guard !changed.isEmpty else { return [] }
    var keep = Set<Int>()
    for index in changed {
      for nearby in max(0, index - context)...min(all.count - 1, index + context) {
        keep.insert(nearby)
      }
    }
    var result: [DiffLine] = []
    var skipped = 0
    for index in all.indices {
      if keep.contains(index) {
        if skipped > 0 { result.append(DiffLine(.gap(skipped), "")) }
        skipped = 0
        result.append(all[index])
      } else {
        skipped += 1
      }
    }
    if skipped > 0 { result.append(DiffLine(.gap(skipped), "")) }
    return result
  }

  private static func split(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // A trailing newline ends the last line rather than starting an empty one.
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  private static func middle(_ a: [String], _ b: [String]) -> [DiffLine] {
    if a.isEmpty { return b.map { DiffLine(.added, $0) } }
    if b.isEmpty { return a.map { DiffLine(.removed, $0) } }
    guard a.count * b.count <= maximumCells else {
      return a.map { DiffLine(.removed, $0) } + b.map { DiffLine(.added, $0) }
    }
    // lengths[i][j]: the LCS of a[i...] and b[j...], flattened.
    let width = b.count + 1
    var lengths = [Int32](repeating: 0, count: (a.count + 1) * width)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        lengths[i * width + j] =
          a[i] == b[j]
          ? lengths[(i + 1) * width + j + 1] + 1
          : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
      }
    }
    var result: [DiffLine] = []
    var i = 0
    var j = 0
    while i < a.count, j < b.count {
      if a[i] == b[j] {
        result.append(DiffLine(.context, a[i]))
        i += 1
        j += 1
      } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
        result.append(DiffLine(.removed, a[i]))
        i += 1
      } else {
        result.append(DiffLine(.added, b[j]))
        j += 1
      }
    }
    result += a[i...].map { DiffLine(.removed, $0) }
    result += b[j...].map { DiffLine(.added, $0) }
    return result
  }
}

/// What a file-changing call does to a file, as diffs a view can draw.
public struct FileChange: Sendable, Equatable {
  public var path: String
  /// One diff per edit; a Write is one.
  public var diffs: [[DiffLine]]
  public var isNewFile: Bool

  /// Nil when no edit could be read. `existing` is the file's current content, which only a
  /// write needs (to diff a rewrite against what it replaces); nil means it does not exist.
  public init?(path: String, edits: [FileEdit], existing: String? = nil) {
    guard !edits.isEmpty else { return nil }
    self.path = path
    var diffs: [[DiffLine]] = []
    var isNewFile = false
    for edit in edits {
      switch edit.change {
      case .replace(let old, let new):
        diffs.append(LineDiff.lines(old: old, new: new))
      case .write(let content):
        diffs.append(LineDiff.hunks(old: existing ?? "", new: content, context: 3))
        isNewFile = existing == nil
      case .patch(let text):
        let patch = PatchText.lines(text)
        diffs.append(patch.lines)
        isNewFile = patch.isNewFile
      }
    }
    self.diffs = diffs
    self.isNewFile = isNewFile
  }

  public var addedCount: Int { count(.added) }
  public var removedCount: Int { count(.removed) }

  private func count(_ kind: DiffLine.Kind) -> Int {
    diffs.joined().filter { $0.kind == kind }.count
  }
}
