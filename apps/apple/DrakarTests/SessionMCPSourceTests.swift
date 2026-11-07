import DrakarKit
import DrakarMCP
import Foundation
import Testing

@testable import Drakar

/// What the MCP server reads of the app: rows in windows run by a stand-in `claude`, rows the
/// session monitor follows in a registry and transcripts of their own, and processes a
/// session host holds with no window. Each test registers its windows in an `OpenSessions` of
/// its own, so nothing the person has open is read.
@MainActor
@Suite("The MCP server's sessions", .serialized)
struct SessionMCPSourceTests {
  private let defaults: UserDefaults

  init() {
    defaults = UserDefaults(suiteName: "drakar-mcp-source-\(UUID().uuidString)")!
    // An empty scratch suite: asks are recognised, as they are by default.
    AttentionChoice.defaults = UserDefaults(suiteName: "drakar-tests-\(UUID().uuidString)")!
  }

  private static func initLine(_ id: String) -> String {
    #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":""#
      + id + #"","model":"m","permissionMode":"default"}"#
  }

  private static let done = [
    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Done."}]}}"#,
    #"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#,
  ]
  private static let asking = [
    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Built. Want me to commit it?"}]}}"#,
    #"{"type":"result","subtype":"success","is_error":false,"result":"Built. Want me to commit it?"}"#,
  ]
  private static let permission =
    #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch a.txt"},"tool_use_id":"toolu_1"}}"#
  private static let question =
    #"{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which filename?","header":"File","options":[{"label":"a.txt"},{"label":"b.txt"}],"multiSelect":false}]},"tool_use_id":"t1","requires_user_interaction":true}}"#
  private static let plan =
    ##"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# Add hello.txt"},"tool_use_id":"t2","requires_user_interaction":true}}"##

  private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// A stand-in `claude` that says these lines once started, then waits.
  private func fake(in folder: URL, _ lines: [String]) throws -> URL {
    let fake = folder.appending(path: "claude")
    let script =
      "#!/bin/sh\n" + lines.map { "echo '\($0)'" }.joined(separator: "\n") + "\ncat > /dev/null\n"
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return fake
  }

  /// A window's session, run by a stand-in that says `lines` after its init, once its turn
  /// ended or it waits on the person.
  private func session(
    _ id: String, _ lines: [String], in project: Project
  ) async throws -> ProjectSession {
    let item = project.newSession(agent: .claude)
    item.session.executableOverride = try fake(
      in: try folder(), [Self.initLine(id)] + lines)
    item.session.send("Build it")
    for _ in 0..<100
    where item.sessionID == nil
      || (item.session.transcript.turnEnd == nil && !item.session.transcript.isWaitingOnPerson)
    {
      try await Task.sleep(for: .milliseconds(50))
    }
    return item
  }

  /// One window, registered in an `OpenSessions` of the test's own.
  private func window() throws -> (Project, OpenSessions, UUID) {
    let project = Project(folder: try folder())
    let open = OpenSessions()
    let window = UUID()
    open.register(project, window: window)
    return (project, open, window)
  }

  private func source(
    _ open: OpenSessions, monitor: SessionMonitor = SessionMonitor()
  ) -> SessionMCPSource {
    SessionMCPSource(defaults: defaults, openSessions: open, monitor: monitor)
  }

  // MARK: - Windows

  /// A row with an id is listed; a blank tab never prompted, which has none, is not (spec §2).
  @Test func windowRowListed() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    _ = try await session("s-idle", Self.done, in: project)
    _ = project.newSession(agent: .claude)

    let rows = await source(open).sessions(includeEnded: false, endedLimit: 0)
    #expect(rows.map(\.id) == ["s-idle"])
    let row = try #require(rows.first)
    #expect(row.place == .window)
    #expect(row.state == .idle)
    #expect(row.agent == .claude)
    #expect(row.folder == ProjectPath.normalize(project.folder))
    #expect(row.runner == nil)
    #expect(row.title == "Build it")
    #expect(row.readOnly == false)
    #expect(row.waitingFor == nil)
  }

  @Test func pendingPermissionIsWaiting() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    _ = try await session("s-perm", [Self.permission], in: project)
    let source = source(open)

    let row = try #require(await source.sessions(includeEnded: false, endedLimit: 0).first)
    #expect(row.state == .waiting)
    #expect(row.waitingFor == "Bash: touch a.txt")

    let items = await source.attention()
    #expect(items.count == 1)
    #expect(items.first?.kind == .permission)
    #expect(items.first?.pending?.requestID == "r1")
    #expect(items.first?.session.id == "s-perm")

    let detail = try #require(await source.detail(of: "s-perm"))
    #expect(detail.pending.map(\.requestID) == ["r1"])
    #expect(detail.row == row)
  }

  @Test func askUserQuestionIsQuestionKind() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    _ = try await session("s-question", [Self.question], in: project)

    let items = await source(open).attention()
    #expect(items.map(\.kind) == [.question])
    #expect(items.first?.pending?.requestID == "q1")
  }

  @Test func planIsPlanKind() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    _ = try await session("s-plan", [Self.plan], in: project)

    let items = await source(open).attention()
    #expect(items.map(\.kind) == [.plan])
    #expect(items.first?.pending?.requestID == "p1")
  }

  /// A turn that ended asking is idle with what it asks, and needs the person after anything
  /// waiting on an answer.
  @Test func attentionIsMostUrgentFirst() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    _ = try await session("s-asks", Self.asking, in: project)
    _ = try await session("s-perm", [Self.permission], in: project)
    _ = try await session("s-plan", [Self.plan], in: project)
    let source = source(open)

    let items = await source.attention()
    #expect(items.map(\.session.id) == ["s-perm", "s-plan", "s-asks"])
    #expect(items.map(\.kind) == [.permission, .plan, .askedInText])
    #expect(items.last?.text == "Want me to commit it?")
    #expect(items.last?.pending == nil)

    let asks = await source.sessions(includeEnded: false, endedLimit: 0)
      .first { $0.id == "s-asks" }
    #expect(asks?.state == .idle)
    #expect(asks?.waitingFor == "Want me to commit it?")
  }

  /// The window's own transcript, live, not one read again from a file.
  @Test func transcriptOfWindowRow() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    let item = try await session("s-read", Self.done, in: project)

    let transcript = try await source(open).transcript(of: "s-read")
    #expect(!transcript.entries.isEmpty)
    #expect(transcript.entries == item.session.displayedTranscript.entries)
  }

  @Test func permissionsSwitchReadPerCall() async throws {
    let source = source(OpenSessions())
    #expect(await source.permissionsAllowed() == false)
    defaults.set(true, forKey: MCPSettingsKey.allowsPermissions)
    #expect(await source.permissionsAllowed() == true)
    defaults.set(false, forKey: MCPSettingsKey.allowsPermissions)
    #expect(await source.permissionsAllowed() == false)
  }

  @Test func anUnknownSessionHasNoDetailAndNoTranscript() async throws {
    let source = source(OpenSessions())
    #expect(await source.detail(of: "nobody") == nil)
    await #expect(throws: SessionError.self) { try await source.transcript(of: "nobody") }
  }

  // MARK: - The monitor

  /// A Claude Code account with transcripts under `/w/drakar` and registry entries for the
  /// sessions given, live in processes that are alive (this one and its parent).
  private func account(
    transcripts: [String], live: [(id: String, pid: Int32, status: String)]
  ) throws -> (home: URL, account: ClaudeAccount) {
    let home = FileManager.default.temporaryDirectory.appending(path: "mcp-monitor-\(UUID())")
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    let projects = account.directory.appending(path: "projects/-w-drakar")
    let registry = account.directory.appending(path: "sessions")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    for id in transcripts {
      let lines = [
        #"{"type":"user","cwd":"/w/drakar","message":{"role":"user","content":"go"}}"#,
        #"{"type":"assistant","message":{"id":"m-\#(id)","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Gone."}]}}"#,
      ]
      try Data(lines.joined(separator: "\n").appending("\n").utf8)
        .write(to: projects.appending(path: "\(id).jsonl"))
    }
    for entry in live {
      let json =
        #"{"pid":\#(entry.pid),"sessionId":"\#(entry.id)","cwd":"/w/drakar","entrypoint":"cli","status":"\#(entry.status)","waitingFor":"permission prompt"}"#
      try Data(json.utf8).write(to: registry.appending(path: "\(entry.pid).json"))
    }
    return (home, account)
  }

  private func started(_ account: ClaudeAccount, live: Int) async throws -> SessionMonitor {
    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    for _ in 0..<40 where monitor.liveIDs.count < live || monitor.all.isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    return monitor
  }

  /// A session live in a terminal is listed read-only, where it runs, and needs the person
  /// while its registry says it waits; one no process has open is listed only when asked.
  @Test func elsewhereAndEndedSessionsFromTheMonitor() async throws {
    let (home, account) = try account(
      transcripts: ["s-else", "s-old"], live: [("s-else", getpid(), "waiting")])
    defer { try? FileManager.default.removeItem(at: home) }
    let monitor = try await started(account, live: 1)
    defer { monitor.stop() }
    let source = source(OpenSessions(), monitor: monitor)

    let live = await source.sessions(includeEnded: false, endedLimit: 0)
    #expect(live.map(\.id) == ["s-else"])
    #expect(live.first?.place == .elsewhere)
    #expect(live.first?.state == .waiting)
    #expect(live.first?.readOnly == true)
    #expect(live.first?.heldBy == "a terminal")
    #expect(live.first?.waitingFor == "permission prompt")
    #expect(live.first?.folder == "/w/drakar")

    let all = await source.sessions(includeEnded: true, endedLimit: 10)
    #expect(all.map(\.id) == ["s-else", "s-old"])
    #expect(all.last?.state == .ended)

    let items = await source.attention()
    #expect(items.map(\.session.id) == ["s-else"])
    #expect(items.first?.kind == .permission)
    #expect(items.first?.pending == nil)

    // Read from its file, as Home's preview reads it.
    let transcript = try await source.transcript(of: "s-old")
    #expect(transcript.entries.first?.kind == .prompt("go"))
    #expect(await source.detail(of: "s-old")?.row.state == .ended)
  }

  /// A session in a window is listed once, as the window's, whatever the monitor says of it.
  @Test func aWindowsSessionIsNotListedAgainFromTheMonitor() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    _ = try await session("s-both", Self.done, in: project)
    let (home, account) = try account(
      transcripts: ["s-both", "s-else"],
      live: [("s-both", getpid(), "busy"), ("s-else", getppid(), "idle")])
    defer { try? FileManager.default.removeItem(at: home) }
    let monitor = try await started(account, live: 2)
    defer { monitor.stop() }

    let rows = await source(open, monitor: monitor).sessions(includeEnded: true, endedLimit: 10)
    #expect(rows.map(\.id).sorted() == ["s-both", "s-else"])
    #expect(rows.first { $0.id == "s-both" }?.place == .window)
  }

  // MARK: - The session host

  private func held(
    _ id: String, session: String?, window: String = "/w/drakar", running: Bool = true,
    attachedApp: Int32? = nil, name: String? = nil, owner: String? = nil
  ) throws -> HeldProcess {
    var meta = SessionMeta(
      start: AgentStart(
        folder: URL(filePath: window), environment: [:], executableOverride: nil,
        allowsBypass: false),
      windowFolder: window, history: .none)
    meta.sessionID = session
    meta.name = name
    meta.owner = owner
    return HeldProcess(
      id: id, meta: try JSONEncoder().encode(meta), running: running, logLength: 0,
      attachedApp: attachedApp)
  }

  /// What no app holds, by its session's id, its state from the registry; what an app holds,
  /// what ended, what a window lists and what is not this Mac's to take are not.
  @Test func backgroundRowsFromTheHost() throws {
    let rows = SessionMCPSource.backgroundRows(
      [
        try held("a", session: "s-bg", name: "Nightly"),
        try held("b", session: "s-busy"),
        try held("c", session: "s-attached", attachedApp: 42),
        try held("d", session: "s-over", running: false),
        try held("e", session: "s-window"),
        try held("f", session: nil),
        try held("g", session: "s-theirs", owner: "Another Mac"),
      ],
      runner: nil,
      live: [LiveSession(pid: 1, sessionID: "s-busy", status: "busy")],
      excluding: ["s-window"]
    ).map(\.row)
    #expect(rows.map(\.id) == ["s-bg", "s-busy"])
    #expect(rows.map(\.state) == [.idle, .working])
    #expect(rows.allSatisfy { $0.place == .background && $0.folder == "/w/drakar" })
    #expect(rows.first?.title == "Nightly")
  }

  /// A listing that never came says nothing of what the host holds: the last one that came
  /// stands, so a slow host does not make its rows drop out, nor `drakar_wait` see them move.
  @Test func aListingThatNeverCameKeepsTheLastOne() async throws {
    let process = try held("a", session: "s-bg")
    let mine = try held("b", session: "s-runner", owner: ThisMac.name)
    var answers: [HostListings] = [
      HostListings(local: [process], runner: .init(id: "r1", name: "eva", held: [mine])),
      HostListings(local: nil, runner: .init(id: "r1", name: "eva", held: nil)),
    ]
    let source = source(OpenSessions())
    source.listHosts = { answers.removeFirst() }

    let first = await source.sessions(includeEnded: false, endedLimit: 0)
    let second = await source.sessions(includeEnded: false, endedLimit: 0)
    #expect(first.map(\.id) == ["s-bg", "s-runner"])
    #expect(second == first)
    #expect(second.map(\.place) == [.background, .background])
    #expect(second.map(\.runner) == [nil, "eva"])
  }

  /// The runner's rows kept from before its connection dropped can't be sent to: unreachable,
  /// until it is back. A connected runner slow to answer keeps them as they were.
  @Test func aDisconnectedRunnersKeptRowsAreUnreachable() async throws {
    let mine = try held("b", session: "s-runner", owner: ThisMac.name)
    var answers: [HostListings] = [
      HostListings(local: [], runner: .init(id: "r1", name: "eva", held: [mine])),
      HostListings(local: [], runner: .init(id: "r1", name: "eva", held: nil)),
      HostListings(
        local: [], runner: .init(id: "r1", name: "eva", held: nil, isConnected: false)),
      HostListings(local: [], runner: .init(id: "r1", name: "eva", held: [mine])),
    ]
    let source = source(OpenSessions())
    source.listHosts = { answers.removeFirst() }

    var states: [SessionState?] = []
    for _ in 0..<4 {
      states.append(await source.sessions(includeEnded: false, endedLimit: 0).first?.state)
    }
    #expect(states == [.idle, .idle, .unreachable, .idle])
  }

  /// A host that has never answered holds nothing yet; another runner set up since is not
  /// read as the one before.
  @Test func aHostThatNeverAnsweredListsNothing() async throws {
    let mine = try held("b", session: "s-runner", owner: ThisMac.name)
    var answers: [HostListings] = [
      HostListings(local: nil, runner: .init(id: "r1", name: "eva", held: [mine])),
      HostListings(local: nil, runner: .init(id: "r2", name: "ada", held: nil)),
    ]
    let source = source(OpenSessions())
    source.listHosts = { answers.removeFirst() }

    #expect(await source.sessions(includeEnded: false, endedLimit: 0).map(\.id) == ["s-runner"])
    #expect(await source.sessions(includeEnded: false, endedLimit: 0).isEmpty)
  }

  /// On the runner, only what this Mac owns, named by the runner.
  @Test func backgroundRowsOnTheRunner() throws {
    let rows = SessionMCPSource.backgroundRows(
      [
        try held("a", session: "s-mine", owner: ThisMac.name),
        try held("b", session: "s-runners"),
      ],
      runner: "eva", live: [], excluding: []
    ).map(\.row)
    #expect(rows.map(\.id) == ["s-mine"])
    #expect(rows.first?.runner == "eva")
  }
}
