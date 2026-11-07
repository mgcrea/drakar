/// The core package: Claude Code's stream-json protocol and the transcript folded out of
/// it. Everything that can be argued about in a unit test lives here, tested against
/// output captured from the real CLI (`docs/claude-stream-json.md`), never against output
/// written by hand.
public enum DrakarKit {
  public static let appName = "Drakar"

  /// The Claude Code version the test fixtures were captured from. The decoder is lenient
  /// toward any version; this is what it has actually been checked against.
  public static let capturedClaudeCodeVersion = "2.1.284"

  /// The module's `JSONValue`, by the name `DrakarKit.JSONValue`.
  ///
  /// A file that also imports MCPKit, which has a `JSONValue` of its own, has to qualify the
  /// name, and `DrakarKit.` there finds this enum before it finds the module. Without this
  /// alias the qualified name does not compile.
  public typealias JSONValue = _ModuleJSONValue
}

/// What `DrakarKit.JSONValue` is spelled through, and nothing else: an alias inside the enum
/// cannot name the module's type directly without naming itself.
public typealias _ModuleJSONValue = JSONValue
