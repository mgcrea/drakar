import Foundation

/// Splits a byte stream into the protocol's lines.
///
/// A pipe hands over whatever the kernel had, not whole lines: a read can end in the middle
/// of a JSON object, or hold several. Feed every chunk in and get back the lines it
/// completed; the tail waits for the next chunk.
///
/// Each byte is searched once: a megabyte line arrives in hundreds of chunks, and searching
/// the whole tail again for each made one take a quarter of a second. The CLI's pipes and
/// the session host's socket are framed here alike.
public struct LineBuffer: Sendable {
  private var pending = Data()
  /// How much of `pending` is known to hold no `\n`.
  private var searched = 0

  public init() {}

  /// The lines `chunk` completed, without their terminators. Blank lines are dropped and a
  /// trailing `\r` is stripped.
  public mutating func append(_ chunk: Data) -> [Data] {
    pending.append(chunk)
    var lines: [Data] = []
    var start = 0
    pending.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      while let found = memchr(base + searched, 0x0A, bytes.count - searched) {
        let newline = base.distance(to: UnsafeRawPointer(found))
        var end = newline
        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
        if end > start { lines.append(Data(bytes[start..<end])) }
        start = newline + 1
        searched = start
      }
      searched = bytes.count
    }
    if start > 0 {
      pending = Data(pending[start...])
      searched -= start
    }
    return lines
  }

  /// Bytes received after the last newline. Non-empty when the process exits mid-line,
  /// which is worth reporting rather than silently dropping.
  public var remainder: Data { pending }
}
