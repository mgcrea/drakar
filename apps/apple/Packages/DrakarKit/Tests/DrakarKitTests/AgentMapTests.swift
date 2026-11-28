import Foundation
import Testing

@testable import DrakarKit

/// The agent map and its toolbar pill, as the extension has them (2.1.332): subagents by the
/// call that started each, the other background tasks, and what the pill's dot says.
@Suite("Agent map")
struct AgentMapTests {

  private func feed(_ fixture: Fixture, upTo count: Int? = nil) throws -> ClaudeFeed {
    var feed = ClaudeFeed()
    feed.addPrompt("Go")
    let messages = try fixture.messages
    for message in messages.prefix(count ?? messages.count) { feed.apply(message) }
    return feed
  }

  private func start(_ call: String, task: String, parent: String? = nil) -> [AgentEvent] {
    var update = AgentTaskUpdate()
    update.isStart = true
    update.taskID = task
    update.isSubagent = true
    update.description = "Agent \(call)"
    update.status = "running"
    let item = AgentEvent.Item(
      id: call, parent: parent,
      kind: .tool(
        .init(id: call, name: "Agent", input: .object([:]), kind: .subagent(description: nil))))
    return [.itemStarted(item), .agentTask(callID: call, update)]
  }

  private func status(_ call: String, _ status: String) -> AgentEvent {
    var update = AgentTaskUpdate()
    update.status = status
    return .agentTask(callID: call, update)
  }

  private func permission(_ id: String, call: String, agentID: String?) -> AgentEvent {
    var request = PermissionRequest(
      toolName: "Bash", input: .object([:]), toolUseID: call, kind: .other)
    request.agentID = agentID
    return .permissionRequested(.init(requestID: id, request: request))
  }

  private func transcript(_ events: [AgentEvent]) -> Transcript {
    var transcript = Transcript()
    transcript.addPrompt("Go")
    for event in events { transcript.apply(event) }
    return transcript
  }

  @Test func readsTheBackgroundSet() throws {
    let messages = try Fixture.forkSubagent.messages
    guard case .system(.backgroundTasks(let tasks)) = messages[3] else {
      Issue.record("not a background set: \(messages[3])")
      return
    }
    #expect(tasks.map(\.taskID) == ["a7128443a04f9b414"])
    #expect(tasks.first?.isSubagent == true)
  }

  @Test func readsTheAgentAPermissionComesFrom() throws {
    let line = #"""
      {"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{},"tool_use_id":"toolu_1","agent_id":"a71"}}
      """#
    guard case .controlRequest(let request) = try StreamMessage(line: Data(line.utf8)),
      case .canUseTool(let permission) = request.kind
    else {
      Issue.record("not a permission request")
      return
    }
    #expect(permission.agentID == "a71")
  }

  /// A fork runs in the background: the pill counts it while it works, and stays once it is
  /// done, at none working.
  @Test func followsAForkFromStartToEnd() throws {
    let running = try feed(.forkSubagent, upTo: 5).agentMap
    #expect(!running.isEmpty)
    #expect(running.working == 1)
    #expect(running.state == .running)
    #expect(running.agents.first?.callID == "toolu_013rNB1wKZcngWYsN2CqLH2y")
    #expect(running.agents.first?.task.startedAt != nil)
    // A subagent in the background set is the tree's, not a background task row.
    #expect(running.tasks.isEmpty)

    let ended = try feed(.forkSubagent).agentMap
    #expect(!ended.isEmpty)
    #expect(ended.working == 0)
    #expect(ended.state == .idle)
    #expect(ended.agents.first?.task.endedAt != nil)
  }

  /// A shell in the background is a task row, not an agent: no pill for it alone.
  @Test func listsAShellAsABackgroundTask() throws {
    let running = try feed(.taskControls, upTo: 4).agentMap
    #expect(running.isEmpty)
    #expect(running.tasks.count == 1)
    #expect(running.tasks.first?.callID == "toolu_01Hriqem1KWjxUocjn2j6NJC")
    #expect(running.tasks.first?.description == "python3 -c 'import time; time.sleep(30)'")
    #expect(try feed(.taskControls).agentMap.tasks.isEmpty)
  }

  @Test func waitsOnAPermissionTheAgentAskedFor() {
    let byID = transcript(start("A", task: "t1") + [permission("r1", call: "x", agentID: "t1")])
    #expect(byID.agentMap.state == .waiting)
    #expect(byID.agentMap.agents.first?.isWaiting == true)

    // Without an agent id, the call it asks about sits inside the agent's card.
    let inner = AgentEvent.itemStarted(
      .init(
        id: "B", parent: "A",
        kind: .tool(.init(id: "B", name: "Bash", input: .object([:]), kind: .other))))
    let byCard = transcript(
      start("A", task: "t1") + [inner, permission("r1", call: "B", agentID: nil)])
    #expect(byCard.agentMap.state == .waiting)

    // The main thread's own permission is not an agent's.
    let main = transcript(start("A", task: "t1") + [permission("r1", call: "z", agentID: nil)])
    #expect(main.agentMap.state == .running)
  }

  @Test func nestsAnAgentUnderTheAgentThatStartedIt() {
    let map = transcript(start("A", task: "t1") + start("C", task: "t2", parent: "A")).agentMap
    #expect(map.agents.map(\.callID) == ["A"])
    #expect(map.agents.first?.children.map(\.callID) == ["C"])
    #expect(map.working == 2)
  }

  @Test func saysAFailureOnceNothingWorks() {
    let failed = transcript(start("A", task: "t1") + [status("A", "failed")])
    #expect(failed.agentMap.state == .failed)
    let stillWorking = transcript(
      start("A", task: "t1") + [status("A", "failed")] + start("B", task: "t2"))
    #expect(stillWorking.agentMap.state == .running)
  }

  /// What `status` keeps is the map's own count and dot, read without building the map.
  @Test func theStatusSummaryAgreesWithTheMap() throws {
    let cases: [Transcript] = [
      transcript([]),
      transcript(start("A", task: "t1")),
      transcript(start("A", task: "t1") + [permission("r1", call: "x", agentID: "t1")]),
      transcript(start("A", task: "t1") + [status("A", "failed")]),
      transcript(start("A", task: "t1") + start("C", task: "t2", parent: "A")),
      try feed(.forkSubagent, upTo: 5).transcript,
      try feed(.forkSubagent).transcript,
    ]
    for transcript in cases {
      #expect(transcript.agentSummary == transcript.agentMap.summary)
      #expect(transcript.status.agents == transcript.agentSummary)
    }
  }

  /// A foreground call with its result is done, as its card reads it, even when no task line
  /// said so.
  @Test func aForegroundCallWithItsResultIsDone() {
    let done = transcript(
      start("A", task: "t1") + [.toolResult(callID: "A", .init(content: "ok", isError: false))])
    #expect(done.agentMap.working == 0)
    #expect(done.agentSummary.working == 0)
  }

  /// A turn that ended took its foreground tasks with it: an ACP subagent cancelled with its
  /// turn says nothing more.
  @Test func aTurnEndingEndsItsForegroundTasks() {
    var interrupted = transcript(start("A", task: "t1"))
    interrupted.apply(.turnEnded(.init(outcome: .interrupted)))
    #expect(interrupted.agentTasks["A"]?.status == .stopped)
    #expect(interrupted.agentSummary.working == 0)
  }

  @Test func stopsCountingWhenTheProcessEnds() {
    var ended = transcript(start("A", task: "t1"))
    ended.processExited()
    #expect(ended.agentMap.working == 0)
    #expect(ended.agentMap.agents.first?.task.endedAt != nil)
  }

  /// ACP reports a subagent only as its `invoke_subagent` call: the call is its task, live.
  @Test func takesAnACPSubagentCallAsATask() throws {
    let started =
      #"{"sessionUpdate":"tool_call","toolCallId":"s1","name":"invoke_subagent","status":"in_progress","title":"Research","rawInput":{"Role":"Researcher"}}"#
    let done =
      #"{"sessionUpdate":"tool_call_update","toolCallId":"s1","name":"invoke_subagent","status":"completed","rawInput":{"Role":"Researcher"}}"#
    let updates = try [started, done].map { try JSONValue.parse(Data($0.utf8)) }

    var translator = AgyTranslator()
    var live = Transcript()
    live.addPrompt("Go")
    for event in translator.translate(update: updates[0]) { live.apply(event) }
    #expect(live.agentMap.working == 1)
    #expect(live.agentMap.agents.first?.task.description == "Researcher")
    for event in translator.translate(update: updates[1]) { live.apply(event) }
    #expect(live.agentMap.working == 0)
    #expect(live.agentMap.agents.first?.task.status == .completed)

    // A reloaded session lists none, as Claude Code's history does.
    var history = Transcript()
    for event in AgyTranslator.history(updates) { history.apply(event) }
    #expect(history.agentMap.isEmpty)
  }
}
