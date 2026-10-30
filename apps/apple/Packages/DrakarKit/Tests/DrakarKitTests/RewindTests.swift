import DrakarKit
import Foundation
import Testing

@Suite("Rewinding a session's files")
struct RewindTests {

  /// `rewind`'s reply to `id` (Fixture.swift names each one's scenario).
  private func reply(_ id: String) throws -> ControlResponse {
    let replies = try Fixture.rewind.messages.compactMap { message -> ControlResponse? in
      if case .controlResponse(let response) = message { return response }
      return nil
    }
    return try #require(replies.first { $0.requestID == id })
  }

  private func result(_ id: String) throws -> RewindResult {
    try #require(RewindResult(try reply(id).response))
  }

  /// A dry run for A: both files it touched, with their line counts.
  @Test func aDryRunDecodes() throws {
    let result = try result("rewind-a-dry")
    #expect(result.canRewind)
    #expect(result.error == nil)
    #expect(result.filesChanged == ["/p/a.txt", "/p/b.txt"])
    #expect(result.insertions == 0)
    #expect(result.deletions == 2)
    #expect(!result.hasNoCheckpoint)
    #expect(!result.isNotEnabled)
  }

  /// A rewind's reply names no files; the missing list and counts read as empty and 0.
  @Test func aRewindDecodes() throws {
    let result = try result("rewind-a")
    #expect(result.canRewind)
    #expect(result.filesChanged.isEmpty)
    #expect(result.insertions == 0)
    #expect(result.deletions == 0)
    #expect(result.skippedLinks == 0)
  }

  /// A dry run for a uuid the session has no snapshot for.
  @Test func noCheckpointDecodes() throws {
    let result = try result("rewind-unknown")
    #expect(!result.canRewind)
    #expect(result.error == "No file checkpoint found for this message.")
    #expect(result.hasNoCheckpoint)
    #expect(!result.isNotEnabled)
    #expect(result.filesChanged.isEmpty)
  }

  /// A dry run in a process started without the environment variable.
  @Test func notEnabledDecodes() throws {
    let result = try result("off-rewind-d-dry")
    #expect(!result.canRewind)
    #expect(result.isNotEnabled)
    #expect(!result.hasNoCheckpoint)
  }

  /// A refused real rewind is a control `error` with no response.
  @Test func aRefusedRewindDecodes() throws {
    let unknown = try reply("rewind-unknown-real")
    #expect(!unknown.isSuccess)
    #expect(unknown.response == nil)
    #expect(RewindResult(unknown.response) == nil)
    let noCheckpoint = RewindResult(refusal: try #require(unknown.error))
    #expect(!noCheckpoint.canRewind)
    #expect(noCheckpoint.error == "No file checkpoint found for this message.")
    #expect(noCheckpoint.hasNoCheckpoint)
    #expect(!noCheckpoint.isNotEnabled)
    #expect(noCheckpoint.filesChanged.isEmpty)

    let off = try reply("off-rewind-d")
    #expect(!off.isSuccess)
    let notEnabled = RewindResult(refusal: try #require(off.error))
    #expect(!notEnabled.canRewind)
    #expect(notEnabled.isNotEnabled)
    #expect(!notEnabled.hasNoCheckpoint)
  }

  @Test func aReplyWithoutCanRewindIsNone() {
    #expect(RewindResult(nil) == nil)
    #expect(RewindResult(.object(["filesChanged": .array([])])) == nil)
  }

  @Test func theWordsAreTheExtensions() {
    #expect(RewindCopy.succeeded == "Code rewind successful")
    #expect(RewindCopy.failed == "Failed to rewind code")
    #expect(RewindCopy.noCheckpoint == "Failed to rewind: no checkpoint for this message")
    #expect(
      RewindCopy.warning
        == "Restored files go back whole, losing later changes by anyone. Bash changes to other files are not undone."
    )
    #expect(
      RewindCopy.forkNote == "A new forked conversation will be created after rewinding.")
    #expect(RewindCopy.nothingToRewind == "No files to rewind.")
    #expect(RewindCopy.notForked == "Couldn't fork from this prompt.")
    #expect(
      RewindCopy.rewoundNotForked == "Code rewind successful, but couldn't fork from this prompt.")
  }

  /// A note something later qualifies is revised where it stands, the latest of its text;
  /// with none to revise, the new text is added.
  @Test func aNoticeIsRevisedInPlace() {
    var transcript = Transcript()
    transcript.addNotice(RewindCopy.succeeded)
    transcript.addPrompt("Next", running: false)
    transcript.addNotice(RewindCopy.succeeded)
    let revision = transcript.revision
    transcript.reviseNotice(RewindCopy.succeeded, to: RewindCopy.rewoundNotForked)
    #expect(
      transcript.entries.map(\.kind) == [
        .notice(RewindCopy.succeeded), .prompt("Next"), .notice(RewindCopy.rewoundNotForked),
      ])
    #expect(transcript.revision > revision)
    var empty = Transcript()
    empty.reviseNotice(RewindCopy.succeeded, to: RewindCopy.rewoundNotForked)
    #expect(empty.entries.map(\.kind) == [.notice(RewindCopy.rewoundNotForked)])
  }
}
