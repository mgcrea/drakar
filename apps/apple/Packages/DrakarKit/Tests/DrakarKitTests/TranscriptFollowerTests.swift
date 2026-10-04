import DrakarKit
import Foundation
import Testing

@Suite("Following a transcript as it is written")
struct TranscriptFollowerTests {

  private let file = FileManager.default.temporaryDirectory.appending(
    path: "follow-\(UUID()).jsonl")

  private func append(_ data: Data) throws {
    if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
      FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
    }
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()
  }

  private func joined(_ lines: [Data]) -> Data {
    Data(lines.map { $0 + Data("\n".utf8) }.joined())
  }

  /// Read in pieces, cut mid-line, it folds to the same thing as one read of the whole.
  @Test func piecesFoldToTheWhole() throws {
    let whole = joined(try Fixture.historyWithTool.lines)
    let cut = whole.count / 2 + 7
    var follower = TranscriptFollower(file: file)
    var transcript = Transcript()
    try append(whole.prefix(cut))
    try follower.catchUp(&transcript)
    try append(whole.dropFirst(cut))
    try follower.catchUp(&transcript)
    let once = try Transcript.history(contentsOf: file)
    #expect(transcript.entries == once.entries)
    #expect(transcript.title == once.title)
    #expect(follower.offset == UInt64(whole.count))
  }

  /// A file that got shorter was rewritten: start over, never append the new to the old.
  @Test func startsOverWhenTheFileShrinks() throws {
    var follower = TranscriptFollower(file: file)
    var transcript = Transcript()
    try append(joined(try Fixture.historyWithTool.lines))
    try follower.catchUp(&transcript)
    let prompt = #"{"type":"user","message":{"role":"user","content":"only this"}}"#
    try Data((prompt + "\n").utf8).write(to: file)
    try follower.catchUp(&transcript)
    #expect(transcript.entries.map(\.kind) == [.prompt("only this")])
  }

  @Test func aMissingFileThrows() {
    var follower = TranscriptFollower(file: file.appending(path: "nope"))
    var transcript = Transcript()
    #expect(throws: (any Error).self) { try follower.catchUp(&transcript) }
  }
}
