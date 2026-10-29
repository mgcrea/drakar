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
  /// Two foreground Bash turns on Claude Code 2.1.296 (2026-10-12, `haiku` 4.5), each with a
  /// prompt queued while the command ran, then interrupted: first with a plain `interrupt`,
  /// Esc's (`eeeeeeee-…` starts and is answered "QUEUED"), then with `cancel_queued`, Stop's
  /// (`ffffffff-…` cancelled). Stream events, thinking and status lines dropped; paths cut.
  case interruptKeepsQueue = "interrupt-keeps-queue"
  /// A `haiku` 4.5 turn on Claude Code 2.1.308 (2026-10-22) calling `Agent` with
  /// `subagent_type: "fork"`: the fork starts in the background and the turn ends; its Bash
  /// call, result and text follow under the call's id; then, with no prompt, the CLI starts a
  /// turn of its own for the task's notification (`system/init`, the reply, a `result` whose
  /// `origin.kind` is `task-notification`). Stream events, thinking and status lines dropped;
  /// ids and paths scrubbed.
  case forkSubagent = "fork-subagent"
  /// Two MCP elicitations on Claude Code 2.1.311 (2026-10-27, `haiku` 4.5), from
  /// `scripts/elicit-mcp-server.py` registered as `elicit`: `ask_team`'s form request
  /// (`requested_schema`, `property_order`), the CLI's lines up to its tool result (the reply
  /// `{"action":"accept","content":{…}}` echoed back by the server, the token as `<secret>`),
  /// then `sign_in`'s URL request (`url`, `elicitation_id` `el-1`) and the
  /// `elicitation_complete` that followed its `{"action":"accept"}`. The lines between are
  /// cut (the second call, its `can_use_tool`); the lines kept are whole.
  case elicitation = "elicitation"
  /// The task controls on Claude Code 2.1.312 (2026-10-28, `haiku` 4.5), lines 1-43 from one
  /// process and 44-49 from a second, in scenario order (docs/claude-stream-json.md, "Task
  /// controls"):
  /// 1. A foreground `python3 -c 'import time; time.sleep(30)'` (`b8cffcoy7`): its
  ///    `task_started` (`is_backgrounded: false`), then `background_tasks` (`r-bg`): the call
  ///    moves (`task_updated` `patch.is_backgrounded`), the reply is `backgrounded: true`, and
  ///    the tool result "Command was manually backgrounded by user…" follows.
  /// 2. `get_task_output` while it runs (`r-out-running`, empty), the turn's end (the model's
  ///    own polling between is cut), the task's `completed` lines, `get_task_output` after them
  ///    (`r-out-ended`), and the turn the CLI starts for the notification.
  /// 3. A second foreground sleep (`beszynucf`) stopped with `stop_task` (`r-stop-bash`):
  ///    `task_updated` `killed`, `task_notification` `stopped`, an empty success, the result
  ///    "Exit code 137", and the turn going on.
  /// 4. A foreground `general-purpose` `Agent` (`a7b2244ac3d1175c6`) whose Bash
  ///    (`b03hcqfs3`) sleeps, stopped with `stop_task` (`r-stop-agent`): the same two
  ///    statuses for the agent, `stopped` for its Bash, and both calls' results.
  /// 5. `stop_task` for an unknown ID (`r-stop-unknown`, an empty success) and
  ///    `background_tasks` for scenario 1's finished call (`r-bg-finished`, `backgrounded:
  ///    false`).
  /// 6. A process with `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`: a foreground sleep with no
  ///    `task_*` lines, and `background_tasks` on it (`r-bg-disabled`) refused.
  /// Stream events, thinking, status, rate limit and `can_use_tool` lines dropped; inits cut
  /// to a few keys; ids and paths scrubbed.
  case taskControls = "task-controls"
  /// Scenario 4's subagent file from `task-controls` (2.1.312, 2026-10-28),
  /// `subagents/agent-a7b2244ac3d1175c6.jsonl`: its prompt, an `api-request` line (no
  /// `isSidechain`, unlike every other line), its Bash call, the rejection the stop gave it,
  /// and `[Request interrupted by user for tool use]`. Stopped, so it has no closing text.
  /// Attachments, request shapes and blobs, and the thinking line dropped; paths and ids
  /// scrubbed.
  case subagentFile = "subagent-file"
  /// `rewind_files` and `--resume-session-at` on Claude Code 2.1.312 (2026-10-29, `haiku` 4.5),
  /// with `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` unless said otherwise, in scenario
  /// order (docs/claude-stream-json.md, "Rewind"). Prompts were sent with the uuids `aaaaaaaa-…`
  /// (A), `bbbbbbbb-…` (B), `cccccccc-…` (C), `dddddddd-…` (D) and `eeeeeeee-…` (E), which come
  /// back as `command_lifecycle`'s `command_uuid`; the request ids name each request.
  /// 1. Lines 1-18, session `…0001`: A writes `a.txt` = "one"; B rewrites it to "two" and
  ///    creates `b.txt` (each prompt's lifecycle, `init`, Write calls, results, "Done.").
  /// 2. Lines 19-23: dry run and rewind for A (`rewind-a-dry` lists both files, `rewind-a`
  ///    deletes both: the state before A), then for B (`rewind-b-dry` lists `a.txt`, `rewind-b`
  ///    brings back "one"), then B's dry run again, now empty.
  /// 3. Lines 24-25: an unknown uuid, dry run (`success`, `canRewind: false`) and real (`error`).
  /// 4. Lines 26-27: a process started with `--resume=…0001`, before any prompt: dry runs for A
  ///    and B both succeed.
  /// 5. Lines 28-39: the same process after C writes `c.txt`: dry runs for A and B (from before
  ///    this process) and C, then the rewind for C.
  /// 6. Lines 40-41: a new session with no prompt yet, dry run and rewind for A: no checkpoint.
  /// 7. Lines 42-52, session `…0002`, without the environment variable: a dry run before any
  ///    prompt, D writing `d.txt`, then a dry run and a rewind for D: not enabled.
  /// 8. Lines 53-58: `--resume=…0001 --fork-session --resume-session-at=<B's parentUuid>`, then
  ///    E: a new session `…0003`, whose reply quotes A only.
  /// 9. Lines 59-68: the same at B's own uuid, session `…0004`: B is kept, unanswered, and E's
  ///    turn carries out B's two Writes.
  /// 10. Line 69: the same at an unknown uuid: the only line, an `error_during_execution`
  ///    result whose `errors` says "No message found with message.uuid of: …"; the process
  ///    exits 1.
  /// Stream events, thinking, status, `thinking_tokens`, rate limit, `can_use_tool` and the
  /// `initialize` reply dropped; inits cut to a few keys; other ids zeroed, paths cut to `/p`.
  case rewind = "rewind"
  /// Session `…0001`'s transcript file from `rewind` (2.1.312, 2026-10-29), after A and B in
  /// one process and C in a resumed one. Each prompt's line keeps the uuid it was sent with
  /// (`aaaaaaaa-…`, `bbbbbbbb-…`, `cccccccc-…`), and a `file-history-snapshot` after it has that
  /// uuid as its `messageId`. B's `parentUuid` (`…0224`, the "Done." line ending A's
  /// turn) is what `--resume-session-at` takes for a fork that ends just before B; A's is
  /// null. The rewinds wrote no line. `api-request*` and `atis-latch` lines dropped,
  /// attachments cut to their type and without `rendered*`, thinking text and signatures
  /// cut; ids zeroed consistently (every `parentUuid` still names a kept line), paths cut.
  case rewindHistory = "rewind-history"
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
