import DrakarKit
import Foundation
import Synchronization
import Testing

@testable import Drakar

/// An `AgentProcess` logged as a session host logs one: what it wrote, what it was sent and
/// the session's notes, in the order they came, each while an app was attached.
private nonisolated final class RecordingTransport: ProcessTransport, NoteSink {
  private let process: AgentProcess
  private let log = Mutex<[HostRecord]>([])

  init(_ configuration: AgentProcess.Configuration) {
    process = AgentProcess(configuration)
  }

  var records: [HostRecord] { log.withLock { $0 } }
  var isRunning: Bool { process.isRunning }

  func start() throws -> AsyncStream<AgentProcess.Event> {
    let events = try process.start()
    let (stream, continuation) = AsyncStream.makeStream(of: AgentProcess.Event.self)
    Task {
      for await event in events {
        if case .lines(let lines) = event {
          for line in lines { append(.out, Self.bytes(line)) }
        }
        continuation.yield(event)
      }
      continuation.finish()
    }
    return stream
  }

  func send(line: Data) throws {
    try process.send(line: line)
    append(.in, line)
  }

  func closeInput() { process.closeInput() }
  func terminate() { process.terminate() }
  func note(_ bytes: Data) { append(.note, bytes) }

  private func append(_ kind: HostRecord.Kind, _ bytes: Data) {
    log.withLock { records in
      let offset = records.last.map { $0.offset + UInt64($0.bytes.count) } ?? 0
      records.append(
        HostRecord(offset: offset, kind: kind, time: .now, attached: true, bytes: bytes))
    }
  }

  /// The line as the CLI wrote it, near enough: `AgentProcess` hands it on parsed.
  private static func bytes(_ line: AgentProcess.Line) -> Data {
    switch line {
    case .json(let json): (try? json.line().dropLast()).map { Data($0) } ?? Data()
    case .invalid(let text): Data(text.utf8)
    }
  }
}

/// A session rebuilt from what its process wrote and its own notes, as a relaunched app
/// rebuilds one a session host kept: the same transcript, and nothing written to the CLI.
@MainActor
@Suite("Replaying a session")
struct SessionReplayTests {
  private let folder: URL
  private let fake: URL
  private var received: URL { fake.appendingPathExtension("stdin") }

  private static let initLine =
    #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s-replay","model":"m","permissionMode":"default"}"#
  private static let looking =
    #"{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-replay"}"#
  private static let asking =
    #"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}}"#
  private static let toolResult =
    #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"a.txt","is_error":false}]},"parent_tool_use_id":null,"session_id":"s-replay"}"#
  private static let done =
    #"{"type":"assistant","message":{"id":"msg_2","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"},"parent_tool_use_id":null,"session_id":"s-replay"}"#
  private static let result =
    #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","stop_reason":"end_turn","session_id":"s-replay"}"#

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fake = folder.appending(path: "claude")
    // init on the first line; after the prompt a tool call and its permission request; the
    // rest of the turn once `req-1` is answered. Every line it is sent goes to `$0.stdin`.
    let script = """
      #!/bin/sh
      log() { printf '%s\\n' "$1" >> "$0.stdin"; }
      read -r line; log "$line"
      echo '\(Self.initLine)'
      while read -r line; do log "$line"; case "$line" in *'"type":"user"'*) break;; esac; done
      echo '\(Self.looking)'
      echo '\(Self.asking)'
      while read -r line; do log "$line"; case "$line" in *'"req-1"'*) break;; esac; done
      echo '\(Self.toolResult)'
      echo '\(Self.done)'
      echo '\(Self.result)'
      exec cat >> "$0.stdin"

      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  private var meta: SessionMeta {
    SessionMeta(
      start: AgentStart(
        folder: folder, environment: [:], executableOverride: fake, allowsBypass: false),
      windowFolder: folder.path(percentEncoded: false), history: .none)
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<50 where !condition() {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// A live session sent "hi", whose permission was allowed and whose turn ended.
  private func liveTurn() async throws -> (AgentSession, RecordingTransport) {
    let session = AgentSession(folder: folder)
    session.executableOverride = fake
    session.accounts = { [] }
    session.makeTransport = { RecordingTransport($0) }
    session.send("hi")
    try await waitFor { !session.transcript.pendingPermissions.isEmpty }
    let pending = try #require(session.transcript.pendingPermissions.first)
    session.answer(pending, .allow(updatedInput: pending.request.input))
    try await waitFor { session.transcript.turnEnd != nil }
    #expect(session.transcript.turnEnd == .completed)
    return (session, try #require(session.process as? RecordingTransport))
  }

  private func receivedLines() -> Int {
    ((try? String(contentsOf: received, encoding: .utf8)) ?? "").split(separator: "\n").count
  }

  private static func isAnswer(_ record: HostRecord) -> Bool {
    guard record.kind == .note,
      case .sent(_, .answered)? = try? JSONDecoder().decode(SessionNote.self, from: record.bytes)
    else { return false }
    return true
  }

  @Test func replayRebuildsTheTranscript() async throws {
    let (live, recorder) = try await liveTurn()
    defer { live.stop() }
    // A prompt to a running process, which the stand-in never answers.
    live.send("again")
    let replayed = await AgentSession(replaying: recorder.records, meta: meta)
    #expect(live.transcript.entries.compactMap(\.headline) == ["hi", "again"])
    #expect(replayed.transcript.entries == live.transcript.entries)
    #expect(replayed.transcript.isRunning)
    #expect(replayed.sessionID == "s-replay")
  }

  @Test func replayWritesNothing() async throws {
    let (live, recorder) = try await liveTurn()
    defer { live.stop() }
    // The context request a `result` makes, written live.
    try await waitFor { receivedLines() >= 5 }
    let before = receivedLines()
    let replayed = await AgentSession(replaying: recorder.records, meta: meta)
    try await Task.sleep(for: .milliseconds(300))
    let transport = try #require(replayed.process as? ReplayTransport)
    #expect(transport.mode == .muted)
    #expect(transport.owed.isEmpty)
    #expect(receivedLines() == before)
  }

  @Test func anAnsweredPermissionIsNotPendingAgain() async throws {
    let (live, recorder) = try await liveTurn()
    defer { live.stop() }
    let records = recorder.records
    let answer = try #require(records.firstIndex(where: Self.isAnswer))
    let replayed = await AgentSession(replaying: Array(records[...answer]), meta: meta)
    #expect(replayed.transcript.isRunning)
    #expect(replayed.transcript.pendingPermissions.isEmpty)
  }

  @Test func anUnansweredPermissionIsPending() async throws {
    let (live, recorder) = try await liveTurn()
    defer { live.stop() }
    let records = recorder.records
    let answer = try #require(records.firstIndex(where: Self.isAnswer))
    let replayed = await AgentSession(replaying: Array(records[..<answer]), meta: meta)
    #expect(replayed.transcript.pendingPermissions.map(\.requestID) == ["req-1"])
  }

  @Test func replayFiresNoCallbacks() async throws {
    var log = Log()
    log.note(
      .started(
        first: .prompt(text: "one", context: [], uuid: "u-1", attachments: []),
        effect: .prompt(text: "one", context: nil, attachments: [])))
    log.out(Self.initLine)
    for turn in 1...3 {
      if turn > 1 {
        log.note(
          .sent(
            .prompt(text: "turn \(turn)", context: [], uuid: "u-\(turn)", attachments: []),
            effect: .prompt(text: "turn \(turn)", context: nil, attachments: [])))
      }
      log.out(
        #"{"type":"assistant","message":{"id":"m-\#(turn)","type":"message","role":"assistant","model":"m","content":[{"type":"tool_use","id":"t-\#(turn)","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":null,"session_id":"s-replay"}"#
      )
      if turn < 3 {
        log.out(
          #"{"type":"control_request","request_id":"p-\#(turn)","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"t-\#(turn)"}}"#
        )
      }
      if turn == 1 {
        log.note(
          .sent(
            .answer(requestID: "p-1", decision: .allow(updatedInput: .object([:]))),
            effect: .answered(requestID: "p-1")))
      }
      log.out(Self.result)
    }

    let replayed = await AgentSession(replaying: [], meta: meta)
    var calls: [String] = []
    replayed.onTurnEnded = { calls.append("turn ended") }
    replayed.onPermissionRequested = { _ in calls.append("permission requested") }
    replayed.onPermissionsChanged = { calls.append("permissions changed") }
    replayed.onPromptSent = { calls.append("prompt sent") }
    replayed.replay(log.records)
    #expect(calls.isEmpty)
    #expect(replayed.transcript.entries.filter { $0.headline != nil }.count == 3)
    #expect(replayed.transcript.turnEnd == .completed)
  }

  private static let elicitation =
    #"{"type":"control_request","request_id":"el-1","request":{"subtype":"elicitation","mcp_server_name":"srv","message":"Pick one"}}"#

  private static func decline() throws -> Data {
    try ClientMessage.declineElicitation(requestID: "el-1").line()
  }

  /// A reply is owed for each request the CLI wrote, and a logged write answers one: two
  /// copies of a request with one decline logged after them still owe the other.
  @Test func owedRepliesAreSentOnce() async throws {
    var log = Log()
    log.out(Self.initLine, attached: false)
    log.out(Self.elicitation, attached: false)
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    let transport = try #require(replayed.process as? ReplayTransport)
    #expect(transport.owed == [try Self.decline()])
    let reply = try JSONValue.parse(try #require(transport.owed.first))
    #expect(reply["response"]?["request_id"]?.stringValue == "el-1")

    log.out(Self.elicitation, attached: false)
    log.in(try Self.decline())
    let again = await AgentSession(replaying: log.records, meta: meta)
    #expect((again.process as? ReplayTransport)?.owed == [try Self.decline()])
  }

  /// Sent after an earlier replay, and logged: the next replay does not decline it again.
  @Test func anOwedReplyAlreadySentIsNotOwed() async throws {
    var log = Log()
    log.out(Self.elicitation, attached: false)
    log.in(try Self.decline())
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    #expect((replayed.process as? ReplayTransport)?.owed.isEmpty == true)
  }

  /// Logged while an app was attached, which quit before it handled the line: nothing
  /// answered it, so it is owed all the same.
  @Test func aReplyNeverWrittenIsOwedThoughAttached() async throws {
    var log = Log()
    log.out(Self.elicitation, attached: true)
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    #expect((replayed.process as? ReplayTransport)?.owed == [try Self.decline()])
  }

  // MARK: Codex

  /// A stand-in `codex app-server`. It answers `initialize`, `thread/start` and `turn/start`,
  /// streams turn `turn-1` up to part of its answer, and ends it, interrupted, on
  /// `turn/interrupt`. `thread/items/list` reads thread `thr-1` back as two turns: one before
  /// the process, and the one it ran.
  private func codexStandIn() throws -> URL {
    let script = folder.appending(path: "codex")
    func reply(_ result: String) -> String { #"echo '{"id":'"$id"',"result":\#(result)}'"# }
    func notify(_ method: String, _ params: String) -> String {
      #"echo '{"method":"\#(method)","params":\#(params)}'"#
    }
    let turn = #""threadId":"thr-1","turnId":"turn-1""#
    let message = #"{"type":"agentMessage","id":"msg-1","text":"Looking"}"#
    let items =
      #"{"data":[{"turnId":"turn-0","item":{"type":"userMessage","id":"u0","content":[{"type":"text","text":"earlier"}]}},{"turnId":"turn-1","item":{"type":"userMessage","id":"u1","content":[{"type":"text","text":"hi"}]}}],"nextCursor":null}"#
    try Data(
      """
      #!/bin/sh
      while read -r line; do
        id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9.]*\\).*/\\1/p')
        case "$line" in
          *'"initialize"'*) \(reply("{}")) ;;
          *'"thread/start"'*) \(reply(#"{"thread":{"id":"thr-1","cwd":"/tmp","cliVersion":"0.160.1"},"model":"m"}"#)) ;;
          *'"turn/start"'*)
            \(reply(#"{"turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}"#))
            \(notify("turn/started", #"{"threadId":"thr-1","turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}"#))
            \(notify("item/started", #"{"item":{"type":"userMessage","id":"u1","clientId":null,"content":[{"type":"text","text":"hi"}]},\#(turn)}"#))
            \(notify("item/started", #"{"item":{"type":"agentMessage","id":"msg-1","text":""},\#(turn)}"#))
            \(notify("item/agentMessage/delta", #"{\#(turn),"itemId":"msg-1","delta":"Looking"}"#)) ;;
          *'"turn/interrupt"'*)
            \(reply("{}"))
            \(notify("item/completed", #"{"item":\#(message),\#(turn)}"#))
            \(notify("turn/completed", #"{"threadId":"thr-1","turn":{"id":"turn-1","items":[],"status":"interrupted","error":null}}"#)) ;;
          *'"thread/read"'*) \(reply(#"{"thread":{"id":"thr-1"}}"#)) ;;
          *'"thread/items/list"'*) \(reply(items)) ;;
        esac
      done

      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// `mode` as the live process was launched with it: Codex writes it with each turn.
  private func codexMeta(
    _ codex: URL, mode: PermissionMode = .ask, resuming: ResumeTarget? = nil, turns: Int = 0
  ) -> SessionMeta {
    SessionMeta(
      start: AgentStart(
        folder: folder, resuming: resuming, environment: [:], executableOverride: codex,
        mode: mode, allowsBypass: false),
      windowFolder: folder.path(percentEncoded: false), modePick: mode, savedTarget: resuming,
      history: .codexTurns(turns))
  }

  private var codexThread: ResumeTarget {
    ResumeTarget(
      sessionID: "thr-1", cwd: folder.path(percentEncoded: false), file: "",
      accountDirectory: "/h", accountIsDefault: true, agent: .codex)
  }

  /// A new thread, its turn interrupted: replayed whole, the same conversation; cut mid-turn,
  /// a session whose own interrupt is the one the live session wrote, ids and all.
  @Test func codexReplayRebuildsTheThread() async throws {
    let codex = try codexStandIn()
    let live = AgentSession(folder: folder, agent: .codex)
    defer { live.stop() }
    live.executableOverride = codex
    live.accounts = { [] }
    live.makeTransport = { RecordingTransport($0) }
    live.setMode(.ask)
    live.send("hi")
    try await waitFor { live.transcript.entries.contains { $0.kind == .text("Looking") } }
    let recorder = try #require(live.process as? RecordingTransport)
    let midTurn = recorder.records
    live.interrupt()
    try await waitFor { live.transcript.turnEnd != nil }
    #expect(live.transcript.turnEnd == .interrupted)
    #expect(live.codexTurnsBeforeProcess == 0)

    let meta = codexMeta(codex)
    let replayed = await AgentSession(replaying: recorder.records, meta: meta)
    #expect(replayed.agent == .codex)
    #expect(replayed.transcript.entries == live.transcript.entries)
    #expect(replayed.sessionID == "thr-1")
    #expect((replayed.process as? ReplayTransport)?.owed.isEmpty == true)

    let cut = await AgentSession(replaying: midTurn, meta: meta)
    #expect(cut.transcript.isRunning)
    let transport = try #require(cut.process as? ReplayTransport)
    #expect(transport.owed.isEmpty)
    transport.mode = .owed
    cut.interrupt()
    let written = try #require(
      recorder.records.last {
        $0.kind == .in && String(decoding: $0.bytes, as: UTF8.self).contains("turn/interrupt")
      })
    #expect(transport.owed == [written.bytes])
    let interrupt = try JSONValue.parse(try #require(transport.owed.first))
    #expect(interrupt["method"]?.stringValue == "turn/interrupt")
    #expect(interrupt["params"]?["turnId"]?.stringValue == "turn-1")
  }

  /// A resumed thread's history holds the turns its process ran too: the replay shows only
  /// those before it, the rest being in the log.
  @Test func aResumedThreadShowsOnlyTheTurnsBeforeItsProcess() async throws {
    let codex = try codexStandIn()
    let replayed = await AgentSession(
      replaying: [], meta: codexMeta(codex, resuming: codexThread, turns: 1))
    #expect(replayed.transcript.entries.contains { $0.kind == .prompt("earlier") })
    #expect(!replayed.transcript.entries.contains { $0.kind == .prompt("hi") })
    #expect(replayed.codexTurnsBeforeProcess == 1)
  }

  /// What a resumed thread held when its process started, for the process's meta.
  @Test func aCodexProcessCountsTheTurnsBeforeIt() async throws {
    let codex = try codexStandIn()
    let session = AgentSession(folder: folder, resuming: codexThread)
    defer { session.stop() }
    session.executableOverride = codex
    session.accounts = { [] }
    session.send("again")
    try await waitFor { session.isProcessRunning }
    #expect(session.codexTurnsBeforeProcess == 2)
  }
}

/// A host's log written by hand.
@MainActor
private struct Log {
  private(set) var records: [HostRecord] = []

  mutating func out(_ line: String, attached: Bool = true) {
    append(.out, Data(line.utf8), attached: attached)
  }

  mutating func `in`(_ bytes: Data) {
    append(.in, bytes, attached: true)
  }

  mutating func note(_ note: SessionNote) {
    append(.note, (try? JSONEncoder().encode(note)) ?? Data(), attached: true)
  }

  private mutating func append(_ kind: HostRecord.Kind, _ bytes: Data, attached: Bool) {
    let offset = records.last.map { $0.offset + UInt64($0.bytes.count) } ?? 0
    records.append(
      HostRecord(offset: offset, kind: kind, time: .now, attached: attached, bytes: bytes))
  }
}
