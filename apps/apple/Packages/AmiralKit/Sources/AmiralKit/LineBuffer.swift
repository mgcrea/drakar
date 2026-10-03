import Foundation

/// Splits a byte stream into the protocol's lines.
///
/// A pipe hands over whatever the kernel had, not whole lines: a read can end in the middle
/// of a JSON object, or hold several. Feed every chunk in and get back the lines it
/// completed; the tail waits for the next chunk.
public struct LineBuffer: Sendable {
  private var pending = Data()

  public init() {}

  /// The lines `chunk` completed, without their terminators. Blank lines are dropped and a
  /// trailing `\r` is stripped.
  public mutating func append(_ chunk: Data) -> [Data] {
    pending.append(chunk)
    var lines: [Data] = []
    var start = pending.startIndex
    while let newline = pending[start...].firstIndex(of: 0x0A) {
      var end = newline
      if end > start, pending[end - 1] == 0x0D { end -= 1 }
      if end > start { lines.append(Data(pending[start..<end])) }
      start = newline + 1
    }
    pending = Data(pending[start...])
    return lines
  }

  /// Bytes received after the last newline. Non-empty when the process exits mid-line,
  /// which is worth reporting rather than silently dropping.
  public var remainder: Data { pending }
}
