import DrakarKit
import Foundation
import Testing

/// Codex's app-server through the same transcript: the check that `AgentEvent` is no
/// agent's in particular (docs/superpowers/specs/2026-10-06-agent-backend-design.md).
@Suite("A Codex turn as agent events")
struct CodexTranslatorTests {
  private func fold(until stop: Int? = nil) throws -> Transcript {
    var translator = CodexTranslator()
    var transcript = Transcript()
    transcript.addPrompt("Create hello.txt with hi, then run touch from-shell.txt.")
    let lines = try Fixture.codexTurn.lines
    for line in lines.prefix(stop ?? lines.count) {
      for event in translator.translate(try JSONValue.parse(line), at: nil) {
        transcript.apply(event)
      }
    }
    return transcript
  }

  @Test func foldsTheTurn() throws {
    let t = try fold()
    #expect(t.session?.sessionID == "thread-1")
    #expect(t.session?.model == "gpt-6-astra")
    let kinds = t.entries.map(\.kind)
    #expect(kinds.count == 4)
    #expect(kinds.first == .prompt("Create hello.txt with hi, then run touch from-shell.txt."))
    #expect(kinds[1] == .thinking("**Planning the file**"))
    guard case .tool(let patch) = kinds[2] else {
      Issue.record("\(kinds)")
      return
    }
    #expect(
      patch.kind
        == .fileChange(
          path: "/Users/me/project/hello.txt",
          edits: [FileEdit(path: "/Users/me/project/hello.txt", change: .patch("hi\n"))]))
    #expect(patch.result?.isError == false)
    #expect(kinds[3] == .text("Created hello.txt containing `hi`; the shell command was rejected."))
    #expect(t.turnEnd == .completed)
    #expect(!t.isRunning)
    #expect(t.contextWindow == 258_400)
    #expect(t.contextUsage == TokenUsage(input: 244, cacheCreation: 0, cacheRead: 21120, output: 5))
  }

  @Test func asksAndWithdrawsApprovals() throws {
    let asking = try fold(until: 9)
    #expect(asking.pendingPermissions.map(\.requestID) == ["0"])
    #expect(asking.pendingPermissions.first?.request.toolUseID == "patch-1")
    if case .fileChange? = asking.pendingPermissions.first?.request.kind {
    } else {
      Issue.record("not a file change: \(String(describing: asking.pendingPermissions.first))")
    }
    let answered = try fold(until: 10)
    #expect(answered.pendingPermissions.isEmpty)
    let command = try fold(until: 12)
    #expect(
      command.pendingPermissions.first?.request.kind == .shell(command: "touch from-shell.txt"))
  }

  @Test func aFileChangeDrawsAsADiff() throws {
    let t = try fold()
    guard case .tool(let call) = t.entries[2].kind,
      case .fileChange(let path, let edits) = call.kind,
      let change = FileChange(path: path, edits: edits)
    else {
      Issue.record("no diff")
      return
    }
    #expect(change.isNewFile)
    #expect(change.addedCount == 1)
  }
}
