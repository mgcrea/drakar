import DrakarKit
import Foundation

/// How `agy acp` starts for a session or a short-lived probe: the binary on the login shell's
/// PATH, else `~/.local/bin` and Homebrew's places.
enum AgyLaunch {
  static var notFound: String {
    String(
      localized:
        "Antigravity (agy) was not found. Install the Antigravity CLI (`agy`), then send again.")
  }

  static func locate(
    path: String?, binary: String = "agy",
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
  ) -> URL? {
    var extra = [
      home.appending(path: ".local/bin").path(percentEncoded: false),
      "/opt/homebrew/bin",
      "/usr/local/bin",
    ]
    if binary == "grok" {
      extra.insert(home.appending(path: ".grok/bin").path(percentEncoded: false), at: 1)
    }
    let folders = (path ?? "").split(separator: ":").map(String.init) + extra
    return folders.lazy.map { URL(filePath: $0).appending(path: binary) }.first(where: isExecutable)
  }

  static func configuration(
    executable: URL, environment: [String: String], folder: URL, agent: AgentKind = .agy
  )
    -> AgentProcess.Configuration
  {
    .init(
      executable: executable, arguments: agent == .grok ? ["agent", "stdio"] : ["acp"],
      environment: environment,
      currentDirectory: folder)
  }

  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }
}
