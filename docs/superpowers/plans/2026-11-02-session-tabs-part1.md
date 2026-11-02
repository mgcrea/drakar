# Session Tabs (Part 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project window's sessions become tabs over the session pane, closed with × or ⌘W without killing a turn, and switching tabs is instant.

**Architecture:** The tab model lives in `Project` (order, preview tab, closing), the strip is a new SwiftUI view over the session pane, and recently shown sessions stay built in an AppKit deck of `NSHostingView`s. A tab closed at work goes to the session host with a new `endWhen` request (host minor 5) and a `closedAtWork` mark in its `SessionMeta`, so no window takes it back on its own and it ends when its turn does.

**Tech Stack:** Swift 6, SwiftUI + AppKit (macOS 26), Swift Testing, DrakarKit (local SPM package).

**Spec:** `docs/superpowers/specs/2026-11-02-session-tabs-design.md` (Part 1 only; Part 2 is a later plan).

## Global Constraints

- Never `make run` / `make quit` or anything that relaunches Drakar: the person's running instance hosts live sessions. Verify with `xcodebuild build` / `test` only.
- App tests: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -derivedDataPath apps/apple/.build -only-testing:DrakarTests/<Suite>`. Kit tests: `swift test --package-path apps/apple/Packages/DrakarKit --filter <Suite>`.
- Format touched files with `xcrun swift-format format --in-place <files>`; `xcrun swift-format lint --strict <files>` must print nothing.
- Known flakes (CapabilityProbe, SessionMoves, some Reattach timings) fail under load: rerun alone before calling a regression.
- Commit style: `feat(app): …` / `feat(kit): …` / `test(…)`, body explains why, ends with `Co-Authored-By: Claude <noreply@anthropic.com>`. Stage only the task's files: other sessions commit on `main` at the same time.
- Closing a tab never kills a turn and never asks, except: an unsent draft or attachments, or a session at work that is not hosted (`stoppedByLeaving`).
- Performance budgets (spec, Performance): warm switch next frame (<16 ms main thread), cold switch chrome next frame and transcript ≤100 ms, background streaming costs the strip one tab, close next frame. No wall-clock assertions in tests.
- Copy: "Close Tab", "Close Other Tabs", "Close Tabs to the Right". No dialog for hosted work at all.

## Review Focus

1. Closing the selected tab: selection goes to the tab on its right, else its left, never jumps to the first tab. (Task 3 test `closingTheSelectedTabShowsItsNeighbour`.)
2. Closing a tab whose session waits on a permission or a question (`isWaitingOnPerson`) hands it over like a running one, and `endWhen` does not end it while it waits (the turn-end markers exclude `can_use_tool` / `elicitation`). (Task 2 test `aTabClosedWhileAskingIsNotEndedByTheAsk`.)
3. Typing in the preview tab, then opening another Elsewhere row: the typed draft must not vanish; a preview with a non-empty draft is promoted instead of replaced. (Task 3 test `aPreviewWithADraftIsKeptAsATab`.)
4. A host older than minor 5: closing at work still hands over and marks `closedAtWork`, sends no `endWhen`, and the process lingers as a background one (no crash, no refused request logged as an error). (Task 1 test `anOlderHostIsNotAskedToEnd`.)
5. A closed-at-work process whose window reopens or whose app relaunches is not adopted and opens no window; opening it from Elsewhere brings it back live and clears the mark. (Task 2 tests `aTabClosedAtWorkStaysClosedWhenTheWindowReopens`, `heldWindowsSkipATabClosedAtWork`, `reopeningClearsTheMark`.)

---

### Task 1: Host `endWhen` request (minor 5)

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostWire.swift` (request case, `minor = 5`)
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostCore.swift` (`Held.endsWhen`, request handling, `take(_:from:_:_:)`)
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostServer.swift:197` (route the id like `.keepAwake`)
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostClient.swift:275` (same grouping as `.keepAwake`)
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostedProcess.swift` (`endWhen(until:)`)
- Modify: `docs/session-host.md` (Requests table row, Versions section)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/HostCoreTests.swift`, `HostWireTests.swift`, `HostedProcessTests.swift`

**Interfaces:**
- Produces: `HostRequest.endWhen(id: String, until: [Data])`; `HostWire.minor == 5`; `HostedProcess.endWhen(until: [Data])` (no-op when `(hostMinor ?? 0) < 5`; an empty `until` takes it back).
- Host behaviour: while `endsWhen` is non-empty and the process runs, a stdout line containing any marker makes the host terminate it with `forget` semantics (as `terminate {forget: true}`): it is forgotten once ended and other clients get `released`. The line is logged first. Exit clears `endsWhen`.

- [ ] **Step 1: Write the failing tests**

`HostWireTests`: `endWhenRoundTrips` — encode `.endWhen(id: "x", until: [Data("a".utf8)])`, decode, `#expect` equal.

`HostCoreTests` (use the suite's existing spawn helpers and a stand-in that echoes stdin lines to stdout):
- `endWhenEndsTheProcessOnAMarkedLine`: spawn, send `.endWhen(id, until: [Data(#""type":"result""#.utf8)])`, write a line holding `"type":"result"`; `#expect` the process is gone from `list()` within the suite's usual wait, and a second client received `.released(id:)`.
- `endWhenIgnoresOtherLines`: same with a line without the marker; `#expect` still listed and `running`.
- `anEmptyEndWhenTakesItBack`: set, then `.endWhen(id, until: [])`, then the marked line; `#expect` still running.
- `endWhenFromAnotherAppIsRefused`: attached by client A, B sends it; `#expect` the reply is the suite's `taken` refusal (same path as `update`).

`HostedProcessTests`: `anOlderHostIsNotAskedToEnd` — with the suite's stand-in host at minor 4, `endWhen(until:)` sends nothing (assert on the recorded requests the suite already inspects for `keepAwake`).

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter 'HostWireTests|HostCoreTests|HostedProcessTests'`
Expected: compile failure, no `endWhen` member.

- [ ] **Step 3: Implement**

`Held.endsWhen: [Data] = []`. In `handle`, `.endWhen(let id, let until)` goes through `update(id, from:)` setting `endsWhen = exitStatus == nil ? until.filter { !$0.isEmpty } : []`. In `take`, for `.line`, after `append`, if a marker matches: clear `endsWhen`, set `held.forgets = true`, and terminate the child off the lock, the same way `terminate(_:forgetting:from:)` does (factor a private helper both use rather than copying). `.exited` clears `endsWhen`. `HostedProcess.endWhen(until:)` mirrors `keepAwake(until:)` with the minor-5 guard. Docs: row `endWhen {id, until}` — "Minor 5. Ends the process, and forgets it once ended, when it writes a line holding any of `until`; an empty `until` takes it back. The app sends it for a tab closed while the agent works, with the lines where a turn ends (`AgentKind.turnEnds`)."

- [ ] **Step 4: Run to verify they pass**

Same command. Expected: all pass.

- [ ] **Step 5: Commit**

`git add` the files above; `git commit -m "feat(kit): the host ends a process when its turn does (endWhen, minor 5)"`.

---

### Task 2: Closing a tab: hand-over, `closedAtWork`, staying closed

**Files:**
- Modify: `apps/apple/Drakar/Services/SessionMeta.swift` (`closedAtWork: Bool?`)
- Modify: `apps/apple/Drakar/Services/KeepAwake.swift:138-158` (add `AgentKind.turnEnds` beside `pauses`)
- Modify: `apps/apple/Drakar/Services/AgentSession.swift` (`closeTab()`, `reopenedAfterClose()`; `AgentSession.swift:576` is where meta is written)
- Modify: `apps/apple/Drakar/Services/Project.swift` (`closeTab(_:)`, `closeAsk(for:)`, `adoptHeld` filter, `reopen` clears)
- Modify: `apps/apple/Drakar/DrakarApp.swift:494-505` (`HeldWindows.folders(of:)` skips `closedAtWork`)
- Test: create `apps/apple/DrakarTests/CloseTabTests.swift` (fixtures copied from `ReattachTests`: `LocalHost`, the `go-stream` / `go-ask` stand-in script, `window(on:)`, `start`, `eventually`)

**Interfaces:**
- Produces:
  - `extension AgentKind { var turnEnds: [Data] }` — Claude `"type":"result"`, Codex `"method":"turn/completed"`. Never the ask markers.
  - `SessionMeta.closedAtWork: Bool?` (nil = not closed; optional so old metas decode).
  - `AgentSession.closeTab()` — at work and hosted: writes meta with `closedAtWork = true`, `hosted.endWhen(until: agent.turnEnds)`, then `stop(handingOver: true)`. Otherwise `stop()`.
  - `AgentSession.reopenedAfterClose()` — clears `closedAtWork` in meta and sends `endWhen(until: [])`.
  - `enum CloseAsk { case unsentDraft, stopsTurn }`; `Project.closeAsk(for: ProjectSession) -> CloseAsk?` — `.unsentDraft` when the trimmed draft or attachments are non-empty; `.stopsTurn` when `isAtWork` and not hosted (`RunningSessions.stoppedByLeaving([session]) > 0`); nil otherwise. Draft wins when both.
  - `Project.closeTab(_ item: ProjectSession)` — calls `item.session.closeTab()`, then removes the row as `remove(_:)` does minus the stop (refactor `remove` to share the bookkeeping), selecting the neighbour (Task 3 defines `neighbour(of:)`; until then keep `remove`'s current selection rule and let Task 3 change both).
- `adoptHeld` skips a process whose meta has `closedAtWork == true` (both `free` and `elsewhere`), except when called from `reopen(_:among:)`, which first calls `reopenedAfterClose()` on the taken-back session (or clears the meta via `setMeta` before adopting; implementer picks, the test pins the result).

- [ ] **Step 1: Write the failing tests** (`CloseTabTests`, `@MainActor @Suite("Closing a tab")`, `.timeLimit(.minutes(2))` as the host suites have)

- `aTabClosedAtWorkKeepsWorkingInTheHost`: start `go-stream`, wait for "one", `project.closeTab(row)`; `#expect(project.sessions.isEmpty)`; `#expect` host lists it with `attachedApp == nil` and `running`; `try step("a")`; host log grows.
- `aTabClosedAtWorkEndsWithItsTurn`: `go-stream`, close, `step("a")`, `step("b")`, then make the stand-in print a `result` line (add a `go-stream-end` case to the script that says three then the result line); `#expect` host no longer lists it.
- `aTabClosedWhileAskingIsNotEndedByTheAsk`: `go-ask` (prints `can_use_tool`), close; `#expect` still listed and running after the request line was written.
- `aTabClosedAtWorkStaysClosedWhenTheWindowReopens`: close at work; a new `window(on: app)` runs `adoptHeld(await app.held())`; `#expect(back.sessions.isEmpty)`.
- `heldWindowsSkipATabClosedAtWork`: `HeldWindows.folders(of:)` over a `HeldProcess` whose meta has `closedAtWork: true` returns `[]`; one without it returns its folder.
- `reopeningClearsTheMark`: close at work, then `await back.reopen(id, among: await app.held())`; `#expect(back.sessions.count == 1)`, live (`isHosted`, `transcript.isRunning`); decoding the host's meta gives `closedAtWork == nil`.
- `anIdleTabClosesAndEnds`: `go-idle`, wait for the turn to end, close; `#expect` host forgets it (as today's idle stop).
- `closeAskSaysWhatWouldBeLost`: no host needed. A row with draft "hi" → `.unsentDraft`; empty draft, idle → nil.

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test … -only-testing:DrakarTests/CloseTabTests`
Expected: compile failure (`closeTab`, `closedAtWork` missing).

- [ ] **Step 3: Implement** the interfaces above. `stop(handingOver: true)` already detaches a hosted session at work (`AgentSession.swift:1383`); `closeTab()` only adds the meta and `endWhen` before it. `HeldWindows.folders(of:)` adds `meta.closedAtWork != true` to its guard.

- [ ] **Step 4: Run to verify they pass**, then `-only-testing:DrakarTests/ReattachTests` to check nothing it covers moved.

- [ ] **Step 5: Commit** — `feat(app): a tab closed at work goes on in the host and ends with its turn`.

---

### Task 3: Tab order, the preview tab, stepping through tabs

**Files:**
- Modify: `apps/apple/Drakar/Services/Project.swift` (`newSession`, `attach`, `takeOver`, `remove`/`closeTab` selection, `step`, new `moveTab`, `neighbour(of:)`, `promote(_:)`)
- Modify: `apps/apple/DrakarTests/SessionStepTests.swift` (order assumptions change)
- Test: create `apps/apple/DrakarTests/TabOrderTests.swift`

**Interfaces:**
- Produces:
  - `Project.tabs: [ProjectSession]` — `sessions` in order (held rows and the preview), the strip's source.
  - Insertion: `newSession` and `attach` insert right of the selected tab (`index(of selected) + 1`), at the end when none is selected. Replaces today's insert at 0.
  - Preview: `attach(_, watching: true, …)` first removes the current preview (the one `isWatching` row, stopped as `remove` stops it) unless that preview has a non-empty trimmed draft or attachments, in which case it is promoted (`takeOver`) and kept. Then inserts the new preview right of the selected tab.
  - `takeOver(_:)` keeps the row where it is (no move to 0).
  - `Project.promote(_ item: ProjectSession)` — `takeOver(item)` for double-click on a preview tab or its sidebar row.
  - `Project.moveTab(_ id: ProjectSession.ID, to index: Int)` — reorders `sessions`; clamps; selection unchanged.
  - `Project.neighbour(of item: ProjectSession) -> ProjectSession?` — the tab right of it, else left, else nil. `remove` and `closeTab` select it when the removed tab was selected.
  - `step(_:wrapping:focusingComposer:)` walks `tabs` only (no Elsewhere / Ended rows). `nextNeedingAttention` unchanged (it still reaches Elsewhere, shown via `openElsewhere`, which is now a preview).
  - `listedHeld` keeps sorting for nothing but Elsewhere's comparator; the strip never reads it. `markedSessions` and `click(.extend)` use `tabs` order.

- [ ] **Step 1: Write the failing tests** (`TabOrderTests`, plain `Project(folder:)` as `SessionStepTests` makes it)

- `aNewSessionOpensRightOfTheSelectedTab`: a, b, c made (each selected on creation) → `tabs` = [a, b, c]; `select(a)`; new d → [a, d, b, c].
- `closingTheSelectedTabShowsItsNeighbour`: [a, b, c], `select(b)`, `remove(b)` → selected c; `select(c)`, `remove(c)` → selected a.
- `aSecondPreviewReplacesTheFirst`: two `openEnded` of two `SessionSummary` stand-ins (build them as `SessionStepTests.theArrowKeysKeepTheKeysOnAnEndedRow` does) → exactly one `isWatching` row, the second.
- `aPreviewWithADraftIsKeptAsATab`: open preview p, `p.draft = "half"`, open another → p is a normal tab (`!p.isWatching`), still in `tabs`, plus the new preview.
- `takingUpAPreviewKeepsItsPlace`: [a, p, b] with p preview; `takeOver(p)` → order unchanged.
- `moveTabReorders`: [a, b, c], `moveTab(c.id, to: 0)` → [c, a, b]; out-of-range index clamps.
- In `SessionStepTests`, rewrite order expectations for the new insertion (`nextAndPreviousWalkTheListAndWrap`: rows a, b, c in creation order) and replace the Ended / Elsewhere stepping tests with `stepStaysInTheTabs`: with an Ended row present and `showsEnded = true`, `step(1, wrapping: true)` from the last tab goes to the first tab, not the Ended row.

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test … -only-testing:DrakarTests/TabOrderTests -only-testing:DrakarTests/SessionStepTests`
Expected: FAIL on order and preview assertions.

- [ ] **Step 3: Implement** the interfaces above. Then grep the test target for order assumptions that broke (`sessions.first`, `sessions[0]`) and fix those tests to the new order, not the code: `rg -n 'sessions\.first|sessions\[0\]' apps/apple/DrakarTests`.

- [ ] **Step 4: Run** `-only-testing:DrakarTests/TabOrderTests -only-testing:DrakarTests/SessionStepTests -only-testing:DrakarTests/ProjectTests -only-testing:DrakarTests/ProjectFanOutTests`. Expected: pass.

- [ ] **Step 5: Commit** — `feat(app): sessions open right of the shown one, and one preview at a time`.

---

### Task 4: The tab strip, and the sidebar without "This Window"

**Files:**
- Create: `apps/apple/Drakar/Views/SessionTabStrip.swift` (`SessionTabStrip`, `SessionTab`, `TabStatus`)
- Create: `apps/apple/Drakar/Views/SessionMenu.swift` (the row menu moved out of `ProjectSidebar.menu(for:)`, plus `confirmEnding` it needs)
- Modify: `apps/apple/Drakar/Views/ProjectSidebar.swift` (remove the "This Window" section; `FanOutBanner`s go to the top of the list; held-row key handling goes)
- Modify: `apps/apple/Drakar/ContentView.swift:437-462` (strip above the pane; full deck comes in Task 5)
- Modify: `apps/apple/Drakar/Services/Project.swift` (`closeOthers(than:)`, `closeToTheRight(of:)`)
- Test: create `apps/apple/DrakarTests/SessionTabTests.swift`

**Interfaces:**
- Consumes: `Project.tabs`, `moveTab`, `promote`, `closeTab`, `closeAsk(for:)`, `click(_:_:)`, `markAll`, `clearMarks`, `RowState` / `StateDot` (`ProjectSidebar.swift`), `ProjectSession.displayTitle`, `urgency`, `isUnread`.
- Produces:
  - `enum TabStatus: Equatable { case needsYou, working, unread, none }` with `static func of(_ item: ProjectSession) -> TabStatus` — priority needsYou (`urgency` at a level that counts, or `transcript.isWaitingOnPerson`) > working (`transcript.isRunning`) > unread > none.
  - `struct SessionTab: View, Equatable` — inputs: `title`, `status`, `agent`, `isSelected`, `isMarked`, `isPreview`, `tooltip`, closures excluded from `==`. Drawn with `StateDot`-style marks; the spinner is a `ProgressView().controlSize(.mini)` only if Task 6's measurement allows, else a static glyph (start with the static `circle.dotted`).
  - `enum TabClosing { @MainActor static func request(_ item: ProjectSession, in project: Project) }` in `SessionMenu.swift` — `project.closeAsk(for:)` nil → `project.closeTab(item)`; `.unsentDraft` → `NSAlert` "Close “\(title)”? Its unsent message will be lost." [Close] [Cancel]; `.stopsTurn` → the alert `ProjectSidebar.confirmIfRunning` shows today. The × and ⌘W (Task 6) both call it.
  - `Project.closeOthers(than: ProjectSession)`, `closeToTheRight(of: ProjectSession)` — `closeTab` on each tab whose `closeAsk(for:)` is nil; any that would ask stays open.
- Strip behaviour: horizontal `ScrollView` + `ScrollViewReader` scrolling the selected tab into view; tabs `minWidth: 120`, `maxWidth: 220`, title `.truncationMode(.middle)`; × visible on hover and on the selected tab; plain click → `click(.plain)` + `focusRequest += 1`; ⌘-click → `.toggle`; ⇧-click → `.extend`; double-click on a preview → `promote`; drag reorder with `.draggable(item.id.uuidString)` / `.dropDestination(for: String.self)` → `moveTab`; context menu = `SessionMenu(item:)` with "Close Tab", "Close Other Tabs", "Close Tabs to the Right". When focused: ←/→ step (`step(±1, wrapping: false, focusingComposer: false)`), Esc clears marks, ⌘A marks all; `FocusedPane.sessions` means the strip. The strip reads only per-tab values; it must not read `transcript.entries`.

- [ ] **Step 1: Write the failing tests** (`SessionTabTests`)

- `statusPrefersWhatNeedsYou`: a row with a pending permission in its transcript and `isRunning` → `.needsYou` (build the transcript state the way `AgentSessionRepliesTests` feeds permission lines); running only → `.working`; `isUnread` only → `.unread`; fresh → `.none`.
- `aTabIsEqualWhateverItsClosures`: two `SessionTab`s with the same values and different closures are `==`; changing `status` makes them unequal.
- `closeOthersKeepsTheOneAndAnyThatWouldAsk`: [a, b, c], `c.draft = "x"`, `closeOthers(than: a)` → `tabs == [a, c]`.
- `closeToTheRight`: [a, b, c], `closeToTheRight(of: a)` → [a].

- [ ] **Step 2: Run** `-only-testing:DrakarTests/SessionTabTests`. Expected: compile failure.

- [ ] **Step 3: Implement** the files above. Remove "This Window" from `ProjectSidebar.list`; keep Elsewhere / Ended; an Elsewhere or Ended row double-click → open then `promote`. `SessionsHeader` keeps New Session and the sort menu (sorting Elsewhere).

- [ ] **Step 4: Run** `-only-testing:DrakarTests/SessionTabTests -only-testing:DrakarTests/SessionStepTests`, then `xcodebuild build` for the whole app. Expected: pass, build clean, no new warnings in the touched files.

- [ ] **Step 5: Commit** — `feat(app): sessions are tabs over the session pane, closed with ×`.

---

### Task 5: Keep-alive session deck, with signposts

**Files:**
- Create: `apps/apple/Drakar/Views/SessionDeck.swift` (`RecentlyShown`, `SessionDeck`)
- Create: `apps/apple/Drakar/Services/TabSignposts.swift`
- Modify: `apps/apple/Drakar/ContentView.swift:437-462` (`SelectedSessionPane` uses the deck)
- Test: create `apps/apple/DrakarTests/RecentlyShownTests.swift`

**Interfaces:**
- Produces:
  - `struct RecentlyShown<ID: Hashable> { init(capacity: Int); mutating func show(_ id: ID) -> [ID] /* evicted */; mutating func remove(_ id: ID); var ids: [ID] /* most recent first */ }`.
  - `struct SessionDeck: NSViewRepresentable` — inputs `project: Project`, `selectedID`, capacity 6. Keeps one `NSHostingView(rootView: SessionView(item:project:).themed())` per id in `RecentlyShown`; on selection, the selected host view becomes the container's only subview (pinned edges); evicted or removed sessions' host views are released. Hidden ones are retained but not in the window.
  - Cold path: the selected session's view is shown at once; `loadHistory()` runs in the background (no `await` before showing, unlike today's `.task(id:)`), the transcript filling in when it lands.
  - `enum TabSignposts { static let signposter = OSSignposter(subsystem: "io.mgcrea.Drakar", category: "tabs"); static func switchBegan(to: ProjectSession.ID) -> OSSignpostIntervalState; static func switchDrawn(_ state: OSSignpostIntervalState) }` plus `historyLoad` and `closeTab` intervals. `switchBegan` is called where the selection changes (`Project.select`), `switchDrawn` from the deck after the host view is in the window and has laid out once (`DispatchQueue.main.async` after `layoutSubtreeIfNeeded`).
- The empty state ("No session" + New Session) stays when there is no tab.

- [ ] **Step 1: Write the failing tests** (`RecentlyShownTests`)

- `showingPastCapacityEvictsTheOldest`: capacity 3; show 1, 2, 3 → evicted []; show 4 → evicted [1]; `ids == [4, 3, 2]`.
- `showingAgainMovesToFront`: 1, 2, 3, show 1 → `ids == [1, 3, 2]`, evicted [].
- `removeForgets`: remove 2 → not in `ids`; showing 4, 5 later evicts in the right order.

- [ ] **Step 2: Run** `-only-testing:DrakarTests/RecentlyShownTests`. Expected: compile failure.

- [ ] **Step 3: Implement** `RecentlyShown`, then `SessionDeck` and the signposts, then swap `SelectedSessionPane` onto it. Keep the composer focus behaviour: after a switch the shown item gets `focusRequest += 1` when `project.focusesComposer`, as `step` and clicks do now.

- [ ] **Step 4: Run** `-only-testing:DrakarTests/RecentlyShownTests`, then the whole app suite once: `xcodebuild test … -derivedDataPath apps/apple/.build` (rerun any known flake alone). Expected: pass.

- [ ] **Step 5: Commit** — `feat(app): recently shown sessions stay built, so a tab switch draws at once`.

---

### Task 6: Keys and ⌘W

**Files:**
- Modify: `apps/apple/Drakar/DrakarApp.swift:391-406` (`CloseCommands`), `:160-180` (session commands)
- Create: `apps/apple/Drakar/Services/CloseTarget.swift`
- Test: create `apps/apple/DrakarTests/CloseTargetTests.swift`

**Interfaces:**
- Produces: `enum CloseTarget: Equatable { case document, tab, window; static func resolve(focusedPane: FocusedPane?, hasActiveDocument: Bool, hasSelectedTab: Bool) -> CloseTarget }` — `.document` iff `focusedPane == .editor && hasActiveDocument`; else `.tab` iff `hasSelectedTab`; else `.window`.
- `CloseCommands`: ⌘W titled "Close Tab" for `.document` and `.tab`, "Close" for `.window`; `.tab` calls `TabClosing.request(selected, in: project)`. Reads `@FocusedValue(\.project)` beside `\.workspace`. ⇧⌘W unchanged.
- Session menu adds: "Select Tab 1"…"Select Tab 8" (⌘1–⌘8) and "Select Last Tab" (⌘9); "Show Next Tab" (⌃Tab and ⇧⌘]) and "Show Previous Tab" (⌃⇧Tab and ⇧⌘[), both `step(±1, wrapping: true)`. If ⌃Tab does not reach the menu from the composer (AppKit's key-view loop can take it), keep ⇧⌘] / ⇧⌘[ and note it in the commit; do not add a local monitor.
- `Project.selectTab(at index: Int)` — index 8 means last; out of range does nothing.

- [ ] **Step 1: Write the failing tests** (`CloseTargetTests`)

- `theEditorsFileWhenTheEditorHasTheKeys`: `resolve(.editor, true, true) == .document`.
- `theTabOtherwise`: `resolve(.composer, true, true) == .tab`; `resolve(.editor, false, true) == .tab`; `resolve(nil, false, true) == .tab`.
- `theWindowWithNoTab`: `resolve(.composer, false, false) == .window`.
- `selectTabByNumber`: [a, b, c]; `selectTab(at: 1)` → b; `selectTab(at: 8)` → c; `selectTab(at: 5)` → selection unchanged.

- [ ] **Step 2: Run** `-only-testing:DrakarTests/CloseTargetTests`. Expected: compile failure.

- [ ] **Step 3: Implement**.

- [ ] **Step 4: Run** `-only-testing:DrakarTests/CloseTargetTests`, then `xcodebuild build`. Expected: pass.

- [ ] **Step 5: Commit** — `feat(app): ⌘W closes the shown tab, ⌘1–⌘9 and ⌃Tab move between them`.

---

### Task 7: Whole-branch check and the person's hand check

**Files:** none new.

- [ ] **Step 1:** Full suites: `swift test --package-path apps/apple/Packages/DrakarKit` and the app suite. Known flakes rerun alone; anything failing alone is a finding.
- [ ] **Step 2:** `xcrun swift-format lint --strict` over every file the branch touched: no output.
- [ ] **Step 3:** Write the hand-check list into the final message, for the person (Drakar is not relaunched from here): a window with a dozen tabs; close an idle tab, a working one (it shows under Elsewhere, then ends when its turn does), one with a draft (asks); reopen the window and relaunch (the closed one does not come back); ⌘W with the editor focused vs the composer; ⌘1–⌘9, ⌃Tab; Instruments with the `io.mgcrea.Drakar` / `tabs` signposts: warm switch, cold switch, close, against the budgets in the spec.

---

## Self-review notes

- Spec coverage, Part 1: strip (Task 4), status marks (4), tooltip (4: `tooltip` input, built from the row's status line, account, subfolder), order and drag (3, 4), overflow and ⌘1–⌘9 (4, 6), empty state (5), closing rules incl. draft and non-hosted (2, 4), after-close life (1, 2), ⌘W and keys (6), sidebar changes incl. marking, context menu, fan-out banners, preview tab (3, 4), keep-alive and signposts (5), budgets checked by hand (7).
- Not in Part 1: plain windows, Go to Session, Home window (Part 2 plan).
