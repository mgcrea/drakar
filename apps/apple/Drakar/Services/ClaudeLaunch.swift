import DrakarKit
import Foundation

/// What a `claude` started for a folder runs: the binary, the environment and the account,
/// as Settings and the folder's pick choose them. Sessions and the capability probe both
/// start from here, so the probe sees what a new session would.
struct ClaudeLaunch {
  /// Nil when no `claude` was found.
  var executable: URL?
  var environment: [String: String]
  /// The account it runs under, picked or the shell's.
  var account: ClaudeAccount?

  static var notFound: String {
    String(localized: "Claude Code was not found. Install it, then open the folder again.")
  }

  /// `environment` is the login shell's (`AgentSession.environment`). A resume runs under
  /// the account that wrote it; a new session under its folder's pick, else the one in
  /// Settings, else the shell's. An explicit `account` wins over all of them: the probe runs
  /// under the account its lists are kept for, and a new session under the one picked for it.
  static func make(
    folder: URL, resuming: ResumeTarget?, account explicit: ClaudeAccount? = nil,
    environment: [String: String], executableOverride: URL?
  ) -> ClaudeLaunch {
    var environment = environment
    let chosen = explicit ?? resuming?.account ?? ClaudeChoice.account(forNewSessionIn: folder)
    if let chosen { environment = chosen.environment(environment) }
    // A prompt's files can be rewound only from checkpoints the process kept: on, unless the
    // person switched them off themselves.
    if environment["CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING"] == nil {
      environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "true"
    }
    let account =
      chosen
      ?? ClaudeChoice.account(
        at: environment["CLAUDE_CONFIG_DIR"]
          ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
          .path(percentEncoded: false))
    let executable =
      executableOverride
      ?? ClaudeLocator.locate(preferred: ClaudeChoice.executable, path: environment["PATH"])
    return ClaudeLaunch(executable: executable, environment: environment, account: account)
  }
}
