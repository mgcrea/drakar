import Foundation

/// An agent CLI's version: as Claude Code's `system/init` reports it (`2.1.288`), or as a
/// `--version` prints it (`2.1.288 (Claude Code)`, `codex-cli 0.172.0`, `1.5.19`,
/// `grok 1.0.92 (b06756fd6256) [stable]`).
public struct CLIVersion: Comparable, Sendable, CustomStringConvertible {
  public let components: [Int]

  /// The first word, read as dot-separated numbers; nil when it is not one.
  public init?(_ text: String) {
    guard let word = text.split(whereSeparator: \.isWhitespace).first else { return nil }
    self.init(word: word)
  }

  /// The first word of a `--version` line that is a version, its pre-release suffix
  /// (`-alpha.2`) dropped: a name before it (`codex-cli`, `grok`) and anything after it are
  /// skipped. A lone number is not taken, so a build count is never read as a version.
  public init?(versionOutput text: String) {
    for word in text.split(whereSeparator: \.isWhitespace) {
      let core = word.prefix { $0 != "-" && $0 != "+" }
      if core.contains("."), let version = CLIVersion(word: core) {
        self = version
        return
      }
    }
    return nil
  }

  private init?(word: Substring) {
    let components = word.split(separator: ".", omittingEmptySubsequences: false).map {
      Int($0)
    }
    guard !components.isEmpty, components.allSatisfy({ $0 != nil }) else { return nil }
    self.components = components.compactMap(\.self)
  }

  public var description: String { components.map(String.init).joined(separator: ".") }

  /// Missing trailing components count as zero: 2.1 is 2.1.0.
  public static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
    for index in 0..<max(lhs.components.count, rhs.components.count) {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  public static func == (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
    !(lhs < rhs) && !(rhs < lhs)
  }

  /// Runs `<executable> --version`; nil when it fails, prints no version, or has not
  /// answered within `timeout`. `environment` is the login shell's: an npm install is a
  /// script that needs `node` on the PATH.
  public static func read(
    of executable: URL, environment: [String: String], timeout: Duration = .seconds(5)
  ) async -> CLIVersion? {
    guard
      let result = try? await ProcessRunner.run(
        executable, ["--version"], environment: environment, readsErrors: false,
        timeout: timeout),
      !result.timedOut, result.status == 0
    else { return nil }
    return CLIVersion(versionOutput: String(decoding: result.output, as: UTF8.self))
  }
}
