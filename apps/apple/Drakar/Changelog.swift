import SwiftUI

/// What changed, in the build you are running.
///
/// Generated from the repository's `CHANGELOG.md` by `make changelog`: a copy
/// nobody regenerates is a copy that rots, and here it would rot into the worst
/// possible shape — release notes that confidently describe a different build.
///
/// **Why generated rather than bundled.** The obvious alternative is to ship
/// `CHANGELOG.md` as a resource and parse it at launch. Baking the text in at
/// generation time means the parse happens once, in Node, where
/// `make changelog-check` can assert the result, rather than on every launch
/// where nothing can — and it keeps a markdown parser out of an app that
/// deliberately carries no dependency it does not need.
///
/// Every string below is **raw markdown**. The generator does not decide what
/// bold looks like; `markdown(_:_:)` renders it.
///
/// The list is capped — see `SHOWN` in `scripts/generate-changelog.mjs` —
/// because this is the pane you open after updating, not an archive. The full
/// history is a link away, and `CHANGELOG.md` remains the source of truth.
///
/// Armada's file (cupertino's before it), copied: the direct-distribution apps share no
/// package.
///
/// `nonisolated`, because `SettingsPane.badge` reads `hasUnseen`, and that requirement
/// belongs to SupportKit's `Sendable` protocol, which gives it no actor to run on. Nothing
/// here needs one: the members are constants, `UserDefaults` and the bundle.
nonisolated enum Changelog {
  /// One released version.
  struct Release: Identifiable, Hashable {
    /// `"1.0.0"`. Compared against the marketing version and the seen key.
    let version: String
    /// `"2026-09-14"`. Kept as the ISO string the CHANGELOG wrote rather than a
    /// `Date` literal: a `Date(timeIntervalSince1970:)` in a generated file is
    /// unreadable in a diff, and formatting at generation time would bake the
    /// generating machine's locale into every build.
    ///
    /// Empty for a version written down before its tag (`## [1.0.0] - Unreleased`),
    /// which the tag dates; `WhatsNewPane.dateLine(for:)` shows it as "Unreleased".
    let date: String
    let sections: [Section]

    var id: String { version }
  }

  /// One `### Added` / `### Fixed` block.
  ///
  /// `name` is whatever the CHANGELOG wrote, so nothing here is an enum.
  struct Section: Identifiable, Hashable {
    let name: String
    /// The prose that can sit between the heading and the first bullet.
    /// Dropping it silently shortens the notes, which is exactly the kind of
    /// loss nothing would report.
    let lead: [String]
    let entries: [Entry]

    var id: String { name }
  }

  /// One bullet.
  struct Entry: Identifiable, Hashable {
    /// Emitted rather than derived, so `ForEach` has a stable identity without
    /// hashing prose or inventing a `UUID` that changes every render.
    ///
    /// Unique across the whole **release**, not within its section. SwiftUI
    /// flattens the section/entry `ForEach` pair inside a `Form`, so
    /// per-section numbering collides as soon as a release has two sections —
    /// and the pane then draws the first section's bullet a second time in
    /// place of the second section's.
    let ordinal: Int
    /// The leading `**…**`, asterisks removed — or nil. Not every bullet opens
    /// with one, so this is an optional by observation rather than by caution.
    let headline: String?
    /// The rest, one string per paragraph.
    let body: [String]

    var id: Int { ordinal }
  }

  /// Where the full history lives, since only the most recent releases are here.
  static let historyURL = URL(
    string: "https://github.com/mgcrea/drakar/blob/main/CHANGELOG.md")!

  // MARK: - Which build this is

  /// The marketing version alone: no build number, no `-dev`.
  ///
  /// Not a version line made for showing a human, such as `"1.0.0 (60)"` or a Debug
  /// build's `"1.0.0-dev"`: both are right on screen, and both are wrong for comparing
  /// against a version string written in a defaults key, which they would never equal.
  static var marketingVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }

  /// Whether this build was compiled with `[Unreleased]` still meaning
  /// something. See `unreleased`.
  static var showsUnreleased: Bool {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }

  /// `a` is a later release than `b`, comparing dotted numbers.
  ///
  /// Numeric per component, so `1.10.0` is correctly newer than `1.9.0` — the
  /// comparison a lexicographic one gets backwards. Anything non-numeric compares
  /// as 0, which makes an unparseable version "not newer" rather than a crash.
  static func isVersion(_ a: String, newerThan b: String) -> Bool {
    let left = a.split(separator: ".").map { Int($0) ?? 0 }
    let right = b.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      if l != r { return l > r }
    }
    return false
  }

  // MARK: - Seen

  /// The last version whose notes were actually read.
  ///
  /// A marketing version string, not a bool: the question the indicator answers
  /// is "did anything ship since you last looked", which needs the comparison.
  static let seenKey = "changelogSeenVersion"

  /// Seed the seen version on a launch that has never set it.
  ///
  /// Without this, a fresh install lights every indicator on first launch — the
  /// key is absent, so everything looks unread, and Drakar greets somebody who
  /// has never run it with a stack of "new" releases. The cost is that the
  /// indicator does nothing until the *next* release; the alternative costs every
  /// new user a false badge.
  static func markSeenIfUnset() {
    guard UserDefaults.standard.string(forKey: seenKey) == nil else { return }
    markSeen()
  }

  /// Record that the notes for this build have been read.
  static func markSeen() {
    UserDefaults.standard.set(marketingVersion, forKey: seenKey)
  }

  /// Releases newer than the last one whose notes were read.
  ///
  /// Empty rather than everything when the key is unset — see
  /// `markSeenIfUnset()`.
  static var unseen: [Release] {
    guard let seen = UserDefaults.standard.string(forKey: seenKey), !seen.isEmpty else { return [] }
    return releases.filter { isVersion($0.version, newerThan: seen) }
  }

  /// Whether to draw an indicator anywhere.
  ///
  /// DIVERGES from armada, which also answers false under a screenshot capture: an
  /// indicator is news about *this* install, and a plate carrying one depends on which
  /// release the capturing Mac last read the notes for. Drakar has no screenshot mode
  /// yet; the guard belongs here, with the others it moves with, when one arrives.
  static var hasUnseen: Bool {
    !unseen.isEmpty
  }

  // MARK: - Rendering

  /// One markdown string as `Text` can draw it.
  ///
  /// `Text` honours `**bold**`, `_italic_` and links from an `AttributedString`
  /// on its own. It does nothing at all for `` `code` `` — the markdown parser
  /// records that as a semantic `inlinePresentationIntent` and applies no font —
  /// so the loop below is the whole of the missing half.
  ///
  /// The style is a parameter because setting `.font` on a run **overrides** the
  /// view's own `.font()` for that run: a body-sized helper used inside a
  /// caption makes one word jump a size. And the emphasis has to be reapplied,
  /// because headlines here contain code spans inside the bold — assigning a
  /// plain monospaced font would silently un-bold them.
  ///
  /// `Text("**bold**")` renders markdown only for string *literals*, through the
  /// `LocalizedStringKey` overload. Every string here is a variable, which takes
  /// the `StringProtocol` overload and draws the asterisks, so this is not an
  /// embellishment; without it the pane shows raw markdown.
  static func markdown(_ source: String, _ style: Font.TextStyle = .body) -> AttributedString {
    guard
      var text = try? AttributedString(
        markdown: source,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else {
      // Literal asterisks are ugly and honest. Nothing here is worth a crash.
      return AttributedString(source)
    }
    for run in text.runs {
      guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
      var font = Font.system(style, design: .monospaced)
      if intent.contains(.stronglyEmphasized) { font = font.bold() }
      if intent.contains(.emphasized) { font = font.italic() }
      text[run.range].font = font
    }
    return text
  }

  // MARK: - Generated

  // <generated:changelog> generated from CHANGELOG.md by `make changelog` — do not edit by hand

  /// The most recent 4 releases, newest first.
  ///
  /// Split into one `let` per release rather than a single nested literal.
  /// Swift's expression type-checker is superlinear in the depth of an array
  /// literal, and this one is releases of sections of entries of strings — the
  /// exact shape that turns into a multi-second type-check with no diagnostic.
  // swift-format-ignore
  static let releases: [Release] = [v1_3_0, v1_2_0, v1_1_0, v1_0_0]

  // swift-format-ignore
  private static let v1_3_0: Release = Release(
    version: "1.3.0",
    date: "2026-11-04",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Session tabs.",
            body: [
              "A window's sessions are tabs above the conversation, in the order you put them: a new one opens right of the tab shown, a drag moves one, and ⌘-click or ⇧-click marks tabs for one prompt to all. A session opened from Elsewhere or Ended shows in a single preview tab that the next one replaces; a double click keeps it. ⌘W closes the tab shown (the editor's file first, while the editor has the keys), ⌘1–⌘9 pick a tab, and ⌃Tab or ⇧⌘] moves to the next. A session shown recently comes back at once, its scroll position and draft kept.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Closing a tab at work lets the turn finish.",
            body: [
              "The agent goes on in the background, listed under Elsewhere, and ends with its turn unless you open it again. Closing asks first only when something would be lost: a draft, or a turn Drakar cannot hand over.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Idle compaction.",
            body: [
              "A session with 200k tokens of context, left idle, compacts six minutes before its hour of prompt cache runs out, as Claude Code does in a terminal, so the next prompt starts from a summary rather than reading the whole conversation again uncached. Settings › General › Compaction turns it off, or sends a command of yours first, such as `/distill`. The Session inspector's Compact does the same on demand.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Send a queued message now.",
            body: [
              "An ↑ beside the first queued message stops the turn, as Esc does, and the queue goes at once.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 4,
            headline: nil,
            body: [
              "A streaming reply is drawn 20 times a second rather than on every token, and no longer redraws the other windows, Home or the sidebar, so several agents at work no longer keep Drakar busy.",
            ]),
          Entry(
            ordinal: 5,
            headline: nil,
            body: [
              "The sidebar keeps Elsewhere and Ended; the sessions it listed under This Window are the tabs.",
            ]),
          Entry(
            ordinal: 6,
            headline: nil,
            body: [
              "A session with a very long log reopens in seconds rather than minutes.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 7,
            headline: nil,
            body: [
              "Scrolling up while an agent writes stays where you scrolled.",
            ]),
          Entry(
            ordinal: 8,
            headline: nil,
            body: [
              "Settings › Runner and a runner window's toolbar draw their icon.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_2_0: Release = Release(
    version: "1.2.0",
    date: "2026-11-02",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Sessions on another Mac.",
            body: [
              "Name a second Mac in Settings › Runner, reached through your own ssh, and a session's `claude` runs there, in a folder there, with that Mac's MCP servers and screen, while you follow it, answer its prompts and send yours from your Mac. Home lists the runner's sessions and starts new ones there, and closing the window or quitting leaves them running. The runner takes nothing until \"Let my other Macs start sessions here\" is on in its own Settings. Setting one up is in [docs/runner.md](https://github.com/mgcrea/drakar/blob/main/docs/runner.md).",
            ]),
          Entry(
            ordinal: 1,
            headline: "Permission rules.",
            body: [
              "The inspector's Rules tab lists the rules a session runs under and where each comes from, and adds or removes yours, with or without a session running.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Open Plan.",
            body: [
              "Session › Open Plan (⌥⌘P) opens the session's plan file in a tab.",
            ]),
          Entry(
            ordinal: 3,
            headline: "The `drakar` command.",
            body: [
              "`drakar .` opens a folder in Drakar, as `code .` does in VS Code, and so do `open -a Drakar` and a folder dropped on the Dock icon. Drakar links the command into `~/.local/bin` when your shell's PATH has it; Settings › General installs it elsewhere.",
            ]),
          Entry(
            ordinal: 4,
            headline: "The Mac stays awake while an agent works,",
            body: [
              "even through a quit, and may sleep again once the agent finishes or waits for you. Settings › General turns it off.",
            ]),
          Entry(
            ordinal: 5,
            headline: "Reconnect a failed MCP server.",
            body: [
              "While a session runs, the inspector's MCP pane lists that session's own servers, and a failed one reconnects without restarting the session: its tools are there at the next prompt.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 6,
            headline: nil,
            body: [
              "Home and a project's sidebar list sessions without waiting for your login shell, so a slow `.zshrc` no longer holds the spinner, and a project window opens faster on a long history.",
            ]),
          Entry(
            ordinal: 7,
            headline: nil,
            body: [
              "Settings groups its panes in three sections: how sessions behave, this build, and the licence.",
            ]),
          Entry(
            ordinal: 8,
            headline: nil,
            body: [
              "The prompt cache timer sits left of the model in the composer, as in the VS Code extension.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_1_0: Release = Release(
    version: "1.1.0",
    date: "2026-10-30",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A licence, sold once.",
            body: [
              "Settings › Licence takes a key, starts a 30-minute trial, and links to the store. Without a key or a trial Drakar sends nothing to an agent, and everything else stays: your projects, sessions, transcripts and diffs, and a turn already running keeps going. The key is checked on your Mac, never by a server. The terms are at drakar.mgcrea.io/terms.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Rewind and fork from a prompt.",
            body: [
              "Hover a prompt, or right-click beside it: fork the conversation from there, rewind the files Claude changed since, or both. The rewind shows which files it would restore, and how much, before anything changes.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Mark All Sessions.",
            body: [
              "Session › Mark All Sessions (⌥⌘A) marks every session in the window, from anywhere, for one prompt to all of them.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 3,
            headline: nil,
            body: [
              "A fork you have not sent yet comes back after a relaunch, with its draft.",
            ]),
          Entry(
            ordinal: 4,
            headline: nil,
            body: [
              "A question's card takes the keyboard when its session is opened from the sidebar.",
            ]),
          Entry(
            ordinal: 5,
            headline: nil,
            body: [
              "A subagent sent to the background says so on its card.",
            ]),
          Entry(
            ordinal: 6,
            headline: nil,
            body: [
              "A rewind overtaken by a turn that starts under it says so, rather than reporting a failure.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_0_0: Release = Release(
    version: "1.0.0",
    date: "2026-10-30",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Claude Code's conversation, natively.",
            body: [
              "Drakar runs the `claude` you installed over its stream-json protocol, the way the VS Code extension does, and shows the conversation, the tool calls, the permission prompts and the diffs in a native window.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Codex as a second agent.",
            body: [
              "A session can run Codex instead, through its `app-server`.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Which `claude`, and which account.",
            body: [
              "Settings › General picks the `claude` that runs when more than one is installed, and the account (`CLAUDE_CONFIG_DIR`) a new session starts under. The footer warns when the CLI is outside the versions Drakar was tested with, since the protocol it speaks is undocumented.",
            ]),
          Entry(
            ordinal: 3,
            headline: "The editor for `claude` in a terminal.",
            body: [
              "While Drakar runs, a `claude --ide` started in a folder Drakar has open (or connected with `/ide`) sends every edit to Drakar's Review Changes window, and the file is written only if you accept it there. Settings › General picks the folders.",
            ]),
          Entry(
            ordinal: 4,
            headline: "An editor beside the conversation.",
            body: [
              "A session window shows its folder's files in the sidebar and opens them as tabs, with line numbers and colours, saved with ⌘S, found by name with ⌘P and searched with ⇧⌘F. A tab the agent changes reloads; if you edited it too, Drakar asks which version to keep, and it asks before a window with unsaved tabs closes.",
            ]),
          Entry(
            ordinal: 5,
            headline: "Your selection goes with the prompt.",
            body: [
              "What you select, or the file you have open, goes with your next prompt, as in the VS Code extension, and with a terminal `claude --ide`'s too. ⌥K pins a selection so the next one can be added beside it.",
            ]),
          Entry(
            ordinal: 6,
            headline: "Sessions that outlive the app.",
            body: [
              "A small helper holds the `claude` and `codex` processes, so a quit, a crash or an update leaves them working, and the next launch attaches again and replays what they did meanwhile.",
            ]),
          Entry(
            ordinal: 7,
            headline: "Many sessions, one window.",
            body: [
              "The sidebar sorts what needs you first; ⌥⌘↑ and ⌥⌘↓ move between sessions, and Next After Replying shows the next one waiting. Mark several with ⌘-click and send them one prompt, or run a skill in a session per subfolder, a few at a time.",
            ]),
          Entry(
            ordinal: 8,
            headline: "Answered where they are asked.",
            body: [
              "Permission prompts, the agent's questions and an MCP server's questions are answered in their card in the transcript; a yes-or-no question also from the toolbar, with ⌥⌘Y or ⌥⌘N.",
            ]),
          Entry(
            ordinal: 9,
            headline: "Tasks and subagents.",
            body: [
              "A subagent's card shows its whole conversation. A running task can be stopped, sent to the background, and its output read.",
            ]),
          Entry(
            ordinal: 10,
            headline: "Sessions run elsewhere.",
            body: [
              "A session a terminal or VS Code runs shows its state in the sidebar, and can be moved into the window. A folder's sessions can move to another account.",
            ]),
          Entry(
            ordinal: 11,
            headline: "A Skills window.",
            body: [
              "Both agents' skills, commands and plugins in one list, installed from a git address or a folder, shared between projects, and deleted without leaving dangling links.",
            ]),
          Entry(
            ordinal: 12,
            headline: "Updates, when you ask for them.",
            body: [
              "Drakar checks for updates only once you said yes. Settings › What's New keeps each release's notes, with a count on its row while some are unread.",
            ]),
        ]),
    ])

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  // swift-format-ignore
  private static let unreleasedRelease: Release = Release(
    version: "Unreleased",
    date: "",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "An MCP server.",
            body: [
              "Turned on in Settings › MCP Server, it lets an AI agent on your Mac, such as Claude Code or Codex, see your sessions, here and on your runner, read their transcripts and wait for one to need you. Allow writes lets it also start sessions, send them messages, interrupt and end them, and answer their questions; answering their permission prompts is a switch of its own. It is off until you turn it on, listens on 127.0.0.1 only, and answers only a client holding the token Drakar keeps in your Keychain. The pane sets up Claude Code, Codex or Bastion for it.",
            ]),
        ]),
    ])

  // swift-format-ignore
  static let unreleased: Release? = unreleasedRelease
  // </generated:changelog>
}
