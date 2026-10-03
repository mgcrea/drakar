import Foundation

/// Finds the `claude` to run.
///
/// An app opened from the Finder gets launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), not
/// the shell's, so `claude` is found by looking: the user's shell PATH first (from
/// `ShellEnvironment`), then the places the installers write to. The first executable wins,
/// which is what the shell would run.
public enum ClaudeLocator {
  /// Install locations, in the order the shell most likely has them: the native installer,
  /// the old per-user npm install, Homebrew on Apple silicon and Intel, then global npm
  /// and bun prefixes.
  public static func knownLocations(home: URL) -> [URL] {
    [
      home.appending(path: ".local/bin/claude"),
      home.appending(path: ".claude/local/claude"),
      URL(filePath: "/opt/homebrew/bin/claude"),
      URL(filePath: "/usr/local/bin/claude"),
      home.appending(path: ".npm-global/bin/claude"),
      home.appending(path: ".bun/bin/claude"),
    ]
  }

  /// Every place worth trying, PATH first, without duplicates.
  public static func candidates(home: URL, path: String?) -> [URL] {
    let fromPath = (path ?? "").split(separator: ":").map {
      URL(filePath: String($0)).appending(path: "claude")
    }
    var seen = Set<String>()
    return (fromPath + knownLocations(home: home)).filter {
      seen.insert($0.standardizedFileURL.path).inserted
    }
  }

  public static func locate(
    home: URL = FileManager.default.homeDirectoryForCurrentUser, path: String?,
    isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
  ) -> URL? {
    candidates(home: home, path: path).first(where: isExecutable)
  }
}

/// The user's login shell environment, which is what a terminal `claude` would inherit.
///
/// Read once by running the shell interactively as a login shell, the way editors launched
/// from the Finder do, because PATH additions live in `.zprofile` *and* `.zshrc`. An
/// interactive shell may print a banner, so the environment follows a marker and is
/// NUL-separated, which no value can contain.
public enum ShellEnvironment {
  static let marker = "__DRAKAR_ENV__"

  /// Runs the shell; nil if it fails or takes longer than `timeout`, in which case the
  /// caller falls back to its own environment.
  public static func read(
    shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
    timeout: Duration = .seconds(5)
  ) async -> [String: String]? {
    let process = Process()
    process.executableURL = URL(filePath: shell)
    process.arguments = ["-l", "-i", "-c", "printf '\(marker)'; /usr/bin/env -0"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }

    let watchdog = Task {
      try await Task.sleep(for: timeout)
      if process.isRunning { process.terminate() }
    }
    defer { watchdog.cancel() }
    let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return parse(data)
  }

  /// The variables after the marker. Exposed for tests.
  public static func parse(_ data: Data) -> [String: String]? {
    guard let range = data.range(of: Data(marker.utf8)) else { return nil }
    var environment: [String: String] = [:]
    for entry in data[range.upperBound...].split(separator: 0) {
      let text = String(decoding: entry, as: UTF8.self)
      guard let equals = text.firstIndex(of: "=") else { continue }
      environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
    }
    return environment.isEmpty ? nil : environment
  }
}
