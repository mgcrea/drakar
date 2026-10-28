import Foundation
import Testing

@testable import DrakarKit

/// A subagent, as the CLI reports it: `task_*` lines keyed by the `Agent` call that started
/// it, and, for one in the foreground, its prompt and tool calls under that call's id.
@Suite("Subagents")
struct AgentTaskTests {

  private let agentID = "toolu_014p1beTxR9BEAEKj43FmLUA"

  private func transcript(upTo count: Int? = nil) throws -> ClaudeFeed {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Run it")
    let messages = try Fixture.subagentAndTodos.messages
    for message in messages.prefix(count ?? messages.count) { transcript.apply(message) }
    return transcript
  }

  @Test func decodesEveryCapturedLine() throws {
    for fixture in [Fixture.subagentAndTodos, .planRequest] {
      for message in try fixture.messages {
        if case .unknown(let type, _) = message { Issue.record("unmodelled line: \(type)") }
      }
    }
  }

  /// While it runs: what it was asked, its newest tool, and what it has used so far.
  @Test func followsARunningSubagent() throws {
    // Up to and including its `task_progress`.
    let transcript = try transcript(upTo: 5)
    let task = try #require(transcript.agentTasks[agentID])
    #expect(task.status == .running)
    #expect(task.prompt?.hasPrefix("Find all .txt files") == true)
    #expect(task.lastToolName == "Bash")
    #expect(task.toolUses == 1)
    #expect(task.totalTokens == 34399)
    #expect(task.progressLine == "Bash · 1 tool · 34K tokens · 6s")
  }

  /// Its prompt is the card's, not a note in the conversation.
  @Test func itsPromptIsNotANote() throws {
    let transcript = try transcript()
    for entry in transcript.entries {
      if case .notice(let text) = entry.kind { Issue.record("a note: \(text)") }
    }
  }

  @Test func endsWithItsReport() throws {
    let transcript = try transcript()
    let task = try #require(transcript.agentTasks[agentID])
    #expect(task.status == .completed)
    #expect(task.summary?.hasPrefix("Found 2 .txt files") == true)
    let call = try #require(
      transcript.entries.lazy.compactMap { entry -> Transcript.ToolCall? in
        if case .tool(let call) = entry.kind, call.id == self.agentID { return call }
        return nil
      }.first)
    let report = try #require(call.result?.agentReport)
    #expect(report.status == "completed")
    #expect(report.text?.hasPrefix("Found 2 .txt files") == true)
    #expect(report.toolUses == 1)
  }

  /// Its tool calls are its own: under the `Agent` call, not the session's.
  @Test func groupsItsToolCallsUnderTheAgent() throws {
    let transcript = try transcript()
    let children = transcript.entries.filter { $0.parentToolUseID == agentID }
    #expect(children.count == 1)
    guard case .tool(let call)? = children.first?.kind else {
      Issue.record("not a tool call: \(String(describing: children.first?.kind))")
      return
    }
    #expect(call.name == "Bash")
    #expect(call.result?.content == "./a.txt\n./b.txt")
  }

  /// The view draws the session's own entries, and a subagent's inside its card; a line
  /// whose call is not in this transcript stays where it is.
  @Test func groupsForTheView() throws {
    var transcript = try transcript()
    transcript.apply(
      try StreamMessage(
        line: Data(
          #"{"type":"assistant","message":{"id":"m9","role":"assistant","content":[{"type":"text","text":"lost"}]},"parent_tool_use_id":"gone","session_id":"s"}"#
            .utf8)))
    let groups = transcript.grouped()
    #expect(!groups.top.contains { $0.parentToolUseID == agentID })
    #expect(groups.top.contains { $0.parentToolUseID == "gone" })
    #expect(groups.children[agentID]?.count == 1)
    #expect(groups.top.count + 1 == transcript.entries.count)
  }

  /// A subagent's own subagent is drawn where its line falls, indented, rather than inside a
  /// card nobody draws.
  @Test func aNestedSubagentsLinesStayListed() throws {
    var transcript = try transcript()
    for line in [
      #"{"type":"assistant","message":{"id":"m7","role":"assistant","content":[{"type":"tool_use","id":"inner","name":"Agent","input":{"description":"Deeper"}}]},"parent_tool_use_id":"toolu_014p1beTxR9BEAEKj43FmLUA","session_id":"s"}"#,
      #"{"type":"assistant","message":{"id":"m8","role":"assistant","content":[{"type":"tool_use","id":"deep","name":"Read","input":{"file_path":"/a"}}]},"parent_tool_use_id":"inner","session_id":"s"}"#,
    ] {
      transcript.apply(try StreamMessage(line: Data(line.utf8)))
    }
    let groups = transcript.grouped()
    #expect(groups.children[agentID]?.contains { $0.id == "inner" } == true)
    #expect(groups.top.contains { $0.id == "deep" })
  }

  /// A process that ends takes its subagents with it: none is left running.
  @Test func anEndedProcessEndsItsSubagents() throws {
    var transcript = try transcript(upTo: 5)
    transcript.processExited()
    #expect(transcript.agentTasks[agentID]?.status == .ended("session ended"))
  }

  /// One sent to the background answers at once, and finishes in a notification that may come
  /// a turn later.
  @Test func followsABackgroundSubagentToItsEnd() throws {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Run it")
    let lines = [
      #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"bg","name":"Agent","input":{"description":"Look around","prompt":"Look"}}]},"parent_tool_use_id":null,"session_id":"s"}"#,
      #"{"type":"system","subtype":"task_started","task_id":"t9","tool_use_id":"bg","description":"Look around","is_backgrounded":true,"task_type":"local_agent","session_id":"s"}"#,
      #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"bg","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"parent_tool_use_id":null,"session_id":"s","tool_use_result":{"isAsync":true,"status":"async_launched","agentId":"t9"}}"#,
      #"{"type":"result","subtype":"success","is_error":false,"result":"Started","session_id":"s"}"#,
    ]
    for line in lines { transcript.apply(try StreamMessage(line: Data(line.utf8))) }
    #expect(transcript.agentTasks["bg"]?.isBackgrounded == true)
    #expect(transcript.agentTasks["bg"]?.status == .running)
    transcript.apply(
      try StreamMessage(
        line: Data(
          #"{"type":"system","subtype":"task_updated","task_id":"t9","patch":{"status":"failed"},"session_id":"s"}"#
            .utf8)))
    #expect(transcript.agentTasks["bg"]?.status == .failed)
  }

  /// `task-controls`, folded up to its `count`th line, the prompt sent first.
  private func taskControls(upTo count: Int? = nil) throws -> ClaudeFeed {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Run it")
    let messages = try Fixture.taskControls.messages
    for message in messages.prefix(count ?? messages.count) { transcript.apply(message) }
    return transcript
  }

  /// A task keeps the stream's ID for it and its type: a foreground Bash is a `local_bash`.
  @Test func aTaskKeepsItsIDAndType() throws {
    let transcript = try taskControls()
    let bash = try #require(transcript.agentTasks["toolu_01Hriqem1KWjxUocjn2j6NJC"])
    #expect(bash.taskID == "b8cffcoy7")
    #expect(bash.taskType == "local_bash")
    let agent = try #require(transcript.agentTasks["toolu_014NzQkqSJ86DigdoFkAABoZ"])
    #expect(agent.taskID == "a7b2244ac3d1175c6")
    #expect(agent.taskType == "local_agent")
  }

  /// A call moved to the background is said so by `task_updated`'s patch alone
  /// (task-controls.jsonl:5): its task reads as background from there.
  @Test func aMovedCallIsBackgrounded() throws {
    let bash = "toolu_01Hriqem1KWjxUocjn2j6NJC"
    #expect(try taskControls(upTo: 4).agentTasks[bash]?.isBackgrounded == false)
    #expect(try taskControls(upTo: 5).agentTasks[bash]?.isBackgrounded == true)
  }

  /// A stop reads as one, whether the CLI says `killed` (`task_updated`) or `stopped`
  /// (`task_notification`), for a Bash, an agent, and the agent's own Bash.
  @Test func aStoppedTaskIsStopped() throws {
    #expect(AgentTask.Status("killed") == .stopped)
    #expect(AgentTask.Status("stopped") == .stopped)
    let bash = "toolu_01QvikCtLJZ1DmHZnT84msYU"
    // Up to and including its `task_updated` `killed`.
    #expect(try taskControls(upTo: 21).agentTasks[bash]?.status == .stopped)
    let transcript = try taskControls()
    #expect(transcript.agentTasks[bash]?.status == .stopped)
    #expect(transcript.agentTasks["toolu_014NzQkqSJ86DigdoFkAABoZ"]?.status == .stopped)
    #expect(transcript.agentTasks["toolu_01Ak2ftyoHCTnMr2dWQvwd3F"]?.status == .stopped)
  }

  /// An `Agent` result names the subagent it ran.
  @Test func aReportKeepsItsAgentID() throws {
    let transcript = try transcript()
    let call = try #require(
      transcript.entries.lazy.compactMap { entry -> Transcript.ToolCall? in
        if case .tool(let call) = entry.kind, call.id == self.agentID { return call }
        return nil
      }.first)
    #expect(call.result?.agentReport?.agentID == "a408679160ffa9e01")
  }
}
