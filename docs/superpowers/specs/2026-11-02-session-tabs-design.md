# Session tabs, plain project windows, Go to Session

Status: approved in conversation 2026-11-02, written up for planning.

## Why

Two complaints from the person, both about getting around:

1. **There is no quick way to close a session.** Today a session leaves a window only through its
   sidebar row's context menu (End Session, Remove from Window). ⌘W closes the active editor file,
   else the whole window.
2. **Native window tabs across projects are sluggish and make the UI clunky.** Every project is its
   own `NSWindow` (`WindowGroup(for: WindowRoute.self)`), grouped as macOS window tabs by ⌘T
   (`WindowTabs.open(_:asTab:)`) and at launch (`ReopenedWindows`, `addTabbedWindow`). Changing tab
   changes window: a whole `NavigationSplitView` with sidebar, editor and inspector comes forward.

And one standing requirement, said while this was being designed: **the fastest UI possible.** Speed
is a goal of this work, not a polish pass after it (see Performance).

The person asked whether "native gpui tabs" would help. gpui is Zed's Rust UI framework; hosting it
in this SwiftUI/AppKit app means rewriting the window, and the slowness is not in drawing a tab bar
but in swapping whole windows and rebuilding the session view. Not pursued.

## Goals

- Sessions of a project window are tabs over the session pane, VS Code style; × and ⌘W close one.
- Closing a tab never kills a turn and never asks.
- Project windows are plain windows: no macOS window tabs.
- One place to jump to any live session in any project (Go to Session), and Home as a window of its
  own for the overview.
- Switching tabs is instant once a session was shown, and fast when it was not (budgets below).

## Non-goals

- One window for every project (a project switcher inside a single window). Window-per-project stays:
  `Workspace`, the editor, `OpenSessions`, restoration and the session host all assume it.
- Tabs for editor files change nothing: the editor keeps its own `TabStrip` (`EditorView.swift`).
- Split panes of two sessions side by side.
- Pinned tabs, tab groups, tab colours.

## Anti-goals

- A tab bar that re-renders on every streamed token of every session.
- A close that loses work: a turn stopped, a draft or attachments dropped without trace.
- Tabs that move under the pointer because a session started or finished working.

## Part 1: session tabs (lands first)

### The strip

A strip of tabs at the top of the session pane (the `main:` side of `SplitPanes`, above
`SessionView`), one tab per session the window holds (`Project.held`), in the window's own order.

Each tab: the session's name (as the sidebar row names it today), a status mark, and a × shown on
hover and always on the selected tab. Status marks, one at a time, by priority:

- needs the person (a permission, a question, an MCP elicitation, a closing ask): an accent dot,
  the same urgency the sidebar row shows today;
- working (`transcript.isRunning`): a small spinner, or a static glyph if a spinner costs frames
  (Performance decides);
- finished while not shown (unread): a secondary dot, cleared when the tab is shown;
- otherwise nothing.

A Codex session shows its agent glyph before the name, as rows do now. Runner windows get the same
strip.

The tooltip carries what the row showed and the tab has no room for: the status line, the account,
the subfolder below the project.

Order: a new session opens right of the selected tab. Tabs move only by dragging; `SessionOrder`
(the sidebar's sort menu) no longer orders them, so nothing moves under the pointer. The order is
the window's stored order (`StoredProject.sessions`), so it survives a relaunch.

Overflow: tabs shrink to a minimum width (about 120 pt, name truncated in the middle), then the
strip scrolls horizontally and keeps the selected tab in view. ⌘1–⌘8 reach the first eight, ⌘9 the
last, as in browsers and VS Code.

The empty window (last tab closed, or none yet) keeps today's "No session" state with New Session
(⌘N). The window stays open.

### Closing

× on a tab, ⌘W with no editor focus, or Close Tab in the tab's context menu:

- **Idle session:** leaves the window at once (`Project.remove`). It is listed under Ended, or
  Elsewhere if another process has it, and comes back from there as today. No dialog.
- **Session at work** (`AgentSession.isAtWork`: a turn running, or waiting on the person): handed to
  the session host, as closing the window does (`stop(handingOver: true)`), and its row leaves the
  window, marked so the window does not take it straight back (below). It keeps working;
  Home and Go to Session list it, and opening it from either brings it back as a tab
  (`Project.reopen`). No dialog.
- **A draft or attachments in the closed tab's composer:** kept on the session's stored state if the
  builder finds a cheap place for it; otherwise closing asks only in this case. (Builder's call;
  a silent loss is the anti-goal.)
- Ending the process for real stays where it is: End Session in the tab's context menu, with its
  confirmation.

This supersedes the 2026-10-27 decision that "removing a row still stops" a session at work: a
closed tab hands over instead. Remove from Window in the context menu becomes Close Tab with the
same behaviour as ×.

A runner's session already carries on in its host whatever the stop; nothing changes for it.

**After a tab at work is closed** (settled after the builder check; calls, not the person's words):

- It stays closed. The process's own `SessionMeta` says so (`closedAtWork`, set with `setMeta`
  before the window lets go), so every window and every launch reads the same thing: neither a
  window reopening nor a relaunch takes the process back on its own (`adoptHeld` skips it), and
  `HeldWindows` opens no window for it.
- Its process ends once its turn does: the window asks the host to end it when it next goes idle
  (a new host request, which bumps the protocol minor; `docs/session-host.md` gets the request). A
  turn waiting on the person counts as at work and is not ended by this. Once ended it is an Ended
  row, resumable as any.
- Until then it is listed under Elsewhere in its own window's sidebar. Opening it there, from Home or
  from Go to Session takes it back as a live tab (`Project.reopen`, dropping it from the closed set
  and cancelling the end-when-idle), never as a read-only preview.
- **Not in the host** (a session running as the app's own child because the host could not be
  reached, `AgentSession.transport`): closing would stop its turn, so in this case only, closing asks,
  as closing the window does today (`stoppedByLeaving`).

### ⌘W and keys

- ⌘W: closes the active editor file when the editor pane has focus (`Workspace.focusedPane ==
  .editor`) and a file is open; otherwise closes the selected session tab. With no tab, it closes
  the window, as today.
- ⇧⌘W: Close Window, unchanged.
- ⌘1–⌘9: select a tab. ⌃Tab / ⌃⇧Tab: next / previous tab, wrapping.
- ⌘⌥↑ / ⌘⌥↓ (Previous / Next Session) move between tabs only, in tab order, wrapping. ⌘⌥⇧↓ (Next
  Session Needing You) goes through the tabs first, then still reaches a session waiting elsewhere
  (another process, a terminal `claude`), which it shows in the preview tab, as today it shows it
  watched.
- Esc in the session keeps interrupting the turn (unchanged).

### What moves off the sidebar

The tabs replace the sidebar's "This Window" section. Everything that section did moves to the strip:

- **Selection:** a click selects the tab, and focuses the composer, as a row click does.
- **Marking for broadcast:** ⌘-click and ⇧-click mark tabs, as they mark rows (`Project.click`,
  `RowClick`); a marked tab is drawn marked; Esc clears marks; ⌘A in the strip marks all.
  `BroadcastChip` in the composer is unchanged.
- **Context menu:** the row's menu (`ProjectSidebar.menu(for:)`) on the tab, with Remove from Window
  renamed Close Tab, plus Close Other Tabs and Close Tabs to the Right.
- **Fan-out banners** (`FanOutBanner`) move to the top of the sidebar, above Elsewhere.
- **Restored focus:** `FocusedPane.sessions` now means the strip (it can take arrow keys: ←/→ move
  the selection while the strip has focus).

The sidebar keeps Elsewhere and Ended. Opening a row from either shows it in the window's one
**preview tab**: name in italics, replaced by the next row opened, made a normal tab once the person
takes the session up here (sends a prompt, or double-clicks the tab or the row). Ended rows included,
so arrowing down the sidebar (`step` over its rows) leaves one preview tab, not a tab per row. The
exception is a tab closed at work, which comes back as a normal tab (see Closing). The sidebar's sort
menu keeps sorting Elsewhere.

## Part 2: across projects (lands second)

### Plain project windows

Project and picker windows set `tabbingMode = .disallowed`, so macOS never groups them, whatever the
"Prefer tabs" system setting. `ReopenedWindows` stops re-tabbing windows at launch;
`WindowTabs.open(_:asTab:)` loses its tab path (`join`, `tabHost`). File › New Tab (⌘T) goes; New
Window (⇧⌘N) and Open Project… (⌘O) stay and open a window. Window › Merge All Windows disappears
with tabbing.

A window macOS restores as a tab from before this change opens as a plain window.

### Go to Session (⇧⌘O)

A sheet like Quick Open (`QuickOpenView`): a search field over a list of every live session across
the app.

- Sources: every project window's held sessions (`OpenSessions`), and what the session host holds
  with no window attached (the "in the background" Home counts). Sessions of other processes
  (terminal `claude`) are not listed: they are not Drakar's to bring forward.
- Order: needs the person, then working, then idle; within each, most recent activity first.
- Each row: status mark, session name, project name, and the runner's name for a runner's.
- Typing filters by session name and project name (substring, case and diacritics ignored).
- Return or click: the project's window comes forward (opened if closed) with that session's tab
  selected; a background session is taken back as a tab (`Project.reopen`). Esc dismisses.
- Available from any Drakar window, including Home, and from the Window menu.

### Home as a window

Home (`HomeView`) becomes one window of its own, Window › Home (⌘0, unused today), brought forward
if open. It stays Home: picking a project there opens that project's window, or brings it forward,
and Home stays where it is; picking a session opens it as a tab of its project's window. So there is
no more picker window that turns into a project:

- File › New Window (⇧⌘N) goes; Window › Home and Open Project… (⌘O) cover it.
- Close Project (⇧⌘H) closes the project's window (its sessions at work handed to the host, as
  closing a window does) and brings Home forward.
- At launch, the project windows open as restored; Home opens too when none does. Clicking the Dock
  icon with no window open opens Home. Home is not otherwise restored.
- Routes stored as `.picker` before this change open Home, once.

Whether Home is a `Window` scene or stays a route of the `WindowGroup` is the builder's call.

## Performance

The person wants the fastest UI possible. Budgets, measured on this Mac with a Release build:

- **Warm tab switch** (a session shown before in this window): the new session fully drawn in the
  next frame, under 16 ms of main-thread time from the click.
- **Cold tab switch** (never shown since launch): the tab selects and the session's chrome (composer,
  header) draws in the next frame; the transcript within 100 ms for a typical session, and never a
  blank pane longer than that: the last lines first, the rest of history after.
- **Streaming:** a session streaming in a background tab costs the strip nothing but its own tab's
  status mark changing, and costs no layout of its hidden transcript.
- **Go to Session:** the sheet up in the next frame; built from memory, no disk read on open.
- **Close:** the tab gone in the next frame; any stop or hand-over finishes off the main thread.

How, as far as decided:

- Today `SelectedSessionPane` rebuilds `SessionView` on every switch (`.id(item.id)`) and waits on
  `loadHistory()` before showing anything. That goes. Recently shown sessions stay built: an AppKit
  container holding one `NSHostingView` per recent session, swapping which one is in the window,
  so a hidden session keeps its view, scroll position and composer state without being laid out.
  Keep the last few (builder picks N, start at 6) and drop the least recently shown.
- Each tab is its own small `Equatable` view reading only its session's name, status and marked
  state, so a delta in one transcript invalidates one tab at most.
- Measurement: `OSSignposter` intervals for tab switch (click to first frame of the new session),
  cold load, and Go to Session open, readable in Instruments; the plan includes taking these numbers
  before and after, and the hand check reports them. No wall-clock budget goes into the test suite
  (the known flakes in loaded runs make those noise).

If an AppKit container turns out unnecessary (a plain SwiftUI `ZStack` with hidden views meets the
budgets, streaming included), the simpler one wins; the budgets are the requirement, the container
is the means.

## Left to the builder

- The strip's look: height, typography, dividers, the selected tab's fill, within the app's current
  style (it sits under a translucent toolbar; the composer uses glass).
- Where a closed tab's draft is kept, or whether closing asks in that one case (see Closing).
- The keep-alive count N and its eviction details.
- Tab drag-and-drop implementation, and whether dragging a tab to another window is refused or
  moves the session (refused is fine for this work).
- Spinner or static glyph for "working", by what the Performance budgets allow.

## Order of work

1. Part 1: strip, closing, keys, sidebar changes, keep-alive pane, signposts. Usable on its own.
2. Part 2: plain windows, Go to Session, Home window.

Each lands on main with its tests; the live check (tabs with a dozen sessions, closing one at work
and bringing it back, numbers from Instruments) is the person's, since Drakar cannot be relaunched
from a session.
