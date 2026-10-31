import DrakarKit
import Foundation

/// A rule added or removed as the VS Code extension does it: `claude edit-permission-rules
/// --json` in the project's folder, the edit on its stdin, outside any session's stream. A
/// running session sees the settings file change by itself.
enum PermissionRuleEditor {
  /// Runs the edit with the executable and account environment a new session in `folder`
  /// would have, less `CLAUDE_CODE_CHILD_SESSION`: with it the command refuses, as if started
  /// from an editor inside a Claude Code session, which Drakar run from one would be.
  /// `environment` stands in for the login shell's in tests.
  static func apply(
    _ edit: PermissionRuleEdit, folder: URL, account: ClaudeAccount?, executableOverride: URL?,
    timeout: Duration = .seconds(30), environment: [String: String]? = nil
  ) async -> PermissionRuleEditOutcome {
    guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
      return .refused(
        String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
    }
    let base: [String: String] =
      if let environment { environment } else { await AgentSession.environment.value }
    let launch = ClaudeLaunch.make(
      folder: folder, resuming: nil, account: account, environment: base,
      executableOverride: executableOverride, checkpoints: false)
    // An override is taken as given, so it is checked here, as the locator checks the others.
    guard let executable = launch.executable,
      FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false))
    else { return .refused(ClaudeLaunch.notFound) }
    var commandEnvironment = launch.environment
    commandEnvironment["CLAUDE_CODE_CHILD_SESSION"] = nil
    do {
      let result = try await ProcessRunner.run(
        executable, PermissionRuleEdit.arguments, environment: commandEnvironment,
        input: try edit.json.line(), currentDirectory: folder, timeout: timeout)
      if result.timedOut {
        return .refused(String(localized: "Claude Code took too long to save the rule."))
      }
      return .read(
        status: result.status, output: String(decoding: result.output, as: UTF8.self),
        errors: String(decoding: result.errors, as: UTF8.self))
    } catch {
      return .refused(error.localizedDescription)
    }
  }
}
