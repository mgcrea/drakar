import Foundation

/// A transcript file read as it grows, for a session another process is writing: each
/// catch-up folds in only the lines appended since the last one.
public struct TranscriptFollower: Sendable {
  public let file: URL
  /// Bytes read so far.
  public private(set) var offset: UInt64 = 0
  private var buffer = LineBuffer()

  public init(file: URL) {
    self.file = file
  }

  /// Folds what was appended since the last call into `transcript`. A line still being
  /// written waits for its newline. A file that got shorter was rewritten, and is read
  /// again from the start into a fresh transcript.
  public mutating func catchUp(_ transcript: inout Transcript) throws {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    if size < offset {
      offset = 0
      buffer = LineBuffer()
      transcript = Transcript()
    }
    guard size > offset else { return }
    try handle.seek(toOffset: offset)
    let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
    offset += UInt64(data.count)
    for line in buffer.append(data) {
      if let json = try? JSONValue.parse(line) { transcript.applyHistory(json) }
    }
    transcript.processExited()
  }
}
