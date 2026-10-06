import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What needs the person")
struct AttentionTests {

  private func project() throws -> Project {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return Project(folder: folder)
  }

  /// Unread rows after the selected one, wrapping, the selected one never.
  @Test func nextGoesToUnreadRowsInOrder() throws {
    let project = try project()
    let c = project.newSession()
    let b = project.newSession()
    let a = project.newSession()  // rows: a, b, c; a selected
    c.isUnread = true
    #expect(project.nextNeedingAttention()?.item?.id == c.id)
    b.isUnread = true
    #expect(project.nextNeedingAttention()?.item?.id == b.id)
    project.select(b)
    #expect(project.nextNeedingAttention()?.item?.id == c.id)
    c.isUnread = false
    #expect(project.nextNeedingAttention() == nil)
    _ = a
  }

  @Test func theBadgeCountsNothingWhenNothingWaits() throws {
    let project = try project()
    _ = project.newSession()
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    #expect(Attention.shared.waitingCount == 0)
  }
}

@MainActor
@Suite("The badge follows the windows")
struct AttentionBadgeTests {
  /// A stand-in `claude` that asks for a permission as soon as it starts: the hook fires when
  /// the request arrives, and again when the process goes away with it still waiting.
  @Test func aRequestAppearingAndGoingWithTheProcessBothTellTheBadge() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fake = folder.appending(path: "claude")
    let request =
      #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch a.txt"},"tool_use_id":"toolu_1"}}"#
    try Data("#!/bin/sh\necho '\(request)'\ncat > /dev/null\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    let session = AgentSession(folder: folder)
    session.executableOverride = fake
    var changes = 0
    session.onPermissionsChanged = { changes += 1 }
    session.send("hi")
    for _ in 0..<50 where session.transcript.pendingPermissions.isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(session.transcript.pendingPermissions.count == 1)
    #expect(changes == 1)
    session.stop()
    #expect(session.transcript.pendingPermissions.isEmpty)
    #expect(changes == 2)
  }

  /// A window that goes away stops counting.
  @Test func aWindowThatClosesStopsCounting() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = Project(folder: folder)
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    OpenSessions.shared.unregister(window: window)
    #expect(OpenSessions.shared.projects[window] == nil)
    #expect(Attention.shared.waitingCount == 0)
  }
}

@MainActor
@Suite("What a session wants, and how much", .serialized)
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
    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Built. Say the word and I will tag it."}]}}"#,
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
    #expect(item.wants == "Say the word and I will tag it.")
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
    #expect(project.nextNeedingAttention()?.item?.id == item.id)
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
      ].joined(separator: "\n").appending("\n").utf8
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

  @Test func aRowSaysWhatItWants() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    #expect(RowState(item) == .asked)
    #expect(RowState.asked.label == "Asked you")
    #expect(RowState.choosing.label == "Asks you to choose")
    #expect(RowState.offered.label == "Offered")
  }

  /// A session started here has no history to read, so it never counts as loaded, and the
  /// file watcher keeps handing it a summary that lags the live turn. The live turn wins.
  @Test func aLiveTurnOutranksTheFilesSummary() async throws {
    let (project, item) = try await session(Self.asking)
    defer { project.stopAll() }
    item.preview = SessionSummary(
      sessionID: "s", account: ClaudeAccount(directory: URL(filePath: "/tmp"), isDefault: false),
      file: URL(filePath: "/tmp/s.jsonl"), modified: .now, size: 0)
    #expect(item.urgency == .question)
    item.session.send("yes")
    #expect(item.urgency == nil)
  }

  /// A level that does not notify falls back to "Finished its turn." when those are on, so
  /// turning finished-turn notifications on still covers a turn that ended on an offer.
  @Test func aTurnEndNotifiesItsAskOrThatItFinished() {
    let offer = ClosingAsk(kind: .offer, text: "Say the word.")
    let question = ClosingAsk(kind: .question, text: "Push it?")
    let quietOffers = { (level: Urgency) in level != .offer }
    #expect(
      Attention.turnEndNotice(
        ask: question, level: .question, notifiesTurnEnds: false, levelNotifies: quietOffers)?
        .body == "Push it?")
    #expect(
      Attention.turnEndNotice(
        ask: offer, level: .offer, notifiesTurnEnds: true, levelNotifies: quietOffers)?.body
        == "Finished its turn.")
    #expect(
      Attention.turnEndNotice(
        ask: offer, level: .offer, notifiesTurnEnds: false, levelNotifies: quietOffers) == nil)
    #expect(
      Attention.turnEndNotice(
        ask: nil, level: nil, notifiesTurnEnds: false, levelNotifies: quietOffers) == nil)
  }

  /// `UserDefaults` is not observable: a switch flipped in the Attention pane must still
  /// redraw the rows and the header that read it.
  @Test func aSwitchFlippedInSettingsRedrawsWhatReadsIt() {
    let redrawn = Flag()
    withObservationTracking {
      _ = AttentionChoice.isOn(.offer, .counts)
    } onChange: {
      redrawn.value = true
    }
    AttentionChoice.defaults.set(true, forKey: AttentionChoice.key(.offer, .counts))
    #expect(redrawn.value)
  }
}

/// Set from an observation callback, which may not capture a variable.
private final class Flag: @unchecked Sendable {
  var value = false
}

@MainActor
@Suite("What a session elsewhere wants")
struct ElsewhereUrgencyTests {
  private func summary(
    status: String?, waitingFor: String? = nil, pendingQuestion: String? = nil,
    ask: ClosingAsk? = nil, live: Bool = true
  ) -> SessionSummary {
    var summary = SessionSummary(
      sessionID: "s1", account: ClaudeAccount(directory: URL(filePath: "/a"), isDefault: true),
      file: URL(filePath: "/a/projects/p/s1.jsonl"), modified: .now, size: 1)
    if live {
      summary.live = LiveSession(pid: 1, sessionID: "s1", status: status, waitingFor: waitingFor)
    }
    summary.pendingQuestion = pendingQuestion
    summary.closingAsk = ask
    summary.closingMessageID = ask.map { _ in "m1" }
    return summary
  }

  private let question = ClosingAsk(kind: .question, text: "Want me to commit it?")

  @Test func waitingIsAPermissionOrAChoice() {
    let permission = summary(status: "waiting", waitingFor: "permission prompt")
    #expect(Urgency.of(permission, recognisesAsks: true, dismissed: nil) == .permission)
    #expect(Urgency.permission.wants(of: permission) == "permission prompt")
    let choice = summary(status: "waiting", pendingQuestion: "Which filename?")
    #expect(Urgency.of(choice, recognisesAsks: true, dismissed: nil) == .choice)
    #expect(Urgency.choice.wants(of: choice) == "Which filename?")
  }

  /// A turn that ended on a question asks once the session is idle, unless that message
  /// was dismissed or recognition is off.
  @Test func anIdleSessionAsksWhatItsTurnEndedOn() {
    let asked = summary(status: "idle", ask: question)
    #expect(Urgency.of(asked, recognisesAsks: true, dismissed: nil) == .question)
    #expect(Urgency.question.wants(of: asked) == "Want me to commit it?")
    #expect(Urgency.of(asked, recognisesAsks: true, dismissed: "m1") == nil)
    #expect(Urgency.of(asked, recognisesAsks: true, dismissed: "m0") == .question)
    #expect(Urgency.of(asked, recognisesAsks: false, dismissed: nil) == nil)
    let offered = summary(status: "idle", ask: ClosingAsk(kind: .offer, text: "Say the word."))
    #expect(Urgency.of(offered, recognisesAsks: true, dismissed: nil) == .offer)
  }

  /// Busy, ended, or one of Drakar's own (no registry entry): nothing to want.
  @Test func busyOrEndedWantsNothing() {
    #expect(
      Urgency.of(summary(status: "busy", ask: question), recognisesAsks: true, dismissed: nil)
        == nil)
    #expect(
      Urgency.of(
        summary(status: nil, ask: question, live: false), recognisesAsks: true, dismissed: nil)
        == nil)
  }

  /// A new ask is news; the same ask seen again is not.
  @Test func eachAskIsItsOwnNews() {
    let asked = summary(status: "idle", ask: question)
    #expect(Attention.newsKey(asked, level: nil) == "")
    #expect(Attention.newsKey(asked, level: .question) == "question#m1")
    var next = asked
    next.closingMessageID = "m2"
    #expect(Attention.newsKey(next, level: .question) != Attention.newsKey(asked, level: .question))
  }

  /// A dismissal of a session elsewhere is kept with the window's, and comes back with it.
  @Test func aDismissalElsewhereSurvivesTheRelaunch() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-elsewhere-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = Project(folder: folder)
    project.dismissAsk(summary(status: "idle", ask: question))
    #expect(project.dismissedElsewhere == ["s1": "m1"])
    #expect(project.stored.dismissedQuestions == ["s1": "m1"])
    let restored = Project(folder: folder, restoring: project.stored)
    #expect(restored.dismissedElsewhere == ["s1": "m1"])
  }
}
