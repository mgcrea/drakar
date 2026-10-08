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
  /// A `haiku` turn in acceptEdits (2.1.288, 2026-10-06): a foreground `Agent` whose
  /// subagent ran one Bash, with its `task_*` lines and the lines the CLI forwards from inside
  /// it (its prompt, its tool call and result, `parent_tool_use_id` set), then a `TodoWrite`
  /// of two items. Hooks, stream events, thinking, `init` and `status` dropped; paths scrubbed.
  case subagentAndTodos = "subagent-and-todos"
  /// A turn in plan mode (2.1.288, 2026-10-06) ending on `ExitPlanMode`'s `can_use_tool`
  /// (`plan`, `planFilePath`), answered `deny` with `interrupt: true`: the CLI's own
  /// rejection, `[Request interrupted by user]`, and an interrupted result. Trimmed the same way.
  case planRequest = "plan-request"
  /// A text-only `haiku` turn (2.1.288, 2026-10-06, no `--replay-user-messages`) during which
  /// "banana" (`bbbbbbbb-…`) and "cherry" (`cccccccc-…`) were sent, cherry then cancelled with
  /// `cancel_async_message`: the `command_lifecycle` lines, the first turn's result, then
  /// banana's own turn. Trimmed as the others.
  case queuedPrompts = "queued-prompts"
  /// The transcript line Claude Code 2.1.288 wrote for a prompt sent with a 64×64 red PNG
  /// and a text document `notes.txt` (2026-10-06): blocks kept as sent, keys trimmed.
  case historyWithAttachments = "history-with-attachments"
  /// A Codex turn (codex-cli 0.160.1, 2026-10-06, docs/codex-app-server.md): reasoning, a
  /// file created after an approval, a command declined, the answer streamed, usage with the
  /// window, the end. Server lines only; ids shortened, paths and account scrubbed. Not
  /// stream-json: read with `CodexTranslator`.
  case codexTurn = "codex-turn"
  /// One `apply_patch` (codex-cli 0.160.1, 2026-10-07): `a.txt` updated, `b.txt` deleted,
  /// `c.txt` renamed to `d.txt`, after an approval answered `accept`. Hand-trimmed from a
  /// capture, ids and paths placeholders.
  case codexFileChanges = "codex-file-changes"
  /// A turn running `sleep 6` with a prompt steered into it (2026-10-07): each `userMessage`
  /// carries the `clientUserMessageId` it was sent with, `prompt-1` and `prompt-2`.
  case codexSteer = "codex-steer"

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

  /// One `thread/items/list` page (2026-10-07): a prompt, a commentary, a declined file
  /// change, the answer. JSON, not lines.
  static var codexItemsPage: JSONValue {
    get throws {
      let url = try #require(
        Bundle.module.url(
          forResource: "codex-items-page", withExtension: "json", subdirectory: "Fixtures"))
      return try JSONValue.parse(Data(contentsOf: url))
    }
  }

  /// A `skills/list` result for one folder, hand-made in the shape codex-cli 0.160.1 answers
  /// (2026-10-08): a repo skill with an `interface`, a user skill shadowing a system one of
  /// the same name, a plugin's skill with a legacy `shortDescription`, a disabled one.
  static var codexSkillsList: JSONValue {
    get throws {
      let url = try #require(
        Bundle.module.url(
          forResource: "codex-skills", withExtension: "json", subdirectory: "Fixtures"))
      return try JSONValue.parse(Data(contentsOf: url))
    }
  }
}
