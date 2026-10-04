import DrakarKit
import Foundation
import Testing

@Suite("Folding the stream into a transcript")
struct TranscriptTests {

  private func transcript(_ fixture: Fixture, prompt: String = "Run it") throws -> Transcript {
    var transcript = Transcript()
    transcript.addPrompt(prompt)
    for message in try fixture.messages { transcript.apply(message) }
    return transcript
  }

  /// Under `--include-partial-messages` every block arrives twice, streamed then whole.
  /// Four blocks must make four entries, not eight, in the order the model wrote them.
  @Test func streamedAndWholeBlocksMakeOneEntryEach() throws {
    let transcript = try transcript(.turnWithTool)
    let kinds = transcript.entries.map(\.kind)
    #expect(kinds.count == 5)
    #expect(kinds.first == .prompt("Run it"))
    guard kinds.count == 5 else { return }
    #expect(kinds[1] == .thinking(""))
    #expect(kinds[3] == .thinking(""))
    #expect(kinds[4] == .text("Amiral."))
    guard case .tool(let call) = kinds[2] else {
      Issue.record("entry 2 is \(kinds[2])")
      return
    }
    #expect(call.name == "Bash")
    #expect(call.input["command"] == .string("echo amiral"))
    #expect(call.result == Transcript.ToolResult(content: "amiral", isError: false))
  }

  /// The same capture with the stream events taken out is what a session without
  /// `--include-partial-messages` sees; it must fold to the same transcript.
  @Test func foldsTheSameWithoutPartialMessages() throws {
    var whole = Transcript()
    whole.addPrompt("Run it")
    for message in try Fixture.turnWithTool.messages {
      if case .streamEvent = message { continue }
      whole.apply(message)
    }
    #expect(whole.entries.map(\.kind) == (try transcript(.turnWithTool)).entries.map(\.kind))
  }

  @Test func streamsTextBeforeTheWholeBlockLands() throws {
    var transcript = Transcript()
    let messages = try Fixture.turnWithTool.messages
    // Stop right after the last text delta, before its `assistant` line.
    let lastDelta = try #require(
      messages.lastIndex {
        if case .streamEvent(.blockDelta(_, .text), _) = $0 { return true }
        return false
      })
    for message in messages[...lastDelta] { transcript.apply(message) }
    #expect(transcript.entries.last?.kind == .text("Amiral."))
  }

  @Test func tracksTheSessionAndTheEndOfTheTurn() throws {
    let transcript = try transcript(.turnWithTool)
    #expect(transcript.session?.sessionID == "84e79584-4dcd-48db-b738-57f6d1946155")
    #expect(!transcript.isRunning)
    #expect(transcript.lastResult?.text == "Amiral.")
  }

  @Test func holdsAPermissionRequestUntilAnswered() throws {
    var transcript = Transcript()
    transcript.addPrompt("Touch it")
    let messages = try Fixture.permissionRequest.messages
    let request = try #require(
      messages.firstIndex {
        if case .controlRequest = $0 { return true }
        return false
      })
    for message in messages[...request] { transcript.apply(message) }

    #expect(transcript.isRunning)
    let pending = try #require(transcript.pendingPermissions.first)
    #expect(transcript.pendingPermissions.count == 1)
    #expect(pending.request.toolName == "Bash")
    #expect(pending.requestID == "4fad1802-9dc6-4a2b-8406-b35194ce2f30")

    transcript.resolvePermission(requestID: pending.requestID)
    #expect(transcript.pendingPermissions.isEmpty)
    for message in messages[(request + 1)...] { transcript.apply(message) }
    #expect(!transcript.isRunning)
    let tools = transcript.entries.compactMap { entry -> Transcript.ToolCall? in
      if case .tool(let call) = entry.kind { return call }
      return nil
    }
    #expect(tools.count == 1)
    #expect(tools.first?.result?.content == "(Bash completed with no output)")
  }

  @Test func aCancelledRequestLeavesThePendingList() throws {
    var transcript = Transcript()
    for message in try Fixture.permissionRequest.messages {
      transcript.apply(message)
      if case .controlRequest(let request) = message {
        transcript.apply(.controlCancelRequest(requestID: request.requestID))
        #expect(transcript.pendingPermissions.isEmpty)
        return
      }
    }
    Issue.record("the fixture holds no control request")
  }

  @Test func hasNoLastPromptBeforeTheFirst() {
    #expect(Transcript().lastPrompt == nil)
  }

  /// The turn after a prompt adds thinking, a tool call and text; the prompt stays the last
  /// one sent, and the next prompt takes over with what the editor attached to it.
  @Test func theLastPromptIsTheNewestSent() throws {
    var transcript = try transcript(.turnWithTool)
    #expect(transcript.lastPrompt?.kind == .prompt("Run it"))
    #expect(transcript.lastPrompt?.id != transcript.entries.last?.id)

    transcript.addPrompt("And again", context: "notes.md:3–5")
    #expect(transcript.lastPrompt?.kind == .prompt("And again"))
    #expect(transcript.lastPrompt?.context == "notes.md:3–5")
  }

  @Test func aPromptsHeadlineIsItsFirstLineWithText() {
    var transcript = Transcript()
    transcript.addPrompt("\n  \n  Fix the bar  \nthen the rest")
    #expect(transcript.lastPrompt?.headline == "Fix the bar")
  }
}
