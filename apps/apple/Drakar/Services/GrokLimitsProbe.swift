import DrakarKit
import Foundation

/// Asking Grok Build (`grok`) for the account's live allowance and subscription tier.
///
/// Grok writes no plan limits to disk. Its TUI's `/usage` fetches them, and the same code
/// answers the Agent Client Protocol extension method `x.ai/billing` (sent on the wire as
/// `_x.ai/billing`) over `grok agent stdio`. Running the user's own `grok` creates no session
/// directory and no `active_sessions.json` entry, sends no prompt, and avoids touching
/// `auth.json`.
nonisolated enum GrokLimitsProbe {
  static let timeout: Duration = .seconds(15)

  /// `$GROK_HOME` when set and non-empty, else `~/.grok`.
  static func resolveHome(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let custom = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !custom.isEmpty
    {
      return URL(
        filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }
    return home.appending(path: ".grok", directoryHint: .isDirectory)
  }

  /// True once `directory` holds xAI Grok Build's markers (`version.json` or `config.toml`,
  /// and `sessions/`), so Macs that have never run Grok Build (or only run the unrelated
  /// community `grok-cli`, which keeps `~/.grok/user-settings.json`) skip probing.
  static func isHomePresent(at directory: URL) -> Bool {
    let fileManager = FileManager.default
    func exists(_ name: String) -> Bool {
      fileManager.fileExists(atPath: directory.appending(path: name).path(percentEncoded: false))
    }
    return (exists("version.json") || exists("config.toml")) && exists("sessions")
  }

  /// Probes `executable` via `grok agent stdio` (`initialize` followed by `_x.ai/billing`)
  /// and returns the decoded allowance, or nil on timeout, cancellation, or error.
  static func limits(
    executable: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    directory: URL = FileManager.default.homeDirectoryForCurrentUser,
    timeout: Duration = timeout
  ) async -> GrokUsage? {
    guard !Task.isCancelled else { return nil }
    let configuration = AgentProcess.Configuration(
      executable: executable,
      arguments: ["agent", "stdio"],
      environment: environment,
      currentDirectory: directory)
    let output = try? await AgyOneShot(configuration: configuration, timeout: timeout).run {
      previous in
      if previous == nil {
        return ("_x.ai/billing", .object([:]))
      }
      return nil
    }
    guard !Task.isCancelled, let result = output?.results.first else { return nil }
    return GrokUsage(billingResult: result, at: .now)
  }
}
