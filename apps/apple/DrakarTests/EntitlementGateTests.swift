import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// The licence gate: what it refuses, against a stand-in `claude` that records its stdin,
/// and what it must never refuse once a turn is running.
///
/// Every session test sets `EntitlementMonitor.forced` for its own task rather than flipping
/// a global: suites run in parallel, and one suite's refusal must never reach another's
/// sends. The monitor tests build their own instances, which never touch the IDE bridge.
@MainActor
@Suite("The licence gate")
struct EntitlementGateTests {
  private let folder: URL
  private let fake: URL
  private var received: URL { fake.appendingPathExtension("stdin") }

  private static let initLine =
    #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s-gate","model":"m","permissionMode":"default"}"#
  private static let looking =
    #"{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-gate"}"#
  private static let asking =
    #"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}}"#

  private let check = SkillEntry(name: "check", description: "Fix it")

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fake = folder.appending(path: "claude")
    // init on the first line; after the prompt a tool call and its permission request; then
    // it reads on, the turn never ending, so a stop has a turn to interrupt. Every line it
    // is sent goes to `$0.stdin`.
    let script = """
      #!/bin/sh
      log() { printf '%s\\n' "$1" >> "$0.stdin"; }
      read -r line; log "$line"
      echo '\(Self.initLine)'
      while read -r line; do log "$line"; case "$line" in *'"type":"user"'*) break;; esac; done
      echo '\(Self.looking)'
      echo '\(Self.asking)'
      exec cat >> "$0.stdin"

      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  private func session() -> AgentSession {
    let session = AgentSession(folder: folder)
    session.executableOverride = fake
    session.accounts = { [] }
    return session
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<50 where !condition() {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func receivedText() -> String {
    (try? String(contentsOf: received, encoding: .utf8)) ?? ""
  }

  private func prompts(_ item: ProjectSession) -> [String] {
    item.session.transcript.entries.compactMap {
      if case .prompt(let text) = $0.kind { text } else { nil }
    }
  }

  /// A session mid-turn and waiting on its permission request, sent while entitled.
  private func waitingOnPermission() async throws -> AgentSession {
    let session = session()
    try await EntitlementMonitor.$forced.withValue(true) {
      session.send("hi")
      try await waitFor { !session.transcript.pendingPermissions.isEmpty }
    }
    try #require(!session.transcript.pendingPermissions.isEmpty)
    return session
  }

  // MARK: - What is refused

  @Test func refusesSendWhenNotEntitled() async throws {
    let session = session()
    defer { session.stop() }
    try await EntitlementMonitor.$forced.withValue(false) {
      #expect(!session.canSend)
      session.send("hi")
      // A spawn runs after `send` returns: give a refused one the time to show itself.
      try await Task.sleep(for: .milliseconds(300))
    }
    #expect(session.transcript.entries.isEmpty)
    #expect(session.process == nil)
    #expect(receivedText().isEmpty)
  }

  /// The composer keeps its text when its `canSend` is false (`ComposerView.submit`), and
  /// `SessionView` hands it `session.canSend || session.canQueue`. What is left to show here:
  /// a broadcast skips every marked session, and nothing in the gate writes a draft.
  @Test func refusedSendKeepsDraft() throws {
    let project = Project(folder: folder)
    project.executableOverride = fake
    defer { project.stopAll() }
    project.newSession()
    project.newSession()
    let items = project.listedHeld
    project.select(items[0])
    project.markAll()
    items[0].draft = "hi"
    EntitlementMonitor.$forced.withValue(false) {
      #expect(!project.canSendToMarked)
      let result = project.broadcast("hi", context: [], attachments: [])
      #expect(result.sent == 0)
      #expect(result.skipped == 2)
      EntitlementMonitor.shared.apply()
    }
    #expect(items[0].draft == "hi")
    for item in items { #expect(prompts(item).isEmpty) }
  }

  @Test func refusesQueueWhenNotEntitled() async throws {
    let session = try await waitingOnPermission()
    defer { session.stop() }
    #expect(EntitlementMonitor.$forced.withValue(true) { session.canQueue })
    EntitlementMonitor.$forced.withValue(false) {
      #expect(!session.canQueue)
      session.send("second")
    }
    #expect(session.transcript.queuedPrompts.isEmpty)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!receivedText().contains("second"))
  }

  @Test func fanOutRefusedWhenNotEntitled() async throws {
    let (parent, folders) = try subfolders()
    let project = Project(folder: parent)
    project.executableOverride = fake
    defer { project.stopAll() }
    EntitlementMonitor.$forced.withValue(false) {
      project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: nil)
      #expect(!project.canRun(in: .newSession))
    }
    for item in project.sessions { #expect(prompts(item).isEmpty) }
    #expect(project.fanOuts.isEmpty)
    try await Task.sleep(for: .milliseconds(300))
    #expect(receivedText().isEmpty)
  }

  /// Three subfolders under `folder`, made.
  private func subfolders() throws -> (URL, [URL]) {
    let parent = folder.appending(path: "parent", directoryHint: .isDirectory)
    let folders = ["alpha", "beta", "gamma"].map {
      parent.appending(path: $0, directoryHint: .isDirectory)
    }
    for folder in folders {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    return (parent, folders)
  }

  /// A fan-out one at a time, started entitled, whose first turn ends after the trial did:
  /// the next is refused and waits again, rather than counting as running.
  private func refusedMidBatch() throws -> (Project, [ProjectSession], FanOutBatch) {
    let (parent, folders) = try subfolders()
    let project = Project(folder: parent)
    project.executableOverride = fake
    EntitlementMonitor.$forced.withValue(true) {
      project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    }
    let items = Array(project.sessions.prefix(3))
    let batch = try #require(project.fanOuts.first)
    #expect(items.map { prompts($0).count } == [1, 0, 0])
    EntitlementMonitor.$forced.withValue(false) { items[0].session.onTurnEnded?() }
    return (project, items, batch)
  }

  @Test func aRefusedFanOutWaitsAndResumes() throws {
    let (project, items, batch) = try refusedMidBatch()
    defer { project.stopAll() }
    #expect(batch.queue.count(.running) == 0)
    #expect(batch.queue.count(.waiting) == 2)
    #expect(project.fanOuts.count == 1)
    #expect(prompts(items[1]).isEmpty)

    // Still refused: nothing moves.
    EntitlementMonitor.$forced.withValue(false) { project.resumeFanOuts() }
    #expect(batch.queue.count(.waiting) == 2)

    // A trial started or a key entered: the next waiting one goes, in order.
    EntitlementMonitor.$forced.withValue(true) { project.resumeFanOuts() }
    #expect(prompts(items[1]) == ["/check"])
    #expect(prompts(items[2]).isEmpty)
    #expect(batch.queue.count(.running) == 1)
    #expect(batch.queue.count(.waiting) == 1)
  }

  @Test func cancelClearsARefusedFanOut() throws {
    let (project, items, batch) = try refusedMidBatch()
    defer { project.stopAll() }
    project.cancelFanOut(batch)
    #expect(project.fanOuts.isEmpty)
    for item in items.dropFirst() { #expect(prompts(item).isEmpty) }
  }

  /// A resume that sends a prompt is refused too: Session > Answer Yes on a session that
  /// ended on a yes-or-no question writes nothing, and leaves the draft.
  @Test func answerYesIsRefusedWhenNotEntitled() throws {
    let project = Project(folder: folder)
    project.executableOverride = fake
    defer { project.stopAll() }
    let item = project.attach(
      ResumeTarget(
        sessionID: "a", cwd: folder.path(percentEncoded: false),
        file: folder.appending(path: "a.jsonl").path(percentEncoded: false),
        accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false))
    var summary = SessionSummary(
      sessionID: "a", account: ClaudeAccount(directory: folder, isDefault: false),
      file: folder.appending(path: "a.jsonl"), modified: .now, size: 1)
    summary.closingAsk = ClosingAsk(kind: .question, text: "Ship it?", isYesOrNo: true)
    summary.closingMessageID = "m1"
    item.preview = summary
    item.draft = "half a thought"
    #expect(EntitlementMonitor.$forced.withValue(true) { project.yesOrNoSelected != nil })
    EntitlementMonitor.$forced.withValue(false) {
      #expect(project.yesOrNoSelected == nil)
      project.answerYesSelected()
    }
    #expect(item.session.transcript.entries.isEmpty)
    #expect(item.session.process == nil)
    #expect(item.draft == "half a thought")
  }

  // MARK: - What is never refused

  /// The trial ends with a turn waiting on a permission: the answer still reaches the CLI,
  /// and Stop still stops it. Only the next prompt is refused.
  @Test func answersPermissionAfterTrialEnds() async throws {
    let session = try await waitingOnPermission()
    defer { session.stop() }
    let pending = try #require(session.transcript.pendingPermissions.first)
    try await EntitlementMonitor.$forced.withValue(false) {
      session.answer(pending, .allow(updatedInput: pending.request.input))
      try await waitFor { receivedText().contains(#""request_id":"req-1""#) }
      #expect(session.transcript.pendingPermissions.isEmpty)
      #expect(session.transcript.isRunning)

      session.interrupt()
      try await waitFor { receivedText().contains(#""subtype":"interrupt""#) }
      session.stop()
      #expect(session.process == nil)
    }
    let text = receivedText()
    #expect(text.contains(#""request_id":"req-1""#))
    #expect(text.contains(#""subtype":"interrupt""#))
  }

  // MARK: - The monitor

  @Test func allowsEverythingWhileNotSelling() {
    let monitor = EntitlementMonitor(
      isSelling: false, entitlement: { .resolve(.refused("No licence key"), trialActive: false) })
    #expect(!monitor.current.isEntitled)
    #expect(monitor.allowsWork)
    monitor.apply()
    #expect(monitor.allowsWork)
  }

  /// The trial is the process's own, and another suite may have started it already
  /// (`Trial.start()` is idempotent and cannot be ended): this asserts only what holds
  /// either way, that a started one lets the work through.
  @Test func trialAllowsWork() {
    let monitor = EntitlementMonitor(isSelling: true)
    Trial.start()
    monitor.apply()
    #expect(monitor.allowsWork)
    #expect(monitor.current.isEntitled)
  }

  /// The two states the live trial above cannot reach in this process, through a source
  /// the test controls.
  @Test func refusesWithNoKeyAndNoTrialWhileSelling() {
    var trialActive = false
    let monitor = EntitlementMonitor(
      isSelling: true,
      entitlement: { .resolve(.refused("No licence key"), trialActive: trialActive) })
    #expect(!monitor.allowsWork)
    trialActive = true
    monitor.apply()
    #expect(monitor.allowsWork)
    trialActive = false
    monitor.apply()
    #expect(!monitor.allowsWork)
  }

  /// What `canSend` reads: the task's forced answer first, else the shared monitor's.
  @Test func forcedWinsForItsTaskOnly() {
    #expect(EntitlementMonitor.$forced.withValue(false) { !EntitlementMonitor.allowsWorkNow })
    #expect(EntitlementMonitor.$forced.withValue(true) { EntitlementMonitor.allowsWorkNow })
    #expect(EntitlementMonitor.allowsWorkNow == EntitlementMonitor.shared.allowsWork)
  }
}
