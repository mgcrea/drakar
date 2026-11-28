import DrakarKit
import Foundation
import Observation

/// Each agent CLI's installed version against the newest its vendor publishes, and the CLI's
/// own `update` run from Settings › Models. Held for the app's life, so reopening Settings
/// within `freshness` does not ask the network again.
///
/// Keyed by executable: two Claude Code installs (native and npm) are two statuses. An update
/// replaces the binary on disk, so a session already running keeps the version it started
/// with, and the next one starts on the new one.
@Observable
final class CLIUpdates {
  static let shared = CLIUpdates()

  struct Status {
    /// What `--version` printed; nil before it answered, or when it printed none.
    var installed: CLIVersion?
    /// The newest published; nil before the check answered, or when it failed.
    var latest: CLIVersion?
    var hasRead = false
    /// The newest could not be learned: offline, or the source changed shape.
    var checkFailed = false
    var isChecking = false
    var isUpdating = false
    /// Why the last update did not land: its last line, or what was seen after it.
    var message: String?
    var checkedAt: Date?

    var isUpdateAvailable: Bool {
      guard let installed, let latest else { return false }
      return latest > installed
    }
  }

  /// How long a check stands before opening Settings again checks again.
  static let freshness: TimeInterval = 15 * 60
  static let updateLimit: Duration = .seconds(300)

  private(set) var statuses: [String: Status] = [:]

  func status(of executable: URL) -> Status {
    statuses[executable.path(percentEncoded: false)] ?? Status()
  }

  /// Reads the installed version and asks for the newest, unless a check is under way, an
  /// update runs, or the last check is younger than `freshness` (`force` skips that last).
  /// `claudeDirectory` is the account whose settings.json names Claude Code's channel; nil
  /// is the shell's.
  func check(agent: AgentKind, executable: URL, claudeDirectory: URL? = nil, force: Bool = false) {
    let key = executable.path(percentEncoded: false)
    var status = statuses[key] ?? Status()
    guard !status.isChecking, !status.isUpdating else { return }
    if !force, let checkedAt = status.checkedAt,
      Date.now.timeIntervalSince(checkedAt) < Self.freshness
    {
      return
    }
    status.isChecking = true
    if force { status.message = nil }
    statuses[key] = status
    Task {
      let environment = await AgentSession.environment.value
      async let installed = CLIVersion.read(
        of: executable, environment: environment, timeout: .seconds(10))
      async let latest = Self.latest(
        agent: agent, executable: executable, environment: environment,
        claudeDirectory: claudeDirectory)
      let (installedVersion, latestVersion) = await (installed, latest)
      var status = statuses[key] ?? Status()
      status.installed = installedVersion
      status.latest = latestVersion
      status.hasRead = true
      status.checkFailed = latestVersion == nil
      status.isChecking = false
      status.checkedAt = .now
      statuses[key] = status
    }
  }

  /// Runs `<cli> update`, then reads the version again. `claudeDirectory`, when set, is the
  /// account Claude Code updates under, for its channel.
  func update(agent: AgentKind, executable: URL, claudeDirectory: URL? = nil) {
    let key = executable.path(percentEncoded: false)
    var status = statuses[key] ?? Status()
    guard !status.isUpdating else { return }
    let before = status.installed
    status.isUpdating = true
    status.message = nil
    statuses[key] = status
    Task {
      var environment = await AgentSession.environment.value
      if let claudeDirectory {
        environment["CLAUDE_CONFIG_DIR"] = claudeDirectory.path(percentEncoded: false)
      }
      let command =
        "\(executable.lastPathComponent) \(CLIRelease.updateArguments.joined(separator: " "))"
      let output: ProcessRunner.Output?
      do {
        output = try await ProcessRunner.run(
          executable, CLIRelease.updateArguments, environment: environment,
          timeout: Self.updateLimit)
      } catch {
        output = nil
      }
      let after = await CLIVersion.read(
        of: executable, environment: environment, timeout: .seconds(10))
      var status = statuses[key] ?? Status()
      status.isUpdating = false
      status.installed = after
      status.hasRead = true
      status.message = Self.message(
        command: command, output: output, before: before, after: after, latest: status.latest)
      statuses[key] = status
    }
  }

  /// Nil when the update landed. With no newest known and the version unmoved, the run's own
  /// last line, such as Antigravity's "You are already on the latest version."
  private static func message(
    command: String, output: ProcessRunner.Output?, before: CLIVersion?, after: CLIVersion?,
    latest: CLIVersion?
  ) -> String? {
    guard let output else { return String(localized: "`\(command)` could not start.") }
    let summary = CLIRelease.summary(of: output)
    if output.timedOut {
      return String(localized: "`\(command)` did not finish within 5 minutes and was stopped.")
    }
    if output.status != 0 {
      return summary.map { String(localized: "`\(command)` failed: \($0)") }
        ?? String(localized: "`\(command)` failed with status \(output.status).")
    }
    if let latest, let after, after < latest {
      let still = String(localized: "Still \(after.description) after `\(command)`.")
      return summary.map { "\(still) \($0)" } ?? still
    }
    if latest == nil, let before, let after, after == before, let summary {
      return summary
    }
    return nil
  }

  private static func latest(
    agent: AgentKind, executable: URL, environment: [String: String], claudeDirectory: URL?
  ) async -> CLIVersion? {
    switch agent {
    case .claude:
      let directory =
        claudeDirectory
        ?? environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
      let settings = try? Data(contentsOf: directory.appending(path: "settings.json"))
      let channel = CLIRelease.claudeChannel(settings: settings)
      return await fetch(CLIRelease.claudeURL(channel: channel)).flatMap(CLIRelease.claudeLatest)
    case .codex:
      return await fetch(CLIRelease.codexURL).flatMap(CLIRelease.codexLatest)
    case .agy:
      return await fetch(CLIRelease.agyURL).flatMap(CLIRelease.agyLatest)
    case .grok:
      guard
        let result = try? await ProcessRunner.run(
          executable, CLIRelease.grokCheckArguments, environment: environment,
          readsErrors: false, timeout: .seconds(30)),
        !result.timedOut, result.status == 0
      else { return nil }
      return CLIRelease.grokLatest(result.output)
    }
  }

  private static func fetch(_ url: URL) async -> Data? {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 15
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return data
  }
}
