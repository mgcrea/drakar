import Foundation

/// A Claude Code version, as `system/init` reports it (`2.1.288`) or `claude --version`
/// prints it (`2.1.288 (Claude Code)`).
public struct ClaudeVersion: Comparable, Sendable, CustomStringConvertible {
  public let components: [Int]

  /// The first word, read as dot-separated numbers; nil when it is not one.
  public init?(_ text: String) {
    guard let word = text.split(whereSeparator: \.isWhitespace).first else { return nil }
    let components = word.split(separator: ".", omittingEmptySubsequences: false).map {
      Int($0)
    }
    guard !components.isEmpty, components.allSatisfy({ $0 != nil }) else { return nil }
    self.components = components.compactMap(\.self)
  }

  public var description: String { components.map(String.init).joined(separator: ".") }

  public static func < (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    let left = lhs.components + Array(repeating: 0, count: count - lhs.components.count)
    let right = rhs.components + Array(repeating: 0, count: count - rhs.components.count)
    return left.lexicographicallyPrecedes(right)
  }

  public static func == (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
    !(lhs < rhs) && !(rhs < lhs)
  }

  /// The versions the fixtures and the documents in `docs/` were captured from. Raise the
  /// upper bound after capturing again on a newer one, not before.
  public static let tested = ClaudeVersion("2.1.284")!...ClaudeVersion("2.1.312")!

  public enum Drift: Sendable {
    /// Older than anything tested: it may lack what Drakar sends.
    case older
    /// Newer: it may say things Drakar does not show, or stop understanding what it sends.
    case newer
  }

  /// Nil inside the tested range.
  public var drift: Drift? {
    if self < Self.tested.lowerBound { return .older }
    if self > Self.tested.upperBound { return .newer }
    return nil
  }

  /// Runs `claude --version`; nil when it fails, prints something else, or has not
  /// answered within `timeout`. `environment` is the login shell's: an npm install is a
  /// script that needs `node` on the PATH.
  public static func read(
    of executable: URL, environment: [String: String], timeout: Duration = .seconds(5)
  ) async -> ClaudeVersion? {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--version"]
    process.environment = environment
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
    // Known hang, not fixed yet: in about 3 of 80 `make test` runs (2026-10-04),
    // `ClaudeVersionTests.asksTheBinary` sat here forever, `waitUntilExit` blocking a
    // thread of Swift's shared async pool, with the other process tests queued behind it.
    // Settings calls this too. The likely fix is to await the process's
    // `terminationHandler` instead of blocking.
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return ClaudeVersion(String(decoding: data, as: UTF8.self))
  }
}
