# Sessions That Asked a Question Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session whose turn ends on a question ("Want me to build it that way?") is
marked "Asked you" with the question on its row, counted in the header and the Dock badge,
and notified, until the person answers or dismisses it.

**Architecture:** DrakarKit gains a pure detector (`ClosingQuestion`) and learns where a
turn's closing text is: in a live `Transcript` (from `result` or `stop_reason: end_turn`)
and in a `TranscriptTail` (for rows whose history is not read). The app derives
`ProjectSession.question` from those, never storing a flag; `Attention` counts and notifies
from it under a new Attention settings pane; the sidebar draws it.

**Tech Stack:** Swift 6 (tools 6.3), SwiftUI + AppKit on macOS 26, Swift Testing,
`UserNotifications`, Swift `Regex` literals. DrakarKit stays Foundation-only.

**Spec:** `docs/superpowers/specs/2026-10-04-session-questions-design.md`

**Two refinements of the spec, decided here:**

1. The spec's rule "one of its last two sentences ends with `?`" would mark rhetorical
   question-then-answer endings ("Why did it fail? The cache was stale.") which Claude
   writes often. The rule here: the **last** sentence is the question, after setting aside
   up to two *trailers* (sign-offs, and "I'd recommend…"-style recommendations). The spike
   (Task 0) measures it; Task 1's fixture test holds it to the spec's targets.
2. A row that Drakar holds read-only (the session is open in a terminal) is never "asked":
   the person cannot answer it from Drakar.

## Global Constraints

- DrakarKit has zero dependencies and imports nothing above Foundation. `make test`
  (in `apps/apple`) resolves nothing and runs offline.
- Protocol shapes are tested against captured output or minimal synthetic lines of shapes
  already captured (`docs/claude-stream-json.md`).
- The app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; kit code is
  nonisolated by default.
- Drakar opens no connection: `make audit` (repo root) must still pass. `UserNotifications`
  is local. No model is called to judge a question.
- Drakar never writes the person's Claude Code settings.
- Commits: `feat(kit): …`, `feat(apple): …`, `docs: …`, `test(kit): …`, a lowercase
  sentence; a prose body when the why is not obvious. No trailers.
- Before each commit: `make -C apps/apple format-swift`.
- Copy, exactly: row state "Asked you"; menu items "Dismiss Question"; pane "Attention";
  toggle "Recognise questions at the end of a turn". British spelling ("Recognise").
- Defaults keys: `drakar.recognisesQuestions`, `drakar.badges.permissions`,
  `drakar.badges.questions`, `drakar.notifies.permissions`, `drakar.notifies.questions`
  (all true when absent); `drakar.notifiesTurnEnds` unchanged (false when absent).
- Shortcut: Dismiss Question is ⌥⌘D. Next Session Needing You stays ⌥⌘↓.
- Question text shown is at most 140 characters, cut on a word boundary with "…".

## Review Focus

1. **A subagent's text ending in a question** (`parent_tool_use_id` set) while the main
   turn ends on a plain statement: not asked. Pinned in Task 2.
2. **An unclosed code fence** (a reply cut off mid-block) or a `?` inside a fence, inline
   code, a URL or a quote: never a question, never a crash. Pinned in Task 1.
3. **A long reply** (200 KB of text): detection stays fast, and the app does not re-run it
   on every draw. Pinned in Tasks 1 (timing) and 4 (memo).
4. **The CLI's own synthetic turn** ("You've hit your session limit", model
   `<synthetic>`) at the end of a transcript: not a question. Pinned in Task 3.
5. **A full-width `？` or a French "Voulez-vous que je continue ?"** (space before `?`):
   still a question. Pinned in Task 1.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Packages/DrakarKit/Sources/DrakarKit/ClosingQuestion.swift` (new) | `ClosingText`, and `ClosingQuestion.detect`: the rules |
| `Packages/DrakarKit/Sources/DrakarKit/StreamMessage.swift` | `AssistantMessage.stopReason` |
| `Packages/DrakarKit/Sources/DrakarKit/Transcript.swift` | `TurnEnd`, `turnEnd`, `closingText` |
| `Packages/DrakarKit/Sources/DrakarKit/ContextUsage.swift` | `TranscriptTail.closingText` |
| `Packages/DrakarKit/Sources/DrakarKit/SessionIndex.swift` | `SessionSummary.closingQuestion` / `closingMessageID` |
| `Drakar/Views/SettingsView.swift` | keys, `AttentionChoice`, `SettingsPane.attention`, `AttentionPane` |
| `Drakar/Services/ClaudeSession.swift` | `onPromptSent` |
| `Drakar/Services/Project.swift` | `ProjectSession.question`, dismissal, `StoredProject.dismissedQuestions`, counts, next |
| `Drakar/Services/Attention.swift` | badge counting, notification rule, question notifications, withdrawal |
| `Drakar/Views/ProjectSidebar.swift` | `RowState.asked`, `StateDot`, second line, context menu |
| `Drakar/DrakarApp.swift` | Session menu: Dismiss Question |
| `docs/claude-stream-json.md` | what the spike found about `AskUserQuestion` |

All paths below are relative to `apps/apple/` unless they start with `docs/`.

---

### Task 0: Spike — `AskUserQuestion`, and the rules against real endings

No product code. Two findings, each committed.

**Files:**
- Modify: `docs/claude-stream-json.md` (a new section)
- Create: `Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/closing-endings.jsonl`
- Scratch (never committed): the session's scratchpad directory

**Interfaces:**
- Produces: `closing-endings.jsonl`, one JSON object per line:
  `{"text": "<closing text>", "question": "<the sentence a row should show>" | null}`.
  Task 1 reads it through `Fixture.closingEndings`.

- [ ] **Step 1: Capture `AskUserQuestion` under `--permission-prompt-tool stdio`**

In a scratch folder, run the CLI the way Drakar does and ask it to use the tool:

```sh
cd "$SCRATCH" && mkdir -p ask && cd ask
printf '%s\n' \
  '{"type":"control_request","request_id":"req_init","request":{"subtype":"initialize","hooks":null}}' \
  '{"type":"user","session_id":"","parent_tool_use_id":null,"message":{"role":"user","content":"Use the AskUserQuestion tool to ask me whether to name the file a.txt or b.txt. Do nothing else."}}' \
| timeout 120 claude --output-format stream-json --verbose --input-format stream-json \
    --permission-prompt-tool stdio --model claude-haiku-4-5 > capture.jsonl 2> stderr.txt
grep -n 'can_use_tool\|AskUserQuestion' capture.jsonl | cut -c1-400
```

Expected: a `control_request` with `"subtype":"can_use_tool"` and
`"tool_name":"AskUserQuestion"`, its `input.questions[]` holding the question and options.
The process then waits (stdin closed: it ends). Note what it does instead if not.

- [ ] **Step 2: Learn what answer carries the choice**

Run again with a FIFO so the request can be answered. Answer with
`{"behavior":"allow","updatedInput":<the request's input with "answers":{"<question text>":"a.txt"}>}`
and check the assistant's next text uses `a.txt`:

```sh
mkfifo in.fifo
(claude --output-format stream-json --verbose --input-format stream-json \
   --permission-prompt-tool stdio --model claude-haiku-4-5 < in.fifo > capture2.jsonl 2>&1 &)
exec 3> in.fifo
echo '{"type":"control_request","request_id":"req_init","request":{"subtype":"initialize","hooks":null}}' >&3
echo '{"type":"user","session_id":"","parent_tool_use_id":null,"message":{"role":"user","content":"Use the AskUserQuestion tool to ask me whether to name the file a.txt or b.txt, then tell me which I picked."}}' >&3
# wait for the can_use_tool line, copy its request_id and input, then:
# echo '{"type":"control_response","response":{"subtype":"success","request_id":"<id>","response":{"behavior":"allow","updatedInput":{...,"answers":{"<question>":"a.txt"}}}}}' >&3
exec 3>&-
```

If `answers` is not the field, try the shape the CLI's own `tool_result` for
AskUserQuestion shows in a transcript (`grep -h AskUserQuestion ~/.claude/projects/*/*.jsonl | head`).

- [ ] **Step 3: Record the finding**

Add a section to `docs/claude-stream-json.md`, after the permission section, titled
`## AskUserQuestion`: the request's shape (trimmed capture), the answer that worked, the
CLI version (`claude --version`), and the date. If it does **not** arrive as `can_use_tool`,
say so plainly, stop, and report to the person: that is a bug of its own, fixed before this
plan continues.

```bash
git add docs/claude-stream-json.md
git commit -m "docs: how AskUserQuestion reaches a stdio permission prompt"
```

- [ ] **Step 4: Extract real closing texts**

Every main-thread assistant message that ended a turn, newest transcripts first, joined
per message id (each block is its own line):

```sh
cd ~/.claude/projects
ls -t ./*/*.jsonl | head -300 | xargs -d '\n' jq -c '
  select(.type=="assistant" and (.isSidechain|not) and .message.stop_reason=="end_turn"
         and .message.model != "<synthetic>")
  | {id: .message.id, text: ([.message.content[]? | select(.type=="text") | .text] | join("\n\n"))}
  | select(.text != "")' 2>/dev/null \
| jq -s 'group_by(.id) | map({id: .[0].id, text: (map(.text) | join("\n\n"))})' \
> "$SCRATCH/endings.json"
jq length "$SCRATCH/endings.json"
```

- [ ] **Step 5: Sample 100, balanced**

50 whose last 300 characters contain `?` or one of the asks ("want me to", "should i",
"shall i", "would you like", "do you want"), 50 drawn from the rest:

```sh
cd "$SCRATCH" && python3 - <<'EOF'
import json, random, re
random.seed(4)
items = json.load(open("endings.json"))
asky = re.compile(r"\?|want me to|should i |shall i |would you like|do you want", re.I)
hot = [i for i in items if asky.search(i["text"][-300:])]
cold = [i for i in items if not asky.search(i["text"][-300:])]
sample = random.sample(hot, min(50, len(hot))) + random.sample(cold, min(50, len(cold)))
json.dump(sample, open("sample.json", "w"), indent=1, ensure_ascii=False)
print(len(hot), len(cold), len(sample))
EOF
```

- [ ] **Step 6: Label, trim and scrub**

For each sample, decide as the person would: **does this turn wait for an answer?** If yes,
`question` is the one sentence a row should show (the one the rules should return, without
markdown emphasis); if no, `null`. Then trim `text` to its last two paragraphs (keep a whole
fenced block if it is one of them) and scrub it: replace people's names, client and company
names, e-mail addresses, tokens, hostnames and home paths with neutral stand-ins (`Alex`,
`Acme`, `/Users/me/project`). Keep the wording of the closing sentences exactly.

Write `Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/closing-endings.jsonl`, one
`{"text":…,"question":…}` per line (`jq -c`).

- [ ] **Step 7: Show the person ten**

Before going on, show the person ten labelled lines (five each way) and ask whether the
labels match their judgment. Fix the labelling rule if they disagree, and relabel.

- [ ] **Step 8: Commit the fixture**

```bash
git add apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/closing-endings.jsonl
git commit -m "test(kit): a hundred real turn endings, labelled asking or not"
```

---

### Task 1: `ClosingQuestion` — the rules

**Files:**
- Create: `Packages/DrakarKit/Sources/DrakarKit/ClosingQuestion.swift`
- Create: `Packages/DrakarKit/Tests/DrakarKitTests/ClosingQuestionTests.swift`
- Modify: `Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift` (one case)

**Interfaces:**
- Consumes: `Fixtures/closing-endings.jsonl` (Task 0).
- Produces:
  - `public struct ClosingText: Sendable, Equatable { public var messageID: String; public var text: String; public init(messageID: String, text: String) }`
  - `public enum ClosingQuestion { public static func detect(_ text: String) -> String?; public static let maxLength: Int /* 140 */ }`

- [ ] **Step 1: Add the fixture case**

In `Fixture.swift`, after `contextUsage`:

```swift
  /// A hundred closing texts of real turns (Task 0 of the session-questions plan, 2026-10-04),
  /// trimmed to their last two paragraphs and scrubbed, each labelled with the question a
  /// row should show or null. Lines are `{"text": …, "question": …}`, not stream messages.
  case closingEndings = "closing-endings"
```

- [ ] **Step 2: Write the failing tests**

`ClosingQuestionTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@Suite("The question a turn ended on")
struct ClosingQuestionTests {

  @Test func aQuestionAtTheEndIsAsked() {
    #expect(
      ClosingQuestion.detect("Built and tested.\n\nWant me to build it that way?")
        == "Want me to build it that way?")
  }

  @Test func aDirectAskNeedsNoQuestionMark() {
    #expect(
      ClosingQuestion.detect("The plan is ready. Should I go ahead with option B.")
        == "Should I go ahead with option B.")
  }

  @Test func aStatementIsNot() {
    #expect(ClosingQuestion.detect("All 146 tests pass. Committed as 2add3ce.") == nil)
  }

  /// Half of all turns close this way; none of them waits for anything.
  @Test func aSignOffAloneIsNot() {
    #expect(ClosingQuestion.detect("Done. Let me know if you'd like any changes.") == nil)
    #expect(ClosingQuestion.detect("Fixed. Feel free to ask if anything is unclear?") == nil)
  }

  @Test func aQuestionBeforeASignOffIsAsked() {
    #expect(
      ClosingQuestion.detect("Do you want me to commit? Let me know if anything else comes up.")
        == "Do you want me to commit?")
    #expect(
      ClosingQuestion.detect("Which approach do you prefer? I'd recommend the first.")
        == "Which approach do you prefer?")
    #expect(
      ClosingQuestion.detect("Shall I push? Let me know if you\u{2019}d rather wait.")
        == "Shall I push?")
  }

  /// Claude answers its own questions often; only the last word counts.
  @Test func aRhetoricalQuestionIsNot() {
    #expect(ClosingQuestion.detect("Why did it fail? The cache was stale.") == nil)
  }

  @Test func onlyTheClosingParagraphCounts() {
    #expect(ClosingQuestion.detect("Should I keep it?\n\nI kept it. All green.") == nil)
  }

  @Test func aListOfOptionsAsksWithTheParagraphBeforeIt() {
    #expect(
      ClosingQuestion.detect("Which do you prefer?\n\n1. Rules\n2. A model")
        == "Which do you prefer?")
    #expect(ClosingQuestion.detect("Changed:\n\n- a\n- b") == nil)
  }

  @Test func codeQuotesAndLinksAreNotSentences() {
    #expect(ClosingQuestion.detect("Run `grep -E 'a?'` to check.") == nil)
    #expect(ClosingQuestion.detect("Done.\n\n```\nwhat?\n```") == nil)
    #expect(ClosingQuestion.detect("> Should we ship?\n\nShipped.") == nil)
    #expect(ClosingQuestion.detect("It is at https://example.com/search?") == nil)
  }

  /// A reply cut off inside a fence: everything after the fence is code.
  @Test func anUnclosedFenceIsCodeToTheEnd() {
    #expect(ClosingQuestion.detect("Here:\n\n```swift\nlet a = b ?? c\nwhat?") == nil)
  }

  @Test func emphasisIsNotPartOfTheQuestion() {
    #expect(ClosingQuestion.detect("**Want me to proceed?**") == "Want me to proceed?")
  }

  @Test func otherQuestionMarksCount() {
    #expect(ClosingQuestion.detect("C'est prêt. Voulez-vous que je continue ?") != nil)
    #expect(ClosingQuestion.detect("準備できました。続けますか？") != nil)
  }

  @Test func aLongQuestionIsCutOnAWord() throws {
    let long = "Should I " + String(repeating: "rename every file ", count: 20) + "now?"
    let shown = try #require(ClosingQuestion.detect(long))
    #expect(shown.count <= ClosingQuestion.maxLength)
    #expect(shown.hasSuffix("…"))
    #expect(!shown.dropLast().hasSuffix(" "))
  }

  @Test func windowsLineEndingsAreLines() {
    #expect(ClosingQuestion.detect("Done.\r\n\r\nWant me to push?") == "Want me to push?")
  }

  @Test func aLongReplyIsReadQuickly() {
    let reply = String(repeating: "A line of prose about the change. ", count: 6_000)
      + "\n\n```\n" + String(repeating: "code();\n", count: 2_000) + "```\n\nWant me to push?"
    let start = ContinuousClock.now
    #expect(ClosingQuestion.detect(reply) == "Want me to push?")
    #expect(ContinuousClock.now - start < .milliseconds(500))
  }

  /// The spec's targets, on real endings: at most 1 mark in 20 wrong, fewer than 1 real
  /// question in 10 missed. The failures print, which is how the rules get tuned.
  @Test func meetsItsTargetsOnRealEndings() throws {
    var wrong: [String] = []
    var missed: [String] = []
    var marked = 0
    var questions = 0
    for line in try Fixture.closingEndings.lines {
      let json = try JSONValue.parse(line)
      let text = try #require(json["text"]?.stringValue)
      let expected = json["question"]?.stringValue
      let found = ClosingQuestion.detect(text)
      if expected != nil { questions += 1 }
      if found != nil { marked += 1 }
      if found != nil, expected == nil { wrong.append(text) }
      if expected != nil, found == nil { missed.append(text) }
    }
    #expect(questions >= 20, "too few questions in the fixture to measure")
    #expect(wrong.count * 20 <= marked, "marked wrongly: \(wrong)")
    #expect(missed.count * 10 < questions, "missed: \(missed)")
  }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `make -C apps/apple test`
Expected: FAIL to compile, "cannot find 'ClosingQuestion' in scope".

- [ ] **Step 4: Write the detector**

`ClosingQuestion.swift`:

```swift
import Foundation

/// The text a turn ended on: its last assistant message's text blocks, joined.
public struct ClosingText: Sendable, Equatable {
  /// `message.id` of that assistant message: what a dismissal remembers.
  public var messageID: String
  public var text: String

  public init(messageID: String, text: String) {
    self.messageID = messageID
    self.text = text
  }
}

/// The question a turn ended on, when it ended on one: "Want me to build it that way?".
///
/// A model often asks for a go-ahead in prose rather than through `AskUserQuestion`, and
/// such a turn waits for the person as surely as a permission request does. Rules, not a
/// model: Drakar makes no outgoing connection. The last sentence of the closing paragraph
/// is the question, once up to two trailers after it are set aside; an earlier question
/// followed by more prose was answered by the prose.
public enum ClosingQuestion {
  /// Asks without a question mark, at the start of a sentence, lowercased.
  public static let asks = [
    "want me to", "should i ", "shall i ", "would you like", "do you want",
    "ready to proceed", "go ahead with", "which one do you", "which option do you",
    "which approach do you",
  ]
  /// Sentences that may follow a question without answering it: sign-offs, which close
  /// half of all turns and never ask on their own, and a recommendation.
  public static let trailers = [
    "let me know if", "feel free to", "happy to", "if you like, i can", "if you'd like, i can",
    "i'd recommend", "i recommend", "my recommendation", "i lean",
  ]
  /// What a row and a notification show at most.
  public static let maxLength = 140

  public static func detect(_ text: String) -> String? {
    let paragraphs = paragraphs(of: stripped(text))
    guard var closing = paragraphs.last else { return nil }
    if isList(closing) {
      guard paragraphs.count > 1 else { return nil }
      closing = paragraphs[paragraphs.count - 2]
    }
    var candidates = sentences(of: closing)[...]
    var setAside = 0
    while setAside < 2, let last = candidates.last, isTrailer(last) {
      candidates = candidates.dropLast()
      setAside += 1
    }
    guard let sentence = candidates.last, !isTrailer(sentence), isQuestion(sentence) else {
      return nil
    }
    return shortened(sentence)
  }

  /// Code, quotes and links taken out: a `?` in a regex, a URL or a quoted message is not
  /// the model asking.
  static func stripped(_ text: String) -> String {
    var text = text.replacingOccurrences(of: "\r\n", with: "\n")
    // An unclosed fence runs to the end: a reply cut off mid-block is code from there on.
    text = text.replacing(#/(?:```|~~~)[\s\S]*?(?:```|~~~|\z)/#, with: "\n\n")
    text = text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
      .joined(separator: "\n")
    text = text.replacing(#/`[^`\n]*`/#, with: "")
    return text.replacing(#/https?://\S+/#, with: "")
  }

  static func paragraphs(of text: String) -> [String] {
    text.split(separator: #/\n[ \t]*\n/#)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  static func isList(_ paragraph: String) -> Bool {
    paragraph.split(separator: "\n").allSatisfy { line in
      line.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/(?:[-*+]|\d+[.)])\s.*/#) != nil
    }
  }

  /// Every line break ends a sentence, and so does `.`, `?`, `!` (or their full-width
  /// forms) before a space or the end of the line.
  static func sentences(of paragraph: String) -> [String] {
    var sentences: [String] = []
    func add(_ raw: String) {
      let sentence = raw.trimmingCharacters(in: decoration)
      if !sentence.isEmpty { sentences.append(sentence) }
    }
    for line in paragraph.split(separator: "\n") {
      let characters = Array(line)
      var current = ""
      for (index, character) in characters.enumerated() {
        current.append(character)
        let atEnd = index + 1 == characters.count || characters[index + 1].isWhitespace
        if atEnd, ".?!？！。".contains(character) {
          add(current)
          current = ""
        }
      }
      add(current)
    }
    return sentences
  }

  /// Markdown emphasis, headings, list bullets and brackets around a sentence.
  static let decoration = CharacterSet.whitespacesAndNewlines.union(
    CharacterSet(charactersIn: "*_#-()[]\"“”"))

  static func isQuestion(_ sentence: String) -> Bool {
    if let last = sentence.last, last == "?" || last == "？" { return true }
    let lower = folded(sentence)
    return asks.contains { lower.hasPrefix($0) }
  }

  static func isTrailer(_ sentence: String) -> Bool {
    let lower = folded(sentence)
    return trailers.contains { lower.hasPrefix($0) }
  }

  /// Lowercased, with typographic apostrophes straight: models write "I’d" as often as "I'd".
  static func folded(_ sentence: String) -> String {
    sentence.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
  }

  static func shortened(_ sentence: String) -> String {
    let words = sentence.split(whereSeparator: \.isWhitespace)
    let collapsed = words.joined(separator: " ")
    guard collapsed.count > maxLength else { return collapsed }
    var shown = ""
    for word in words {
      let next = shown.isEmpty ? String(word) : shown + " " + word
      if next.count > maxLength - 1 { break }
      shown = next
    }
    return shown + "…"
  }
}
```

- [ ] **Step 5: Run the tests**

Run: `make -C apps/apple test`
Expected: PASS. If `aLongReplyIsReadQuickly` fails on time, replace the `Regex` literals in
`stripped` with `NSRegularExpression` (same patterns, `.dotMatchesLineSeparators` not
needed) and keep the test. If `meetsItsTargetsOnRealEndings` fails, read the printed texts and tune
`asks`, `trailers` or the stripping, never the fixture's labels, until it passes and every
other test still does. Add a hand-written test for each rule you add.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): the question a turn ended on, by rules measured on real endings"
```

---

### Task 2: The closing text of a live or replayed transcript

**Files:**
- Modify: `Packages/DrakarKit/Sources/DrakarKit/StreamMessage.swift` (`AssistantMessage`)
- Modify: `Packages/DrakarKit/Sources/DrakarKit/Transcript.swift`
- Test: `Packages/DrakarKit/Tests/DrakarKitTests/TranscriptTests.swift`,
  `Packages/DrakarKit/Tests/DrakarKitTests/HistoryTests.swift`

**Interfaces:**
- Consumes: `ClosingText` (Task 1).
- Produces:
  - `AssistantMessage.stopReason: String?`
  - `Transcript.TurnEnd` (`completed`, `failed`, `interrupted`), `Transcript.turnEnd: TurnEnd?`
  - `Transcript.closingText: ClosingText?`

- [ ] **Step 1: Write the failing tests**

Append to `TranscriptTests`:

```swift
  private func message(_ json: String) throws -> StreamMessage {
    try StreamMessage(line: Data(json.utf8))
  }

  private let asking =
    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Built. Want me to commit it?"}]}}"#
  private let succeeded =
    #"{"type":"result","subtype":"success","is_error":false,"result":"Built. Want me to commit it?"}"#

  @Test func aTurnThatEndedHasItsClosingText() throws {
    var transcript = Transcript()
    transcript.addPrompt("Build it")
    transcript.apply(try message(asking))
    #expect(transcript.closingText == nil)  // still running
    transcript.apply(try message(succeeded))
    #expect(transcript.turnEnd == .completed)
    #expect(
      transcript.closingText == ClosingText(messageID: "m1", text: "Built. Want me to commit it?"))
  }

  @Test func theCapturedTurnEndsOnItsText() throws {
    let closing = try #require(try transcript(.turnWithTool).closingText)
    #expect(closing.text == "Amiral.")
    #expect(!closing.messageID.isEmpty)
  }

  @Test func anInterruptedOrFailedTurnHasNone() throws {
    for result in [
      #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming"}"#,
      #"{"type":"result","subtype":"error_max_turns","is_error":true}"#,
    ] {
      var transcript = Transcript()
      transcript.addPrompt("Build it")
      transcript.apply(try message(asking))
      transcript.apply(try message(result))
      #expect(transcript.closingText == nil)
    }
  }

  @Test func aPromptAfterItTakesItAway() throws {
    var transcript = Transcript()
    transcript.addPrompt("Build it")
    transcript.apply(try message(asking))
    transcript.apply(try message(succeeded))
    transcript.addPrompt("yes")
    #expect(transcript.turnEnd == nil)
    #expect(transcript.closingText == nil)
  }

  @Test func aTurnEndingOnAToolCallHasNone() throws {
    var transcript = Transcript()
    transcript.addPrompt("Build it")
    transcript.apply(
      try message(
        #"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Should I run it?"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#
      ))
    transcript.apply(try message(succeeded))
    #expect(transcript.closingText == nil)
  }

  /// A subagent's words are its own; the turn closes on the main thread's.
  @Test func aSubagentsQuestionIsNotTheTurns() throws {
    var transcript = Transcript()
    transcript.addPrompt("Build it")
    transcript.apply(
      try message(
        #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"All done."}]}}"#
      ))
    transcript.apply(
      try message(
        #"{"type":"assistant","parent_tool_use_id":"t9","message":{"id":"s1","content":[{"type":"text","text":"Should I continue?"}]}}"#
      ))
    transcript.apply(try message(succeeded))
    #expect(transcript.closingText == ClosingText(messageID: "m1", text: "All done."))
  }

  @Test func joinsTheTextBlocksOfTheLastMessage() throws {
    var transcript = Transcript()
    transcript.addPrompt("Build it")
    transcript.apply(
      try message(
        #"{"type":"assistant","message":{"id":"m0","content":[{"type":"text","text":"Earlier."}]}}"#
      ))
    transcript.apply(
      try message(
        #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Built."},{"type":"thinking","thinking":"hm"},{"type":"text","text":"Push it?"}]}}"#
      ))
    transcript.apply(try message(succeeded))
    #expect(transcript.closingText == ClosingText(messageID: "m1", text: "Built.\n\nPush it?"))
  }
```

Append to `HistoryTests`:

```swift
  /// A transcript has no `result`: a turn that ended says so on its message, block by block.
  @Test func historyKnowsATurnThatEnded() {
    let transcript = history([
      #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
      #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""}]}}"#,
      #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Built. Want me to commit it?"}]}}"#,
    ])
    #expect(transcript.turnEnd == .completed)
    #expect(transcript.closingText?.messageID == "m1")
    #expect(transcript.closingText?.text == "Built. Want me to commit it?")
  }

  @Test func historyWithoutAStopReasonDoesNotGuess() {
    let transcript = history([
      #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
      #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Want me to commit it?"}]}}"#,
    ])
    #expect(transcript.closingText == nil)
  }

  @Test func anInterruptInHistoryHasNone() {
    let transcript = history([
      #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
      #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Want me to commit it?"}]}}"#,
      #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}"#,
    ])
    #expect(transcript.closingText == nil)
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `make -C apps/apple test`
Expected: FAIL to compile, "value of type 'Transcript' has no member 'closingText'".

- [ ] **Step 3: Read `stop_reason` on an assistant message**

In `StreamMessage.swift`, `AssistantMessage`:

```swift
  /// The request's tokens. Every block of one message repeats the same object.
  public var usage: TokenUsage?
  /// `end_turn` on a message that ended the turn, `tool_use` on one that calls a tool.
  /// Transcript files repeat it on every block line; the live stream may leave it null.
  public var stopReason: String?
```

and in its `init?`, after `usage = …`:

```swift
    stopReason = message["stop_reason"]?.stringValue
```

- [ ] **Step 4: Record how the turn ended, and find its closing text**

In `Transcript.swift`, next to `ToolResult`:

```swift
  /// How the newest turn ended.
  public enum TurnEnd: Sendable, Equatable {
    case completed, failed, interrupted
  }
```

Next to `lastResult`:

```swift
  /// How the newest turn ended; nil while it runs, before any turn, and after a prompt.
  /// Live, from its `result`; in history, which has none, from `stop_reason: end_turn`.
  public private(set) var turnEnd: TurnEnd?
```

In `addPrompt`, after `isRunning = running`:

```swift
    turnEnd = nil
```

In `apply(_:)`, `case .assistant(let assistant):`, before `let index = blockCount[…]`:

```swift
      if assistant.parentToolUseID == nil, assistant.stopReason == "end_turn" {
        turnEnd = .completed
      }
```

In `case .result(let result):`, after `lastResult = result`:

```swift
      turnEnd = result.wasInterrupted ? .interrupted : result.isError ? .failed : .completed
```

After `lastPrompt`:

```swift
  /// The text the newest turn ended on, once it ended normally with nothing waiting: the
  /// main thread's last entry is text, and it and the text blocks of the same message
  /// before it make the closing text. Nil when it ended on a tool call or a note.
  public var closingText: ClosingText? {
    guard turnEnd == .completed, !isRunning, pendingPermissions.isEmpty else { return nil }
    var messageID: String?
    var parts: [String] = []
    scan: for entry in entries.reversed() where entry.parentToolUseID == nil {
      switch entry.kind {
      case .thinking: continue
      case .text(let text):
        let id = Self.messageID(ofEntry: entry.id)
        if let messageID, id != messageID { break scan }
        messageID = id
        parts.insert(text, at: 0)
      case .prompt, .tool, .notice: break scan
      }
    }
    let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let messageID, !text.isEmpty else { return nil }
    return ClosingText(messageID: messageID, text: text)
  }

  /// A block's entry is keyed `<message id>#<block index>`.
  static func messageID(ofEntry id: String) -> String {
    String(id[..<(id.lastIndex(of: "#") ?? id.endIndex)])
  }
```

- [ ] **Step 5: Run the tests**

Run: `make -C apps/apple test`
Expected: PASS, every suite.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): a transcript knows how its newest turn ended and the text it ended on"
```

---

### Task 3: The closing question of a transcript file's tail

**Files:**
- Modify: `Packages/DrakarKit/Sources/DrakarKit/ContextUsage.swift` (`TranscriptTail`)
- Modify: `Packages/DrakarKit/Sources/DrakarKit/SessionIndex.swift` (`SessionSummary`, `summarize`)
- Test: `Packages/DrakarKit/Tests/DrakarKitTests/ContextUsageTests.swift`

**Interfaces:**
- Consumes: `ClosingText`, `ClosingQuestion.detect` (Task 1).
- Produces: `TranscriptTail.closingText: ClosingText?`;
  `SessionSummary.closingQuestion: String?`, `SessionSummary.closingMessageID: String?`.

- [ ] **Step 1: Write the failing tests**

Append to `ContextUsageTests`:

```swift
  private let endedOnAQuestion = [
    #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
    #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Built."}]}}"#,
    #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Want me to commit it?"}]}}"#,
    #"{"type":"system","subtype":"turn_duration"}"#,
    #"{"type":"last-prompt","lastPrompt":"Build it"}"#,
  ]

  @Test func theTailKnowsTheTextATurnEndedOn() {
    #expect(
      tail(endedOnAQuestion).closingText
        == ClosingText(messageID: "m1", text: "Built.\n\nWant me to commit it?"))
  }

  @Test func aPromptAfterTheEndTakesItAway() {
    let answered = endedOnAQuestion + [#"{"type":"user","message":{"role":"user","content":"yes"}}"#]
    #expect(tail(answered).closingText == nil)
  }

  @Test func aTurnThatCalledAToolHasNone() {
    #expect(
      tail([
        #"{"type":"assistant","message":{"id":"m","stop_reason":"tool_use","content":[{"type":"text","text":"Should I?"}]}}"#
      ]).closingText == nil)
  }

  /// "You've hit your session limit" is the CLI talking, not the model asking.
  @Test func aSyntheticTurnHasNone() {
    #expect(
      tail([
        #"{"type":"assistant","message":{"id":"m","model":"<synthetic>","stop_reason":"end_turn","content":[{"type":"text","text":"Limit reached. Upgrade?"}]}}"#
      ]).closingText == nil)
  }

  @Test func aSubagentsEndIsNotTheSessions() {
    let lines =
      endedOnAQuestion + [
        #"{"type":"assistant","isSidechain":true,"message":{"id":"s","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}"#
      ]
    #expect(tail(lines).closingText?.messageID == "m1")
  }

  @Test func aSummaryCarriesTheQuestion() throws {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "drakar-closing-\(UUID().uuidString).jsonl")
    try Data(endedOnAQuestion.joined(separator: "\n").utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let account = ClaudeAccount(directory: file.deletingLastPathComponent(), isDefault: false)
    let summary = try #require(SessionIndex.summary(of: file, account: account))
    #expect(summary.closingQuestion == "Want me to commit it?")
    #expect(summary.closingMessageID == "m1")
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `make -C apps/apple test`
Expected: FAIL to compile, "value of type 'TranscriptTail' has no member 'closingText'".

- [ ] **Step 3: Read the closing text from the tail**

In `ContextUsage.swift`, inside `TranscriptTail`, after `isAwaitingToolResult`:

```swift
  /// The text the newest main-thread turn ended on, when its last message ended the turn
  /// (`end_turn`) and nothing was sent after it: what a row whose history is not read
  /// shows its question from. Every block of a message is its own line, newest first here.
  public var closingText: ClosingText? {
    var messageID: String?
    var parts: [String] = []
    for line in newestFirst {
      guard let json = try? JSONValue.parse(line), json["isSidechain"]?.boolValue != true
      else { continue }
      switch json["type"]?.stringValue {
      case "user":
        if json["isMeta"]?.boolValue == true { continue }
        // Newer than any assistant line: the person answered, or interrupted.
        guard messageID != nil else { return nil }
        return Self.closing(messageID, parts)
      case "assistant":
        guard let message = json["message"], let id = message["id"]?.stringValue else {
          continue
        }
        if let messageID, id != messageID { return Self.closing(messageID, parts) }
        if messageID == nil {
          guard message["stop_reason"]?.stringValue == "end_turn",
            message["model"]?.stringValue != Self.syntheticModel
          else { return nil }
          messageID = id
        }
        for block in (message["content"]?.arrayValue ?? []).reversed()
        where block["type"]?.stringValue == "text" {
          if let text = block["text"]?.stringValue { parts.insert(text, at: 0) }
        }
      default: continue
      }
    }
    return Self.closing(messageID, parts)
  }

  private static func closing(_ messageID: String?, _ parts: [String]) -> ClosingText? {
    let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let messageID, !text.isEmpty else { return nil }
    return ClosingText(messageID: messageID, text: text)
  }
```

- [ ] **Step 4: Carry the question in a summary**

In `SessionIndex.swift`, `SessionSummary`, after `awaitsToolResult`:

```swift
  /// The question the newest turn ended on (`ClosingQuestion`), while nothing was sent
  /// after it, and the id of the message that asked it.
  public var closingQuestion: String?
  public var closingMessageID: String?
```

In `summarize`, after `summary.awaitsToolResult = tail.isAwaitingToolResult`:

```swift
    if let closing = tail.closingText, let question = ClosingQuestion.detect(closing.text) {
      summary.closingQuestion = question
      summary.closingMessageID = closing.messageID
    }
```

- [ ] **Step 5: Run the tests**

Run: `make -C apps/apple test`
Expected: PASS, every suite.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): a session summary carries the question its last turn ended on"
```

---

### Task 4: `ProjectSession.question` — derived, dismissable, remembered

**Files:**
- Modify: `Drakar/Views/SettingsView.swift` (keys and `AttentionChoice` only; the pane is Task 7)
- Modify: `Drakar/Services/ClaudeSession.swift` (`onPromptSent`)
- Modify: `Drakar/Services/Project.swift`
- Test: `DrakarTests/AttentionTests.swift`

**Interfaces:**
- Consumes: `Transcript.closingText`, `SessionSummary.closingQuestion` / `closingMessageID`,
  `ClosingQuestion.detect`.
- Produces:
  - `PreferenceKey.recognisesQuestions`, `.badgesPermissions`, `.badgesQuestions`,
    `.notifiesPermissions`, `.notifiesQuestions` (strings as in Global Constraints)
  - `enum AttentionChoice { static var defaults: UserDefaults; static var recognisesQuestions, badgesPermissions, badgesQuestions, notifiesPermissions, notifiesQuestions, notifiesTurnEnds: Bool }`
  - `ClaudeSession.onPromptSent: (() -> Void)?`
  - `ProjectSession.question: String?`, `ProjectSession.dismissedQuestion: String?`,
    `ProjectSession.dismissQuestion()`
  - `Project.dismissQuestion(_ item: ProjectSession)`
  - `StoredProject.dismissedQuestions: [String: String]?`
  - `Project.waitingCount` now counts rows waiting **or** asked; `nextNeedingAttention()`
    goes waiting, then asked, then unread.

- [ ] **Step 1: Write the failing tests**

Add a new suite to `AttentionTests.swift`:

```swift
@MainActor
@Suite("A session that asked a question")
struct QuestionTests {
  init() {
    // An empty scratch suite: every switch reads as its default, whatever the person set.
    AttentionChoice.defaults = UserDefaults(suiteName: "drakar-tests-\(UUID().uuidString)")!
  }

  private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-question-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// A stand-in `claude` that answers any prompt with one turn ending on a question.
  private func asking(in folder: URL) throws -> URL {
    let fake = folder.appending(path: "claude")
    let lines = [
      #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Built. Want me to commit it?"}]}}"#,
      #"{"type":"result","subtype":"success","is_error":false,"result":"Built. Want me to commit it?"}"#,
    ]
    let script = "#!/bin/sh\n" + lines.map { "echo '\($0)'" }.joined(separator: "\n")
      + "\ncat > /dev/null\n"
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return fake
  }

  private func askedSession() async throws -> (Project, ProjectSession) {
    let folder = try folder()
    let project = Project(folder: folder)
    let item = project.newSession()
    item.session.executableOverride = try asking(in: folder)
    item.session.send("Build it")
    for _ in 0..<50 where item.session.transcript.turnEnd == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    return (project, item)
  }

  @Test func aTurnEndingOnAQuestionAsks() async throws {
    let (project, item) = try await askedSession()
    defer { project.stopAll() }
    #expect(item.question == "Want me to commit it?")
    #expect(project.waitingCount == 1)
  }

  /// Looking is not answering.
  @Test func selectingTheRowKeepsIt() async throws {
    let (project, item) = try await askedSession()
    defer { project.stopAll() }
    let other = project.newSession()
    project.select(item)
    #expect(item.question != nil)
    _ = other
  }

  @Test func aPromptAnswersIt() async throws {
    let (project, item) = try await askedSession()
    defer { project.stopAll() }
    item.session.send("yes")
    #expect(item.question == nil)
  }

  @Test func dismissingQuietsIt() async throws {
    let (project, item) = try await askedSession()
    defer { project.stopAll() }
    project.dismissQuestion(item)
    #expect(item.question == nil)
    #expect(item.dismissedQuestion == "m1")
    #expect(project.waitingCount == 0)
  }

  @Test func endingTheSessionClearsIt() async throws {
    let (project, item) = try await askedSession()
    project.end(item)
    #expect(item.question == nil)
  }

  @Test func turningRecognitionOffClearsIt() async throws {
    let (project, item) = try await askedSession()
    defer { project.stopAll() }
    AttentionChoice.defaults.set(false, forKey: PreferenceKey.recognisesQuestions)
    #expect(item.question == nil)
  }

  @Test func theNextRowNeedingYouIsAnAskedOneBeforeAnUnreadOne() async throws {
    let (project, item) = try await askedSession()
    defer { project.stopAll() }
    let unread = project.newSession()  // selected; rows: unread, item
    unread.isUnread = true
    let third = project.newSession()  // selected; rows: third, unread, item
    #expect(project.nextNeedingAttention()?.id == item.id)
    _ = third
  }

  /// A restored row asks from its transcript's tail, before its history is read, and a
  /// dismissal survives the relaunch for that message and no other.
  @Test func aRestoredRowAsksUnlessThatQuestionWasDismissed() async throws {
    let folder = try folder()
    let file = folder.appending(path: "s1.jsonl")
    try Data(
      [
        #"{"type":"user","cwd":"/tmp","message":{"role":"user","content":"Build it"}}"#,
        #"{"type":"assistant","message":{"id":"m2","stop_reason":"end_turn","content":[{"type":"text","text":"Want me to commit it?"}]}}"#,
      ].joined(separator: "\n").utf8
    ).write(to: file)
    let target = ResumeTarget(
      sessionID: "s1", cwd: folder.path(percentEncoded: false),
      file: file.path(percentEncoded: false), accountDirectory: folder.path(percentEncoded: false),
      accountIsDefault: false)

    func restored(dismissing id: String?) async throws -> ProjectSession {
      let stored = StoredProject(
        sessions: [target], selected: nil, dismissedQuestions: id.map { ["s1": $0] })
      let project = Project(folder: folder, restoring: stored)
      let item = try #require(project.sessions.first)
      for _ in 0..<50 where item.preview == nil {
        try await Task.sleep(for: .milliseconds(100))
      }
      return item
    }

    #expect(try await restored(dismissing: nil).question == "Want me to commit it?")
    #expect(try await restored(dismissing: "m2").question == nil)
    #expect(try await restored(dismissing: "m1").question == "Want me to commit it?")
  }

  @Test func aDismissalIsStoredUnderItsSession() throws {
    let stored = StoredProject(sessions: [], selected: nil, dismissedQuestions: ["s1": "m2"])
    let data = try JSONEncoder().encode(stored)
    #expect(try JSONDecoder().decode(StoredProject.self, from: data) == stored)
    // A window stored before the field existed still decodes.
    let old = try JSONDecoder().decode(StoredProject.self, from: Data(#"{"sessions":[]}"#.utf8))
    #expect(old.dismissedQuestions == nil)
  }
}
```

Note on restore: `Project.init` selects the first row and starts reading its history, after
which `unloadedPreview` is nil and the question comes from the transcript instead. Both
paths must give the same answer, so `aRestoredRowAsksUnlessThatQuestionWasDismissed` holds
whichever lands first: the line carries `stop_reason: end_turn`, which Task 2 reads in
history and Task 3 in the tail.

- [ ] **Step 2: Run them to see them fail**

Run: `make -C apps/apple test-app`
Expected: FAIL to compile, "cannot find 'AttentionChoice' in scope".

- [ ] **Step 3: Keys and `AttentionChoice`**

In `SettingsView.swift`, inside `enum PreferenceKey`, after `notifiesTurnEnds`:

```swift
  /// Whether a turn that ends on a question marks its row "Asked you".
  static let recognisesQuestions = "drakar.recognisesQuestions"
  /// What the Dock badge counts.
  static let badgesPermissions = "drakar.badges.permissions"
  static let badgesQuestions = "drakar.badges.questions"
  /// What posts a notification.
  static let notifiesPermissions = "drakar.notifies.permissions"
  static let notifiesQuestions = "drakar.notifies.questions"
```

After `enum ClaudeChoice { … }`:

```swift
/// What the Attention pane picked. Every switch but the ended-turn one is on until it is
/// turned off.
enum AttentionChoice {
  /// Where the choices are read from; a scratch suite in tests, never the real one.
  static var defaults = UserDefaults.standard

  static var recognisesQuestions: Bool { flag(PreferenceKey.recognisesQuestions) }
  static var badgesPermissions: Bool { flag(PreferenceKey.badgesPermissions) }
  static var badgesQuestions: Bool { flag(PreferenceKey.badgesQuestions) }
  static var notifiesPermissions: Bool { flag(PreferenceKey.notifiesPermissions) }
  static var notifiesQuestions: Bool { flag(PreferenceKey.notifiesQuestions) }
  static var notifiesTurnEnds: Bool { defaults.bool(forKey: PreferenceKey.notifiesTurnEnds) }

  private static func flag(_ key: String) -> Bool {
    defaults.object(forKey: key) as? Bool ?? true
  }
}
```

- [ ] **Step 4: Say when a prompt went**

In `ClaudeSession.swift`, after `onPermissionsChanged`:

```swift
  /// A prompt was sent: whatever the last turn asked is answered.
  @ObservationIgnored var onPromptSent: (() -> Void)?
```

In `send(_:context:)`, after `transcript.addPrompt(text, context: label)`:

```swift
    onPromptSent?()
```

- [ ] **Step 5: The question, derived**

In `Project.swift`, `ProjectSession`, after `preview`:

```swift
  /// The message id of the question the person dismissed: that one stays quiet, the next
  /// one does not.
  var dismissedQuestion: String?
  /// `ClosingQuestion.detect` of the newest closing text, kept until the text changes: a
  /// row asks on every draw, and a reply can be long.
  @ObservationIgnored private var detected: (key: String, question: String?)?
```

After `waitingFor`:

```swift
  /// The question the newest turn ended on, while it waits for an answer: nil once a
  /// prompt went, after Dismiss, once the process ended, and for a row held read-only.
  var question: String? { asked?.question }

  /// Quiets `question` until a newer one.
  func dismissQuestion() {
    dismissedQuestion = asked?.messageID
  }

  private var asked: (messageID: String, question: String)? {
    guard AttentionChoice.recognisesQuestions, !session.isReadOnly else { return nil }
    switch session.phase {
    case .exited, .failed: return nil
    case .idle, .starting, .ready: break
    }
    let found: (messageID: String, question: String)?
    if let preview = unloadedPreview {
      found = preview.closingMessageID.flatMap { id in preview.closingQuestion.map { (id, $0) } }
    } else if let closing = session.transcript.closingText {
      found = detect(closing).map { (closing.messageID, $0) }
    } else {
      found = nil
    }
    guard let found, found.messageID != dismissedQuestion else { return nil }
    return found
  }

  private func detect(_ closing: ClosingText) -> String? {
    let key = "\(closing.messageID)#\(closing.text.utf8.count)"
    if let detected, detected.key == key { return detected.question }
    let question = ClosingQuestion.detect(closing.text)
    detected = (key, question)
    return question
  }
```

- [ ] **Step 6: Stored, restored, counted, dismissed**

`StoredProject`:

```swift
struct StoredProject: Codable, Equatable {
  var sessions: [ResumeTarget] = []
  var selected: String?
  /// Per session id, the message id of the question dismissed. Optional so that a window
  /// stored before the field existed still decodes.
  var dismissedQuestions: [String: String]?
}
```

`Project.init`, replace the loop body's append:

```swift
      let item = make(ClaudeSession(folder: folder, resuming: target))
      item.dismissedQuestion = stored?.dismissedQuestions?[target.sessionID]
      sessions.append(item)
```

`nextNeedingAttention()`:

```swift
  /// The next row after the selected one that wants the person: waiting on a permission
  /// first, then asked, then unread, wrapping. Never the selected row.
  func nextNeedingAttention() -> ProjectSession? {
    let start = sessions.firstIndex { $0.id == selectedID } ?? -1
    let ordered = sessions[(start + 1)...] + sessions[..<max(start, 0)]
    return ordered.first { $0.waitingFor != nil } ?? ordered.first { $0.question != nil }
      ?? ordered.first { $0.isUnread }
  }

  /// Quiets the row's question until it asks another.
  func dismissQuestion(_ item: ProjectSession) {
    item.dismissQuestion()
    Attention.shared.refresh()
  }
```

`waitingCount`:

```swift
  /// Rows that want the person, waiting on a permission request or asked a question: the
  /// group's header.
  var waitingCount: Int { sessions.count { $0.waitingFor != nil || $0.question != nil } }
```

`stored`:

```swift
  var stored: StoredProject {
    let dismissed = sessions.compactMap { item -> (String, String)? in
      guard let id = item.sessionID, let message = item.dismissedQuestion else { return nil }
      return (id, message)
    }
    return StoredProject(
      sessions: sessions.compactMap(\.session.savedTarget),
      selected: selected?.session.savedTarget?.sessionID,
      dismissedQuestions: dismissed.isEmpty
        ? nil : Dictionary(dismissed, uniquingKeysWith: { first, _ in first }))
  }
```

`make(_:)`, add after `onPermissionsChanged`, and refresh on stop:

```swift
    session.onPromptSent = { Attention.shared.refresh() }
    session.onStopped = { [weak self, weak item] in
      Attention.shared.refresh()
      guard let self, let item, item.id != self.selectedID, item.hasStopped else { return }
      item.isUnread = true
    }
```

(replacing the existing `onStopped` closure).

`readPreview(_:)`: a restored row's question arrives with its preview, so the badge
follows it. Replace `item?.preview = summary` with:

```swift
      item?.preview = summary
      Attention.shared.refresh()
```

- [ ] **Step 7: Run the tests**

Run: `make -C apps/apple test-app`
Expected: PASS, including the existing `AttentionTests` and `ClosingTests`.

- [ ] **Step 8: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a session knows the question it ended on until it is answered or dismissed"
```

---

### Task 5: Attention — the badge, the notification rule, question notifications

**Files:**
- Modify: `Drakar/Services/Attention.swift`
- Test: `DrakarTests/AttentionTests.swift`

**Interfaces:**
- Consumes: `ProjectSession.question`, `AttentionChoice` (Task 4).
- Produces:
  - `static func Attention.count(_ items: [ProjectSession], badgesPermissions: Bool, badgesQuestions: Bool) -> Int`
  - `static func Attention.isInView(appIsActive: Bool, windowIsKey: Bool, rowIsSelected: Bool) -> Bool`
  - `waitingCount` honours the badge switches; `turnEnded` posts the question.

- [ ] **Step 1: Write the failing tests**

Append to `QuestionTests` (Task 4's suite):

```swift
  @Test func theBadgeCountsWhatItIsToldTo() async throws {
    let (project, item) = try await askedSession()
    defer { project.stopAll() }
    #expect(Attention.count([item], badgesPermissions: true, badgesQuestions: true) == 1)
    #expect(Attention.count([item], badgesPermissions: true, badgesQuestions: false) == 0)
  }

  /// Notified unless it is the row the person is looking at, in the window they are in.
  @Test func notifiesUnlessInView() {
    #expect(Attention.isInView(appIsActive: true, windowIsKey: true, rowIsSelected: true))
    #expect(!Attention.isInView(appIsActive: true, windowIsKey: false, rowIsSelected: true))
    #expect(!Attention.isInView(appIsActive: true, windowIsKey: true, rowIsSelected: false))
    #expect(!Attention.isInView(appIsActive: false, windowIsKey: true, rowIsSelected: true))
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `make -C apps/apple test-app`
Expected: FAIL to compile, "type 'Attention' has no member 'count'".

- [ ] **Step 3: Rewrite `Attention`'s counting and posting**

Replace the class's members above `userNotificationCenter(_:didReceive:)` with:

```swift
  static let shared = Attention()

  /// Asked once; every post awaits the same answer, so one made during the prompt waits.
  private var authorization: Task<Bool, Never>?
  /// Sessions with a notification that wants an answer (a permission, a question) on
  /// screen: withdrawn when the answer comes, however it comes.
  private var asking: Set<String> = []

  var waitingCount: Int {
    Self.count(
      OpenSessions.shared.projects.values.flatMap(\.sessions),
      badgesPermissions: AttentionChoice.badgesPermissions,
      badgesQuestions: AttentionChoice.badgesQuestions)
  }

  /// What the Dock badge counts of `items`: their waiting requests and their questions, as
  /// the Attention pane says.
  static func count(
    _ items: [ProjectSession], badgesPermissions: Bool, badgesQuestions: Bool
  ) -> Int {
    items.reduce(0) { total, item in
      total + (badgesPermissions ? item.session.transcript.pendingPermissions.count : 0)
        + (badgesQuestions && item.question != nil ? 1 : 0)
    }
  }

  /// The row the person is looking at, in the window they are in: nothing to tell them.
  static func isInView(appIsActive: Bool, windowIsKey: Bool, rowIsSelected: Bool) -> Bool {
    appIsActive && windowIsKey && rowIsSelected
  }

  /// The badge follows, and a notification whose session no longer wants anything goes.
  func refresh() {
    let count = waitingCount
    NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
    let answered = asking.filter { id in
      guard let (_, item) = OpenSessions.shared.locate(id) else { return true }
      return item.waitingFor == nil && item.question == nil
    }
    guard !answered.isEmpty else { return }
    asking.subtract(answered)
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: Array(answered))
  }

  /// A session's waiting requests changed.
  func permissionsChanged(_ item: ProjectSession?) {
    refresh()
  }

  func permissionRequested(_ item: ProjectSession, in project: Project) {
    refresh()
    guard AttentionChoice.notifiesPermissions, !inView(item, in: project),
      let wants = item.waitingFor
    else { return }
    post(
      title: item.displayTitle, body: String(localized: "Wants to use \(wants)"), item: item,
      wantsAnswer: true)
  }

  func turnEnded(_ item: ProjectSession, in project: Project) {
    refresh()
    guard !inView(item, in: project) else { return }
    if let question = item.question {
      guard AttentionChoice.notifiesQuestions else { return }
      post(title: item.displayTitle, body: question, item: item, wantsAnswer: true)
    } else if AttentionChoice.notifiesTurnEnds {
      post(
        title: item.displayTitle, body: String(localized: "Finished its turn."), item: item,
        wantsAnswer: false)
    }
  }

  private func inView(_ item: ProjectSession, in project: Project) -> Bool {
    Self.isInView(
      appIsActive: NSApp.isActive, windowIsKey: project.workspace.window?.isKeyWindow == true,
      rowIsSelected: project.selectedID == item.id)
  }

  private func post(title: String, body: String, item: ProjectSession, wantsAnswer: Bool) {
    guard let sessionID = item.sessionID else { return }
    if wantsAnswer { asking.insert(sessionID) }
    let center = UNUserNotificationCenter.current()
    let asked =
      authorization
      ?? Task { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
    authorization = asked
    Task {
      _ = await asked.value
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.userInfo = ["sessionID": sessionID]
      try? await center.add(
        UNNotificationRequest(identifier: sessionID, content: content, trigger: nil))
    }
  }
```

Update the class's doc comment's first sentence to: "What wants the person while they
look elsewhere: the Dock badge for permission requests and questions waiting in any window,
and a local notification unless the session is the one in front of them."

- [ ] **Step 4: Run the tests**

Run: `make -C apps/apple test-app`
Expected: PASS, including `AttentionBadgeTests`.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a question badges and notifies like a permission request, unless it is in front of you" -m "Notifications used to wait for Drakar to be in the background, which missed the case that costs the most: the person is in Drakar, in another project's window. Every kind now posts unless the session is the row shown in the key window."
```

---

### Task 6: The sidebar and the Session menu

**Files:**
- Modify: `Drakar/Views/ProjectSidebar.swift`
- Modify: `Drakar/DrakarApp.swift` (`SessionCommands`)
- Test: `DrakarTests/AttentionTests.swift`

**Interfaces:**
- Consumes: `ProjectSession.question`, `Project.dismissQuestion(_:)` (Task 4).
- Produces: `RowState.asked`; `StateDot` view.

- [ ] **Step 1: Write the failing test**

Append to `QuestionTests`:

```swift
  @Test func anAskedRowSaysSo() async throws {
    let (project, item) = try await askedSession()
    defer { project.stopAll() }
    #expect(RowState(item) == .asked)
    #expect(RowState.asked.label == "Asked you")
  }
```

- [ ] **Step 2: Run it to see it fail**

Run: `make -C apps/apple test-app`
Expected: FAIL to compile, "type 'RowState' has no member 'asked'".

- [ ] **Step 3: The state, its dot, its line**

In `ProjectSidebar.swift`, `RowState`:

```swift
  case working, runningTool, waiting, asked, idle, notStarted, stopped, ended, elsewhere
```

In `init(_ item:)`, after the `waitingFor` branch:

```swift
    } else if item.question != nil {
      self = .asked
```

In `label`: `case .asked: String(localized: "Asked you")`. In `tint`:
`case .waiting, .asked: .blue` (replacing `case .waiting: .blue`).

Add below `RowState`:

```swift
/// A row's state as a dot: filled, or a ring for a question, so that waiting on a
/// permission and asked read apart at a glance in the same blue.
struct StateDot: View {
  let state: RowState

  var body: some View {
    Group {
      if state == .asked {
        Circle().strokeBorder(state.tint, lineWidth: 1.5)
      } else {
        Circle().fill(state.tint)
      }
    }
    .frame(width: 7, height: 7)
    .help(state.label)
  }
}
```

In `SessionRow.body`, replace the `Circle()…help(state.label)` chain with
`StateDot(state: state)`. In `SummaryRow.body`, replace
`Circle().fill(state.tint).frame(width: 7, height: 7).help(state.label)` with
`StateDot(state: state)`.

In `SessionRow.detail`:

```swift
    if let lead = item.waitingFor ?? item.question ?? item.stopReason { parts.append(lead) }
```

In `SessionListView`, so rows redraw when the switch flips in Settings, add:

```swift
  @AppStorage(PreferenceKey.recognisesQuestions) private var recognisesQuestions = true
```

and read it in `body` before `List` (`let _ = recognisesQuestions`).

In the header's count, change `.help("Waiting for you: \(project.waitingCount)")` to
`.help("Waiting for you or asked: \(project.waitingCount)")`.

In `menu(for:)`, first:

```swift
    if item.question != nil {
      Button("Dismiss Question") { project.dismissQuestion(item) }
      Divider()
    }
```

- [ ] **Step 4: The Session menu**

In `DrakarApp.swift`, `SessionCommands.body`, after Next Session Needing You:

```swift
    Button("Dismiss Question") {
      if let project, let item = project.selected { project.dismissQuestion(item) }
    }
    .keyboardShortcut("d", modifiers: [.command, .option])
    .disabled(project?.selected?.question == nil)
```

- [ ] **Step 5: Run the tests**

Run: `make -C apps/apple test-app`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): an asked row shows its question, and ⌥⌘D dismisses it"
```

---

### Task 7: The Attention settings pane

**Files:**
- Modify: `Drakar/Views/SettingsView.swift`
- Test: `DrakarTests/SettingsPaneTests.swift`

**Interfaces:**
- Consumes: the keys and `AttentionChoice` (Task 4).
- Produces: `SettingsPane.attention`, `AttentionPane`.

- [ ] **Step 1: Write the failing tests**

In `SettingsPaneTests`, replace `keepsPaneIdentifiersStable`'s expectation:

```swift
    #expect(SettingsPane.allCases.map(\.rawValue) == ["general", "attention", "about"])
```

and add:

```swift
  /// Every switch but the ended-turn one starts on, and the ended-turn one kept its key
  /// when it moved panes.
  @Test @MainActor func attentionStartsOnExceptForEndedTurns() {
    let saved = AttentionChoice.defaults
    defer { AttentionChoice.defaults = saved }
    AttentionChoice.defaults = UserDefaults(suiteName: "drakar-tests-\(UUID().uuidString)")!
    #expect(AttentionChoice.recognisesQuestions)
    #expect(AttentionChoice.badgesPermissions && AttentionChoice.badgesQuestions)
    #expect(AttentionChoice.notifiesPermissions && AttentionChoice.notifiesQuestions)
    #expect(!AttentionChoice.notifiesTurnEnds)
    AttentionChoice.defaults.set(true, forKey: "drakar.notifiesTurnEnds")
    #expect(AttentionChoice.notifiesTurnEnds)
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `make -C apps/apple test-app`
Expected: FAIL, the identifiers are `["general", "about"]`.

- [ ] **Step 3: The pane**

`SettingsPane`: add `case attention` between `general` and `about`; title
`case .attention: "Attention"`; image `case .attention: "bell.badge"`. Replace the enum's
doc comment with:

```swift
/// The panes, and the order they sit in: General, Attention, About.
///
/// An entitlement pane joins only when something is actually sold: before a StoreKit
/// product is registered it would be a button that fails.
///
/// About stays last, because it answers a question you only ask with a bug report open.
```

`SettingsView.body`: add `case .attention: AttentionPane()`.

In `GeneralPane`, delete the `notifiesTurnEnds` `@AppStorage` and its whole `Section`.

Add after `GeneralPane`:

```swift
/// What wants the person, and how loudly: the Dock badge and notifications, per kind.
struct AttentionPane: View {
  @AppStorage(PreferenceKey.recognisesQuestions) private var recognisesQuestions = true
  @AppStorage(PreferenceKey.badgesPermissions) private var badgesPermissions = true
  @AppStorage(PreferenceKey.badgesQuestions) private var badgesQuestions = true
  @AppStorage(PreferenceKey.notifiesPermissions) private var notifiesPermissions = true
  @AppStorage(PreferenceKey.notifiesQuestions) private var notifiesQuestions = true
  @AppStorage(PreferenceKey.notifiesTurnEnds) private var notifiesTurnEnds = false

  var body: some View {
    Form {
      Section {
        Toggle("Recognise questions at the end of a turn", isOn: $recognisesQuestions)
          .accessibilityIdentifier("settings.recognisesQuestions")
      } footer: {
        Text(
          "A session that ends its reply on a question, such as “Want me to build it that way?”, is marked “Asked you” until you answer it or dismiss it (⌥⌘D)."
        )
      }
      Section("Dock badge") {
        Toggle("Permission requests", isOn: $badgesPermissions)
          .accessibilityIdentifier("settings.badgesPermissions")
        Toggle("Questions", isOn: $badgesQuestions)
          .disabled(!recognisesQuestions)
          .accessibilityIdentifier("settings.badgesQuestions")
      }
      Section {
        Toggle("Permission requests", isOn: $notifiesPermissions)
          .accessibilityIdentifier("settings.notifiesPermissions")
        Toggle("Questions", isOn: $notifiesQuestions)
          .disabled(!recognisesQuestions)
          .accessibilityIdentifier("settings.notifiesQuestions")
        Toggle("Finished turns", isOn: $notifiesTurnEnds)
          .accessibilityIdentifier("settings.notifiesTurnEnds")
      } header: {
        Text("Notifications")
      } footer: {
        Text("Drakar notifies unless the session is the one you are looking at.")
      }
    }
    .formStyle(.grouped)
    .onChange(of: [recognisesQuestions, badgesPermissions, badgesQuestions]) {
      Attention.shared.refresh()
    }
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `make -C apps/apple test-app`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): an Attention pane for what badges and what notifies"
```

---

### Task 8: See it work

No new code unless something is broken; a fix goes in its own commit with a test.

- [ ] **Step 1: The whole suite and the audit**

```bash
make -C apps/apple test-all
make audit
make -C apps/apple format-swift-check
```

Expected: all green.

- [ ] **Step 2: In the running app**

Run: `make -C apps/apple run`. Open two project windows (any two folders). In window A,
start a session and send: "Reply with exactly: I looked at it. Want me to build it that
way?" (pin a cheap model if the composer offers one). While it runs, switch to window B.

Check, and screenshot each for the person:
1. A notification titled with the session, body "Want me to build it that way?".
2. The Dock badge reads 1.
3. In window A: the row's dot is a blue ring, its second line starts with the question,
   the header count reads 1.
4. Select the row: the mark stays. ⌥⌘D: it goes, the badge clears, the notification is
   withdrawn from Notification Centre.
5. Ask again, then answer "yes" in the composer: the mark goes the moment the prompt is sent.
6. Settings → Attention: turn "Recognise questions…" off; the row's mark goes at once.
7. Quit with a question unanswered and relaunch: the restored row is marked again.

- [ ] **Step 3: Report**

Tell the person what passed, with the screenshots, and anything that did not.
