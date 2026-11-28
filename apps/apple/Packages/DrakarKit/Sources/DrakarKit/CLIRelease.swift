import Foundation

/// Where each agent CLI's newest version is published, and how its answer reads. Settings ›
/// Models compares it with the installed `--version`, then runs the CLI's own `update`,
/// which knows how it was installed (native, npm, Homebrew).
///
/// Each source is what the CLI's own updater reads, where one could be found, so "an update
/// is available" means its `update` will install one:
/// - Claude Code: `downloads.claude.ai/claude-code-releases/<channel>`, a bare version, the
///   channel being `autoUpdatesChannel` in the account's settings.json (`latest` unless set).
/// - Codex: npm's `latest` tag of `@openai/codex`. A Homebrew cask can lag it by hours, so
///   `codex update` may find nothing yet.
/// - Antigravity: its updater's front page, "… Stable Version: 1.5.19. …". `agy update` has
///   no check-only mode, and this page is the only place found that names the version.
/// - Grok: `grok update --check --json`, the CLI asking for itself.
public enum CLIRelease {
  public static func claudeURL(channel: String) -> URL {
    URL(string: "https://downloads.claude.ai/claude-code-releases/\(channel)")!
  }

  public static let codexURL = URL(string: "https://registry.npmjs.org/@openai/codex/latest")!

  public static let agyURL = URL(
    string: "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app")!

  /// Grok's check without installing; the others have none.
  public static let grokCheckArguments = ["update", "--check", "--json"]

  /// Every one of the four installs through `<cli> update`.
  public static let updateArguments = ["update"]

  /// `autoUpdatesChannel` from a Claude Code settings.json: `stable` or `latest`, `latest`
  /// when unset, unreadable or something else.
  public static func claudeChannel(settings: Data?) -> String {
    guard let settings, let json = try? JSONValue.parse(settings),
      json["autoUpdatesChannel"]?.stringValue == "stable"
    else { return "latest" }
    return "stable"
  }

  public static func claudeLatest(_ data: Data) -> CLIVersion? {
    CLIVersion(String(decoding: data, as: UTF8.self))
  }

  public static func codexLatest(_ data: Data) -> CLIVersion? {
    (try? JSONValue.parse(data))?["version"]?.stringValue.flatMap(CLIVersion.init(versionOutput:))
  }

  public static func agyLatest(_ data: Data) -> CLIVersion? {
    let page = String(decoding: data, as: UTF8.self)
    guard let match = page.firstMatch(of: /Stable Version:\s*([0-9][0-9.]*[0-9])/) else {
      return nil
    }
    return CLIVersion(String(match.1))
  }

  public static func grokLatest(_ data: Data) -> CLIVersion? {
    // The JSON is the last line: a warning may come before it.
    let line = String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline).last { $0.hasPrefix("{") }
    return line.flatMap { try? JSONValue.parse(Data($0.utf8)) }?["latestVersion"]?.stringValue
      .flatMap(CLIVersion.init(versionOutput:))
  }

  /// The line of an `update` run worth showing: its last non-empty one, from standard error
  /// when the run failed and wrote there, without terminal colours.
  public static func summary(of output: ProcessRunner.Output) -> String? {
    let failed = output.timedOut || output.status != 0
    let sources = failed ? [output.errors, output.output] : [output.output, output.errors]
    for data in sources {
      let text = String(decoding: data, as: UTF8.self)
        .replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
      if let line = text.split(whereSeparator: \.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty })
      {
        return line
      }
    }
    return nil
  }
}
