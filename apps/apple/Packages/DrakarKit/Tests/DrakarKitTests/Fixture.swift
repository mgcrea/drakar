import DrakarKit
import Foundation
import Testing

/// A capture from the real CLI, trimmed (docs/claude-stream-json.md, "Raw captures").
///
/// The captures were made while the app was still called Amiral, so the prompts, the
/// commands and the model's replies say `amiral` (`echo amiral`, `amiral-probe.txt`,
/// "Amiral."), and so do the tests that quote them. That is what the CLI wrote; renaming
/// it would make the fixtures a fiction. Leave it.
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
  /// A transcript file as Claude Code 2.1.288 wrote it for a session Drakar ran (`touch
  /// ahoy.txt`, then "done"), cut to its user, assistant and title entries.
  case historyWithTool = "history-with-tool"
  /// What an interactive claude 2.1.288 sent a spike editor over the IDE bridge while
  /// editing one file (docs/claude-ide-bridge.md), the editor's path and pids scrubbed.
  case ideRequests = "ide-requests"
  /// A `haiku` turn under `--include-partial-messages` (2026-10-04, Task 0 of the project
  /// windows plan): init, an assistant line with usage, the result, and the replies to
  /// `get_context_usage` sent mid-turn and between turns.
  case contextUsage = "context-usage"
  /// A hundred closing texts of real turns (Task 0 of the session-questions plan, 2026-10-04),
  /// trimmed to their last three paragraphs and scrubbed, each labelled `question`, `offer`
  /// or null with the sentence a row should show. Lines are `{"text", "kind", "shows"}`,
  /// not stream messages.
  case closingEndings = "closing-endings"
  /// What a `claude` with no prompt answers to `initialize` and `mcp_status` (2.1.288,
  /// 2026-10-04, the skills inspector's spike): a few commands, the CLI's own among them,
  /// and servers in every status seen. Trimmed, and every header, env value and URL token
  /// replaced by `drakar-fixture-secret`, the `initialize` reply's account dropped.
  case capabilities = "capabilities"
  /// A `claude` with no prompt (2.1.288, 2026-10-06, the mode and model spike): the
  /// `initialize` reply cut to its `models` and `current_permission_mode`, then the replies to
  /// `set_model` (`r2`) and `set_permission_mode` (`r3` acceptEdits, `r4` bypassPermissions
  /// refused, `r5` auto, `r6` plan) with the `status` lines that followed. Ids zeroed.
  case modeAndModel = "mode-and-model"

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
