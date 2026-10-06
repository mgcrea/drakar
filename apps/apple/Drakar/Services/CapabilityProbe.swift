import DrakarKit
import Foundation

/// What one probe read, and what each pane says about what it did not.
struct ProbeOutcome: Equatable {
  var capabilities = ProjectCapabilities()
  /// Why the skills are missing; nil when they arrived.
  var skillsProblem: String?
  var serversProblem: String?
  /// The end of the CLI's stderr.
  var diagnostics = ""

  static func failed(_ reason: String) -> ProbeOutcome {
    ProbeOutcome(skillsProblem: reason, serversProblem: reason)
  }
}

/// A `claude` started in a project's folder only to be asked what it would load, then let
/// go: `initialize` and `mcp_status`, no prompt, no transcript
/// (docs/claude-stream-json.md, "Skills and MCP status").
enum CapabilityProbe {
  static let initializeID = "probe-init"
  static let statusID = "probe-mcp"
  /// How long a probe may take before it is let go, whatever it read.
  static let timeout: Duration = .seconds(20)
  /// After input closes, how long the CLI has to exit on its own before it is terminated.
  static let grace: Duration = .seconds(2)
  /// While a server is still connecting, `mcp_status` is asked again this often...
  static let statusInterval: Duration = .seconds(1)
  /// ...until this long after the probe started; a server still connecting then is shown so.
  static let connectingLimit: Duration = .seconds(10)

  /// What a new session in `folder` would load, under `account` when given (the one its
  /// lists are kept for), else under the account a new session there would take.
  /// Cancelling the calling task lets the process go as a finished probe does.
  static func run(
    folder: URL, account: ClaudeAccount? = nil, executableOverride: URL? = nil,
    timeout: Duration = timeout, grace: Duration = grace,
    connectingLimit: Duration = connectingLimit
  ) async -> ProbeOutcome {
    guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
      return .failed(
        String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
    }
    let environment = await AgentSession.environment.value
    // Cancelled while the environment loaded: nothing has started, so nothing is launched.
    // (Launching now would meet an already-closed input and need a hard kill.)
    guard !Task.isCancelled else { return .failed(String(localized: "Cancelled.")) }
    let launch = ClaudeLaunch.make(
      folder: folder, resuming: nil, account: account, environment: environment,
      executableOverride: executableOverride)
    guard let executable = launch.executable else { return .failed(ClaudeLaunch.notFound) }
    let process = AgentProcess(
      .init(
        executable: executable,
        arguments: ClaudeCommand(includesPartialMessages: false).arguments,
        environment: launch.environment, currentDirectory: folder))
    return await withTaskCancellationHandler {
      await collect(
        from: process, timeout: timeout, grace: grace, connectingLimit: connectingLimit)
    } onCancel: {
      release(process, after: grace)
    }
  }

  /// What the loop below wakes for: the process, or the next time to ask the status again.
  private enum Input {
    case event(AgentProcess.Event)
    case askAgain
  }

  private static func collect(
    from process: AgentProcess, timeout: Duration, grace: Duration, connectingLimit: Duration
  ) async -> ProbeOutcome {
    let events: AsyncStream<AgentProcess.Event>
    do {
      events = try process.start()
      try process.send(.initialize(requestID: initializeID))
      try process.send(.mcpStatus(requestID: statusID))
    } catch {
      release(process, after: grace)
      return .failed(error.localizedDescription)
    }
    let started = ContinuousClock.now
    let deadline = started + timeout
    let stopAsking = started + connectingLimit
    let timer = Task {
      try? await Task.sleep(for: timeout)
      if !Task.isCancelled { release(process, after: grace) }
    }
    // The process's events and the asks again, in one loop that keeps the replies.
    let (inputs, input) = AsyncStream.makeStream(of: Input.self)
    let pump = Task {
      for await event in events { input.yield(.event(event)) }
      input.finish()
    }
    var asking: Task<Void, Never>?
    defer {
      timer.cancel()
      pump.cancel()
      asking?.cancel()
    }
    var replies = CapabilityReplies(initializeID: initializeID, statusID: statusID)
    var released = false
    func letGo() {
      guard !released else { return }
      released = true
      asking?.cancel()
      release(process, after: grace)
    }
    var diagnostics = ""
    var status: Int32?
    for await next in inputs {
      switch next {
      case .event(.messages(let messages)):
        for case .controlResponse(let response) in messages { replies.take(response) }
        guard replies.isComplete, !released else { break }
        if !replies.hasPendingServers || ContinuousClock.now >= stopAsking {
          letGo()
        } else if asking == nil {
          // Every `statusInterval`, and once more at `stopAsking` to let the process go.
          asking = Task {
            while !Task.isCancelled {
              let wake = min(ContinuousClock.now + statusInterval, stopAsking)
              try? await Task.sleep(until: wake)
              input.yield(.askAgain)
              if wake == stopAsking { return }
            }
          }
        }
      case .askAgain:
        guard !released else { break }
        if ContinuousClock.now >= stopAsking {
          letGo()
        } else {
          try? process.send(.mcpStatus(requestID: replies.askStatusAgain()))
        }
      case .event(.stderr(let text)):
        diagnostics = String((diagnostics + text).suffix(4000))
      case .event(.exited(let code, _)):
        status = code
      }
    }
    let reason =
      if ContinuousClock.now >= deadline {
        String(localized: "Claude Code took too long to answer.")
      } else if let status, status != 0 {
        String(localized: "Claude Code exited with status \(status).")
      } else {
        String(localized: "Claude Code stopped before it answered.")
      }
    return outcome(replies, reason: reason, diagnostics: diagnostics)
  }

  /// Each pane's list, or why it has none: the CLI's error, a reply without the list, or
  /// no reply at all.
  static func outcome(_ replies: CapabilityReplies, reason: String, diagnostics: String)
    -> ProbeOutcome
  {
    var outcome = ProbeOutcome(capabilities: replies.capabilities, diagnostics: diagnostics)
    if replies.capabilities.skills == nil {
      outcome.skillsProblem =
        replies.hasInitialize
        ? replies.initializeError
          ?? String(localized: "This Claude Code version didn't list skills.")
        : String(localized: "Couldn't read skills. \(reason)")
    }
    if replies.capabilities.mcpServers == nil {
      outcome.serversProblem =
        replies.hasStatus
        ? replies.statusError
          ?? String(localized: "This Claude Code version didn't list MCP servers.")
        : String(localized: "Couldn't read MCP status. \(reason)")
    }
    return outcome
  }

  /// Input closed first, so the CLI exits on its own and takes its registry entry with it;
  /// terminated only if it is still there after `grace`. Safe to call more than once.
  nonisolated static func release(_ process: AgentProcess, after grace: Duration) {
    process.closeInput()
    Task.detached {
      try? await Task.sleep(for: grace)
      process.terminate()
    }
  }
}
