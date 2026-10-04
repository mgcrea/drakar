# Sessions that asked a question

A session that ends its turn on a question ("Want me to build it that way?") is waiting for
the person as surely as one waiting on a permission request, but today it looks finished.
After this, Drakar recognises the question, marks the row "Asked you" with the question on
its second line, counts it in the badges and notifies, until the person answers or
dismisses it.

## Why

The person runs several sessions and goes round them in turn. A model often replies within
seconds with a confirmation question instead of `AskUserQuestion`, and the person finds it
twenty minutes later. That lost time is where Drakar costs them the most today. Permission
requests already get a blue row, the Dock badge and a notification; a question in prose gets
an unread dot that clears as soon as the row is glanced at.

## Decisions

Settled with the person on 2026-10-04.

| Question | Decision |
| --- | --- |
| How loud a question is | As loud as a permission request: row, group header, Dock badge, notification |
| Which sessions | Drakar's own (attached rows). Sessions live in a terminal or VS Code are not read for questions; Armada covers them, and Drakar is meant to replace them |
| How a question is recognised | Rules over the turn's last text, in DrakarKit. No model call: Drakar makes no outgoing connection (`make audit`) |
| What clears it | A prompt sent to the session, Dismiss, or the session ending. Not looking at it |
| Where it is configured | A new Attention pane in Settings |
| Pinning, priorities, sorting | A separate spec, after this one |

## Recognising a question

`ClosingQuestion.detect(_ text: String) -> String?` in DrakarKit: pure, given the text of the
turn's last assistant message, returns the question to show, or nil.

1. **Strip** fenced code blocks, block quotes and inline code spans, so a `?` in a regex,
   a URL or a shell glob does not count.
2. **Take the closing paragraph**: the last non-empty one. When it is a list (every line
   starts with `-`, `*`, or `1.`-style numbering), take the paragraph before it, and the list
   is the options.
3. **It is a question when** one of its last two sentences ends with `?`, or it contains a
   direct ask without one, matched case-insensitively at a sentence start: "want me to",
   "should I", "shall I", "would you like", "do you want", "ready to proceed", "go ahead
   with", "which (one|option|approach) do you".
4. **It is not a question** when the only ask is a sign-off: a sentence starting "let me
   know if", "feel free to", "happy to", "if you('d) like, I can". These close half of all
   turns and would badge every one.
5. **What is shown** is the matched sentence, whitespace collapsed, cut at 140 characters
   on a word boundary with an ellipsis.

The `?` rule holds in any language; the phrase lists start in English.

### When it runs

Only on a turn that **ended**: a `result` that is not an error and not an interruption, with
no permission request pending. A turn the person stopped is never "asked". The text is that
of the last assistant message after the last prompt; a turn whose last message is a tool call
has no closing text and no question.

## The state

"Asked" is derived, never stored as a flag, so it cannot drift from the transcript the way
the badge did before ddcbbc9.

`ProjectSession.question: String?` is the detected question when all hold:

- the newest turn ended and its closing text has a question;
- no prompt was sent after it;
- its assistant message id (`message.id`) is not the one dismissed for this session;
- the process has not ended.

**Before the history is read** (a restored row that was never shown), the same comes from
the transcript's tail: `TranscriptTail` gains the newest assistant message's id, text and
`stop_reason`, and `SessionSummary` gains `closingQuestion` and `closingMessageID`, set when
that message ended the turn (`end_turn`) and no user prompt follows it. A restored row is
marked at launch.

**Dismiss** stores the message id: `StoredProject.dismissedQuestions: [String: String]`,
session id to message id, decoded with `decodeIfPresent` so windows saved before this load.
A later question in the same session has a new id and marks the row again. An entry goes
when its session leaves the window.

**`isUnread` is unchanged**: it still clears on selection. A row can be asked and read.

## What the person sees

- **The row**: a new `RowState.asked`, "Asked you", blue like `.waiting`, drawn as a ring
  instead of a dot so the two read apart. Its second line leads with the question, in place
  of `waitingFor`. A pending permission request outranks it: such a row is `.waiting`.
- **The group header** counts rows that want the person: waiting or asked.
- **⌥⌘↓ Next Session Needing You** goes to waiting rows, then asked ones, then unread.
- **Dismiss Question**, ⌥⌘D, in the Session menu and the row's context menu, enabled when
  the selected (menu) or clicked (context menu) row is asked.
- **The Dock badge** counts, across every window, what the Attention pane says it counts:
  permission requests and questions by default.
- **A notification** for a question has the session's title as its title and the question
  as its body. It shares the session's identifier with permission notifications, so a newer
  one replaces it, and it is withdrawn when the question clears, the way
  `permissionsChanged` withdraws a permission's.

### When a notification is posted

Today a notification is posted only while Drakar is not the active app. That misses the case
this spec exists for: the person is in Drakar, in another project's window. The rule
becomes: **post unless the session is the one shown in the key window.** It applies to
permission requests and to ended turns as well as to questions, so all three follow one
rule.

## The Attention pane

A new Attention pane in the settings pane list (`Support.settings`), between General and
About. The ended-turn toggle moves here
from General; its key does not change.

| Event | Dock badge | Notification |
| --- | --- | --- |
| A permission request | on | on |
| A question at the end of a turn | on | on |
| A finished turn | not offered | off (`drakar.notifiesTurnEnds`) |

Keys: `drakar.badges.permissions`, `drakar.badges.questions`,
`drakar.notifies.permissions`, `drakar.notifies.questions`, all defaulting to true when
absent. Above the table, "Recognise questions at the end of a turn", on by default,
turns the detection itself off: no "Asked you" rows, and the question row greyed.

## Kit changes

- `ClosingQuestion` (new), with its rules as data so the tests can list them.
- `Transcript` keeps the assistant `message.id` on text entries and records how the newest
  turn ended (`result` subtype, interrupted or not).
- `TranscriptTail` / `SessionSummary`: the closing message and question, as above.

## Spike first

Before any UI:

1. **`AskUserQuestion` under `--permission-prompt-tool stdio`.** Confirm it arrives as a
   `can_use_tool` request (so it is already a waiting row) and what Drakar must answer for
   the question to reach the model with the person's choice. If it does not arrive that way,
   it is a bug of its own, recorded and fixed before this work.
2. **The rules against real endings.** Read the closing text of every ended turn in the
   person's transcripts under `~/.claude/projects` (read-only, nothing leaves the Mac),
   label a sample of 100, and measure the rules: the target is no more than 1 in 20 marks
   wrong, and fewer than 1 in 10 real questions missed. The labelled endings, trimmed to
   their closing paragraph, become the test fixtures.

## Testing

- `ClosingQuestionTests` (DrakarKit): the labelled fixture table, both ways, plus the
  stripping cases: `?` in code, in a URL, in a quote; a closing list of options; a sign-off
  after a real question (the question wins, it is one of the last two sentences); a
  sign-off alone.
- `TranscriptTests`: the turn-end record, an interrupted turn, a turn ending on a tool call.
- `SessionIndex` tail: a transcript ending on an `end_turn` question; one where a prompt
  follows it.
- `AttentionTests`: the badge counts questions when the setting says so and not otherwise;
  a prompt clears the question and withdraws its notification; Dismiss clears it and it
  stays cleared after `StoredProject` round-trips; a newer question after a dismissal marks
  the row again; the notification rule (key window, shown session).
- `SettingsPaneTests`: the Attention pane and its defaults; the moved toggle keeps its value.

## Out of scope

- Pinning, priorities and sort orders: the next spec.
- Questions in sessions live elsewhere (terminal, VS Code).
- Asking a model to judge unclear endings, on-device or otherwise. The spike's numbers say
  whether it is needed.
- Phrase lists in other languages than English.
- Answering from the notification (a text reply action).
