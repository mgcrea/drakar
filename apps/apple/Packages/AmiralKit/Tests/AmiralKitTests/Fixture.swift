import AmiralKit
import Foundation
import Testing

/// A capture from the real CLI, trimmed (docs/claude-stream-json.md, "Raw captures").
enum Fixture: String {
  /// `echo amiral` through Bash, under `--include-partial-messages`: two assistant
  /// messages, a tool call with its result, the streamed text "Amiral.".
  case turnWithTool = "turn-with-tool"
  /// `touch amiral-probe.txt`, without partial messages: a `can_use_tool` request that
  /// was answered `allow`, then the tool ran.
  case permissionRequest = "permission-request"
  /// A story interrupted after its first words, then a second turn ("ready") on the same
  /// process: the interrupt's acknowledgement, the CLI's `[Request interrupted by user]`
  /// note, and a result that is an error by its fields and an interrupt by its reason.
  case interruptThenTurn = "interrupt-then-turn"

  var lines: [Data] {
    get throws {
      let url = try #require(
        Bundle.module.url(forResource: rawValue, withExtension: "jsonl", subdirectory: "Fixtures"))
      var buffer = LineBuffer()
      return buffer.append(try Data(contentsOf: url))
    }
  }

  var messages: [StreamMessage] {
    get throws { try lines.map { try StreamMessage(line: $0) } }
  }
}
