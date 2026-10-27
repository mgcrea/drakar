# Answering MCP elicitations

An MCP server can stop in the middle of a tool call to ask the person something: a form
("Which team?", "Confirm the refund amount") or a link to open (a sign-in that finishes in the
browser). The terminal CLI shows a dialog for both. Drakar declines every one
(`StreamMessage.swift:397`) and leaves a note, so the tool call fails in Drakar where it would
have worked in the terminal. After this, Drakar shows the question as a card where it was
asked, the person answers or declines, and the answer goes back to the server.

## Why

On 2026-10-06 (2cb05a0) Drakar chose to decline, as the VS Code extension declines (its host
passes no handler). That matched a client with no dialog when few servers asked anything. On
2026-10-23 Anthropic announced elicitations in the Claude Code CLI and told plugin authors to
add them to their servers ("confirming a refund or filling in a missing detail"). As servers
come to rely on them, declining stops being a neutral default and becomes a failed tool call.
Source: the feature scout report, `.idea/feature-scout/2026-10-24.md`, evening addendum.

The person answers where the question was asked (the inline `AskUserQuestion` card, 96eb3fd).
That holds here too.

## What the CLI sends and takes

Read from the 2.1.308 binary's own SDK schema. Not yet captured live: slice 1 starts by
capturing it.

- **Request:** `control_request`, `subtype: "elicitation"`, with `mcp_server_name`, `message`,
  `mode` (`form` | `url`, optional), `url`, `elicitation_id`, `requested_schema`,
  `property_order`, `title`, `display_name` and `description`. `property_order` lists the
  schema's top-level keys in the server's order, for hosts that don't keep JSON key order.
  `JSONValue.object` is a dictionary, so Drakar needs it. `title`, `display_name` and
  `description` come from the server's `_meta['anthropic/permissionDisplay']`.
- **Reply:** the SDK host's answer goes back as is, as the `control_response`'s `response`:
  `{action: "accept" | "decline" | "cancel", content?: {…}}`. Today's decline
  (`ClientMessage.swift:107`) is the same envelope with `{action: "decline"}`.
- **Withdrawal:** when the call is aborted, the CLI sends `control_cancel_request` for the
  request ID. Drakar already turns that into `.permissionWithdrawn` (`ClaudeTranslator.swift`).
- **URL completion:** `system` `elicitation_complete` with `mcp_server_name` and
  `elicitation_id`, "emitted when an MCP server confirms that a URL-mode elicitation is
  complete". Drakar doesn't decode it today.
- The CLI waits with **no deadline** (`docs/claude-stream-json.md:244`). A question nobody can
  see blocks the session for good.

Codex (`docs/codex-app-server.md:495-500`, from the app-server types, not seen live):
`mcpServer/elicitation/request {threadId, turnId, serverName, mode, message, …}`. `mode` is
`form` (`requestedSchema`), `url` (`url`, `elicitationId`) or `openai/form`. The answer is
`{action, content, _meta}`. Today Drakar refuses it with a JSON-RPC error and a "can't answer
yet" note (`CodexSession.swift:217-226`). It doesn't decline, which is what the doc says, so
the doc is stale.

## Goals

- A form elicitation shows as a card with the server's fields. The person fills it in and
  Submits, or Declines. The values go back as `content`.
- A URL elicitation shows the server, its message and the link's host. The person picks Open
  in Browser (`accept`, then `NSWorkspace.open`) or Decline. When `elicitation_complete`
  arrives, a note says so.
- While it waits, the session counts as wanting the person at **permission** urgency (a tool
  blocked mid-turn): row mark, header count, Dock badge, notification.
- A withdrawn request takes its card away. An interrupted turn answers `cancel` for any open
  question.

## Non-goals

- Questions from MCP **tasks** (`input_required`). The CLI cancels those in a non-interactive
  session and never calls the SDK host (code.claude.com/docs/en/mcp, "Answer a question from
  an MCP task"). Nothing Drakar does reaches them.
- Remembering or pre-filling answers across calls, and auto-answering (the CLI's
  `Elicitation` hook already covers that).
- Codex's `openai/form` mode.

## Anti-goals

Any of these makes it a failure, even if it works:

- A value the person typed shows up in a Drakar note, a log line, `os_log`, or anything Drakar
  writes. The note says only that a question was answered, declined or cancelled.
- A link opens without the person clicking Open.
- An elicitation that arrives with no visible card. Whatever happens to the transcript, a
  waiting elicitation is always on screen somewhere.

## Decisions

My calls, since the person skipped the questions (2026-10-25). Each one is open to change.

| Question | Decision |
| --- | --- |
| Where the card goes | In the card of the MCP tool call it belongs to: the newest call named `mcp__<server>__…` that has no result yet. If there is none, it docks above the composer, as the question panel does. The composer shows "Waiting for your answer above", as `question.waiting` does |
| Urgency | Permission level. A tool is blocked mid-turn |
| Field order | `property_order`, else required fields first, then alphabetical (Codex sends no order) |
| Which schemas render | The MCP form subset: a flat object whose properties are `string` (with `title`, `description`, `minLength`/`maxLength`, `format` email/uri/date/date-time, `default`), `number`/`integer` (`minimum`/`maximum`, `default`), `boolean`, single-select enum (`enum` + `enumNames`, or `oneOf` `{const, title}`), and multi-select (`type: array` with enum `items`). Anything else gets a card that names the server and the question, says Drakar can't show this form, and offers Decline only |
| Validation | Submit stays disabled until every required field is filled and every bound holds. Each field shows its own error |
| Secrets | A field whose key or title reads as a password, secret, token or API key is a `SecureField`. Values are never written by Drakar (see Anti-goals) |
| URL mode | The card shows the host big and the full URL selectable. Open in Browser sends `accept`, then opens the link. Only `http`/`https` URLs get the Open button; anything else is Decline only |
| Several at once | They queue in arrival order. The card shows the first, with "1 of 3" |
| Server name shown | `display_name` when present, else `mcp_server_name` |
| Shortcuts | ⌘↩ Submit or Open, Esc Decline. Focus lands in the first field through the same `focusRequest` path the question card uses: no state changes in `onAppear` (d19c1fa) |

## Slices

1. **Claude.** First capture a live form request and a live URL request. A tiny stdio MCP
   server in `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/` (or a script next
   to it) that elicits one of each will do. Check the reply shape and whether the transcript
   JSONL records the answer. Then:
   - DrakarKit: parse the full request (`StreamMessage.swift:385`/`:412`); an elicitation
     schema type with the subset, ordering and validation; an `answerElicitation` reply
     (`ClientMessage.swift`); a pending-elicitation list on `Transcript` alongside
     `pendingPermissions`; decode `elicitation_complete` as a note.
   - App: `ControlRequest.reply` returns nil for an elicitation, so `ClaudeBackend.swift:138`
     no longer auto-answers it; the card; the waiting state; interrupt → `cancel`.
   - Docs: the `elicitation` row in `docs/claude-stream-json.md:244`, plus an
     `elicitation_complete` row.
2. **Codex**, after a live capture of `mcpServer/elicitation/request`. Route it to the same
   card instead of refusing it (`CodexSession.swift:217`), answer `{action, content, _meta}`,
   and withdraw on `serverRequest/resolved`. Fix the stale line in
   `docs/codex-app-server.md:500`.

## Tests

- DrakarKit: request parsing with every field and with only the required ones; schema
  decoding for each supported kind and for an unsupported one; ordering with and without
  `property_order`; validation bounds; the reply's JSON for accept with content, decline and
  cancel; withdrawal removing the pending entry; `elicitation_complete` becoming a note.
- `NothingSilentTests.declinesAnElicitation` and `AgentSessionRepliesTests.anElicitationIsDeclined`
  become "waits for the person", plus answered, declined, withdrawn and
  cancelled-on-interrupt cases.
- By hand, through the accessibility tree (screenshots are black here): the card in a live
  session against the test server, in both modes, focus, ⌘↩ and Esc.

## Left to the builder

- Whether pending elicitations share `PendingPermission` (a new kind of request) or get their
  own list. Both work. What matters is that every place that counts waiting requests counts
  these too (`SessionView.swift`, `SessionMoves.swift:40`, `TranscriptView.swift:51-62`,
  `AgentSession.swift:595/648`). A single "wants the person" property may be the cleaner way
  to get there.
- How the card's layout reuses `QuestionPanel`.
- The test server's language and shape.

## Open questions

- Does the CLI write the answered `content` into the session's JSONL? If it does, a secret
  typed here lands on disk, which Drakar can't prevent but should mention in the card's
  footnote. Slice 1's capture answers it.
- Whether the MCP server in the capture receives `accept` with `content` exactly as sent. This
  is assumed from the SDK's pass-through (`return n` in the 2.1.308 handler).
