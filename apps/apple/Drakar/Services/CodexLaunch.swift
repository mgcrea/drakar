import DrakarKit
import Foundation

/// How a `codex app-server` starts for a session or a short-lived read: the binary from the
/// login shell's PATH, else Homebrew's places; the environment as it is, so a `CODEX_HOME`
/// in it still picks the account until Codex accounts (slice 4).
enum CodexLaunch {
  static var notFound: String {
    String(
      localized:
        "Codex was not found. Install it with `brew install --cask codex`, then send again.")
  }

  static func locate(
    path: String?,
    isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
  ) -> URL? {
    let folders =
      (path ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    return folders.lazy.map { URL(filePath: $0).appending(path: "codex") }.first(
      where: isExecutable)
  }

  static func configuration(executable: URL, environment: [String: String], folder: URL)
    -> AgentProcess.Configuration
  {
    .init(
      executable: executable, arguments: ["app-server"], environment: environment,
      currentDirectory: folder)
  }

  /// What `initialize` says Drakar is.
  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }
}
