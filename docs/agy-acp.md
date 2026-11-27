# Driving Antigravity (`agy`) over ACP

Findings from probes run on 2026-11-27 against `agy 1.5.18` (`/Users/olivier/.local/bin/agy`)
running its built-in Agent Client Protocol (ACP) stdio server (`agy acp`). The Antigravity
counterpart of [claude-stream-json.md](claude-stream-json.md) and
[codex-app-server.md](codex-app-server.md).

## Verdict

- **`agy acp` speaks standard JSON-RPC 2.0 over stdio.** One JSON object per line in both
  directions, always carrying `"jsonrpc": "2.0"`. stderr is diagnostic logging, not protocol.
- **The whole interactive loop works from outside** (verified 2026-11-27): `initialize`,
  `session/new`, `session/resume`, `session/load`, `session/close`, `session/list`,
  `session/prompt` (text and base64 images), `session/cancel`, `session/set_mode`,
  `session/set_config_option` (`model`, `thought_level`), and `session/request_permission`.
- **Native modes, models, thinking levels, diffs, slash commands, and context usage are all
  on the wire.** `session/new` returns `models`, `modes` (`default`, `accept-edits`, `auto`,
  `plan`), and `configOptions` (`model`, `thought_level`, `mode`), followed by
  `available_commands_update` (slash commands and skills) and `usage_update` (`used`, `size`).
- **One process per session**, matching `claude` and `codex app-server`. Closing stdin ends
  the process cleanly (exit 0).

## Spawning (verified)

```sh
agy acp
```

- Located on the login shell's `PATH`, then `~/.local/bin/agy`, `/opt/homebrew/bin/agy`, and
  `/usr/local/bin/agy`.
- Uses the user's installed `agy` configuration and authentication under
  `~/.gemini/antigravity-cli/`.
- Drakar does not pass `--dangerously-skip-permissions`: switching to and from Bypass mode
  works mid-session by auto-approving `session/request_permission` requests in `AgySession`
  while Bypass is active.

## Framing and handshake (verified)

```jsonc
>> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
     "protocolVersion":1,
     "clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},
     "clientInfo":{"name":"drakar","version":"…"}}}
<< {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,
     "agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true,"audio":false,"embeddedContext":true},
       "sessionCapabilities":{"resume":{},"close":{},"load":{},"list":{},"additionalDirectories":{}}},
     "agentInfo":{"name":"Antigravity ACP Server","version":"1.5.18"},
     "authMethods":[…]}}
```

- Client request ids are integers starting at 1; server request ids (`session/request_permission`)
  are strings (`"1"`, `"2"`, …). Keep the two namespaces separate.

## Sessions (verified)

- **Start**: `session/new {"cwd": "/path", "mcpServers": []}` returns `{sessionId, models, modes, configOptions}`.
- **Resume (no replay)**: `session/resume {"sessionId": "…", "cwd": "/path", "mcpServers": []}`
  attaches to an existing conversation without replaying history.
- **Load (with history replay)**: `session/load {"sessionId": "…", "cwd": "/path", "mcpServers": []}`
  emits `session/update` notifications (`user_message_chunk`, `tool_call`, `agent_message_chunk`,
  `session_info_update`, `usage_update`, `available_commands_update`) and then responds with the
  session metadata. Drakar uses this in a short-lived `AgyOneShot` to restore history.
- **Close**: `session/close {"sessionId": "…"}` → `{}`.

## Prompts, streaming, and cancellation (verified)

- **Prompt**: `session/prompt {"sessionId": "…", "prompt": [ContentBlock]}` stays pending for
  the whole turn and resolves with `{"stopReason": "end_turn" | "cancelled" | "refusal" | …, "usage": {…}}`.
  - Text block: `{"type": "text", "text": "…"}`.
  - Image block: `{"type": "image", "mimeType": "image/png", "data": "<base64>"}` (verified with a 1×1 red PNG).
  - No PDF block: PDFs are refused at intake (`acceptsPDF: false`); text attachments go inline as `<attachment name="…">`.
- **Streaming notifications** (`method: "session/update"`, `params: {sessionId, update}`):
  - `agent_thought_chunk`: `{content: {type: "text", text}}`
  - `agent_message_chunk`: `{content: {type: "text", text}}`
  - `tool_call` / `tool_call_update`: `{toolCallId, name, args, rawInput, rawOutput, status: "in_progress" | "pending" | "completed" | "failed", kind: "read" | "edit" | "execute" | "search" | "fetch" | "other", title, locations, content}`
    - File edits (`edit_file`, `write_file`) carry `content: [{"type": "diff", "path": "…", "oldText"?: "…", "newText": "…"}]`.
    - Shell commands (`run_command`) carry `rawOutput: {"output": "…", "exit_code": 0}` and text content blocks.
  - `usage_update`: `{used, size}` (context window gauge).
  - `session_info_update`: `{title}` (AI-generated session title).
  - `available_commands_update`: `{availableCommands: [{name, description, input?: {hint}}]}`.
  - `config_option_update`: `{configOptions: […]}`.
  - `current_mode_update`: `{currentModeId}`.
- **Cancel**: notification `{"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": "…"}}`.
  Running tools fail cleanly and `session/prompt` resolves with `stopReason: "cancelled"`.
- **Mid-turn prompts**: queued client-side in `AgySession`, so individual queued messages can
  be cancelled (`cancelsQueued: true`), kept across Esc, or dropped by Stop.

## Modes, models, and thinking level (verified)

- `session/set_mode {"sessionId": "…", "modeId": "default" | "accept-edits" | "plan" | "auto"}` → `{}`.
- `session/set_config_option {"sessionId": "…", "configId": "model" | "thought_level", "value": "…"}`
  → `{"configOptions": […]}` and emits `config_option_update`.
- `configOptions` lists base models (`gemini-4-neon`, `gemini-3.8-flash`, `claude-opus-5-5`, …)
  while `models.availableModels` lists every `(model, effort)` variant (`gemini-4-neon-high`, …).
  Drakar combines both to populate per-model effort pills.

## Permissions (verified)

```jsonc
<< {"jsonrpc":"2.0","id":"2","method":"session/request_permission","params":{
     "sessionId":"…",
     "toolCall":{"toolCallId":"call_…","name":"run_command","status":"pending","kind":"execute",
                 "rawInput":{"CommandLine":"echo ok"}, "content":[…]},
     "options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},
                {"optionId":"deny","name":"Deny","kind":"reject_once"}]}}
>> {"jsonrpc":"2.0","id":"2","result":{"outcome":{"outcome":"selected","optionId":"allow"}}}
```

- Deny (continue turn): select the `reject_once` option.
- Deny with interrupt / Cancel: `{"outcome": {"outcome": "cancelled"}}`.
- Any `allow_always` option is surfaced as a permission suggestion in Drakar's sheet.
