import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A project window's sessions")
struct ProjectTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-project-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func target(_ id: String, cwd: String? = nil) -> ResumeTarget {
    ResumeTarget(
      sessionID: id, cwd: cwd ?? folder.path(percentEncoded: false),
      file: folder.appending(path: "\(id).jsonl").path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
  }

  @Test func attachingPutsTheSessionOnTopAndSelectsIt() {
    let project = Project(folder: folder)
    let first = project.attach(target("a"))
    let second = project.attach(target("b"))
    #expect(project.sessions.map(\.id) == [second.id, first.id])
    #expect(project.selectedID == second.id)
  }

  /// One writer per transcript: attaching what is already here selects it.
  @Test func attachingTwiceSelectsTheOneAlreadyHere() {
    let project = Project(folder: folder)
    let first = project.attach(target("a"))
    _ = project.attach(target("b"))
    let again = project.attach(target("a"))
    #expect(again.id == first.id)
    #expect(project.sessions.count == 2)
    #expect(project.selectedID == first.id)
  }

  @Test func theAttachedListSurvivesARelaunch() throws {
    let project = Project(folder: folder)
    _ = project.attach(target("a"))
    _ = project.attach(target("b"))
    _ = project.newSession()  // no id yet: not restorable, and not stored
    project.select(project.sessions[1])  // b
    let stored = try JSONDecoder().decode(
      StoredProject.self, from: JSONEncoder().encode(project.stored))
    let restored = Project(folder: folder, restoring: stored)
    #expect(restored.sessions.map(\.sessionID) == ["b", "a"])
    #expect(restored.selected?.sessionID == "b")
    #expect(restored.sessions.allSatisfy { !$0.session.isProcessRunning })
  }

  @Test func aForkIsANewRowBesideTheOriginal() {
    let project = Project(folder: folder)
    let original = project.attach(target("a"), watching: true, readOnly: true)
    let fork = project.fork(original)
    #expect(project.sessions.count == 2)
    #expect(fork.session.resuming?.forks == true)
    #expect(!fork.session.isReadOnly)
    #expect(original.session.isReadOnly)
  }

  /// Each copy is numbered after its original's title, a copy of a copy as the next one.
  @Test func forksAreNumberedAfterTheirOriginal() async throws {
    try Data(
      [
        #"{"type":"user","cwd":"/w","message":{"role":"user","content":"go"}}"#,
        #"{"type":"ai-title","aiTitle":"Pineapple"}"#,
      ].joined(separator: "\n").appending("\n").utf8
    ).write(to: folder.appending(path: "a.jsonl"))
    let project = Project(folder: folder)
    let original = project.attach(target("a"))
    await original.session.loadHistory()

    let first = project.fork(original)
    let second = project.fork(original)
    let third = project.fork(first)
    #expect(first.displayTitle == "Pineapple (fork)")
    #expect(second.displayTitle == "Pineapple (fork #2)")
    #expect(third.displayTitle == "Pineapple (fork #3)")
    #expect(original.displayTitle == "Pineapple")
  }

  /// A row whose title is not known yet has nothing to number: the CLI keeps the copied one.
  @Test func aForkOfAnUntitledRowTakesNoName() {
    let project = Project(folder: folder)
    let fork = project.fork(project.attach(target("a")))
    #expect(fork.session.title == nil)
  }

  /// A session opened from Elsewhere or Ended is looked at there, not made the window's
  /// own, until it is taken over: prompted, or attached.
  @Test func aWatchedSessionStaysOutOfTheWindowUntilTakenOver() {
    let project = Project(folder: folder)
    let own = project.attach(target("a"))
    let watched = project.attach(target("b"), watching: true)
    #expect(watched.isWatching && !watched.session.isReadOnly)
    #expect(project.held.map(\.id) == [own.id])
    #expect(project.stored.sessions.map(\.sessionID) == ["a"])
    #expect(project.stored.selected == nil)
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    #expect(OpenSessions.shared.locate("b") == nil)
    #expect(project.attach(target("b"), watching: true).isWatching)
    project.select(own)
    project.attach(target("b"))
    #expect(!watched.isWatching)
    #expect(project.held.map(\.id) == [watched.id, own.id])
    #expect(project.stored.sessions.map(\.sessionID) == ["b", "a"])
  }

  /// Nothing to copy before the first finished turn, and nothing whole during one.
  @Test func onlyASessionWithATranscriptAndNoTurnRunningForks() throws {
    let project = Project(folder: folder)
    let fresh = project.newSession()
    #expect(!project.canFork(fresh))
    #expect(!project.canForkSelected)
    project.forkSelected()
    #expect(project.sessions.count == 1)

    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    project.executableOverride = script
    let attached = project.attach(target("a"))
    defer { project.stopAll() }
    #expect(project.canForkSelected)
    attached.session.send("hello")
    #expect(attached.session.transcript.isRunning)
    #expect(!project.canForkSelected)
  }

  @Test func forkingTheSelectedSessionShowsTheCopy() {
    let project = Project(folder: folder)
    let original = project.attach(target("a"))
    project.forkSelected()
    #expect(project.sessions.count == 2)
    #expect(project.selectedID != original.id)
    #expect(project.selected?.session.resuming?.forks == true)
  }

  /// A session attached with `ask` as what its file's newest turn ended on, and a `claude`
  /// that takes prompts and says nothing.
  private func asking(_ ask: ClosingAsk, in project: Project) throws -> ProjectSession {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    project.executableOverride = script
    let item = project.attach(target("a"))
    var summary = SessionSummary(
      sessionID: "a", account: ClaudeAccount(directory: folder, isDefault: false),
      file: folder.appending(path: "a.jsonl"), modified: .now, size: 1)
    summary.closingAsk = ask
    summary.closingMessageID = "m1"
    item.preview = summary
    return item
  }

  /// A question dismissed while its session was live elsewhere stays dismissed once that
  /// process exits and the watched row can send again: whether it was dismissed before the
  /// row was opened here or while it was watched.
  @Test func aQuestionDismissedElsewhereStaysDismissedOnceItsProcessExits() throws {
    var elsewhere = SessionSummary(
      sessionID: "a", account: ClaudeAccount(directory: folder, isDefault: false),
      file: folder.appending(path: "a.jsonl"), modified: .now, size: 1)
    elsewhere.closingAsk = ClosingAsk(kind: .question, text: "Want me to push?")
    elsewhere.closingMessageID = "m1"
    for dismissedFirst in [true, false] {
      let project = Project(folder: folder)
      if dismissedFirst { project.dismissAsk(elsewhere) }
      let item = project.attach(target("a"), watching: true, readOnly: true)
      item.preview = elsewhere
      if !dismissedFirst { project.dismissAsk(elsewhere) }
      item.session.isReadOnly = false
      #expect(item.closingAsk == nil, "dismissed first: \(dismissedFirst)")
    }
  }

  @Test func yesAnswersAYesOrNoQuestion() throws {
    let project = Project(folder: folder)
    let item = try asking(
      ClosingAsk(kind: .question, text: "Does this look right?", isYesOrNo: true), in: project)
    defer { project.stopAll() }
    item.draft = "half a thought"
    #expect(project.yesOrNoSelected?.text == "Does this look right?")
    project.answerYesSelected()
    #expect(item.session.transcript.entries.last?.headline == "Yes")
    #expect(item.draft == "half a thought")
    #expect(project.yesOrNoSelected == nil)
  }

  /// A "No" mostly comes with what to do instead: it starts the reply.
  @Test func noStartsTheReply() throws {
    let project = Project(folder: folder)
    let item = try asking(
      ClosingAsk(kind: .question, text: "Want me to push?", isYesOrNo: true), in: project)
    defer { project.stopAll() }
    project.answerNoSelected()
    #expect(item.draft == "No, ")
    #expect(item.focusRequest == 1)
    #expect(item.session.transcript.entries.isEmpty)
    project.answerNoSelected(bare: true)
    #expect(item.session.transcript.entries.last?.headline == "No")
  }

  @Test func aQuestionThatNeedsWordsHasNoYesOrNo() throws {
    let project = Project(folder: folder)
    let item = try asking(ClosingAsk(kind: .question, text: "Which option?"), in: project)
    defer { project.stopAll() }
    #expect(project.yesOrNoSelected == nil)
    project.answerYesSelected()
    project.answerNoSelected()
    #expect(item.session.transcript.entries.isEmpty)
    #expect(item.draft.isEmpty)
  }

  @Test func aForkOfAWatchedSessionIsTheWindowsOwn() {
    let project = Project(folder: folder)
    let watched = project.attach(target("a"), watching: true, readOnly: true)
    let fork = project.fork(watched)
    #expect(project.held.map(\.id) == [fork.id])
    #expect(watched.isWatching)
  }

  /// `id`'s transcript: two prompts and their replies, as Claude Code writes them.
  private func writeTwoPrompts(_ id: String) throws {
    let lines = [
      #"{"type":"user","uuid":"p-1","parentUuid":null,"message":{"role":"user","content":"First"}}"#,
      #"{"type":"assistant","uuid":"r-1","parentUuid":"p-1","message":{"id":"m-1","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"One."}],"stop_reason":"end_turn"}}"#,
      #"{"type":"user","uuid":"p-2","parentUuid":"r-1","message":{"role":"user","content":"Second"}}"#,
      #"{"type":"assistant","uuid":"r-2","parentUuid":"p-2","message":{"id":"m-2","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Two."}],"stop_reason":"end_turn"}}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(
      to: folder.appending(path: "\(id).jsonl"))
  }

  /// A fork from a prompt resumes at the message before it, shows the history up to there,
  /// and has the prompt's text waiting in its composer.
  @Test func forkFromAPromptEndsBeforeIt() async throws {
    try writeTwoPrompts("a")
    let project = Project(folder: folder)
    let original = project.attach(target("a"))
    let fork = try #require(await project.fork(original, from: "p-2", text: "Second"))
    #expect(fork.id != original.id)
    #expect(project.selectedID == fork.id)
    #expect(fork.session.resuming?.forks == true)
    #expect(fork.session.resuming?.sessionID == "a")
    #expect(fork.session.resuming?.resumeAt == "r-1")
    #expect(fork.draft == "Second")
    await fork.session.loadHistory()
    #expect(fork.session.transcript.entries.map(\.kind) == [.prompt("First"), .text("One.")])
    let launch = ClaudeBackend().launch(
      AgentStart(
        folder: folder, resuming: fork.session.resuming, environment: [:],
        executableOverride: URL(filePath: "/bin/echo"), allowsBypass: false))
    #expect(launch.configuration?.arguments.contains("--resume-session-at=r-1") == true)
  }

  /// A fork writes no transcript until its first turn: kept by its target and draft, it comes
  /// back after a relaunch beside its original, still forking at the same message.
  @Test func anUnsentForkSurvivesARelaunch() async throws {
    try writeTwoPrompts("a")
    let project = Project(folder: folder)
    let original = project.attach(target("a"))
    let fork = try #require(await project.fork(original, from: "p-2", text: "Second"))
    let whole = project.fork(original)
    whole.draft = ""
    let stored = try JSONDecoder().decode(
      StoredProject.self, from: JSONEncoder().encode(project.stored))
    let restored = Project(folder: folder, restoring: stored)
    #expect(restored.sessions.count == 3)
    let forks = restored.sessions.filter { $0.session.resuming?.forks == true }
    #expect(forks.count == 2)
    let fromPrompt = try #require(forks.first { $0.session.resuming?.resumeAt == "r-1" })
    #expect(fromPrompt.session.resuming?.sessionID == "a")
    #expect(fromPrompt.draft == fork.draft)
    #expect(forks.contains { $0.session.resuming?.resumeAt == nil && $0.draft.isEmpty })
  }

  /// Nothing comes before the first prompt: a new session in the same folder, picked as the
  /// original was, with the prompt's text in its composer.
  @Test func forkFromTheFirstPromptIsANewSession() async throws {
    try writeTwoPrompts("a")
    let project = Project(folder: folder)
    let original = project.attach(target("a"))
    original.session.setMode(.plan)
    original.session.setModel("opus")
    let fork = try #require(await project.fork(original, from: "p-1", text: "First"))
    #expect(fork.id != original.id)
    #expect(project.selectedID == fork.id)
    #expect(fork.session.resuming == nil)
    #expect(fork.session.agent == .claude)
    #expect(fork.session.folder == original.session.folder)
    #expect(fork.draft == "First")
    #expect(fork.session.modePick == .plan)
    #expect(fork.session.modelPick == "opus")
  }

  @Test func noForkFromWhileATurnRuns() async throws {
    try writeTwoPrompts("a")
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let project = Project(folder: folder)
    project.executableOverride = script
    let attached = project.attach(target("a"))
    defer { project.stopAll() }
    #expect(project.canForkFrom(attached))
    attached.session.send("hello")
    #expect(attached.session.transcript.isRunning)
    #expect(!project.canForkFrom(attached))
    // Still offered, for the prompt's menu to show it disabled.
    #expect(project.offersForkFrom(attached))
    #expect(await project.fork(attached, from: "p-2", text: "Second") == nil)
    #expect(project.sessions.count == 1)
  }

  /// A message id the transcript does not hold has no point to fork at.
  @Test func noForkFromAPromptNotInTheFile() async throws {
    try writeTwoPrompts("a")
    let project = Project(folder: folder)
    let original = project.attach(target("a"))
    #expect(await project.fork(original, from: "not-a-prompt", text: "Lost") == nil)
    #expect(project.sessions.count == 1)
    #expect(project.selectedID == original.id)
  }

  /// A fork that can't be made says so in the session it was asked of, rather than nothing.
  @Test func aForkNotMadeLeavesANotice() async throws {
    try writeTwoPrompts("a")
    let project = Project(folder: folder)
    let original = project.attach(target("a"))
    #expect(await project.fork(original, from: "not-a-prompt", text: "Lost") == nil)
    #expect(original.session.transcript.entries.map(\.kind) == [.notice(RewindCopy.notForked)])
  }

  /// After a rewind that took, the fork's failure is said in the rewind's own note: one
  /// note, which still says the code was rewound.
  @Test func aForkNotMadeAfterARewindSaysTheCodeWasRewound() async throws {
    try writeTwoPrompts("a")
    let project = Project(folder: folder)
    let original = project.attach(target("a"))
    original.session.noteRewound()
    #expect(
      await project.fork(original, from: "not-a-prompt", text: "Lost", afterRewind: true) == nil)
    #expect(
      original.session.transcript.entries.map(\.kind) == [.notice(RewindCopy.rewoundNotForked)])
    // With no rewind note to amend (it was never written), it is added.
    try writeTwoPrompts("b")
    let other = project.attach(target("b"))
    #expect(
      await project.fork(other, from: "not-a-prompt", text: "Lost", afterRewind: true) == nil)
    #expect(other.session.transcript.entries.map(\.kind) == [.notice(RewindCopy.rewoundNotForked)])
  }

  /// A turn that starts while the transcript is read forks nothing: the fork would copy a
  /// history the turn is still writing.
  @Test func aTurnStartedDuringTheReadForksNothing() async throws {
    try writeTwoPrompts("a")
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let project = Project(folder: folder)
    project.executableOverride = script
    let attached = project.attach(target("a"))
    defer { project.stopAll() }
    let read = project.readResumePoint
    project.readResumePoint = { file, messageID in
      // The stand-in never ends the turn.
      attached.session.send("hello")
      return await read(file, messageID)
    }
    #expect(project.canForkFrom(attached))
    #expect(await project.fork(attached, from: "p-2", text: "Second") == nil)
    #expect(attached.session.transcript.isRunning)
    #expect(project.sessions.count == 1)
    #expect(project.selectedID == attached.id)
    #expect(
      attached.session.transcript.entries.contains { $0.kind == .notice(RewindCopy.notForked) })
  }

  /// A Codex prompt's id is Drakar's, not one a Claude Code fork can resume at.
  @Test func noForkFromACodexSession() {
    var codex = target("a")
    codex.agent = .codex
    let project = Project(folder: folder)
    let item = project.attach(codex)
    #expect(!project.canForkFrom(item))
    #expect(!project.offersForkFrom(item))
  }

  @Test func theWindowIndexFindsASessionAndItsOwner() {
    let project = Project(folder: folder)
    let attached = project.attach(target("a"))
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    #expect(OpenSessions.shared.locate("a")?.1.id == attached.id)
    let sub = folder.appending(path: "sub").path(percentEncoded: false)
    #expect(
      OpenSessions.shared.ownerFolder(forCwd: sub)
        == ProjectPath.normalize(folder))
    #expect(OpenSessions.shared.ownerFolder(forCwd: "/elsewhere/x") == "/elsewhere/x")
  }

  @Test func pendingAttachmentsWaitForTheirWindow() {
    let path = ProjectPath.normalize(folder)
    OpenSessions.shared.requestAttach(target("a"), in: path)
    #expect(OpenSessions.shared.takePending(for: path).map(\.sessionID) == ["a"])
    #expect(OpenSessions.shared.takePending(for: path).isEmpty)
  }

  @Test func aSessionLiveElsewhereIsReadOnlyAndWritableAgain() {
    let project = Project(folder: folder)
    let item = project.attach(target("a"))
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    OpenSessions.shared.liveChanged(["a"])
    #expect(item.session.isReadOnly)
    OpenSessions.shared.liveChanged([])
    #expect(!item.session.isReadOnly)
  }

  @Test func aRestoredRowLiveElsewhereIsReadOnly() {
    let stored = StoredProject(sessions: [target("a"), target("a"), target("b")], selected: "a")
    let project = Project(folder: folder, restoring: stored)
    #expect(project.sessions.map(\.sessionID) == ["a", "b"])
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    OpenSessions.shared.liveChanged(["b"])
    #expect(project.sessions.map(\.session.isReadOnly) == [false, true])
  }

  /// Every restored row has its title and gauge before it is shown, not only the selected
  /// one: they come from the transcript's end, read at restore.
  @Test func restoredRowsShowTheirTitleAndGaugeBeforeTheyAreShown() async throws {
    for (id, title) in [("a", "Title A"), ("b", "Title B")] {
      try Data(
        [
          #"{"type":"user","cwd":"/w","message":{"role":"user","content":"go"}}"#,
          #"{"type":"assistant","message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":40000,"output_tokens":5}}}"#,
          #"{"type":"ai-title","aiTitle":"\#(title)"}"#,
        ].joined(separator: "\n").appending("\n").utf8
      ).write(to: folder.appending(path: "\(id).jsonl"))
    }
    let project = Project(
      folder: folder, restoring: StoredProject(sessions: [target("a"), target("b")], selected: "a"))
    let unshown = project.sessions[1]
    for _ in 0..<50 where unshown.displayTitle != "Title B" {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(project.sessions.map(\.displayTitle) == ["Title A", "Title B"])
    #expect(!unshown.session.hasLoadedHistory)
    #expect(unshown.gauge(accountModel: nil)?.used == 40_012)
    #expect(unshown.lastActivity != nil)
  }

  private func standIn(_ name: String, _ body: String) throws -> URL {
    let script = folder.appending(path: name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// A row waiting on a permission counts in the group's header.
  @Test func aWaitingRowCountsInTheHeader() async throws {
    let request =
      #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"make test"},"tool_use_id":"toolu_1"}}"#
    let project = Project(folder: folder)
    _ = project.newSession()
    let item = project.newSession()
    item.session.executableOverride = try standIn("claude", "echo '\(request)'\ncat > /dev/null")
    #expect(project.waitingCount == 0)
    item.session.send("go")
    for _ in 0..<50 where project.waitingCount == 0 {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(project.waitingCount == 1)
    item.session.stop()
    #expect(project.waitingCount == 0)
  }

  /// A process that exits on an error says so in its row: "Stopped, exit 3".
  @Test func aFailedExitSaysItsStatus() async throws {
    let project = Project(folder: folder)
    let item = project.newSession()
    item.session.executableOverride = try standIn("claude", "read line\nexit 3")
    item.session.send("go")
    for _ in 0..<50 where !item.hasStopped {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(item.session.phase == .exited(status: 3))
    #expect(item.stopReason == "Stopped, exit 3")
  }

  /// A session running here gives way when another process opens it: an editor's panel
  /// typed in after a move resumes the same id, and two writers must never meet.
  @Test func aRowWithItsOwnProcessGivesWayToAnother() async throws {
    let fake = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat >> \"$0.stdin\"\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let file = folder.appending(path: "a.jsonl")
    try Data(
      #"{"type":"user","message":{"role":"user","content":"Earlier"}}"#.appending("\n").utf8
    ).write(to: file)
    let project = Project(folder: folder)
    let item = project.attach(target("a"))
    item.session.executableOverride = fake
    await item.session.loadHistory()
    item.session.send("hello")
    for _ in 0..<50 where !item.session.isProcessRunning {
      try await Task.sleep(for: .milliseconds(100))
    }
    defer { item.session.stop() }
    #expect(item.session.isProcessRunning)
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    OpenSessions.shared.liveChanged(["a"])
    #expect(item.session.isReadOnly)
    #expect(!item.session.isProcessRunning)
  }

  /// Another app's session between turns: its process is ended, and the session becomes
  /// one of the window's rows, read-only until the registry lets it go.
  @Test func movingASessionHereEndsItsProcess() async throws {
    let sleeper = Process()
    sleeper.executableURL = URL(filePath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    defer { if sleeper.isRunning { sleeper.terminate() } }
    let pid = sleeper.processIdentifier
    let sessions = folder.appending(path: "sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try Data(#"{"pid":\#(pid),"sessionId":"a","status":"idle"}"#.utf8)
      .write(to: sessions.appending(path: "\(pid).json"))
    var summary = SessionSummary(
      sessionID: "a", account: ClaudeAccount(directory: folder, isDefault: false),
      file: folder.appending(path: "a.jsonl"), modified: .now, size: 1)
    summary.cwd = folder.path(percentEncoded: false)
    summary.live = LiveSession(pid: pid, sessionID: "a", status: "busy")
    let project = Project(folder: folder)
    #expect(!project.moveHere(summary))
    #expect(project.sessions.isEmpty)
    summary.live?.status = "idle"
    #expect(project.moveHere(summary))
    for _ in 0..<50 where sleeper.isRunning { try await Task.sleep(for: .milliseconds(100)) }
    #expect(!sleeper.isRunning)
    let item = try #require(project.selected)
    #expect(item.sessionID == "a" && !item.isWatching && item.session.isReadOnly)
  }

  /// A window opened after a relaunch, without its scene storage, gets its rows back; one
  /// left with none forgets the folder.
  @Test func theAppRemembersEachFoldersSessions() throws {
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let stored = StoredProject(sessions: [target("a"), target("b")], selected: "b")
    ProjectMemory.remember(stored, for: folder, in: defaults)
    let other = folder.appending(path: "other", directoryHint: .isDirectory)
    #expect(ProjectMemory.stored(for: folder.appending(path: "."), in: defaults) == stored)
    #expect(ProjectMemory.stored(for: other, in: defaults) == nil)

    let project = Project(
      folder: folder, restoring: ProjectMemory.stored(for: folder, in: defaults))
    #expect(project.sessions.map(\.sessionID) == ["a", "b"])
    #expect(project.selected?.sessionID == "b")

    ProjectMemory.remember(StoredProject(), for: folder, in: defaults)
    #expect(ProjectMemory.stored(for: folder, in: defaults) == nil)
  }

  /// The editor's tabs come back with the window, the active one active; a file deleted
  /// since is left out without a word.
  @Test func theOpenTabsSurviveARelaunch() throws {
    let names = ["a.txt", "b.txt", "c.txt"]
    for name in names {
      try name.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
    }
    let project = Project(folder: folder)
    for name in names { project.workspace.open(folder.appending(path: name)) }
    project.workspace.activate(
      try #require(project.workspace.documents.first { $0.name == "b.txt" }))
    let stored = try JSONDecoder().decode(
      StoredProject.self, from: JSONEncoder().encode(project.stored))
    try FileManager.default.removeItem(at: folder.appending(path: "c.txt"))

    let restored = Project(folder: folder, restoring: stored)
    #expect(restored.workspace.documents.map(\.name) == ["a.txt", "b.txt"])
    #expect(restored.workspace.active?.name == "b.txt")
    #expect(restored.workspace.problem == nil)
  }

  /// A window stored before tabs were kept still decodes, with its sessions.
  @Test func aWindowStoredWithoutTabsStillDecodes() throws {
    let json = #"{"sessions":[],"selected":"a"}"#
    let stored = try JSONDecoder().decode(StoredProject.self, from: Data(json.utf8))
    #expect(stored.selected == "a")
    #expect(stored.documents == nil)
  }

  /// A folder left with tabs open and no session is still worth remembering.
  @Test func theAppRemembersAFolderWithOnlyTabs() throws {
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let stored = StoredProject(documents: [
      folder.appending(path: "a.txt").path(percentEncoded: false)
    ])
    ProjectMemory.remember(stored, for: folder, in: defaults)
    #expect(ProjectMemory.stored(for: folder, in: defaults) == stored)
  }

  private func relaunched(_ project: Project) throws -> Project {
    let stored = try JSONDecoder().decode(
      StoredProject.self, from: JSONEncoder().encode(project.stored))
    return Project(folder: folder, restoring: stored)
  }

  /// Removing the marked rows reads no transcript of a row about to go: only the row shown
  /// once they are gone loads its history.
  @Test func removingTheMarkedRowsLoadsOnlyTheRowLeft() async throws {
    let project = Project(folder: folder)
    for id in ["d", "c", "b", "a"] {
      try Data(#"{"type":"user","message":{"role":"user","content":"go"}}"#.appending("\n").utf8)
        .write(to: folder.appending(path: "\(id).jsonl"))
      project.attach(target(id))
    }
    let restored = try relaunched(project)
    let rows = Dictionary(
      uniqueKeysWithValues: restored.sessions.compactMap { item in
        item.sessionID.map { ($0, item) }
      })
    let (a, b, c, d) = (rows["a"]!, rows["b"]!, rows["c"]!, rows["d"]!)
    restored.select(a)
    restored.click(b, .toggle)
    restored.click(c, .toggle)
    try #require(restored.marked == [a.id, b.id, c.id])
    restored.removeMarked()
    #expect(restored.selectedID == d.id)
    for _ in 0..<50 where !d.session.hasLoadedHistory {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(d.session.hasLoadedHistory)
    #expect(!b.session.hasLoadedHistory)
    #expect(!c.session.hasLoadedHistory)
  }

  /// A Codex row's last activity is its rollout file's date, as a Claude row's is its
  /// transcript's: read when the window comes back, and again when a turn ends.
  @Test func aCodexRowsLastActivityIsItsRolloutsDate() async throws {
    let rollout = folder.appending(path: "rollout-t1.jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    func written(_ date: Date) throws {
      try FileManager.default.setAttributes(
        [.modificationDate: date], ofItemAtPath: rollout.path(percentEncoded: false))
    }
    func activity(becomes date: Date, of item: ProjectSession) async throws {
      for _ in 0..<100 where item.lastActivity != date {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(item.lastActivity == date)
    }
    let earlier = Date(timeIntervalSince1970: 1_800_000_000)
    let later = earlier.addingTimeInterval(600)
    try written(earlier)
    let project = Project(folder: folder)
    project.attach(
      ResumeTarget(
        sessionID: "t1", cwd: folder.path(percentEncoded: false),
        file: rollout.path(percentEncoded: false), accountDirectory: "/home/.codex",
        accountIsDefault: true, agent: .codex))
    let restored = try relaunched(project)
    let item = try #require(restored.sessions.first)
    try await activity(becomes: earlier, of: item)
    try written(later)
    item.session.onTurnEnded?()
    try await activity(becomes: later, of: item)
  }

  /// The pane the keys were in comes back with the window: the editor's restored tab does
  /// not take them from the composer, and takes them when it had them.
  @Test func theFocusedPaneSurvivesARelaunch() throws {
    let file = folder.appending(path: "a.txt")
    try "a".write(to: file, atomically: true, encoding: .utf8)
    let project = Project(folder: folder)
    project.workspace.open(file)

    project.workspace.focusedPane = .composer
    let typing = try relaunched(project)
    #expect(typing.workspace.focusedPane == .composer)
    #expect(typing.focusesComposer)
    #expect(typing.workspace.holdsEditorFocus)

    project.workspace.focusedPane = .editor
    let editing = try relaunched(project)
    #expect(!editing.focusesComposer)
    #expect(!editing.workspace.holdsEditorFocus)

    project.workspace.focusedPane = .sessions
    let browsing = try relaunched(project)
    #expect(!browsing.focusesComposer)
    #expect(browsing.claimsRestoredFocus(.sessions))
    #expect(!browsing.claimsRestoredFocus(.sessions))  // once
  }

  /// The editor had the keys but its file is gone: the composer takes them, not nobody.
  @Test func anEditorFocusWithNoTabLeftFallsBackToTheComposer() throws {
    let file = folder.appending(path: "a.txt")
    try "a".write(to: file, atomically: true, encoding: .utf8)
    let project = Project(folder: folder)
    project.workspace.open(file)
    project.workspace.focusedPane = .editor
    let stored = try JSONDecoder().decode(
      StoredProject.self, from: JSONEncoder().encode(project.stored))
    try FileManager.default.removeItem(at: file)
    let restored = Project(folder: folder, restoring: stored)
    #expect(restored.focusesComposer)
  }

  /// Choosing a tab is the user's doing: its text view takes the keys again.
  @Test func activatingATabLetsTheEditorTakeTheKeys() throws {
    let file = folder.appending(path: "a.txt")
    try "a".write(to: file, atomically: true, encoding: .utf8)
    let project = Project(folder: folder)
    project.workspace.open(file)
    project.workspace.focusedPane = .composer
    let restored = try relaunched(project)
    #expect(restored.workspace.holdsEditorFocus)
    restored.workspace.activate(try #require(restored.workspace.active))
    #expect(!restored.workspace.holdsEditorFocus)
  }
}
