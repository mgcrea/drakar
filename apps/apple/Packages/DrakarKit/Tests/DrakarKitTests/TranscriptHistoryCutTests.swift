import DrakarKit
import Foundation
import Testing

/// What forking from a prompt needs of a history: each prompt's message uuid, the history
/// cut just before one, and the message `--resume-session-at` keeps for that cut
/// (`Fixture.rewindHistory`; docs/claude-stream-json.md, "Rewind").
@Suite("Cutting a history before a prompt")
struct TranscriptHistoryCutTests {
  private let promptA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  private let promptB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  private let promptC = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

  @Test func historyPromptsCarryTheirUUID() throws {
    let transcript = Transcript.history(lines: try Fixture.rewindHistory.lines)
    let prompts = transcript.entries.filter { $0.headline != nil }
    #expect(prompts.map(\.messageID) == [promptA, promptB, promptC])
    #expect(transcript.entries.filter { $0.headline == nil }.allSatisfy { $0.messageID == nil })
  }

  @Test func cutsBeforeThePrompt() throws {
    let lines = try Fixture.rewindHistory.lines
    let whole = Transcript.history(lines: lines)
    let cut = Transcript.history(lines: lines, endingBefore: promptB)
    let indexOfB = try #require(whole.entries.firstIndex { $0.messageID == promptB })
    #expect(cut.entries.map(\.kind) == whole.entries[..<indexOfB].map(\.kind))
    #expect(cut.entries.compactMap(\.messageID) == [promptA])
    #expect(cut.entries.last?.kind == .text("Done."))
  }

  @Test func cutsAtTheUUIDNotTheText() {
    let lines = [
      #"{"type":"user","uuid":"p-1","parentUuid":null,"message":{"role":"user","content":"Same"}}"#,
      #"{"type":"assistant","uuid":"r-1","parentUuid":"p-1","message":{"id":"m-1","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"One."}],"stop_reason":"end_turn"}}"#,
      #"{"type":"user","uuid":"p-2","parentUuid":"r-1","message":{"role":"user","content":"Same"}}"#,
      #"{"type":"assistant","uuid":"r-2","parentUuid":"p-2","message":{"id":"m-2","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Two."}],"stop_reason":"end_turn"}}"#,
    ].map { Data($0.utf8) }
    let cut = Transcript.history(lines: lines, endingBefore: "p-2")
    #expect(cut.entries.map(\.kind) == [.prompt("Same"), .text("One.")])
    #expect(cut.entries.first?.messageID == "p-1")
  }

  @Test func resumePointIsTheOneTheCLITakes() throws {
    let lines = try Fixture.rewindHistory.lines
    // B's `parentUuid`: the "Done." line closing A's turn.
    #expect(
      Transcript.resumePoint(before: promptB, in: lines) == "00000000-0000-4000-8000-000000000224")
    #expect(Transcript.resumePoint(before: promptA, in: lines) == nil)
    #expect(Transcript.resumePoint(before: "not-a-prompt", in: lines) == nil)
  }

  @Test func forkAtAMessageArguments() {
    var command = ClaudeCommand(resumeSessionID: "s")
    command.forksSession = true
    command.resumeSessionAt = "u"
    #expect(
      command.arguments.suffix(3) == ["--resume=s", "--fork-session", "--resume-session-at=u"])
    // Only a fork is cut: resuming the session itself at a message would end it there.
    for var unforked in [ClaudeCommand(resumeSessionID: "s"), ClaudeCommand()] {
      unforked.resumeSessionAt = "u"
      #expect(!unforked.arguments.contains { $0.hasPrefix("--resume-session-at") })
    }
  }

  @Test func aLivePromptKeepsTheUUIDItWasSentWith() {
    var transcript = Transcript()
    transcript.addPrompt("x", uuid: "u")
    #expect(transcript.entries.last?.messageID == "u")
  }

  /// The uuid a queued prompt was sent with is the one its transcript line keeps.
  @Test func aQueuedPromptKeepsItsUUIDWhenItStarts() {
    var transcript = Transcript()
    transcript.addPrompt("first")
    transcript.queue(QueuedPrompt(uuid: "q", text: "next"))
    transcript.apply(.queue(id: "q", .started))
    #expect(transcript.entries.last?.messageID == "q")
  }
}
