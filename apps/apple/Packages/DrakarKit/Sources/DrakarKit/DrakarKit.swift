/// The core package: Claude Code's stream-json protocol and the transcript folded out of
/// it. Everything that can be argued about in a unit test lives here, tested against
/// output captured from the real CLI (`docs/claude-stream-json.md`), never against output
/// written by hand.
public enum DrakarKit {
  public static let appName = "Drakar"

  /// The Claude Code version the test fixtures were captured from. The decoder is lenient
  /// toward any version; this is what it has actually been checked against.
  public static let capturedClaudeCodeVersion = "2.1.284"
}
