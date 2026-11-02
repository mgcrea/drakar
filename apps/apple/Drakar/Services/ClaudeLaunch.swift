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
  /// `checkpoints` false leaves file checkpointing as the environment has it: the probe is
  /// never prompted, and a process with checkpoints on leaves a `file-history/<id>/` folder
  /// behind even then.
  static func make(
    folder: URL, resuming: ResumeTarget?, account explicit: ClaudeAccount? = nil,
    environment: [String: String], executableOverride: URL?, checkpoints: Bool = true
  ) -> ClaudeLaunch {
    var environment = environment
    let chosen = explicit ?? resuming?.account ?? ClaudeChoice.account(forNewSessionIn: folder)
    if let chosen { environment = chosen.environment(environment) }
    if checkpoints { environment = keepingCheckpoints(environment) }
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

  /// A new session on a runner (remote sessions spec §4), from what the runner's relay stated
  /// alone: its GUI session's environment, the `claude` picked for the runner (`executable`)
  /// or else the first it found, and `account`, one of the runner's directories, or else the
  /// one its environment names. Nothing of this Mac's is read: not its environment, Settings'
  /// picks (`ClaudeChoice`) nor its disk (`ClaudeLocator`). No `claude` found there is none.
  static func make(
    onRunner facts: RunnerFacts, folder: URL, account explicit: ClaudeAccount?,
    executable: String?
  ) -> ClaudeLaunch {
    var environment = facts.environment
    if let explicit { environment = explicit.environment(environment) }
    environment = keepingCheckpoints(environment)
    let standard = URL(filePath: facts.home, directoryHint: .isDirectory)
      .appending(path: ".claude", directoryHint: .isDirectory)
    // The runner shell's own, as `make` takes this Mac's: `~/.claude` there unless its
    // environment names another.
    let shell =
      environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
      ?? standard
    let account =
      explicit
      ?? ClaudeAccount(
        directory: shell,
        isDefault: ProjectPath.normalize(shell) == ProjectPath.normalize(standard))
    let path = executable ?? facts.claude.first?.path
    return ClaudeLaunch(
      executable: path.map { URL(filePath: $0) }, environment: environment, account: account)
  }

  /// A prompt's files can be rewound only from checkpoints the process kept: on, unless the
  /// person switched them off, or set the switch on to a value of their own.
  private static func keepingCheckpoints(_ environment: [String: String]) -> [String: String] {
    guard environment["CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING"] == nil,
      environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == nil
    else { return environment }
    var environment = environment
    environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "true"
    return environment
  }
}
