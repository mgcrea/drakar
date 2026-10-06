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

  /// Folds inline lines after a prompt, sending a second prompt before line `promptBefore`.
  private func fold(_ lines: [String], promptBefore: Int? = nil) throws -> Transcript {
    var translator = CodexTranslator()
    var transcript = Transcript()
    transcript.addPrompt("go")
    for (index, line) in lines.enumerated() {
      if index == promptBefore { transcript.addPrompt("next") }
      for event in translator.translate(
        try JSONValue.parse(Data(line.utf8)), at: nil)
      {
        transcript.apply(event)
      }
    }
    return transcript
  }

  private func exec(_ method: String, _ fields: String, turn: String = "turn-1") -> String {
    """
    {"method":"\(method)","params":{"item":{"type":"commandExecution","id":"exec-1",\
    "command":"/bin/zsh -lc 'cat note.txt'","cwd":"/Users/me/project",\
    "commandActions":[{"type":"read","command":"cat note.txt","name":"note.txt",\
    "path":"/Users/me/project/note.txt"}],\(fields)},"threadId":"thread-1","turnId":"\(turn)"}}
    """
  }

  @Test func aCommandRunsAndCompletes() throws {
    let t = try fold([
      exec("item/started", #""status":"inProgress""#),
      exec(
        "item/completed",
        #""status":"completed","exitCode":0,"aggregatedOutput":"hello\n""#),
    ])
    #expect(t.entries.count == 2)
    guard case .tool(let call) = t.entries[1].kind else {
      Issue.record("\(t.entries)")
      return
    }
    #expect(call.kind == .read(path: "/Users/me/project/note.txt"))
    #expect(call.result?.content == "hello\n")
    #expect(call.result?.isError == false)
  }

  @Test func aDeclinedCommandWithoutAStartIsAnError() throws {
    let t = try fold([
      exec("item/completed", #""status":"declined","exitCode":null,"aggregatedOutput":null"#)
    ])
    #expect(t.entries.count == 2)
    guard case .tool(let call) = t.entries[1].kind else {
      Issue.record("\(t.entries)")
      return
    }
    #expect(call.result?.isError == true)
    #expect(call.result?.content == "declined")
  }

  @Test func aCompletedCommandWithNoOutputShowsNone() throws {
    let t = try fold([
      exec("item/completed", #""status":"completed","exitCode":0,"aggregatedOutput":null"#)
    ])
    guard case .tool(let call) = t.entries[1].kind else {
      Issue.record("\(t.entries)")
      return
    }
    #expect(call.result?.content == "")
    #expect(call.result?.isError == false)
  }

  @Test func aSearchWithNoQuerySearchesItsPath() throws {
    let t = try fold([
      """
      {"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-1",\
      "command":"/bin/zsh -lc 'rg --files src'","cwd":"/Users/me/project",\
      "commandActions":[{"type":"search","command":"rg --files src","query":null,"path":"src"}],\
      "status":"inProgress"},"threadId":"thread-1","turnId":"turn-1"}}
      """
    ])
    guard case .tool(let call) = t.entries[1].kind else {
      Issue.record("\(t.entries)")
      return
    }
    #expect(call.kind == .search(pattern: "src"))
  }

  @Test func aLateCompletionLandsOnItsOwnEntry() throws {
    let lines = [
      exec("item/started", #""status":"inProgress""#),
      """
      {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],\
      "status":"interrupted","error":null,"durationMs":5}}}
      """,
      exec("item/completed", #""status":"completed","exitCode":0,"aggregatedOutput":"late""#),
    ]
    let before = try fold(Array(lines.prefix(2)))
    #expect(before.turnEnd == .interrupted)
    let t = try fold(lines, promptBefore: 2)
    #expect(t.isRunning)
    #expect(t.entries.filter { if case .tool = $0.kind { true } else { false } }.count == 1)
    guard case .tool(let call) = t.entries[1].kind else {
      Issue.record("\(t.entries)")
      return
    }
    #expect(call.result?.content == "late")
    #expect(call.result?.isError == false)
  }

  @Test func aFailedTurnEndsWithItsError() throws {
    let t = try fold([
      """
      {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],\
      "status":"failed","error":{"message":"Overloaded"},"durationMs":5}}}
      """
    ])
    #expect(t.turnEnd == .failed)
    #expect(t.entries.last?.kind == .failure("Overloaded"))
  }

  @Test func reasoningIsThereWhileItStreams() throws {
    let t = try fold(until: 6)
    #expect(t.entries[1].kind == .thinking("**Planning the file**"))
    #expect(t.entries[1].thinkingSince != nil)
  }

  @Test func aSecondSummaryPartIsAParagraphApart() throws {
    func line(_ method: String, _ extra: String) -> String {
      #"{"method":"item/reasoning/\#(method)","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"rs-1",\#(extra)}}"#
    }
    let t = try fold([
      #"{"method":"item/started","params":{"item":{"type":"reasoning","id":"rs-1","summary":[],"content":[]},"threadId":"thread-1","turnId":"turn-1"}}"#,
      line("summaryTextDelta", #""delta":"first","summaryIndex":0"#),
      line("summaryPartAdded", #""summaryIndex":1"#),
      line("summaryTextDelta", #""delta":"second","summaryIndex":1"#),
    ])
    #expect(t.entries[1].kind == .thinking("first\n\nsecond"))
  }

  private func reasoning(_ method: String, summary: String = "[]") -> String {
    #"{"method":"\#(method)","params":{"item":{"type":"reasoning","id":"rs-1","summary":\#(summary),"content":[]},"threadId":"thread-1","turnId":"turn-1"}}"#
  }

  @Test func anEmptyReasoningItemLeavesNoEntry() throws {
    let t = try fold([reasoning("item/started"), reasoning("item/completed")])
    #expect(t.entries.map(\.kind) == [.prompt("go")])
  }

  @Test func anEmptyCompletionKeepsWhatStreamed() throws {
    let t = try fold([
      reasoning("item/started"),
      #"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"rs-1","delta":"Weighing","summaryIndex":0}}"#,
      reasoning("item/completed"),
    ])
    #expect(t.entries.count == 2)
    #expect(t.entries[1].kind == .thinking("Weighing"))
    #expect(t.entries[1].thinkingSince == nil)
    #expect(t.entries[1].thinkingDuration != nil)
  }
}
