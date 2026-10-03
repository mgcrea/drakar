import Foundation

/// The command line Drakar starts `claude` with: the arguments the VS Code extension passes
/// to its bundled binary (`docs/claude-stream-json.md`, "Spawning").
public struct ClaudeCommand: Sendable, Equatable {
  /// Continue an existing session instead of starting one.
  public var resumeSessionID: String?
  /// A model id or alias; nil leaves the user's configured default.
  public var model: String?
  /// `default`, `acceptEdits`, `plan` or `bypassPermissions`; nil leaves the default.
  public var permissionMode: String?
  /// Stream text as it is written rather than block by block.
  public var includesPartialMessages = true
  /// `summarized` makes thinking arrive as text; without it the CLI sends thinking blocks
  /// with the text withheld (checked against 2.1.288). The extension passes `summarized`.
  public var thinkingDisplay: String? = "summarized"
  /// With `resumeSessionID`: continue a copy under a new id, leaving the original to
  /// whoever has it open.
  public var forksSession = false
  /// Appended as given, after everything else.
  public var extraArguments: [String] = []

  public init(
    resumeSessionID: String? = nil, model: String? = nil, permissionMode: String? = nil,
    includesPartialMessages: Bool = true, extraArguments: [String] = []
  ) {
    self.resumeSessionID = resumeSessionID
    self.model = model
    self.permissionMode = permissionMode
    self.includesPartialMessages = includesPartialMessages
    self.extraArguments = extraArguments
  }

  public var arguments: [String] {
    // `--verbose` is required with stream-json output; `--permission-prompt-tool stdio`
    // turns permission prompts into `can_use_tool` requests Drakar answers.
    var arguments = [
      "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
      "--permission-prompt-tool", "stdio",
    ]
    if includesPartialMessages { arguments.append("--include-partial-messages") }
    if let thinkingDisplay { arguments += ["--thinking-display", thinkingDisplay] }
    if let model { arguments += ["--model", model] }
    if let permissionMode { arguments += ["--permission-mode", permissionMode] }
    // One argument, `--resume=<id>`, as the extension passes it, so an id can never be
    // read as a flag.
    if let resumeSessionID {
      arguments.append("--resume=\(resumeSessionID)")
      if forksSession { arguments.append("--fork-session") }
    }
    return arguments + extraArguments
  }
}
