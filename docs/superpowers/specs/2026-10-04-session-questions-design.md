# Sessions that want the person, by urgency

A session can want the person in several ways: a tool waiting on a permission, an
`AskUserQuestion` waiting on a choice, a turn that ended on a question ("Want me to build it
that way?"), or one that ended on an offer ("Say the word and I'll add it"). Today only the
first is seen; a question in prose looks like a finished turn. After this, Drakar tells the
four apart, gives each its own mark on the row and its own feedback (header count, Dock
badge, notification), and lets the person answer an `AskUserQuestion` properly.

## Why

The person runs several sessions and goes round them in turn. A model often replies within
seconds with a confirmation question instead of `AskUserQuestion`, and the person finds it
twenty minutes later. That lost time is where Drakar costs them the most today. Not every
ending wants them equally, though: an offer at the end of a report can wait, a question
should not, and a tool blocked mid-turn least of all. One loudness for all of them would
either miss questions or nag about offers.

## Decisions

Settled with the person on 2026-10-04.

| Question | Decision |
| --- | --- |
| How many kinds | Four urgency levels, most urgent first: permission, choice (`AskUserQuestion`), question, offer. A plain finished turn stays as it is (unread) |
| How loud each is | A question is as loud as a permission request. An offer is marked on its row only. Each level's feedback is a setting |
| Which sessions | Drakar's own (attached rows). Sessions live in a terminal or VS Code are not read; Armada covers them, and Drakar is meant to replace them |
| How questions and offers are recognised | Rules over the turn's closing text, in DrakarKit, measured on 100 labelled real endings. No model call: Drakar makes no outgoing connection (`make audit`) |
| What clears a question or an offer | A prompt sent to the session, Dismiss, or the session ending. Not looking at it |
| `AskUserQuestion` | Answered in its own sheet with its options, the picked labels sent back |
| Where it is configured | A new Attention pane in Settings |
| Pinning, priorities, sorting | A separate spec, after this one |

## The levels

| Level | When | Row mark | Row label | Second line |
| --- | --- | --- | --- | --- |
| Permission | A `can_use_tool` request waits, for any tool but `AskUserQuestion` | blue dot | Waiting for you | "Bash: make test" (as today) |
| Choice | A `can_use_tool` request for `AskUserQuestion` waits | blue dot | Asks you to choose | its first question |
| Question | The newest turn ended on a question or an ask | blue ring | Asked you | the question |
| Offer | The newest turn ended on an offer | grey ring | Offered | the offer |

A row has one level, the most urgent that applies. A question or an offer exists only once
the turn ended, so it never coexists with a waiting request on the same row.

Default feedback, each a switch in the Attention pane:

| Level | Counts (header, ⌥⌘↓) | Dock badge | Notification |
| --- | --- | --- | --- |
| Permission | on | on | on |
| Choice | on | on | on |
| Question | on | on | on |
| Offer | off | off | off |
| Finished turn | (unread, unchanged) | – | off (`drakar.notifiesTurnEnds`) |

## Recognising questions and offers

`ClosingAsk.detect(_ text: String) -> ClosingAsk?` in DrakarKit: pure, given the text of the
turn's last assistant message, returns `.question` or `.offer` with the sentence to show, or
nil.

1. **Strip** fenced code blocks (an unclosed fence runs to the end), block quotes, inline
   code spans and URLs, so a `?` in a regex, a URL or a quoted message does not count.
2. **Read the closing paragraphs**: the last two non-empty ones. Each line is its own
   sentence boundary, list items included.
3. **A question** is a sentence there that ends with `?` (or `？`), or starts with a direct
   ask ("want me to", "should I", "shall I", "would you like", "do you want", "which option
   do you"…), or asks the person to act ("tell me when", "…, tell me, and…", "waiting on
   your go-ahead"). Sign-offs ("let me know if", "feel free to") are never a question, even
   with a `?`. The last question found is the one shown.
4. **An offer**, when there is no question: a sentence there that offers without asking
   ("let me know if you'd like", "if you want…", "say the word", "say if you want", "I can …
   if you want", "happy to"). The last one found is shown.
5. **What is shown** is that sentence, markdown emphasis removed, whitespace collapsed, cut
   at 140 characters on a word boundary with an ellipsis.

The phrase lists start in English; the `?` rule holds in any language.

**Targets**, on the labelled fixture: of the endings marked as questions, at most 1 in 20
is wrong (labelled offer or nothing); fewer than 1 real question in 10 is missed; at least 2
offers in 3 are recognised as offers.

### When it runs

Only on a turn that **ended**: a `result` that is not an error and not an interruption, or
in history (which has no `result`) an assistant message with `stop_reason: end_turn`; with
no permission request pending. A turn the person stopped is never asking. The text is that
of the last main-thread assistant message after the last prompt; a turn whose last message
is a tool call has no closing text.

## The state

A row's level is derived, never stored as a flag, so it cannot drift from the transcript the
way the badge did before ddcbbc9.

`ProjectSession.closingAsk: ClosingAsk?` is the detected ask when all hold:

- the newest turn ended and its closing text has a question or an offer;
- no prompt was sent after it;
- its assistant message id (`message.id`) is not the one dismissed for this session;
- the process has not ended, and the row is not held read-only.

**Before the history is read** (a restored row that was never shown), the same comes from
the transcript's tail: `TranscriptTail` gains the closing text of a turn that ended
(`end_turn`) with no user prompt after it, and `SessionSummary` gains `closingAsk` and
`closingMessageID`. A restored row is marked at launch.

**Dismiss** stores the message id: `StoredProject.dismissedQuestions: [String: String]`,
session id to message id, optional so windows saved before this load. A later ask in the
same session has a new id and marks the row again. An entry goes when its session leaves the
window.

**`isUnread` is unchanged**: it still clears on selection. A row can be asked and read.

## What the person sees

- **The row**: its level's mark and label, and the second line above. Dot and ring are the
  same size, so a row does not shift when its level changes.
- **The group header** counts rows whose level counts.
- **⌥⌘↓ Next Session Needing You** goes to the most urgent counting row after the selected
  one (wrapping), then to unread rows.
- **Dismiss**, ⌥⌘D, in the Session menu and the row's context menu, enabled for a question or
  an offer.
- **The Dock badge** counts, across every window, the rows whose level badges.
- **A notification**: the session's title, and as body "Wants to use Bash: make test", the
  choice's first question, the question, or the offer. It shares the session's identifier,
  so a newer one replaces it, and it is withdrawn when the row no longer wants the person.

### When a notification is posted

Today a notification is posted only while Drakar is not the active app. That misses the case
this spec exists for: the person is in Drakar, in another project's window. The rule
becomes: **post unless the session is the one shown in the key window.** It applies to every
level and to ended turns.

## Answering `AskUserQuestion`

Verified on 2026-10-04 (`docs/claude-stream-json.md`, "AskUserQuestion"): the request is a
`can_use_tool` with `requires_user_interaction: true`; a plain `allow` gives the model "The
user did not answer the questions", and an `allow` whose `updatedInput` adds
`answers: {"<question>": "<label>"}` reaches it. Several questions each get an entry; a
multi-select answer is its labels joined with ", ", as the CLI's own picker writes it.

When the waiting request is for `AskUserQuestion`, the session shows a **choice sheet**
instead of the permission sheet: each question with its header, its options as radio
buttons (checkboxes when `multiSelect`), each option's description under its label, and an
"Other" field for a typed answer. **Answer** (the default button) is enabled once every
question has an answer and sends `allow` with the input plus `answers`. **Skip** sends
`deny` with "The user chose not to answer."

## The Attention pane

A new pane between General and About. The ended-turn toggle moves here from General; its key
does not change.

- "Recognise questions and offers at the end of a turn", on by default: off, no row is ever
  a question or an offer.
- One row per level, with three switches: Counts, Dock badge, Notification. Defaults as in
  the table above. Keys: `drakar.attention.<level>.<feedback>`, level one of `permission`,
  `choice`, `question`, `offer`, feedback one of `counts`, `badges`, `notifies`.
- "Finished turn": a notification switch only (`drakar.notifiesTurnEnds`).

## Kit changes

- `ClosingAsk` (new): the rules, their phrase lists as data, and `ClosingText`.
- `AssistantMessage.stopReason`; `Transcript.turnEnd` and `Transcript.closingText`.
- `TranscriptTail.closingText`; `SessionSummary.closingAsk` / `closingMessageID`.
- `PermissionRequest.requiresUserInteraction`; `UserQuestion` (parsed from an
  `AskUserQuestion` input) and building the answered input.

## Spike (done 2026-10-04)

1. `AskUserQuestion` under `--permission-prompt-tool stdio`: recorded in
   `docs/claude-stream-json.md`, as above.
2. 100 closing texts from the person's own transcripts, scrubbed, labelled question, offer
   or nothing, trimmed to their last three paragraphs: the fixture the rules are measured on.

## Testing

- `ClosingAskTests` (DrakarKit): the labelled fixture against the targets; the stripping
  cases (`?` in code, a URL, a quote; an unclosed fence); a question followed by an
  explanation; a sign-off alone (an offer, not a question); a full-width `？` and a French
  "continue ?"; a long reply read quickly.
- `TranscriptTests` / `HistoryTests`: the turn end, interrupted and failed turns, a turn
  ending on a tool call, a subagent's text, history with and without `stop_reason`.
- `ContextUsageTests` (tail): a turn ending on an ask; answered; a tool call; a synthetic
  turn; a sidechain; a summary carrying the ask.
- `UserQuestion` tests: parsing the captured input; single, multi-select, "Other" and several
  questions answered into `updatedInput`.
- `AttentionTests`: the level of a row for each kind; looking keeps it, a prompt, Dismiss and
  ending clear it; a restored row is marked unless that message was dismissed; counting and
  badging follow the switches per level; the notification rule; next row by urgency.
- `SettingsPaneTests`: the Attention pane, its defaults, the moved toggle keeps its key.

## Out of scope

- Pinning, priorities and sort orders: the next spec.
- Questions and offers in sessions live elsewhere (terminal, VS Code).
- Asking a model to judge unclear endings, on-device or otherwise.
- Phrase lists in other languages than English.
- Answering from the notification (a text reply action).
- `AskUserQuestion`'s optional `annotations` (notes per answer).
