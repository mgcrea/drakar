import Foundation

/// A transcript file read as it grows, for a session another process is writing: each
/// catch-up folds in only the lines appended since the last one.
public struct TranscriptFollower: Sendable {
  public private(set) var file: URL
  /// Bytes read so far.
  public private(set) var offset: UInt64 = 0
  private var buffer = LineBuffer()
  private var translator = ClaudeTranslator()

  public init(file: URL) {
    self.file = file
  }

  /// The same reading, of the file this one was moved to whole: what was read stays read.
  public func moved(to file: URL) -> TranscriptFollower {
    var moved = self
    moved.file = file
    return moved
  }

  /// Folds what was appended since the last call into `transcript`. A line still being
  /// written waits for its newline. A file that got shorter was rewritten, and is read
  /// again from the start into a fresh transcript.
  public mutating func catchUp(_ transcript: inout Transcript) throws {
    try catchUp(&transcript, upTo: .max)
  }

  /// The same, reading no further than `length` bytes into the file: the history a process
  /// started from, without what it appended since.
  public mutating func catchUp(_ transcript: inout Transcript, upTo length: UInt64) throws {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    if size < offset {
      offset = 0
      buffer = LineBuffer()
      translator = ClaudeTranslator()
      transcript = Transcript()
    }
    let end = min(size, length)
    guard end > offset else { return }
    try handle.seek(toOffset: offset)
    let data = try handle.read(upToCount: Int(end - offset)) ?? Data()
    offset += UInt64(data.count)
    for line in buffer.append(data) {
      guard let json = try? JSONValue.parse(line) else { continue }
      let time = ClaudeTranslator.timestamp(of: json)
      for event in translator.history(json) { transcript.apply(event, at: time ?? .now) }
    }
    transcript.processExited()
  }
}
