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
    #expect(project.nextNeedingAttention()?.id == c.id)
    b.isUnread = true
    #expect(project.nextNeedingAttention()?.id == b.id)
    project.select(b)
    #expect(project.nextNeedingAttention()?.id == c.id)
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

    let session = ClaudeSession(folder: folder)
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
}
