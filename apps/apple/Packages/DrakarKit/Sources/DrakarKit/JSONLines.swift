import Foundation

/// The lines of a newline-delimited JSON buffer, walked one at a time without copying the
/// buffer, newest or oldest first. Ported from Armada, where it replaced six copies of a
/// split-everything-first loop that held 50MB transcripts several times over.
///
/// **`droppingFirstLine` is the contract every tail reader relies on.** A read that did
/// not start at byte zero almost certainly starts part-way through a line, and that
/// fragment is not parseable JSON. Set, the first non-empty line is skipped in both
/// directions. Empty lines are never yielded, matching the
/// `split(separator:omittingEmptySubsequences: true)` the copies used, so a buffer that
/// happens to open on a newline still loses its first *non-empty* line.
enum JSONLines {
  /// Newest line first: what every "the last X in the file" parser wants.
  static func newestFirst(_ buffer: Data, droppingFirstLine: Bool) -> NewestFirst {
    NewestFirst(
      buffer: buffer, floor: floor(of: buffer, droppingFirstLine: droppingFirstLine),
      cursor: buffer.endIndex)
  }

  /// Oldest line first, for the readers that want the first match or the whole series.
  static func oldestFirst(_ buffer: Data, droppingFirstLine: Bool) -> OldestFirst {
    OldestFirst(buffer: buffer, cursor: floor(of: buffer, droppingFirstLine: droppingFirstLine))
  }

  struct NewestFirst: Sequence, IteratorProtocol {
    let buffer: Data
    /// Nothing before this index is yielded.
    let floor: Data.Index
    /// The exclusive end of the part not yet walked.
    var cursor: Data.Index

    mutating func next() -> Data? {
      let (base, floor) = (buffer.startIndex, self.floor)
      while cursor > floor {
        let end = cursor
        let start = buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data.Index in
          var index = end - 1
          while index >= floor, raw[index - base] != 0x0A { index -= 1 }
          return index + 1
        }
        // Onto the newline that ended the search, or below the floor when there was none.
        cursor = start - 1
        if start < end { return buffer[start..<end] }
      }
      return nil
    }
  }

  struct OldestFirst: Sequence, IteratorProtocol {
    let buffer: Data
    /// The start of the part not yet walked.
    var cursor: Data.Index

    mutating func next() -> Data? {
      let (base, end) = (buffer.startIndex, buffer.endIndex)
      while cursor < end {
        let start = cursor
        let stop = buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data.Index in
          var index = start
          while index < end, raw[index - base] != 0x0A { index += 1 }
          return index
        }
        cursor = stop + 1
        if stop > start { return buffer[start..<stop] }
      }
      return nil
    }
  }

  /// Where the first line worth reading starts: the buffer's start, or just past the
  /// leading fragment and any newlines before it.
  private static func floor(of buffer: Data, droppingFirstLine: Bool) -> Data.Index {
    guard droppingFirstLine else { return buffer.startIndex }
    var first = OldestFirst(buffer: buffer, cursor: buffer.startIndex)
    guard let fragment = first.next() else { return buffer.endIndex }
    return fragment.endIndex
  }
}
