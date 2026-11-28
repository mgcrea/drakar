import Foundation

/// A Claude Code version, as `system/init` reports it (`2.1.288`) or `claude --version`
/// prints it (`2.1.288 (Claude Code)`).
public struct ClaudeVersion: Equatable, Sendable, CustomStringConvertible {
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

  /// Runs `claude --version`; nil when it fails, prints something else, or has not
  /// answered within `timeout`. `environment` is the login shell's: an npm install is a
  /// script that needs `node` on the PATH.
  public static func read(
    of executable: URL, environment: [String: String], timeout: Duration = .seconds(5)
  ) async -> ClaudeVersion? {
    guard
      let result = try? await ProcessRunner.run(
        executable, ["--version"], environment: environment, readsErrors: false,
        timeout: timeout),
      !result.timedOut, result.status == 0
    else { return nil }
    return ClaudeVersion(String(decoding: result.output, as: UTF8.self))
  }
}
