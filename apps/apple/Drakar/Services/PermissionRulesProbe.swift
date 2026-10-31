import DrakarKit
import Foundation

/// A `claude` started in a project's folder only to be asked its permission rules, then let
/// go, as `CapabilityProbe` does for skills and servers: for the Permissions tab when no
/// session's process is there to ask.
enum PermissionRulesProbe {
  static let initializeID = "rules-probe-init"
  static let listID = "rules-probe-list"

  /// The rules a new session in `folder` would run with, under `account` when given, else
  /// under the account a new session there would take. Cancelling the calling task lets the
  /// process go as a finished probe does.
  static func run(
    folder: URL, account: ClaudeAccount?, executableOverride: URL?,
    timeout: Duration = .seconds(20)
  ) async -> PermissionRulesAnswer {
    guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
      return .refused(
        String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
    }
    let environment = await AgentSession.environment.value
    // Cancelled while the environment loaded: nothing is launched, as in `CapabilityProbe`.
    guard !Task.isCancelled else { return .refused(String(localized: "Cancelled.")) }
    let launch = CapabilityProbe.launch(
      folder: folder, account: account, environment: environment,
      executableOverride: executableOverride)
    guard let executable = launch.executable else { return .refused(ClaudeLaunch.notFound) }
    let process = AgentProcess(
      .init(
        executable: executable,
        arguments: ClaudeCommand(includesPartialMessages: false).arguments,
        environment: launch.environment, currentDirectory: folder))
    let grace = CapabilityProbe.grace
    return await withTaskCancellationHandler {
      await collect(from: process, timeout: timeout, grace: grace)
    } onCancel: {
      CapabilityProbe.release(process, after: grace)
    }
  }

  private static func collect(
    from process: AgentProcess, timeout: Duration, grace: Duration
  ) async -> PermissionRulesAnswer {
    let events: AsyncStream<AgentProcess.Event>
    do {
      events = try process.start()
      try process.send(.initialize(requestID: initializeID))
      try process.send(.listPermissionRules(requestID: listID))
    } catch {
      CapabilityProbe.release(process, after: grace)
      return .refused(error.localizedDescription)
    }
    // Whether the timeout let the process go, rather than the time the loop below saw: a
    // busy main actor can read an exit late, and that exit still says why.
    let expiry = Expiry()
    let timer = Task {
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      expiry.hasPassed = true
      CapabilityProbe.release(process, after: grace)
    }
    defer { timer.cancel() }
    var answer: PermissionRulesAnswer?
    var status: Int32?
    // Read to the stream's end, the process's own once its input closes, so that it is gone
    // when the answer is given.
    for await event in events {
      switch event {
      case .lines(let lines, _):
        for case .controlResponse(let response) in lines.map(StreamMessage.init)
        where response.requestID == listID && answer == nil {
          answer = PermissionRulesAnswer(response)
          CapabilityProbe.release(process, after: grace)
        }
      case .stderr:
        break
      case .exited(let code, _):
        status = code
      }
    }
    if let answer { return answer }
    let reason =
      if expiry.hasPassed {
        String(localized: "Claude Code took too long to answer.")
      } else if let status, status != 0 {
        String(localized: "Claude Code exited with status \(status).")
      } else {
        String(localized: "Claude Code stopped before it answered.")
      }
    return .refused(reason)
  }

  private final class Expiry {
    var hasPassed = false
  }
}
