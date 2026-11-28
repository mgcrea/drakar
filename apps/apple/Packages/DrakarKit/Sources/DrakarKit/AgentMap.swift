import Foundation

/// What the session's subagents and background tasks are doing, as the extension's agent map
/// and its toolbar pill show it (2.1.332): the agents nested under the call that started
/// each, and the other tasks running in the background. In no agent's words: any agent whose
/// translator reports its subagents as tasks has one.
public struct AgentMap: Sendable, Equatable {
  /// The pill's dot, most urgent first.
  public enum State: Sendable, Equatable {
    /// A working agent waits on a permission only the person can give.
    case waiting
    case running
    /// None works, and one failed.
    case failed
    case idle
  }

  public struct Agent: Sendable, Equatable, Identifiable {
    /// The call that started it: its card's id.
    public var id: String { callID }
    public var callID: String
    public var task: AgentTask
    /// Still at work, as its card reads it: running, and not a foreground call that has its
    /// result already.
    public var isWorking: Bool
    /// Working, and a permission it asked for waits on the person.
    public var isWaiting: Bool
    /// The agents it started itself.
    public var children: [Agent]
  }

  /// What the pill shows, and all `Transcript.Status` keeps: a subagent's progress changes
  /// the map's rows but none of this, so it does not redraw what reads the status.
  public struct Summary: Sendable, Equatable {
    /// The session started a subagent: the pill shows.
    public var hasAgents = false
    /// Agents working now, nested or not.
    public var working = 0
    public var state: State = .idle

    public init(hasAgents: Bool = false, working: Int = 0, state: State = .idle) {
      self.hasAgents = hasAgents
      self.working = working
      self.state = state
    }
  }

  /// A task in the background that is not a subagent: a shell, a workflow, a monitor.
  public struct Task: Sendable, Equatable, Identifiable {
    public var id: String { taskID }
    public var taskID: String
    /// The call that started it, when the agent named one: where its card is.
    public var callID: String?
    public var taskType: String?
    public var description: String?
    public var startedAt: Date?
  }

  /// Oldest first; each with the agents it started.
  public var agents: [Agent] = []
  public var tasks: [Task] = []

  public init(agents: [Agent] = [], tasks: [Task] = []) {
    self.agents = agents
    self.tasks = tasks
  }

  /// Every agent, nested or not.
  public var allAgents: [Agent] {
    agents.flatMap { [$0] + Self.flatten($0.children) }
  }

  private static func flatten(_ agents: [Agent]) -> [Agent] {
    agents.flatMap { [$0] + flatten($0.children) }
  }

  /// Agents working now, nested or not: the pill's count.
  public var working: Int { allAgents.count(where: \.isWorking) }

  /// The session never started a subagent: no pill.
  public var isEmpty: Bool { agents.isEmpty }

  public var state: State {
    let all = allAgents
    return Self.state(
      waiting: all.contains { $0.isWorking && $0.isWaiting },
      working: all.contains(where: \.isWorking),
      failed: all.contains { $0.task.status == .failed })
  }

  public var summary: Summary { Summary(hasAgents: !isEmpty, working: working, state: state) }

  static func state(waiting: Bool, working: Bool, failed: Bool) -> State {
    waiting ? .waiting : working ? .running : failed ? .failed : .idle
  }
}

extension Transcript {
  /// What the pill shows. Part of `status`, taken after every event: it walks the tasks once,
  /// never the entries, and sorts nothing.
  public var agentSummary: AgentMap.Summary {
    if agentTasks.isEmpty { return AgentMap.Summary() }
    var summary = AgentMap.Summary()
    var waiting = false
    var working = false
    var failed = false
    let asking = pendingPermissions.isEmpty ? nil : askingAgents()
    for (call, task) in agentTasks where task.isSubagent {
      summary.hasAgents = true
      if isAgentWorking(call: call, task: task) {
        summary.working += 1
        working = true
        if let asking, asking.isAsking(call: call, task: task) { waiting = true }
      } else if task.status == .failed {
        failed = true
      }
    }
    summary.state = AgentMap.state(waiting: waiting, working: working, failed: failed)
    return summary
  }

  /// The session's agent map, for the panel the pill opens: read from the transcript while the
  /// panel is up, never from `status`, since a subagent's progress changes it.
  public var agentMap: AgentMap {
    if agentTasks.isEmpty && backgroundTasks.isEmpty { return AgentMap() }
    let subagents = agentTasks.filter { $0.value.isSubagent }
    let asking = askingAgents()
    var childrenOf: [String: [String]] = [:]
    var roots: [String] = []
    for call in subagents.keys {
      // The nearest enclosing call that is itself a subagent's: a subagent's subagent.
      if let parent = entry(withID: call)?.parentToolUseID, subagents[parent] != nil,
        parent != call
      {
        childrenOf[parent, default: []].append(call)
      } else {
        roots.append(call)
      }
    }
    func ordered(_ calls: [String]) -> [String] {
      calls.sorted { lhs, rhs in
        let left = subagents[lhs]?.startedAt ?? .distantPast
        let right = subagents[rhs]?.startedAt ?? .distantPast
        return left == right ? lhs < rhs : left < right
      }
    }
    func node(_ call: String, depth: Int) -> AgentMap.Agent {
      let task = subagents[call]!
      let isWorking = isAgentWorking(call: call, task: task)
      // Depth-capped against a cycle the parent links should never make.
      let children =
        depth < 16 ? ordered(childrenOf[call] ?? []).map { node($0, depth: depth + 1) } : []
      return AgentMap.Agent(
        callID: call, task: task, isWorking: isWorking,
        isWaiting: isWorking && asking.isAsking(call: call, task: task), children: children)
    }
    let callByTask = Dictionary(
      agentTasks.compactMap { call, task in task.taskID.map { ($0, call) } },
      uniquingKeysWith: { first, _ in first })
    let tasks = backgroundTasks.filter { !$0.isSubagent }.map { task in
      let call = callByTask[task.taskID]
      return AgentMap.Task(
        taskID: task.taskID, callID: call, taskType: task.taskType,
        description: task.description ?? call.flatMap { agentTasks[$0]?.description },
        startedAt: call.flatMap { agentTasks[$0]?.startedAt })
    }
    return AgentMap(agents: ordered(roots).map { node($0, depth: 0) }, tasks: tasks)
  }

  /// As its card reads it (`TaskCardState`): a foreground call with its result is done,
  /// whatever its task last said, since a closing task line can fail to come.
  private func isAgentWorking(call: String, task: AgentTask) -> Bool {
    guard task.status == .running else { return false }
    if task.isBackgrounded { return true }
    guard case .tool(let toolCall)? = entry(withID: call)?.kind else { return true }
    return toolCall.result == nil || toolCall.result?.agentReport?.isBackgrounded == true
  }

  /// Who the permissions waiting on the person come from: an agent by its task id (Claude
  /// Code's `agent_id`), or by the card the call asked about sits in.
  private func askingAgents() -> AskingAgents {
    var asking = AskingAgents()
    for pending in pendingPermissions {
      if let agent = pending.request.agentID { asking.tasks.insert(agent) }
      if let call = pending.request.toolUseID,
        let parent = entry(withID: call)?.parentToolUseID
      {
        asking.calls.insert(parent)
      }
    }
    return asking
  }
}

private struct AskingAgents {
  var tasks = Set<String>()
  var calls = Set<String>()

  func isAsking(call: String, task: AgentTask) -> Bool {
    calls.contains(call) || (task.taskID.map(tasks.contains) ?? false)
  }
}
