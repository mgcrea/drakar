import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Running a skill in each subfolder", .serialized)
struct ProjectFanOutTests {
  private let parent: URL
  private let folders: [URL]
  private let check = SkillEntry(name: "check", description: "Fix it")
  private let audit = SkillEntry(name: "audit", argumentHint: "<area>")

  init() throws {
    let parent = FileManager.default.temporaryDirectory.appending(
      path: "drakar-fanout-\(UUID().uuidString)", directoryHint: .isDirectory)
    self.parent = parent
    folders = ["alpha", "beta", "gamma"].map {
      parent.appending(path: $0, directoryHint: .isDirectory)
    }
    for folder in folders {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  /// A stand-in CLI that reads forever (`cat`), or one that exits at once.
  private func standIn(exits: Bool = false) throws -> URL {
    let script = parent.appending(path: exits ? "claude-exits" : "claude")
    try Data((exits ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\ncat > /dev/null\n").utf8)
      .write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func prompts(_ item: ProjectSession) -> [String] {
    item.session.transcript.entries.compactMap {
      if case .prompt(let text) = $0.kind { text } else { nil }
    }
  }

  /// One session per folder, named after the skill and the folder, on top in folder order,
  /// the first shown; unlimited, each is sent the skill.
  @Test func oneSessionPerFolder() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: nil)
    #expect(
      project.sessions.prefix(3).map(\.displayTitle)
        == ["/check · alpha", "/check · beta", "/check · gamma"])
    #expect(
      project.sessions.prefix(3).map(\.session.folder.lastPathComponent)
        == ["alpha", "beta", "gamma"])
    #expect(project.selected?.id == project.sessions.first?.id)
    for item in project.sessions.prefix(3) { #expect(prompts(item) == ["/check"]) }
    #expect(project.fanOuts.count == 1)
  }

  /// Arguments follow the name; blank ones are left out.
  @Test func argumentsFollowTheName() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(
      audit, folders: [folders[0]], arguments: "  auth  ", mode: nil, limit: nil)
    #expect(prompts(try #require(project.sessions.first)) == ["/audit auth"])
  }

  /// The mode picked goes to every session.
  @Test func theModeGoesToEach() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: .plan, limit: 1)
    for item in project.sessions.prefix(3) { #expect(item.session.startingMode == .plan) }
  }

  /// With a limit, that many are sent; a turn end sends the next.
  @Test func aLimitSendsTheNextOnATurnEnd() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 2)
    let items = Array(project.sessions.prefix(3))
    #expect(items.map { prompts($0).count } == [1, 1, 0])
    items[0].session.onTurnEnded?()
    #expect(prompts(items[2]) == ["/check"])
  }

  /// A session that stops without a turn end (it could not start) frees its slot too.
  @Test func aSessionThatStopsFreesItsSlot() async throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn(exits: true)
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let last = try #require(project.sessions.dropFirst(2).first)
    // Each stand-in exits at once; the stops walk the queue to the last.
    for _ in 0..<100 where prompts(last).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(prompts(last) == ["/check"])
  }

  /// A folder gone before its session starts fails it at once: its slot goes to the next.
  @Test func aFolderGoneFreesItsSlot() async throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    let gone = parent.appending(path: "gone", directoryHint: .isDirectory)
    project.runInSubfolders(
      check, folders: [gone] + folders.prefix(1), arguments: "", mode: nil, limit: 1)
    let next = try #require(project.sessions.dropFirst().first)
    for _ in 0..<100 where prompts(next).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(prompts(next) == ["/check"])
  }

  /// A waiting session closed before its turn is skipped, not waited for.
  @Test func aClosedWaitingSessionIsSkipped() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.remove(items[1])
    items[0].session.onTurnEnded?()
    #expect(prompts(items[2]) == ["/check"])
  }

  /// Cancel leaves the waiting ones unsent; the batch goes once the running one is done.
  @Test func cancelLeavesTheWaitingUnsent() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.cancelFanOut(try #require(project.fanOuts.first))
    items[0].session.onTurnEnded?()
    #expect(prompts(items[1]).isEmpty)
    #expect(prompts(items[2]).isEmpty)
    #expect(project.fanOuts.isEmpty)
  }

  /// Ending or removing a running session frees its slot: the next one is sent the skill.
  @Test func endingOrRemovingARunningOneFreesItsSlot() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.end(items[0])
    #expect(prompts(items[1]) == ["/check"])
    project.remove(items[1])
    #expect(prompts(items[2]) == ["/check"])
  }

  /// One taken up in another process gives way here, and its slot with it.
  @Test func oneTakenUpElsewhereFreesItsSlot() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(2))
    project.gaveWay(items[0])
    #expect(prompts(items[1]) == ["/check"])
  }

  /// Closing the window stops every session without sending the waiting ones.
  @Test func stopAllSendsNothingMore() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.stopAll()
    #expect(prompts(items[1]).isEmpty)
    #expect(prompts(items[2]).isEmpty)
  }

  // MARK: After a relaunch

  /// A stand-in CLI that works on a prompt until the test writes `.done`, ends its turn, and
  /// logs every line it is sent.
  private func slowStandIn() throws -> URL {
    let script = parent.appending(path: "claude-slow")
    let source = """
      #!/bin/sh
      sid="s-$$"
      log() { printf '%s\\n' "$1" >> "$0.stdin"; }
      while read -r line; do
        log "$line"
        case "$line" in *'"type":"user"'*) break;; esac
      done
      printf '%s\\n' '{"type":"system","subtype":"init","cwd":"/tmp","session_id":"'"$sid"'","model":"m","permissionMode":"default"}'
      printf '%s\\n' '{"type":"assistant","message":{"id":"m-1","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"working"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"'"$sid"'"}'
      while [ ! -f "$0.done" ]; do sleep 0.02; done
      rm -f "$0.done"
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done.","stop_reason":"end_turn","session_id":"'"$sid"'"}'
      while read -r line; do log "$line"; done

      """
    try Data(source.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func eventually(
    within limit: Duration = .seconds(60), _ condition: () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  /// How many prompts the stand-in was sent.
  private func sent(_ text: String, by script: URL) -> Int {
    let log = (try? String(contentsOf: script.appendingPathExtension("stdin"), encoding: .utf8))
    return (log ?? "").split(separator: "\n").count { $0.contains(text) }
  }

  /// A batch over a relaunch: the stored window says one running and two waiting; the host
  /// still holds the running one, which comes back live, while the others come back as new
  /// sessions in their folders, unsent until the running turn ends. Then the next is sent.
  @Test func aBatchSurvivesARelaunch() async throws {
    let host = try LocalHost()
    defer {
      host.close()
      SessionHost.testDirectory = nil
    }
    SessionHost.testDirectory = host.directory
    let app = SessionHost(cooldown: .milliseconds(100), helper: URL(filePath: "/usr/bin/true"))
    let script = try slowStandIn()
    _ = await AgentSession.environment.value

    let before = Project(folder: parent)
    before.executableOverride = script
    before.sessionHost = app
    before.runInSubfolders(check, folders: folders, arguments: "", mode: .plan, limit: 1)
    let live = try #require(before.sessions.first)
    #expect(await eventually { live.session.hostID != nil && sent("/check", by: script) == 1 })
    #expect(await eventually { live.session.transcript.isRunning })

    // What the window wrote down, as `UserDefaults` hands it back.
    let stored = try JSONDecoder().decode(
      StoredProject.self, from: JSONEncoder().encode(before.stored))
    let batch = try #require(stored.fanOuts?.first)
    #expect(batch.entries.map(\.state) == [.running, .waiting, .waiting])
    #expect(
      batch.entries.map { URL(filePath: $0.folder).lastPathComponent } == [
        "alpha", "beta", "gamma",
      ])
    #expect(batch.entries[0].hostID == live.session.hostID)
    // The running one's pick follows what its process reported.
    #expect(batch.entries.dropFirst().map(\.mode) == [.plan, .plan])
    (live.session.process as? HostedProcess)?.detach()

    let after = Project(folder: parent, restoring: stored)
    after.executableOverride = script
    after.sessionHost = app
    defer { after.stopAll() }
    await after.takeBackHeld().value
    #expect(after.sessions.count == 3)
    let rows = after.sessions.sorted { $0.displayTitle < $1.displayTitle }
    #expect(rows.map(\.displayTitle) == ["/check · alpha", "/check · beta", "/check · gamma"])
    #expect(rows[0].session.isHosted && rows[0].session.transcript.isRunning)
    #expect(rows[0].session.hostID == live.session.hostID)
    for row in rows.dropFirst() {
      #expect(!row.session.isProcessRunning)
      #expect(prompts(row).isEmpty)
      #expect(row.session.startingMode == .plan)
    }
    #expect(after.fanOuts.count == 1)
    #expect(after.fanOuts.first?.queue.summary == "1 running · 2 waiting")
    #expect(sent("/check", by: script) == 1)

    try Data().write(to: script.appendingPathExtension("done"))
    #expect(await eventually { prompts(rows[1]) == ["/check"] })
    #expect(prompts(rows[2]).isEmpty)
    #expect(after.fanOuts.first?.queue.summary == "1 running · 1 waiting · 1 done")
    #expect(await eventually { sent("/check", by: script) == 2 })
  }

  /// A running entry whose process the host no longer holds has finished: its slot goes on.
  /// The waiting ones are new sessions that keep their account and mode, and Cancel works on
  /// the restored batch as it does on a new one.
  @Test func aRestoredBatchKeepsPicksAndCancels() async throws {
    let project = Project(
      folder: parent,
      restoring: StoredProject(fanOuts: [
        StoredFanOut(
          batch: UUID(), skillName: "check", prompt: "/check", limit: 1,
          entries: [
            .init(
              folder: folders[0].path, name: "/check · alpha", state: .running, hostID: "gone"),
            .init(
              folder: folders[1].path, name: "/check · beta", accountDirectory: "/tmp/acct",
              accountIsDefault: false, mode: .plan, state: .waiting),
            .init(
              folder: folders[2].path, name: "/check · gamma", accountDirectory: "/tmp/acct",
              accountIsDefault: false, mode: .plan, state: .waiting),
          ])
      ]))
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    await project.takeBackHeld().value
    let rows = project.sessions.sorted { $0.displayTitle < $1.displayTitle }
    #expect(rows.map(\.displayTitle) == ["/check · beta", "/check · gamma"])
    // The first waiting one took the slot the missing process left; the other still waits.
    #expect(prompts(rows[0]) == ["/check"])
    #expect(prompts(rows[1]).isEmpty)
    for row in rows {
      #expect(
        row.session.accountPick
          == ClaudeAccount(
            directory: URL(filePath: "/tmp/acct", directoryHint: .isDirectory), isDefault: false))
      #expect(row.session.startingMode == .plan)
    }
    #expect(project.fanOuts.first?.queue.summary == "1 running · 1 waiting · 1 done")
    project.cancelFanOut(try #require(project.fanOuts.first))
    rows[0].session.onTurnEnded?()
    #expect(prompts(rows[1]).isEmpty)
    #expect(project.fanOuts.isEmpty)
  }

  /// A window stored before batches were kept still decodes.
  @Test func aWindowStoredBeforeBatchesStillDecodes() throws {
    let old = Data(#"{"sessions":[],"selected":"abc"}"#.utf8)
    let stored = try JSONDecoder().decode(StoredProject.self, from: old)
    #expect(stored.fanOuts == nil && stored.selected == "abc")
  }

  /// A meta written before a session knew its batch still decodes.
  @Test func aMetaWrittenBeforeBatchesStillDecodes() throws {
    var meta = SessionMeta(
      start: AgentStart(
        folder: parent, environment: [:], executableOverride: nil, allowsBypass: false),
      windowFolder: parent.path, history: .none)
    meta.fanOut = FanOutMark(batch: UUID(), index: 2)
    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])
    #expect(object["fanOut"] != nil)
    var old = object
    old["fanOut"] = nil
    let back = try JSONDecoder().decode(
      SessionMeta.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(back.fanOut == nil && back.windowFolder == parent.path)
    let same = try JSONDecoder().decode(
      SessionMeta.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(same.fanOut == meta.fanOut)
  }
}
