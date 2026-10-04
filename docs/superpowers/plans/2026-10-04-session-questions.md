# Sessions That Want You, by Urgency — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drakar tells apart four ways a session wants the person — permission, choice
(`AskUserQuestion`), question, offer — marks each on its row, gives each its own feedback
(count, Dock badge, notification) under an Attention pane, and answers `AskUserQuestion`
in its own sheet.

**Architecture:** DrakarKit gains a pure detector (`ClosingAsk.detect`) measured on 100
labelled real endings, learns where a turn's closing text is (live `Transcript`, and
`TranscriptTail` for unread rows), and parses `AskUserQuestion` inputs (`UserQuestion`).
The app derives a row's `Urgency` from those, never storing a flag; `Attention` counts and
notifies per level under `AttentionChoice`; the sidebar draws it; a choice sheet answers.

**Tech Stack:** Swift 6 (tools 6.3), SwiftUI + AppKit on macOS 26, Swift Testing,
`UserNotifications`, Swift `Regex` literals. DrakarKit stays Foundation-only.

**Spec:** `docs/superpowers/specs/2026-10-04-session-questions-design.md` (revised
2026-10-04 with the urgency levels and the choice sheet, after Task 0).

**Where:** worktree `/Users/olivier/Projects/apps/drakar-session-questions`, branch
`feat/session-questions`. All paths below are relative to `apps/apple/` unless they start
with `docs/`.

## Global Constraints

- DrakarKit has zero dependencies and imports nothing above Foundation. `make test`
  (in `apps/apple`) resolves nothing and runs offline.
- Protocol shapes are tested against captured output or minimal synthetic lines of shapes
  already captured (`docs/claude-stream-json.md`).
- The app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; kit code is
  nonisolated by default.
- Drakar opens no connection: `make audit` (repo root) must still pass. No model is called.
- Commits: `feat(kit): …`, `feat(apple): …`, `docs: …`, `test(kit): …`, a lowercase
  sentence; a prose body when the why is not obvious. No trailers.
- Before each commit: `make -C apps/apple format-swift`.
- Levels, most urgent first: permission, choice, question, offer. Labels: "Waiting for
  you", "Asks you to choose", "Asked you", "Offered".
- Defaults keys: `drakar.recognisesAsks` (true); `drakar.attention.<level>.<feedback>` with
  level `permission|choice|question|offer` and feedback `counts|badges|notifies`, true when
  absent except for `offer` (false); `drakar.notifiesTurnEnds` unchanged (false).
- Shortcut: Dismiss is ⌥⌘D. Next Session Needing You stays ⌥⌘↓.
- Shown text is at most 140 characters, cut on a word boundary with "…".
- Targets on the fixture: wrong question marks ≤ 1 in 20 of question marks; missed
  questions < 1 in 10; offers recognised ≥ 2 in 3.

## Review Focus

1. **A subagent's text ending in a question** while the main turn ends on a statement: not
   asked. Pinned in Task 2.
2. **An unclosed code fence**, or a `?` inside a fence, inline code, a URL or a quote: never
   a question, never a crash. Pinned in Task 1.
3. **A long reply** (200 KB): detection stays fast, and the app does not re-run it on every
   draw. Pinned in Tasks 1 (timing) and 5 (memo).
4. **The CLI's own synthetic turn** at the end of a transcript: not an ask. Pinned in Task 3.
5. **An `AskUserQuestion` with several questions, one multi-select, one answered in
   "Other"**: every question gets its entry, labels in option order. Pinned in Task 4.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Packages/DrakarKit/Sources/DrakarKit/ClosingAsk.swift` (new) | `ClosingText`, `ClosingAsk` and its rules |
| `Packages/DrakarKit/Sources/DrakarKit/UserQuestion.swift` (new) | `AskUserQuestion` input parsing and answering |
| `Packages/DrakarKit/Sources/DrakarKit/StreamMessage.swift` | `AssistantMessage.stopReason`, `PermissionRequest.requiresUserInteraction` |
| `Packages/DrakarKit/Sources/DrakarKit/Transcript.swift` | `TurnEnd`, `turnEnd`, `closingText` |
| `Packages/DrakarKit/Sources/DrakarKit/ContextUsage.swift` | `TranscriptTail.closingText` |
| `Packages/DrakarKit/Sources/DrakarKit/SessionIndex.swift` | `SessionSummary.closingAsk` / `closingMessageID` |
| `Drakar/Services/Attention.swift` | `Urgency`, counting, the notification rule, posting per level |
| `Drakar/Views/SettingsView.swift` | keys, `AttentionChoice`, `SettingsPane.attention`, `AttentionPane` |
| `Drakar/Services/ClaudeSession.swift` | `onPromptSent` |
| `Drakar/Services/Project.swift` | `ProjectSession.closingAsk` / `urgency` / `wants`, dismissal, stored, counts, next |
| `Drakar/Views/ProjectSidebar.swift` | `RowState` levels, `StateDot`, second line, context menu |
| `Drakar/Views/ChoiceSheet.swift` (new) | the `AskUserQuestion` sheet |
| `Drakar/Views/SessionView.swift` | which sheet a waiting request gets |
| `Drakar/DrakarApp.swift` | Session menu: Dismiss |

---

### Task 0: Spike — `AskUserQuestion`, and labelled real endings

Done in this session before the spec revision: steps 1–3 committed as `b54b0ce`
(`docs/claude-stream-json.md`, "AskUserQuestion"); the 100 endings extracted, sampled,
scrubbed and labelled; ten shown to the person, whose answer was the urgency levels.

- [x] **Steps 1–3:** capture and document `AskUserQuestion` (`b54b0ce`).
- [x] **Steps 4–7:** extract, sample, label (kind `question` 53, `offer` 8, none 39), scrub.
- [ ] **Step 8: Commit the fixture and the revised spec and plan**

`Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/closing-endings.jsonl`, one object per
line: `{"text": …, "kind": "question" | "offer" | null, "shows": … | null}`.

```bash
git add apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/closing-endings.jsonl \
  docs/superpowers/specs/2026-10-04-session-questions-design.md \
  docs/superpowers/plans/2026-10-04-session-questions.md
git commit -m "docs: sessions that want you, by urgency: spec, plan and a hundred labelled endings"
```

---

### Task 1: `ClosingAsk` — the rules

**Files:**
- Create: `Packages/DrakarKit/Sources/DrakarKit/ClosingAsk.swift`
- Create: `Packages/DrakarKit/Tests/DrakarKitTests/ClosingAskTests.swift`
- Modify: `Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift` (one case)

**Interfaces:**
- Produces:
  - `public struct ClosingText: Sendable, Equatable { messageID: String; text: String; init(messageID:text:) }`
  - `public struct ClosingAsk: Sendable, Hashable { enum Kind: String { case question, offer }; var kind: Kind; var text: String; init(kind:text:); static func detect(_ text: String) -> ClosingAsk?; static let maxLength = 140 }`

- [ ] **Step 1: Add the fixture case**

In `Fixture.swift`, after `contextUsage`:

```swift
  /// A hundred closing texts of real turns (Task 0 of the session-questions plan, 2026-10-04),
  /// trimmed to their last three paragraphs and scrubbed, each labelled `question`, `offer`
  /// or null with the sentence a row should show. Lines are `{"text", "kind", "shows"}`,
  /// not stream messages.
  case closingEndings = "closing-endings"
```

- [ ] **Step 2: Write the failing tests**

`ClosingAskTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@Suite("What a turn ended on")
struct ClosingAskTests {
  private func question(_ text: String) -> ClosingAsk { ClosingAsk(kind: .question, text: text) }
  private func offer(_ text: String) -> ClosingAsk { ClosingAsk(kind: .offer, text: text) }

  @Test func aQuestionAtTheEndIsAsked() {
    #expect(
      ClosingAsk.detect("Built and tested.\n\nWant me to build it that way?")
        == question("Want me to build it that way?"))
  }

  @Test func aDirectAskNeedsNoQuestionMark() {
    #expect(
      ClosingAsk.detect("The plan is ready. Should I go ahead with option B.")
        == question("Should I go ahead with option B."))
  }

  /// Most real asks explain themselves after the question.
  @Test func aQuestionFollowedByItsExplanationIsAsked() {
    #expect(
      ClosingAsk.detect(
        "Should I commit this on a branch? It would be something like `fix/x`, since you're on main."
      ) == question("Should I commit this on a branch?"))
  }

  @Test func askingThePersonToActIsAQuestion() {
    #expect(
      ClosingAsk.detect("Stop the recording.\n\nTell me when it's saved. I'll convert it.")
        == question("Tell me when it's saved."))
  }

  @Test func aStatementIsNothing() {
    #expect(ClosingAsk.detect("All 146 tests pass. Committed as 2add3ce.") == nil)
  }

  @Test func aSignOffIsAnOfferNeverAQuestion() {
    #expect(
      ClosingAsk.detect("Done. Let me know if you'd like any changes.")
        == offer("Let me know if you'd like any changes."))
    #expect(
      ClosingAsk.detect("Fixed. Let me know if that works for you?")
        == offer("Let me know if that works for you?"))
  }

  @Test func offersAreRecognised() {
    #expect(
      ClosingAsk.detect("Shipped.\n\nSay the word and I'll add the readout.")
        == offer("Say the word and I'll add the readout."))
    #expect(ClosingAsk.detect("Say if you want this landed.") == offer("Say if you want this landed."))
  }

  @Test func aQuestionOutranksAnOffer() {
    #expect(
      ClosingAsk.detect("Shall I push? If you want, I can also tag it.")
        == question("Shall I push?"))
  }

  @Test func onlyTheLastTwoParagraphsCount() {
    #expect(ClosingAsk.detect("Should I keep it?\n\nI kept it.\n\nAll green.") == nil)
  }

  @Test func aListOfOptionsAfterTheQuestionAsks() {
    #expect(
      ClosingAsk.detect("Which do you prefer?\n1. Rules\n2. A model")
        == question("Which do you prefer?"))
    #expect(
      ClosingAsk.detect("Done.\n\nStill to do:\n- `.work/` is 12 GB. Shall I delete it?")
        == question("Shall I delete it?"))
  }

  @Test func codeQuotesAndLinksAreNotSentences() {
    #expect(ClosingAsk.detect("Run `grep -E 'a?'` to check.") == nil)
    #expect(ClosingAsk.detect("Done.\n\n```\nwhat?\n```") == nil)
    #expect(ClosingAsk.detect("> Should we ship?\n\nShipped.") == nil)
    #expect(ClosingAsk.detect("It is at https://example.com/search?") == nil)
  }

  @Test func anUnclosedFenceIsCodeToTheEnd() {
    #expect(ClosingAsk.detect("Here:\n\n```swift\nlet a = b ?? c\nwhat?") == nil)
  }

  @Test func emphasisAndQuotesAreNotPartOfIt() {
    #expect(ClosingAsk.detect("**Want me to proceed?**") == question("Want me to proceed?"))
    #expect(ClosingAsk.detect(#"Reply "OK to remove?" Then I delete it."#)?.kind == .question)
  }

  @Test func otherQuestionMarksCount() {
    #expect(ClosingAsk.detect("C'est prêt. Voulez-vous que je continue ?")?.kind == .question)
    #expect(ClosingAsk.detect("準備できました。続けますか？")?.kind == .question)
  }

  @Test func typographicApostrophesMatch() {
    #expect(
      ClosingAsk.detect("Done. Let me know if you\u{2019}d like changes.")?.kind == .offer)
  }

  @Test func aLongAskIsCutOnAWord() throws {
    let long = "Should I " + String(repeating: "rename every file ", count: 20) + "now?"
    let shown = try #require(ClosingAsk.detect(long)).text
    #expect(shown.count <= ClosingAsk.maxLength)
    #expect(shown.hasSuffix("…"))
    #expect(!shown.dropLast().hasSuffix(" "))
  }

  @Test func windowsLineEndingsAreLines() {
    #expect(ClosingAsk.detect("Done.\r\n\r\nWant me to push?") == question("Want me to push?"))
  }

  @Test func aLongReplyIsReadQuickly() {
    let reply =
      String(repeating: "A line of prose about the change. ", count: 6_000)
      + "\n\n```\n" + String(repeating: "code();\n", count: 2_000) + "```\n\nWant me to push?"
    let start = ContinuousClock.now
    #expect(ClosingAsk.detect(reply) == question("Want me to push?"))
    #expect(ContinuousClock.now - start < .milliseconds(500))
  }

  /// The spec's targets on real endings. The failures print, which is how the rules get
  /// tuned; the labels are never edited to pass.
  @Test func meetsItsTargetsOnRealEndings() throws {
    var wrongQuestions: [String] = []
    var missedQuestions: [String] = []
    var missedOffers: [String] = []
    var questionMarks = 0
    var questions = 0
    var offers = 0
    for line in try Fixture.closingEndings.lines {
      let json = try JSONValue.parse(line)
      let text = try #require(json["text"]?.stringValue)
      let expected = json["kind"]?.stringValue
      let found = ClosingAsk.detect(text)?.kind.rawValue
      if expected == "question" { questions += 1 }
      if expected == "offer" { offers += 1 }
      if found == "question" { questionMarks += 1 }
      if found == "question", expected != "question" { wrongQuestions.append(text) }
      if expected == "question", found != "question" { missedQuestions.append(text) }
      if expected == "offer", found != "offer" { missedOffers.append(text) }
    }
    #expect(questions >= 40 && offers >= 6, "the fixture is too thin to measure")
    #expect(wrongQuestions.count * 20 <= questionMarks, "marked wrongly: \(wrongQuestions)")
    #expect(missedQuestions.count * 10 < questions, "missed: \(missedQuestions)")
    #expect(missedOffers.count * 3 <= offers, "offers missed: \(missedOffers)")
  }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `make -C apps/apple test > $W/t1.log 2>&1; tail -5 $W/t1.log`
Expected: FAIL to compile, "cannot find 'ClosingAsk' in scope".

- [ ] **Step 4: Write the rules**

`ClosingAsk.swift`:

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

/// What a turn ended on, when it wants the person: a question ("Want me to build it that
/// way?") or an offer ("Say the word and I'll add it").
///
/// A model often asks for a go-ahead in prose rather than through `AskUserQuestion`, and
/// such a turn waits for the person as surely as a permission request does. Rules, not a
/// model: Drakar makes no outgoing connection. Measured on a hundred labelled endings
/// (`closing-endings.jsonl`): most asks explain themselves after the question, so any
/// question in the closing paragraphs counts, the last one shown.
public struct ClosingAsk: Sendable, Hashable {
  public enum Kind: String, Sendable {
    case question, offer
  }

  public var kind: Kind
  /// The sentence a row and a notification show.
  public var text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }

  /// Asks without a question mark, at the start of a sentence, folded.
  public static let asks = [
    "want me to", "should i ", "shall i ", "would you like", "do you want",
    "ready to proceed", "go ahead with", "which one do you", "which option do you",
    "which approach do you",
  ]
  /// The person is asked to act, anywhere in a sentence, folded.
  public static let requests = ["tell me when", ", tell me,", "waiting on your go-ahead"]
  /// Sign-offs: never a question, even with a question mark.
  public static let signOffs = ["let me know if", "feel free to", "happy to"]
  /// Offers without asking, anywhere in a sentence, folded.
  public static let offers = [
    "let me know if you", "if you want", "if you'd like", "if you like", "say the word",
    "say if you want", "happy to",
  ]
  /// What a row and a notification show at most.
  public static let maxLength = 140

  public static func detect(_ text: String) -> ClosingAsk? {
    let sentences = paragraphs(of: stripped(text)).suffix(2).flatMap(sentences(of:))
    if let sentence = sentences.last(where: isQuestion) {
      return ClosingAsk(kind: .question, text: shortened(sentence))
    }
    if let sentence = sentences.last(where: isOffer) {
      return ClosingAsk(kind: .offer, text: shortened(sentence))
    }
    return nil
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

  /// Every line break ends a sentence, and so does `.`, `?`, `!` (or their full-width
  /// forms) before a space or the end of the line, closing quotes and emphasis included.
  static func sentences(of paragraph: String) -> [String] {
    var sentences: [String] = []
    func add(_ raw: String) {
      let sentence = raw.trimmingCharacters(in: decoration)
      if !sentence.isEmpty { sentences.append(sentence) }
    }
    for line in paragraph.split(separator: "\n") {
      let characters = Array(line)
      var current = ""
      var index = 0
      while index < characters.count {
        let character = characters[index]
        current.append(character)
        index += 1
        guard ".?!？！。".contains(character) else { continue }
        var next = index
        while next < characters.count, closers.contains(characters[next]) { next += 1 }
        if next == characters.count || characters[next].isWhitespace {
          current.append(contentsOf: characters[index..<next])
          index = next
          add(current)
          current = ""
        }
      }
      add(current)
    }
    return sentences
  }

  static let closers: Set<Character> = ["\"", "”", "'", "’", ")", "]", "*", "_"]

  /// Markdown emphasis, headings, list bullets and brackets around a sentence.
  static let decoration = CharacterSet.whitespacesAndNewlines.union(
    CharacterSet(charactersIn: "*_#-()[]\"“”"))

  static func isQuestion(_ sentence: String) -> Bool {
    let folded = folded(sentence)
    if signOffs.contains(where: folded.hasPrefix) { return false }
    if let last = sentence.last, last == "?" || last == "？" { return true }
    return asks.contains(where: folded.hasPrefix) || requests.contains(where: folded.contains)
  }

  static func isOffer(_ sentence: String) -> Bool {
    let folded = folded(sentence)
    return offers.contains(where: folded.contains)
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

Run: `make -C apps/apple test > $W/t1.log 2>&1; tail -30 $W/t1.log`
Expected: PASS. If `aLongReplyIsReadQuickly` fails on time, replace the `Regex` literals in
`stripped` with `NSRegularExpression` (same patterns). If `meetsItsTargetsOnRealEndings`
fails, read the printed texts and tune `asks`, `requests`, `signOffs`, `offers` or the
stripping, never the labels, and add a hand-written test for each rule added.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): what a turn ended on, a question or an offer, by rules measured on real endings"
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
- Produces: `AssistantMessage.stopReason: String?`; `Transcript.TurnEnd`
  (`completed`, `failed`, `interrupted`); `Transcript.turnEnd: TurnEnd?`;
  `Transcript.closingText: ClosingText?`.

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

Run: `make -C apps/apple test > $W/t2.log 2>&1; tail -5 $W/t2.log`
Expected: FAIL to compile, "value of type 'Transcript' has no member 'closingText'".

- [ ] **Step 3: Read `stop_reason` on an assistant message**

In `StreamMessage.swift`, `AssistantMessage`, after `usage`:

```swift
  /// `end_turn` on a message that ended the turn, `tool_use` on one that calls a tool.
  /// Transcript files repeat it on every block line; the live stream may leave it null.
  public var stopReason: String?
```

and in its `init?`, after `usage = …`: `stopReason = message["stop_reason"]?.stringValue`.

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

In `addPrompt`, after `isRunning = running`: `turnEnd = nil`.

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

(If `Transcript.Kind` gained cases on main since the plan, list them with the
`break scan` group unless they are text the model wrote.)

- [ ] **Step 5: Run the tests**

Run: `make -C apps/apple test > $W/t2.log 2>&1; tail -5 $W/t2.log`
Expected: PASS, every suite.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): a transcript knows how its newest turn ended and the text it ended on"
```

---

### Task 3: The closing ask of a transcript file's tail

**Files:**
- Modify: `Packages/DrakarKit/Sources/DrakarKit/ContextUsage.swift` (`TranscriptTail`)
- Modify: `Packages/DrakarKit/Sources/DrakarKit/SessionIndex.swift`
- Test: `Packages/DrakarKit/Tests/DrakarKitTests/ContextUsageTests.swift`

**Interfaces:**
- Consumes: `ClosingText`, `ClosingAsk.detect` (Task 1).
- Produces: `TranscriptTail.closingText: ClosingText?`; `SessionSummary.closingAsk: ClosingAsk?`,
  `SessionSummary.closingMessageID: String?`.

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
    let answered =
      endedOnAQuestion + [#"{"type":"user","message":{"role":"user","content":"yes"}}"#]
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

  @Test func aSummaryCarriesTheAsk() throws {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "drakar-closing-\(UUID().uuidString).jsonl")
    try Data(endedOnAQuestion.joined(separator: "\n").utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let account = ClaudeAccount(directory: file.deletingLastPathComponent(), isDefault: false)
    let summary = try #require(SessionIndex.summary(of: file, account: account))
    #expect(summary.closingAsk == ClosingAsk(kind: .question, text: "Want me to commit it?"))
    #expect(summary.closingMessageID == "m1")
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `make -C apps/apple test > $W/t3.log 2>&1; tail -5 $W/t3.log`
Expected: FAIL to compile, "value of type 'TranscriptTail' has no member 'closingText'".

- [ ] **Step 3: Read the closing text from the tail**

In `ContextUsage.swift`, inside `TranscriptTail`, after `isAwaitingToolResult`:

```swift
  /// The text the newest main-thread turn ended on, when its last message ended the turn
  /// (`end_turn`) and nothing was sent after it: what a row whose history is not read
  /// shows its ask from. Every block of a message is its own line, newest first here.
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

- [ ] **Step 4: Carry the ask in a summary**

`SessionSummary`, after `awaitsToolResult`:

```swift
  /// What the newest turn ended on (`ClosingAsk`), while nothing was sent after it, and the
  /// id of the message that asked it.
  public var closingAsk: ClosingAsk?
  public var closingMessageID: String?
```

`summarize`, after `summary.awaitsToolResult = …`:

```swift
    if let closing = tail.closingText, let ask = ClosingAsk.detect(closing.text) {
      summary.closingAsk = ask
      summary.closingMessageID = closing.messageID
    }
```

- [ ] **Step 5: Run the tests**

Run: `make -C apps/apple test > $W/t3.log 2>&1; tail -5 $W/t3.log`
Expected: PASS, every suite.

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): a session summary carries what its last turn ended on"
```

---

### Task 4: `UserQuestion` — reading and answering `AskUserQuestion`

**Files:**
- Create: `Packages/DrakarKit/Sources/DrakarKit/UserQuestion.swift`
- Modify: `Packages/DrakarKit/Sources/DrakarKit/StreamMessage.swift` (`PermissionRequest`)
- Create: `Packages/DrakarKit/Tests/DrakarKitTests/UserQuestionTests.swift`

**Interfaces:**
- Produces:
  - `PermissionRequest.requiresUserInteraction: Bool`, `PermissionRequest.isChoice: Bool`
  - `public struct UserQuestion: Sendable, Equatable, Identifiable { struct Option { label: String; description: String? }; question: String; header: String?; options: [Option]; multiSelect: Bool; static let toolName = "AskUserQuestion"; static func list(_ input: JSONValue) -> [UserQuestion]; func answer(picked: Set<String>, other: String) -> String?; static func answering(_ input: JSONValue, with answers: [String: String]) -> JSONValue }`

- [ ] **Step 1: Write the failing tests**

`UserQuestionTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@Suite("Answering AskUserQuestion")
struct UserQuestionTests {
  /// The input captured on 2026-10-04 (docs/claude-stream-json.md, "AskUserQuestion").
  private let captured = try! JSONValue.parse(
    Data(
      #"{"questions":[{"question":"Which filename would you prefer?","header":"Filename","options":[{"label":"a.txt","description":"Name the file a.txt"},{"label":"b.txt","description":"Name the file b.txt"}],"multiSelect":false}]}"#
        .utf8))

  @Test func readsTheCapturedQuestion() throws {
    let questions = UserQuestion.list(captured)
    #expect(questions.count == 1)
    let first = try #require(questions.first)
    #expect(first.question == "Which filename would you prefer?")
    #expect(first.header == "Filename")
    #expect(first.options.map(\.label) == ["a.txt", "b.txt"])
    #expect(first.options.first?.description == "Name the file a.txt")
    #expect(!first.multiSelect)
  }

  @Test func theRequestSaysItWantsThePerson() throws {
    let line =
      #"{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[]},"tool_use_id":"t","requires_user_interaction":true}}"#
    guard case .controlRequest(let request) = try StreamMessage(line: Data(line.utf8)),
      case .canUseTool(let permission) = request.kind
    else {
      Issue.record("not a can_use_tool request")
      return
    }
    #expect(permission.requiresUserInteraction)
    #expect(permission.isChoice)
  }

  /// Picked labels in the options' order, then the typed answer, joined as the CLI's own
  /// picker joins them.
  @Test func anAnswerIsItsLabelsInOrderThenOther() throws {
    let question = UserQuestion(
      question: "Which?", header: nil,
      options: [.init(label: "A", description: nil), .init(label: "B", description: nil)],
      multiSelect: true)
    #expect(question.answer(picked: ["B", "A"], other: "") == "A, B")
    #expect(question.answer(picked: ["B"], other: "  my own  ") == "B, my own")
    #expect(question.answer(picked: [], other: " ") == nil)
  }

  @Test func theAnswersRideInTheInput() throws {
    let answered = UserQuestion.answering(
      captured, with: ["Which filename would you prefer?": "a.txt"])
    #expect(answered["answers"]?["Which filename would you prefer?"]?.stringValue == "a.txt")
    #expect(answered["questions"] == captured["questions"])
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `make -C apps/apple test > $W/t4.log 2>&1; tail -5 $W/t4.log`
Expected: FAIL to compile, "cannot find 'UserQuestion' in scope".

- [ ] **Step 3: The request's flag**

`PermissionRequest`, after `blockedPath`:

```swift
  /// Set on a request only the person can answer, such as `AskUserQuestion`'s.
  public var requiresUserInteraction: Bool
  /// An `AskUserQuestion` waiting on a choice, not a tool waiting on permission.
  public var isChoice: Bool { toolName == UserQuestion.toolName }
```

In its `init?`: `requiresUserInteraction = request["requires_user_interaction"]?.boolValue ?? false`.

- [ ] **Step 4: `UserQuestion`**

`UserQuestion.swift`:

```swift
import Foundation

/// One question of an `AskUserQuestion` call, and how its answer goes back.
///
/// Verified on 2.1.288 (docs/claude-stream-json.md, "AskUserQuestion"): the answer rides in
/// the permission's `updatedInput` as `answers: {question: answer}`; a plain `allow`
/// tells the model the person did not answer. A multi-select answer is its labels joined
/// with ", ", as the CLI's own picker writes it.
public struct UserQuestion: Sendable, Equatable, Identifiable {
  public struct Option: Sendable, Equatable {
    public var label: String
    public var description: String?

    public init(label: String, description: String?) {
      self.label = label
      self.description = description
    }
  }

  public static let toolName = "AskUserQuestion"

  public var id: String { question }
  public var question: String
  public var header: String?
  public var options: [Option]
  public var multiSelect: Bool

  public init(question: String, header: String?, options: [Option], multiSelect: Bool) {
    self.question = question
    self.header = header
    self.options = options
    self.multiSelect = multiSelect
  }

  /// The questions of an `AskUserQuestion` input, in order.
  public static func list(_ input: JSONValue) -> [UserQuestion] {
    (input["questions"]?.arrayValue ?? []).compactMap { entry in
      guard let question = entry["question"]?.stringValue else { return nil }
      return UserQuestion(
        question: question, header: entry["header"]?.stringValue,
        options: (entry["options"]?.arrayValue ?? []).compactMap { option in
          option["label"]?.stringValue.map {
            Option(label: $0, description: option["description"]?.stringValue)
          }
        },
        multiSelect: entry["multiSelect"]?.boolValue ?? false)
    }
  }

  /// The answer for `picked` labels and a typed `other`: the labels in the options' order,
  /// then the typed text; nil when there is neither.
  public func answer(picked: Set<String>, other: String) -> String? {
    var parts = options.map(\.label).filter(picked.contains)
    let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { parts.append(typed) }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  /// `input` with `answers` added: the `updatedInput` of the `allow` that answers.
  public static func answering(_ input: JSONValue, with answers: [String: String]) -> JSONValue {
    guard case .object(var object) = input else { return input }
    object["answers"] = .object(answers.mapValues { .string($0) })
    return .object(object)
  }
}
```

- [ ] **Step 5: Run the tests**

Run: `make -C apps/apple test > $W/t4.log 2>&1; tail -5 $W/t4.log`
Expected: PASS. (`JSONValue` must be `Equatable` for `answered["questions"] ==`; it is used
so elsewhere. If `StreamMessage(line:)` or `.controlRequest`'s shape differs, follow
`StreamMessageTests`.)

- [ ] **Step 6: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): an AskUserQuestion is read, and answered the way the CLI's picker does"
```

---

### Task 5: The row's urgency — derived, dismissable, remembered

**Files:**
- Modify: `Drakar/Services/Attention.swift` (`Urgency` only; the rest is Task 6)
- Modify: `Drakar/Views/SettingsView.swift` (keys and `AttentionChoice`; the pane is Task 9)
- Modify: `Drakar/Services/ClaudeSession.swift` (`onPromptSent`)
- Modify: `Drakar/Services/Project.swift`
- Test: `DrakarTests/AttentionTests.swift`

**Interfaces:**
- Consumes: `Transcript.closingText`, `SessionSummary.closingAsk`/`closingMessageID`,
  `ClosingAsk.detect`, `PermissionRequest.isChoice`, `UserQuestion.list`.
- Produces:
  - `enum Urgency: String, CaseIterable, Comparable { case offer, question, choice, permission }`
  - `enum AttentionFeedback: String, CaseIterable { case counts, badges, notifies }`
  - `PreferenceKey.recognisesAsks`; `enum AttentionChoice { static var defaults: UserDefaults; static var recognisesAsks: Bool; static func key(_: Urgency, _: AttentionFeedback) -> String; static func isOn(_: Urgency, _: AttentionFeedback) -> Bool; static func defaultValue(_: Urgency, _: AttentionFeedback) -> Bool; static var notifiesTurnEnds: Bool }`
  - `ClaudeSession.onPromptSent: (() -> Void)?`
  - `ProjectSession.closingAsk: ClosingAsk?`, `.urgency: Urgency?`, `.wants: String?`,
    `.dismissedAsk: String?`, `.dismissAsk()`
  - `Project.dismissAsk(_:)`; `StoredProject.dismissedQuestions: [String: String]?`
  - `Project.waitingCount` counts rows whose urgency counts; `nextNeedingAttention()` goes
    by urgency, then unread.

- [ ] **Step 1: Write the failing tests**

Add a suite to `AttentionTests.swift`:

```swift
@MainActor
@Suite("What a session wants, and how much")
struct UrgencyTests {
  init() {
    // An empty scratch suite: every switch reads as its default, whatever the person set.
    AttentionChoice.defaults = UserDefaults(suiteName: "drakar-tests-\(UUID().uuidString)")!
  }

  private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-urgency-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// A stand-in `claude` that answers any prompt with these lines and then waits.
  private func fake(in folder: URL, _ lines: [String]) throws -> URL {
    let fake = folder.appending(path: "claude")
    let script =
      "#!/bin/sh\n" + lines.map { "echo '\($0)'" }.joined(separator: "\n") + "\ncat > /dev/null\n"
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return fake
  }

  static let asking = [
    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Built. Want me to commit it?"}]}}"#,
    #"{"type":"result","subtype":"success","is_error":false,"result":"Built. Want me to commit it?"}"#,
  ]
  static let offering = [
    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Built. Say the word and I'll tag it."}]}}"#,
    #"{"type":"result","subtype":"success","is_error":false,"result":"Built."}"#,
  ]
  static let choosing = [
    #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which filename?","header":"File","options":[{"label":"a.txt"},{"label":"b.txt"}],"multiSelect":false}]},"tool_use_id":"t1","requires_user_interaction":true}}"#
  ]

  private func session(_ lines: [String]) async throws -> (Project, ProjectSession) {
    let folder = try folder()
    let project = Project(folder: folder)
    let item = project.newSession()
    item.session.executableOverride = try fake(in: folder, lines)
    item.session.send("Build it")
    for _ in 0..<50
    where item.session.transcript.turnEnd == nil
      && item.session.transcript.pendingPermissions.isEmpty
    {
      try await Task.sleep(for: .milliseconds(100))
    }
    return (project, item)
  }

  @Test func aTurnEndingOnAQuestionAsks() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    #expect(item.urgency == .question)
    #expect(item.wants == "Want me to commit it?")
    #expect(project.waitingCount == 1)
  }

  @Test func anOfferIsMarkedButNotCounted() async throws {
    let (project, item) = try await session(Self.offering)
    defer { project.stopAll() }
    #expect(item.urgency == .offer)
    #expect(item.wants == "Say the word and I'll tag it.")
    #expect(project.waitingCount == 0)
  }

  @Test func anAskUserQuestionIsAChoice() async throws {
    let (project, item) = try await session(Self.choosing)
    defer { project.stopAll() }
    #expect(item.urgency == .choice)
    #expect(item.wants == "Which filename?")
  }

  /// Looking is not answering.
  @Test func selectingTheRowKeepsIt() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    _ = project.newSession()
    project.select(item)
    #expect(item.urgency == .question)
  }

  @Test func aPromptAnswersIt() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    item.session.send("yes")
    #expect(item.urgency == nil)
  }

  @Test func dismissingQuietsIt() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    project.dismissAsk(item)
    #expect(item.urgency == nil)
    #expect(item.dismissedAsk == "m1")
    #expect(project.waitingCount == 0)
  }

  @Test func endingTheSessionClearsIt() async throws {
    let (project, item) = try await session(Self.asking)
    project.end(item)
    #expect(item.urgency == nil)
  }

  @Test func turningRecognitionOffClearsIt() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    AttentionChoice.defaults.set(false, forKey: PreferenceKey.recognisesAsks)
    #expect(item.urgency == nil)
  }

  @Test func theSwitchesHaveTheirDefaults() {
    #expect(AttentionChoice.isOn(.question, .badges))
    #expect(AttentionChoice.isOn(.permission, .notifies))
    #expect(!AttentionChoice.isOn(.offer, .counts))
    #expect(AttentionChoice.key(.offer, .counts) == "drakar.attention.offer.counts")
    AttentionChoice.defaults.set(true, forKey: AttentionChoice.key(.offer, .counts))
    #expect(AttentionChoice.isOn(.offer, .counts))
  }

  @Test func theNextRowNeedingYouIsTheMostUrgent() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    let unread = project.newSession()
    unread.isUnread = true
    _ = project.newSession()  // selected; rows: third, unread, item
    #expect(project.nextNeedingAttention()?.id == item.id)
  }

  /// A restored row asks from its transcript's tail, and a dismissal survives the relaunch
  /// for that message and no other.
  @Test func aRestoredRowAsksUnlessThatAskWasDismissed() async throws {
    let folder = try folder()
    let file = folder.appending(path: "s1.jsonl")
    try Data(
      [
        #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
        #"{"type":"assistant","message":{"id":"m2","stop_reason":"end_turn","content":[{"type":"text","text":"Want me to commit it?"}]}}"#,
      ].joined(separator: "\n").utf8
    ).write(to: file)
    let target = ResumeTarget(
      sessionID: "s1", cwd: folder.path(percentEncoded: false),
      file: file.path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)

    func restored(dismissing id: String?) async throws -> ProjectSession {
      let stored = StoredProject(
        sessions: [target], selected: nil, dismissedQuestions: id.map { ["s1": $0] })
      let project = Project(folder: folder, restoring: stored)
      let item = try #require(project.sessions.first)
      for _ in 0..<50 where item.preview == nil || !item.session.hasLoadedHistory {
        try await Task.sleep(for: .milliseconds(100))
      }
      return item
    }

    #expect(try await restored(dismissing: nil).wants == "Want me to commit it?")
    #expect(try await restored(dismissing: "m2").urgency == nil)
    #expect(try await restored(dismissing: "m1").urgency == .question)
  }

  @Test func aDismissalIsStoredUnderItsSession() throws {
    let stored = StoredProject(sessions: [], selected: nil, dismissedQuestions: ["s1": "m2"])
    let data = try JSONEncoder().encode(stored)
    #expect(try JSONDecoder().decode(StoredProject.self, from: data) == stored)
    let old = try JSONDecoder().decode(StoredProject.self, from: Data(#"{"sessions":[]}"#.utf8))
    #expect(old.dismissedQuestions == nil)
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `make -C apps/apple test-app > $W/t5.log 2>&1; grep -E "error:|Test run|passed|failed" $W/t5.log | head`
Expected: FAIL to compile, "cannot find 'AttentionChoice' in scope".

- [ ] **Step 3: `Urgency`**

In `Attention.swift`, above the class:

```swift
/// How much a session wants the person, least first: an offer at the end of a turn, a
/// question at the end of a turn, an `AskUserQuestion` waiting on a choice, a tool waiting
/// on permission.
enum Urgency: String, CaseIterable, Comparable {
  case offer, question, choice, permission

  static func < (a: Urgency, b: Urgency) -> Bool {
    allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
  }
}
```

- [ ] **Step 4: Keys and `AttentionChoice`**

In `SettingsView.swift`, `PreferenceKey`, after `notifiesTurnEnds`:

```swift
  /// Whether a turn that ends on a question or an offer marks its row.
  static let recognisesAsks = "drakar.recognisesAsks"
```

After `enum ClaudeChoice { … }`:

```swift
/// What each level of `Urgency` does, as the Attention pane set it.
enum AttentionFeedback: String, CaseIterable {
  /// In the group's header count and ⌥⌘↓.
  case counts
  case badges
  case notifies
}

enum AttentionChoice {
  /// Where the choices are read from; a scratch suite in tests, never the real one.
  static var defaults = UserDefaults.standard

  static var recognisesAsks: Bool {
    defaults.object(forKey: PreferenceKey.recognisesAsks) as? Bool ?? true
  }

  static var notifiesTurnEnds: Bool { defaults.bool(forKey: PreferenceKey.notifiesTurnEnds) }

  static func key(_ level: Urgency, _ feedback: AttentionFeedback) -> String {
    "drakar.attention.\(level.rawValue).\(feedback.rawValue)"
  }

  /// Everything is on but an offer, which only marks its row.
  static func defaultValue(_ level: Urgency, _ feedback: AttentionFeedback) -> Bool {
    level != .offer
  }

  static func isOn(_ level: Urgency, _ feedback: AttentionFeedback) -> Bool {
    defaults.object(forKey: key(level, feedback)) as? Bool ?? defaultValue(level, feedback)
  }
}
```

- [ ] **Step 5: Say when a prompt went**

`ClaudeSession.swift`, after `onPermissionsChanged`:

```swift
  /// A prompt was sent: whatever the last turn asked is answered.
  @ObservationIgnored var onPromptSent: (() -> Void)?
```

In `send(_:context:)`, after `transcript.addPrompt(text, context: label)`: `onPromptSent?()`.

- [ ] **Step 6: The urgency, derived**

`Project.swift`, `ProjectSession`, after `preview`:

```swift
  /// The message id of the ask the person dismissed: that one stays quiet, the next one
  /// does not.
  var dismissedAsk: String?
  /// `ClosingAsk.detect` of the newest closing text, kept until the text changes: a row
  /// asks on every draw, and a reply can be long.
  @ObservationIgnored private var detected: (key: String, ask: ClosingAsk?)?
```

After `waitingFor`:

```swift
  /// How much this session wants the person, from the most urgent thing it waits on.
  var urgency: Urgency? {
    if let pending = session.transcript.pendingPermissions.first {
      return pending.request.isChoice ? .choice : .permission
    }
    switch closingAsk?.kind {
    case .question: return .question
    case .offer: return .offer
    case nil: return nil
    }
  }

  /// What it wants, for the row's second line and the notification.
  var wants: String? {
    if let pending = session.transcript.pendingPermissions.first, pending.request.isChoice {
      return UserQuestion.list(pending.request.input).first?.question ?? waitingFor
    }
    return waitingFor ?? closingAsk?.text
  }

  /// The question or offer the newest turn ended on, while it waits: nil once a prompt
  /// went, after Dismiss, once the process ended, and for a row held read-only.
  var closingAsk: ClosingAsk? { asked?.ask }

  /// Quiets `closingAsk` until a newer one.
  func dismissAsk() {
    dismissedAsk = asked?.messageID
  }

  private var asked: (messageID: String, ask: ClosingAsk)? {
    guard AttentionChoice.recognisesAsks, !session.isReadOnly else { return nil }
    switch session.phase {
    case .exited, .failed: return nil
    case .idle, .starting, .ready: break
    }
    let found: (messageID: String, ask: ClosingAsk)?
    if let preview = unloadedPreview {
      found = preview.closingMessageID.flatMap { id in preview.closingAsk.map { (id, $0) } }
    } else if let closing = session.transcript.closingText {
      found = detect(closing).map { (closing.messageID, $0) }
    } else {
      found = nil
    }
    guard let found, found.messageID != dismissedAsk else { return nil }
    return found
  }

  private func detect(_ closing: ClosingText) -> ClosingAsk? {
    let key = "\(closing.messageID)#\(closing.text.utf8.count)"
    if let detected, detected.key == key { return detected.ask }
    let ask = ClosingAsk.detect(closing.text)
    detected = (key, ask)
    return ask
  }
```

- [ ] **Step 7: Stored, restored, counted, dismissed**

`StoredProject`, add:

```swift
  /// Per session id, the message id of the ask dismissed. Optional so that a window stored
  /// before the field existed still decodes.
  var dismissedQuestions: [String: String]?
```

`Project.init`, the restore loop:

```swift
      let item = make(ClaudeSession(folder: folder, resuming: target))
      item.dismissedAsk = stored?.dismissedQuestions?[target.sessionID]
      sessions.append(item)
```

`nextNeedingAttention()`:

```swift
  /// The next row after the selected one that wants the person: the most urgent level that
  /// counts first, then unread, wrapping. Never the selected row.
  func nextNeedingAttention() -> ProjectSession? {
    let start = sessions.firstIndex { $0.id == selectedID } ?? -1
    let ordered = sessions[(start + 1)...] + sessions[..<max(start, 0)]
    for level in Urgency.allCases.reversed() where AttentionChoice.isOn(level, .counts) {
      if let item = ordered.first(where: { $0.urgency == level }) { return item }
    }
    return ordered.first { $0.isUnread }
  }

  /// Quiets the row's question or offer until it asks another.
  func dismissAsk(_ item: ProjectSession) {
    item.dismissAsk()
    Attention.shared.refresh()
  }
```

`waitingCount`:

```swift
  /// Rows that want the person at a level that counts: the group's header.
  var waitingCount: Int {
    sessions.count { item in item.urgency.map { AttentionChoice.isOn($0, .counts) } ?? false }
  }
```

`stored`:

```swift
  var stored: StoredProject {
    let dismissed = sessions.compactMap { item -> (String, String)? in
      guard let id = item.sessionID, let message = item.dismissedAsk else { return nil }
      return (id, message)
    }
    return StoredProject(
      sessions: sessions.compactMap(\.session.savedTarget),
      selected: selected?.session.savedTarget?.sessionID,
      dismissedQuestions: dismissed.isEmpty
        ? nil : Dictionary(dismissed, uniquingKeysWith: { first, _ in first }))
  }
```

`make(_:)`: add `session.onPromptSent = { Attention.shared.refresh() }`, and make
`onStopped` call `Attention.shared.refresh()` first, before its guard.

`readPreview(_:)`: after `item?.preview = summary`, add `Attention.shared.refresh()`.

- [ ] **Step 8: Run the tests**

Run: `make -C apps/apple test-app > $W/t5.log 2>&1; grep -E "error:|Test run|passed|failed" $W/t5.log | head`
Expected: PASS, including the existing `AttentionTests` and `ClosingTests`.

- [ ] **Step 9: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a session knows how much it wants you, until it is answered or dismissed"
```

---

### Task 6: Attention — counting, the notification rule, posting per level

**Files:**
- Modify: `Drakar/Services/Attention.swift`
- Test: `DrakarTests/AttentionTests.swift`

**Interfaces:**
- Consumes: `Urgency`, `AttentionChoice`, `ProjectSession.urgency`/`wants`/`closingAsk`.
- Produces: `static func Attention.count(_ items: [ProjectSession], badges: (Urgency) -> Bool) -> Int`;
  `static func Attention.isInView(appIsActive:windowIsKey:rowIsSelected:) -> Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `UrgencyTests`:

```swift
  @Test func theBadgeCountsTheLevelsItIsToldTo() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    #expect(Attention.count([item], badges: { _ in true }) == 1)
    #expect(Attention.count([item], badges: { $0 != .question }) == 0)
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

Run: `make -C apps/apple test-app > $W/t6.log 2>&1; grep -E "error:|Test run" $W/t6.log | head`
Expected: FAIL to compile, "type 'Attention' has no member 'count'".

- [ ] **Step 3: Rewrite counting and posting**

Replace the class's members above `userNotificationCenter(_:didReceive:)` with:

```swift
  static let shared = Attention()

  /// Asked once; every post awaits the same answer, so one made during the prompt waits.
  private var authorization: Task<Bool, Never>?
  /// Sessions with a notification on screen that wants an answer: withdrawn when the row
  /// no longer wants the person, however that came about.
  private var asking: Set<String> = []

  var waitingCount: Int {
    Self.count(OpenSessions.shared.projects.values.flatMap(\.sessions)) {
      AttentionChoice.isOn($0, .badges)
    }
  }

  /// Rows of `items` whose level `badges`.
  static func count(_ items: [ProjectSession], badges: (Urgency) -> Bool) -> Int {
    items.count { $0.urgency.map(badges) ?? false }
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
      OpenSessions.shared.locate(id).map { $0.1.urgency == nil } ?? true
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
    guard let level = item.urgency, AttentionChoice.isOn(level, .notifies),
      !inView(item, in: project), let wants = item.wants
    else { return }
    let body = level == .choice ? wants : String(localized: "Wants to use \(wants)")
    post(title: item.displayTitle, body: body, item: item, wantsAnswer: true)
  }

  func turnEnded(_ item: ProjectSession, in project: Project) {
    refresh()
    guard !inView(item, in: project) else { return }
    if let level = item.urgency, let ask = item.closingAsk {
      guard AttentionChoice.isOn(level, .notifies) else { return }
      post(title: item.displayTitle, body: ask.text, item: item, wantsAnswer: true)
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

Class doc comment, first sentence: "What wants the person while they look elsewhere: the Dock
badge for rows that want them, by level, and a local notification unless the session is the
one in front of them."

- [ ] **Step 4: Run the tests**

Run: `make -C apps/apple test-app > $W/t6.log 2>&1; grep -E "error:|Test run|passed|failed" $W/t6.log | head`
Expected: PASS, including `AttentionBadgeTests`.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): each level badges and notifies as set, unless the session is in front of you" -m "Notifications used to wait for Drakar to be in the background, which missed the case that costs the most: the person is in Drakar, in another project's window. Every level now posts unless the session is the row shown in the key window."
```

---

### Task 7: The sidebar and the Session menu

**Files:**
- Modify: `Drakar/Views/ProjectSidebar.swift`
- Modify: `Drakar/DrakarApp.swift` (`SessionCommands`)
- Test: `DrakarTests/AttentionTests.swift`

**Interfaces:**
- Consumes: `ProjectSession.urgency`/`wants`/`closingAsk`, `Project.dismissAsk(_:)`.
- Produces: `RowState.choosing`, `.asked`, `.offered`; `StateDot`.

- [ ] **Step 1: Write the failing test**

Append to `UrgencyTests`:

```swift
  @Test func aRowSaysWhatItWants() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    #expect(RowState(item) == .asked)
    #expect(RowState.asked.label == "Asked you")
    #expect(RowState.choosing.label == "Asks you to choose")
    #expect(RowState.offered.label == "Offered")
  }
```

- [ ] **Step 2: Run it to see it fail**

Run: `make -C apps/apple test-app > $W/t7.log 2>&1; grep -E "error:|Test run" $W/t7.log | head`
Expected: FAIL to compile, "type 'RowState' has no member 'asked'".

- [ ] **Step 3: States, dot, line, menu**

`RowState`: add `choosing, asked, offered` after `waiting`. `init(_ item:)`, replace the
`waitingFor` branch's head with:

```swift
    if let urgency = item.urgency {
      self =
        switch urgency {
        case .permission: .waiting
        case .choice: .choosing
        case .question: .asked
        case .offer: .offered
        }
    } else if session.transcript.isRunning {
```

`label`: `.choosing: "Asks you to choose"`, `.asked: "Asked you"`, `.offered: "Offered"`
(each `String(localized:)`). `tint`: `.waiting, .choosing, .asked` → `.blue`; `.offered`
joins the `.secondary` group.

Add below `RowState`:

```swift
/// A row's state as a dot: filled, or a ring for what a finished turn asked, so that a
/// blocked tool and a question read apart at a glance. Same size either way.
struct StateDot: View {
  let state: RowState

  var body: some View {
    Group {
      if state == .asked || state == .offered {
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

Use `StateDot(state: state)` in `SessionRow` and `SummaryRow` where each draws its
`Circle()…help(state.label)` dot. `SessionRow.detail`:
`if let lead = item.wants ?? item.stopReason { parts.append(lead) }`.

`SessionListView`: add `@AppStorage(PreferenceKey.recognisesAsks) private var recognisesAsks = true`
and `let _ = recognisesAsks` at the top of `body`, so rows redraw when the switch flips. The
header's count help: `"Wants you: \(project.waitingCount)"`.

`menu(for:)`, first:

```swift
    if item.closingAsk != nil {
      Button("Dismiss") { project.dismissAsk(item) }
      Divider()
    }
```

`DrakarApp.swift`, `SessionCommands.body`, after Next Session Needing You:

```swift
    Button("Dismiss") {
      if let project, let item = project.selected { project.dismissAsk(item) }
    }
    .keyboardShortcut("d", modifiers: [.command, .option])
    .disabled(project?.selected?.closingAsk == nil)
```

- [ ] **Step 4: Run the tests**

Run: `make -C apps/apple test-app > $W/t7.log 2>&1; grep -E "error:|Test run|passed|failed" $W/t7.log | head`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a row shows what it wants and how much, and ⌥⌘D dismisses a question or an offer"
```

---

### Task 8: The choice sheet

**Files:**
- Create: `Drakar/Views/ChoiceSheet.swift`
- Modify: `Drakar/Views/SessionView.swift` (the `.sheet(item: pendingPermission)` body)
- Test: `DrakarTests/AttentionTests.swift`

**Interfaces:**
- Consumes: `UserQuestion`, `PermissionRequest.isChoice`, `PermissionDecision`.
- Produces: `struct ChoiceSheet: View { init(pending:answer:) }`;
  `ChoiceSheet.decision(for questions: [UserQuestion], input: JSONValue, picked: [String: Set<String>], other: [String: String]) -> PermissionDecision?`.

- [ ] **Step 1: Write the failing test**

Append to `UrgencyTests`:

```swift
  @Test func theSheetAnswersEveryQuestionOrNothing() throws {
    let input = try JSONValue.parse(
      Data(
        #"{"questions":[{"question":"Which file?","options":[{"label":"a"},{"label":"b"}],"multiSelect":false},{"question":"Which tags?","options":[{"label":"x"},{"label":"y"}],"multiSelect":true}]}"#
          .utf8))
    let questions = UserQuestion.list(input)
    #expect(
      ChoiceSheet.decision(
        for: questions, input: input, picked: ["Which file?": ["a"]], other: [:]) == nil)
    let decision = ChoiceSheet.decision(
      for: questions, input: input, picked: ["Which file?": ["a"], "Which tags?": ["y", "x"]],
      other: ["Which tags?": "z"])
    #expect(
      decision
        == .allow(
          updatedInput: UserQuestion.answering(
            input, with: ["Which file?": "a", "Which tags?": "x, y, z"])))
  }
```

- [ ] **Step 2: Run it to see it fail**

Run: `make -C apps/apple test-app > $W/t8.log 2>&1; grep -E "error:|Test run" $W/t8.log | head`
Expected: FAIL to compile, "cannot find 'ChoiceSheet' in scope". (If `PermissionDecision`
is not `Equatable`, add the conformance in DrakarKit's `ClientMessage.swift`; `JSONValue`
already is.)

- [ ] **Step 3: The sheet**

`ChoiceSheet.swift`:

```swift
import DrakarKit
import SwiftUI

/// An `AskUserQuestion`, answered: each question with its options, an "Other" field, and
/// the picked labels sent back the way the CLI's own picker sends them. A plain Allow would
/// tell the model the person did not answer.
struct ChoiceSheet: View {
  let pending: Transcript.PendingPermission
  let answer: (PermissionDecision) -> Void

  @State private var picked: [String: Set<String>] = [:]
  @State private var other: [String: String] = [:]

  private var questions: [UserQuestion] { UserQuestion.list(pending.request.input) }

  /// `allow` with every question answered, or nil while one is not.
  static func decision(
    for questions: [UserQuestion], input: JSONValue, picked: [String: Set<String>],
    other: [String: String]
  ) -> PermissionDecision? {
    var answers: [String: String] = [:]
    for question in questions {
      guard
        let answer = question.answer(
          picked: picked[question.question] ?? [], other: other[question.question] ?? "")
      else { return nil }
      answers[question.question] = answer
    }
    return .allow(updatedInput: UserQuestion.answering(input, with: answers))
  }

  private var decision: PermissionDecision? {
    Self.decision(
      for: questions, input: pending.request.input, picked: picked, other: other)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(questions) { question in
        VStack(alignment: .leading, spacing: 8) {
          if let header = question.header {
            Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          }
          Text(question.question).font(.title3.weight(.semibold))
          ForEach(question.options, id: \.label) { option in
            Toggle(isOn: binding(question, option.label)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                if let description = option.description {
                  Text(description).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("choice.option.\(option.label)")
          }
          TextField("Other", text: otherBinding(question))
            .accessibilityIdentifier("choice.other")
        }
      }
      HStack {
        Spacer()
        Button("Skip") { answer(.deny(message: "The user chose not to answer.")) }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("choice.skip")
        Button("Answer") { if let decision { answer(decision) } }
          .keyboardShortcut(.defaultAction)
          .disabled(decision == nil)
          .accessibilityIdentifier("choice.answer")
      }
    }
    .padding(20)
    .frame(width: 460)
    .interactiveDismissDisabled()
  }

  /// A checkbox per option; picking one of a single-choice question unpicks the rest.
  private func binding(_ question: UserQuestion, _ label: String) -> Binding<Bool> {
    Binding(
      get: { picked[question.question]?.contains(label) == true },
      set: { isOn in
        var set = question.multiSelect ? picked[question.question] ?? [] : []
        if isOn { set.insert(label) } else { set.remove(label) }
        picked[question.question] = set
      })
  }

  private func otherBinding(_ question: UserQuestion) -> Binding<String> {
    Binding(
      get: { other[question.question] ?? "" },
      set: { other[question.question] = $0 })
  }
}
```

`SessionView.swift`, the sheet body:

```swift
    .sheet(item: pendingPermission) { pending in
      if pending.request.isChoice {
        ChoiceSheet(pending: pending) { decision in session.answer(pending, decision) }
      } else {
        PermissionSheet(pending: pending) { decision in session.answer(pending, decision) }
      }
    }
```

- [ ] **Step 4: Run the tests**

Run: `make -C apps/apple test-app > $W/t8.log 2>&1; grep -E "error:|Test run|passed|failed" $W/t8.log | head`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests apps/apple/Packages/DrakarKit
git commit -m "feat(apple): an AskUserQuestion gets its own sheet, and your pick reaches the model"
```

---

### Task 9: The Attention pane

**Files:**
- Modify: `Drakar/Views/SettingsView.swift`
- Test: `DrakarTests/SettingsPaneTests.swift`

**Interfaces:**
- Consumes: `Urgency`, `AttentionFeedback`, `AttentionChoice`, `PreferenceKey.recognisesAsks`.
- Produces: `SettingsPane.attention`, `AttentionPane`.

- [ ] **Step 1: Write the failing test**

`SettingsPaneTests.keepsPaneIdentifiersStable`:

```swift
    #expect(SettingsPane.allCases.map(\.rawValue) == ["general", "attention", "about"])
```

- [ ] **Step 2: Run it to see it fail**

Run: `make -C apps/apple test-app > $W/t9.log 2>&1; grep -E "error:|Test run|failed" $W/t9.log | head`
Expected: FAIL, the identifiers are `["general", "about"]`.

- [ ] **Step 3: The pane**

`SettingsPane`: `case attention` between `general` and `about`; title `"Attention"`; image
`"bell.badge"`. Its doc comment becomes:

```swift
/// The panes, and the order they sit in: General, Attention, About.
///
/// An entitlement pane joins only when something is actually sold: before a StoreKit
/// product is registered it would be a button that fails.
///
/// About stays last, because it answers a question you only ask with a bug report open.
```

`SettingsView.body`: `case .attention: AttentionPane()`.

`GeneralPane`: delete the `notifiesTurnEnds` `@AppStorage` and its `Section`.

After `GeneralPane`:

```swift
/// What wants the person, and how loudly: per level, whether it counts, badges, notifies.
struct AttentionPane: View {
  @AppStorage(PreferenceKey.recognisesAsks) private var recognisesAsks = true
  @AppStorage(PreferenceKey.notifiesTurnEnds) private var notifiesTurnEnds = false

  var body: some View {
    Form {
      Section {
        Toggle("Recognise questions and offers at the end of a turn", isOn: $recognisesAsks)
          .accessibilityIdentifier("settings.recognisesAsks")
      } footer: {
        Text(
          "A reply that ends on a question, such as “Want me to build it that way?”, marks its session “Asked you”; one that ends on an offer marks it “Offered”. Either stays until you answer or dismiss it (⌥⌘D)."
        )
      }
      Section {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
          GridRow {
            Text("")
            Text("Counts").gridColumnAlignment(.center)
            Text("Dock badge").gridColumnAlignment(.center)
            Text("Notification").gridColumnAlignment(.center)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          ForEach(Urgency.allCases.reversed(), id: \.self) { level in
            GridRow {
              Text(level.title)
              ForEach(AttentionFeedback.allCases, id: \.self) { feedback in
                FeedbackToggle(level: level, feedback: feedback)
                  .disabled(!recognisesAsks && (level == .question || level == .offer))
              }
            }
          }
          GridRow {
            Text("Finished turn")
            Text("")
            Text("")
            Toggle("", isOn: $notifiesTurnEnds)
              .labelsHidden()
              .accessibilityIdentifier("settings.notifiesTurnEnds")
          }
        }
      } footer: {
        Text(
          "Counts puts the session in the sidebar's count and in Next Session Needing You (⌥⌘↓). Drakar notifies unless the session is the one you are looking at."
        )
      }
    }
    .formStyle(.grouped)
    .onChange(of: recognisesAsks) { Attention.shared.refresh() }
  }
}

/// One switch of the Attention grid, on its own key.
private struct FeedbackToggle: View {
  let level: Urgency
  let feedback: AttentionFeedback
  @AppStorage private var isOn: Bool

  init(level: Urgency, feedback: AttentionFeedback) {
    self.level = level
    self.feedback = feedback
    _isOn = AppStorage(
      wrappedValue: AttentionChoice.defaultValue(level, feedback),
      AttentionChoice.key(level, feedback))
  }

  var body: some View {
    Toggle("", isOn: $isOn)
      .labelsHidden()
      .gridColumnAlignment(.center)
      .onChange(of: isOn) { Attention.shared.refresh() }
      .accessibilityIdentifier("settings.\(level.rawValue).\(feedback.rawValue)")
  }
}
```

In `Attention.swift`, add to `Urgency`:

```swift
  /// Its row in the Attention pane.
  var title: String {
    switch self {
    case .permission: String(localized: "Permission request")
    case .choice: String(localized: "Choice to make")
    case .question: String(localized: "Question")
    case .offer: String(localized: "Offer")
    }
  }
```

- [ ] **Step 4: Run the tests**

Run: `make -C apps/apple test-app > $W/t9.log 2>&1; grep -E "error:|Test run|passed|failed" $W/t9.log | head`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): an Attention pane for what counts, badges and notifies, level by level"
```

---

### Task 10: See it work

No new code unless something is broken; a fix goes in its own commit with a test.

- [ ] **Step 1: The whole suite and the audit**

```bash
make -C apps/apple test-all > $W/t10.log 2>&1; tail -20 $W/t10.log
make audit
make -C apps/apple format-swift-check
```

Expected: all green.

- [ ] **Step 2: In the running app**

Run: `make -C apps/apple run`. Open two project windows. In window A, start a session and
send: "Reply with exactly: I looked at it. Want me to build it that way?" Switch to window B
while it runs. Check, with a screenshot each:

1. A notification with the session's title and "Want me to build it that way?"; the Dock
   badge reads 1.
2. Window A: a blue ring, "Asked you", the question on the second line, the header count 1.
3. Select the row: the mark stays. ⌥⌘D: it goes, the badge clears, the notification is
   withdrawn.
4. Send "Reply with exactly: Done. Say the word and I'll tag it.": a grey ring, "Offered",
   no badge, no notification.
5. Send "Use the AskUserQuestion tool to ask me whether to call the file a.txt or b.txt,
   then tell me which I picked.": the choice sheet; pick b.txt, Answer; the reply names b.txt.
6. Settings → Attention: the grid; turn Offer → Counts on, and the offered row counts.
7. Quit with a question unanswered and relaunch: the restored row is marked again.

- [ ] **Step 3: Report**

Tell the person what passed, with the screenshots, and anything that did not.
