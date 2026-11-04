# Main-thread performance

The person wants the fastest UI possible, and the main thread is where Drakar loses it:
every window, every session's stream and every file watcher end up there. This is how to
measure it, the rules that keep a streamed token from redrawing the app, and what was tried.
Measured on this Mac (Xcode 27.2, Swift 6.4.2) in November 2026.

## Measuring

- **`make -C apps/apple profile`** attaches Time Profiler to the running Drakar and prints
  the main thread's busy share, its heaviest app functions (inclusive) and its heaviest leaves.
  Profile a Release build made here (`make build-release`): Debug inflates the app's own
  frames. A notarized build should refuse the attach (hardened runtime, no `get-task-allow`);
  not tried.
- **`make -C apps/apple bench`** runs `DrakarTests/SessionStreamingBench`: a stand-in
  `claude` writes 60 replies, then streams 1,000 tokens at about 60 a second into a
  `SessionView` on screen, and the test prints the main thread's CPU per token
  (`BENCH streaming: …`). It builds Release with testability into `.build/bench`, so it never
  rewrites a Release app that is running, and it is skipped unless `DRAKAR_BENCH` is set.
  Run-to-run noise is about ±1 ms a token: run it three times before believing a small
  change. Its idle control (the test host doing nothing for 12 s) costs 7–16% of a core by
  itself, inside the streaming figure too.
- **To see where the bench's time goes**, profile its test host while it streams:
  `scripts/profile.py --pid <pid> --seconds 12 --keep`, about 15 s after the process under
  `.build/bench/Build/Products/Release/Drakar.app` appears. `--keep` leaves the trace for
  `xcrun xctrace export`.
- **The live app under real agents is not a benchmark.** Its load is whatever the agents are
  doing: the same build measured 47% busy with several streaming and 1.5% with one.
- **The SwiftUI Instruments template's timings are wrong.** It records a backtrace on every
  observation `willSet`, so its own symbolication (`dyld findClosestDefinedSymbol`) shows up
  as the app's cost: one run blamed 17% of the main thread on `AgentSession.transcript.modify`
  that Time Profiler did not see. Use it for counts. Attached to a running app, most updates
  are "created before tracing started", and its updates table exported 4 GB for 30 s.

## Rules that keep a token from redrawing the app

- **Outside the transcript view, read `session.status`, never `session.transcript`.** A view
  body that reads any `session.transcript.X` observes the whole transcript, which changes on
  every token: before `Transcript.Status` existed, a token in any session redrew every
  window's sidebar, Home, attention and keep-awake, and every token of a session rebuilt its
  composer. `Status` carries what rows, counts, the pane's panels, pills, footer and inspector
  read; add a field there rather than reading the transcript.
- **The transcript view draws `session.displayedTranscript`**, which takes growing text at
  most every 50 ms (20 a second, the person's choice); a new entry, a queued prompt or a change
  of `status` is drawn at once. Actions (rewind, fork) read `transcript`, the source of truth.
- **`Transcript.status` runs after every event, so it must stay O(1).** Anything that walks
  the entries makes a long replay quadratic: a first-prompt scan took
  `ReattachTests.aLongLogReplaysQuickly` (50,000 lines, about 3 s) past its 120 s limit,
  hence `firstPromptIndex`.
- **A second reference to the transcript makes the next in-place change copy every entry.**
  Publishing `displayedTranscript` on every new entry made the same replay take 105 s; while
  a log replays it is published on the 50 ms beat only. For the same reason `transcript`'s
  `didSet` never reads `oldValue`.
- **`@Observable` does not notify when an `Equatable` property is assigned an equal value**
  (the macro's `shouldNotifyObservers`, in Swift 6.2 and later, and in 1.2.0's CI build with
  Xcode 26.6: `nm` shows the helpers). Reassigning an unchanged `Equatable` value is not a
  redraw; a non-`Equatable` one, or a mutation through `_modify`, always is.
- **Nothing O(n) in a `ForEach` row.** Home read a computed `stats` that walked every
  transcript folder once per row: 13 rows × 42 ms a redraw. Compute once above the list and
  let the rows read the result.

## What was tried and did not help

- **The composer's `safeAreaInset`.** In the bench profile, sizing the inset makes the
  transcript's `LazyVStack` measure estimates across every entry on each update (about 13% of
  the main thread, and O(entries)). Three rewrites changed nothing measurable (8.7 ms a token
  each): `.frame(minHeight: 0, maxHeight: .infinity)` on the transcript; the bar in a `ZStack`
  over it with `safeAreaPadding` (still `InsetViewLayout`); the same with
  `contentMargins(.bottom, …, for: .scrollContent)`. The lazy stack measures on each layout
  pass whatever wraps it: the lever was fewer passes, which `displayedTranscript` gives.

## Where it stands

`make bench` per token: 9.46 ms on e59b6cb; 7.5–8.7 ms after 9d9c95b (only `LiveTranscript`
reads the transcript in the session pane); 5.2–5.5 ms after 06ebcc8 (20 updates a second).
What is left of each update, from the bench profile, largest first:

- SwiftUI laying the transcript out again, the lazy stack's estimates across every entry
  included: long sessions cost more per update.
- `MarkdownView` parsing the whole streaming message again (`MarkdownBlock.parse` in its
  body).
- `TextSelection.Configuration.textLayoutManager` in layout, about 4%.
- `WorkingIndicator`: a `TimelineView` every 0.12 s, and its verb retyped every 40 ms.
- `LastPromptBar` reading `Entry.headline`, about 1%.
- Sidebar rows for sessions elsewhere each calling `OpenSessions.locate`, which walks every
  window's sessions, twice.
