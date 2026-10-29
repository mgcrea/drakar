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
        if case .lines(let lines, let time) = event {
          for line in lines { append(.out, Self.bytes(line), at: time) }
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

  private func append(_ kind: HostRecord.Kind, _ bytes: Data, at time: Date = .now) {
    log.withLock { records in
      let offset = records.last.map { $0.offset + UInt64($0.bytes.count) } ?? 0
      records.append(
        HostRecord(offset: offset, kind: kind, time: time, attached: true, bytes: bytes))
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

  /// A session's second process counts its request ids from one, as the replay's new
  /// backend does: nothing it asked comes back owed.
  @Test func aSecondProcessReplaysOwingNothing() async throws {
    let (live, first) = try await liveTurn()
    defer { live.stop() }
    live.stop()
    live.send("again")
    try await waitFor { (live.process as? RecordingTransport).map { $0 !== first } == true }
    let second = try #require(live.process as? RecordingTransport)
    try await waitFor { !live.transcript.pendingPermissions.isEmpty }
    let pending = try #require(live.transcript.pendingPermissions.first)
    live.answer(pending, .allow(updatedInput: pending.request.input))
    // The context request the turn's `result` makes, the last thing the backend asks.
    try await waitFor {
      second.records.contains {
        $0.kind == .in && String(decoding: $0.bytes, as: UTF8.self).contains("get_context_usage")
      }
    }
    let replayed = await AgentSession(replaying: second.records, meta: meta)
    let transport = try #require(replayed.process as? ReplayTransport)
    #expect(transport.owed.isEmpty)
  }

  /// A stop goes straight to the process, with no note for a replay to send again, and
  /// waits no longer once the process is gone.
  @Test func aTaskControlIsSentUnnoted() async throws {
    let (live, recorder) = try await liveTurn()
    defer { live.stop() }
    #expect(live.tasks.isAvailable)
    live.tasks.stop(taskID: "t")
    #expect(live.tasks.stopping == ["t"])
    let records = recorder.records
    #expect(
      records.contains {
        $0.kind == .in && String(decoding: $0.bytes, as: UTF8.self).contains("stop_task")
      })
    #expect(
      !records.contains {
        $0.kind == .note && String(decoding: $0.bytes, as: UTF8.self).contains("stopTask")
      })
    let replayed = await AgentSession(replaying: records, meta: meta)
    #expect(try #require(replayed.process as? ReplayTransport).owed.isEmpty)
    live.stop()
    #expect(live.tasks.stopping.isEmpty)
    #expect(!live.tasks.isAvailable)
  }

  /// A rate limit the log kept is a reading from when its line came, not from the replay:
  /// one from hours ago never passes for the account's latest.
  @Test func aReplayedRateLimitIsReadWhenItsLineCame() async throws {
    let account = ClaudeAccount(
      directory: folder.appending(path: "account", directoryHint: .isDirectory),
      isDefault: false)
    var start = meta.start
    start.account = account
    let meta = SessionMeta(
      start: start, windowFolder: folder.path(percentEncoded: false), history: .none)
    let then = Date.now.addingTimeInterval(-6 * 3600)
    let event =
      #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":4070908800}}}}"#
    let records = [Self.initLine, event].enumerated().map { index, line in
      HostRecord(
        offset: UInt64(index * 1000), kind: .out, time: then, attached: true,
        bytes: Data(line.utf8))
    }
    _ = await AgentSession(replaying: records, meta: meta)
    #expect(AccountStore.shared.usage(for: account)?.readAt == then)
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
    replayed.onPermissionRequested = { calls.append("permission requested") }
    replayed.onPermissionsChanged = { calls.append("permissions changed") }
    replayed.onPromptSent = { calls.append("prompt sent") }
    await replayed.replay(log.records)
    #expect(calls.isEmpty)
    #expect(replayed.transcript.entries.filter { $0.headline != nil }.count == 3)
    #expect(replayed.transcript.turnEnd == .completed)
  }

  /// The uuid each prompt was sent with, which a fork or a rewind from it names, comes back
  /// from the note's command: the first, typed before the process, and a later one.
  @Test func replayedPromptsKeepTheUUIDTheyWereSentWith() async throws {
    var log = Log()
    log.note(
      .started(
        first: .prompt(text: "one", context: [], uuid: "u-1", attachments: []),
        effect: .prompt(text: "one", context: nil, attachments: [])))
    log.out(Self.initLine)
    log.out(Self.done)
    log.out(Self.result)
    log.note(
      .sent(
        .prompt(text: "two", context: [], uuid: "u-2", attachments: []),
        effect: .prompt(text: "two", context: nil, attachments: [])))
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    #expect(replayed.transcript.entries.compactMap(\.messageID) == ["u-1", "u-2"])
  }

  /// A request Drakar cannot serve, which it refuses on its own.
  private static let unserved =
    #"{"type":"control_request","request_id":"h-1","request":{"subtype":"hook_callback","callback_id":"c"}}"#

  private static func refusal() throws -> Data {
    try ClientMessage.refuse(
      requestID: "h-1", error: "Unsupported control request subtype: hook_callback"
    ).line()
  }

  /// A reply is owed for each request the CLI wrote, and a logged write answers one: two
  /// copies of a request with one refusal logged after them still owe the other.
  @Test func owedRepliesAreSentOnce() async throws {
    var log = Log()
    log.out(Self.initLine, attached: false)
    log.out(Self.unserved, attached: false)
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    let transport = try #require(replayed.process as? ReplayTransport)
    #expect(transport.owed == [try Self.refusal()])
    let reply = try JSONValue.parse(try #require(transport.owed.first))
    #expect(reply["response"]?["request_id"]?.stringValue == "h-1")

    log.out(Self.unserved, attached: false)
    log.in(try Self.refusal())
    let again = await AgentSession(replaying: log.records, meta: meta)
    #expect((again.process as? ReplayTransport)?.owed == [try Self.refusal()])
  }

  /// Sent after an earlier replay, and logged: the next replay does not refuse it again.
  @Test func anOwedReplyAlreadySentIsNotOwed() async throws {
    var log = Log()
    log.out(Self.unserved, attached: false)
    log.in(try Self.refusal())
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    #expect((replayed.process as? ReplayTransport)?.owed.isEmpty == true)
  }

  private static let elicitation =
    #"{"type":"control_request","request_id":"el-1","request":{"subtype":"elicitation","mcp_server_name":"srv","message":"Pick one"}}"#

  /// Asked while nobody was attached: the person's, so it waits for them again and nothing
  /// is owed for it.
  @Test func anUnansweredElicitationIsPending() async throws {
    var log = Log()
    log.out(Self.initLine, attached: false)
    log.out(Self.elicitation, attached: false)
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    #expect(replayed.transcript.pendingElicitations.map(\.requestID) == ["el-1"])
    #expect((replayed.process as? ReplayTransport)?.owed.isEmpty == true)
  }

  /// Answered before the app quit: not asked again, and noted as it was live.
  @Test func anAnsweredElicitationIsNotPendingAgain() async throws {
    var log = Log()
    log.out(Self.initLine)
    log.out(Self.elicitation)
    log.note(
      .sent(
        .answerElicitation(requestID: "el-1", NotedAnswer(.decline)),
        effect: .answeredElicitation(requestID: "el-1", action: .decline)))
    log.in(try ClientMessage.answerElicitation(requestID: "el-1", .decline).line())
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    #expect(replayed.transcript.pendingElicitations.isEmpty)
    #expect((replayed.process as? ReplayTransport)?.owed.isEmpty == true)
    #expect(
      replayed.transcript.entries.contains {
        $0.kind == .notice("Declined srv's question: Pick one")
      })
  }

  /// A form answered before the app quit: the log has its keys alone, which is enough to
  /// have it answered and owe nothing for it.
  @Test func anAnsweredFormIsNotPendingAgain() async throws {
    let answer = ElicitationAnswer.accept(["team": .string("core")])
    let message = ClientMessage.answerElicitation(requestID: "el-1", answer)
    var log = Log()
    log.out(Self.initLine)
    log.out(Self.elicitation)
    log.note(
      .sent(
        .answerElicitation(requestID: "el-1", NotedAnswer(answer)),
        effect: .answeredElicitation(requestID: "el-1", action: ElicitationAction(answer))))
    log.in(try #require(try message.redactedLine()))
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    #expect(replayed.transcript.pendingElicitations.isEmpty)
    #expect((replayed.process as? ReplayTransport)?.owed.isEmpty == true)
    #expect(
      replayed.transcript.entries.contains {
        $0.kind == .notice("Answered srv's question: Pick one")
      })
  }

  /// The note a replay takes the answer from says what was done, never what was typed.
  @Test func anAnswersNoteKeepsNothingTyped() throws {
    let answer = ElicitationAnswer.accept(["token": .string("s3cret-value")])
    let note = SessionNote.sent(
      .answerElicitation(requestID: "el-1", NotedAnswer(answer)),
      effect: .answeredElicitation(requestID: "el-1", action: ElicitationAction(answer)))
    let bytes = try JSONEncoder().encode(note)
    let leaks = String(decoding: bytes, as: UTF8.self).contains("s3cret")
    #expect(!leaks)
    #expect(
      try JSONDecoder().decode(SessionNote.self, from: bytes)
        == .sent(
          .answerElicitation(requestID: "el-1", NotedAnswer(.accept(nil))),
          effect: .answeredElicitation(requestID: "el-1", action: .accept)))
  }

  /// A session host keeps each line's `\n`, which a pipe's reader takes off: a replayed
  /// line is the line the live session read, a line that is not JSON included.
  @Test func aLoggedLineIsReadWithoutItsNewline() async {
    let records = [
      HostRecord(offset: 0, kind: .out, time: .now, attached: true, bytes: Data("text\n".utf8)),
      HostRecord(offset: 10, kind: .out, time: .now, attached: true, bytes: Data("{}\n".utf8)),
      HostRecord(offset: 20, kind: .in, time: .now, attached: true, bytes: Data("{}\n".utf8)),
    ]
    let lines = await AgentSession.lines(of: records, from: 0, count: 3).value
    #expect(lines == [.invalid("text"), .json(.object([:])), nil])
  }

  /// Logged while an app was attached, which quit before it handled the line: nothing
  /// answered it, so it is owed all the same.
  @Test func aReplyNeverWrittenIsOwedThoughAttached() async throws {
    var log = Log()
    log.out(Self.unserved, attached: true)
    let replayed = await AgentSession(replaying: log.records, meta: meta)
    #expect((replayed.process as? ReplayTransport)?.owed == [try Self.refusal()])
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

  // MARK: The real CLIs

  /// Opt-in, as they spend a few cheap turns of the signed-in accounts:
  /// `TEST_RUNNER_DRAKAR_LIVE_CLI=1 xcodebuild test …`.
  private nonisolated static let runsLiveCLIs =
    ProcessInfo.processInfo.environment["DRAKAR_LIVE_CLI"] == "1"

  /// Thinking, a tool that asks first, partial messages: what the stand-ins never write.
  @Test(.enabled(if: runsLiveCLIs), .timeLimit(.minutes(3)))
  func liveClaudeReplayMatches() async throws {
    let scratch = try Self.liveScratch(git: false)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let suite = "drakar-live-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    try await ClaudeChoice.$testSuite.withValue(suite) {
      let live = AgentSession(folder: scratch)
      defer { live.stop() }
      // As `-drakar.debugSettingSources project` runs it: the person's own rules and hooks
      // would let the tool through unasked.
      (live.backend as? ClaudeBackend)?.command = ClaudeCommand(
        extraArguments: ["--setting-sources", "project"])
      live.setModel("claude-haiku-4-5-20251001")
      try await expectLiveReplayMatches(
        live, history: .none,
        prompts: [
          "Think briefly, then create a file named hello.txt containing hi. Then say done.",
          "Now say bye.",
        ])
    }
  }

  /// Item deltas, a command approval, the thread's own ids and counters.
  @Test(.enabled(if: runsLiveCLIs), .timeLimit(.minutes(3)))
  func liveCodexReplayMatches() async throws {
    let scratch = try Self.liveScratch(git: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let suite = "drakar-live-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    try await ClaudeChoice.$testSuite.withValue(suite) {
      let live = AgentSession(folder: scratch, agent: .codex)
      defer { live.stop() }
      // The cheapest `model/list` offers (0.163.0).
      live.setModel("gpt-6-luna")
      live.setEffort("low")
      try await expectLiveReplayMatches(
        live, history: .codexTurns(0),
        prompts: ["Run the shell command `touch hello.txt`, then say done.", "Now say bye."])
      #expect(live.codexTurnsBeforeProcess == 0)
    }
  }

  /// `/tmp/dh-live-<6 chars>`, a git repository for Codex.
  private static func liveScratch(git: Bool) throws -> URL {
    let name = "dh-live-" + UUID().uuidString.prefix(6).lowercased()
    let scratch = URL(filePath: "/tmp/\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    if git {
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/git")
      process.arguments = ["init", "-q", scratch.path(percentEncoded: false)]
      try process.run()
      process.waitUntilExit()
    }
    return scratch
  }

  /// `live` sent each prompt in turn, every permission allowed, then rebuilt from its log:
  /// the same entries, and nothing written or owed to the CLI. What else differs is printed
  /// (`LIVE-CHECK`), for the stop point's report.
  private func expectLiveReplayMatches(
    _ live: AgentSession, history: HistoryMark, prompts: [String]
  ) async throws {
    live.accounts = { [] }
    live.catalog = ModelCatalog()
    live.accountStore = AccountStore()
    live.makeTransport = { RecordingTransport($0) }
    live.setMode(.ask)
    let began = ContinuousClock.now
    for (index, prompt) in prompts.enumerated() {
      live.send(prompt)
      try await endTurn(live, prompts: index + 1)
    }
    let recorder = try #require(live.process as? RecordingTransport)
    try await settle(recorder)
    let records = recorder.records
    let writes = records.count(where: { $0.kind == .in })
    print("LIVE-CHECK \(live.agent) live took \(ContinuousClock.now - began)")

    let replayed = await AgentSession(
      replaying: [],
      meta: SessionMeta(
        start: AgentStart(
          folder: live.folder, environment: [:], executableOverride: live.executable,
          model: live.modelPick, mode: live.modePick, effort: live.effortPick,
          allowsBypass: live.launchedWithBypass),
        windowFolder: live.folder.path(percentEncoded: false), modePick: live.modePick,
        modelPick: live.modelPick, effortPick: live.effortPick, history: history))
    replayed.catalog = ModelCatalog()
    replayed.accountStore = AccountStore()
    await replayed.replay(records)

    let transport = try #require(replayed.process as? ReplayTransport)
    #expect(transport.mode == .muted)
    #expect(
      transport.owed.isEmpty,
      Comment(rawValue: transport.owed.map { String(decoding: $0, as: UTF8.self) }.joined()))
    try await Task.sleep(for: .milliseconds(500))
    #expect(recorder.records.count(where: { $0.kind == .in }) == writes)
    let entries = Self.differences(live.transcript.entries, replayed.transcript.entries)
    #expect(
      live.transcript.entries == replayed.transcript.entries,
      Comment(rawValue: entries.joined(separator: "\n")))

    Self.report(live, records: records)
    for line in entries { print("LIVE-CHECK \(live.agent) entries\(line)") }
    let transcript = Self.differences(live.transcript, replayed.transcript)
    for line in transcript where !line.hasPrefix(".entries") {
      print("LIVE-CHECK \(live.agent) transcript\(line)")
    }
    let (shownLive, shownReplayed) = (Self.shown(live), Self.shown(replayed))
    for (key, value) in shownLive.sorted(by: { $0.key < $1.key }) where shownReplayed[key] != value
    {
      print("LIVE-CHECK \(live.agent) session.\(key): \(value) ≠ \(shownReplayed[key] ?? "-")")
    }
  }

  /// Until the `prompts`th turn ends, allowing what it asks; fails fast on a dead process.
  private func endTurn(_ session: AgentSession, prompts: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(75)
    while session.transcript.turnEnd == nil
      || session.transcript.entries.compactMap(\.headline).count < prompts
    {
      if case .failed(let reason) = session.phase {
        Issue.record("\(session.agent) failed: \(reason) \(session.diagnostics)")
        throw CancellationError()
      }
      if case .exited(let status) = session.phase {
        Issue.record("\(session.agent) exited \(status): \(session.diagnostics)")
        throw CancellationError()
      }
      try #require(ContinuousClock.now < deadline, "turn \(prompts) never ended")
      if let pending = session.transcript.pendingPermissions.first {
        print("LIVE-CHECK \(session.agent) allowing \(pending.request.toolName)")
        session.answer(pending, .allow(updatedInput: pending.request.input))
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    #expect(session.transcript.turnEnd == .completed)
  }

  /// Until the CLI has written nothing for two seconds: the replies a turn's end asks for.
  private func settle(_ recorder: RecordingTransport) async throws {
    var count = -1
    for _ in 0..<15 where recorder.records.count != count {
      count = recorder.records.count
      try await Task.sleep(for: .seconds(2))
    }
  }

  /// What the pills, the gauge and the footer read off a session.
  private static func shown(_ session: AgentSession) -> [String: String] {
    [
      "sessionID": "\(session.sessionID as Any)",
      "phase": "\(session.phase)",
      "title": "\(session.title as Any)",
      "permissionMode": "\(session.permissionMode as Any)",
      "shownMode": session.shownMode,
      "shownEffort": "\(session.shownEffort as Any)",
      "appliedModel": "\(session.appliedModel as Any)",
      "runningModel": "\(session.runningModel as Any)",
      "reportedContext": "\(session.reportedContext as Any)",
      "pillNote": "\(session.pillNote as Any)",
      "canSend": "\(session.canSend)",
    ]
  }

  /// What the log held and the transcript showed, for the report.
  private static func report(_ live: AgentSession, records: [HostRecord]) {
    let kinds = Dictionary(grouping: records, by: \.kind).mapValues(\.count)
    let types = Dictionary(
      grouping: records.filter { $0.kind == .out }.compactMap { record in
        (try? JSONValue.parse(record.bytes)).map {
          $0["type"]?.stringValue ?? $0["method"]?.stringValue ?? "reply"
        }
      }, by: { $0 }
    ).mapValues(\.count)
    let shapes = live.transcript.entries.map { entry in
      switch entry.kind {
      case .prompt: "prompt"
      case .text: "text"
      case .thinking: "thinking(\(entry.thinkingDuration.map { "\($0)s" } ?? "-"))"
      case .tool(let call): "tool(\(call.name))"
      case .notice: "notice"
      case .failure(let reason): "failure(\(reason))"
      }
    }
    print("LIVE-CHECK \(live.agent) records \(kinds) out \(types.sorted { $0.key < $1.key })")
    print("LIVE-CHECK \(live.agent) entries \(shapes)")
    print(
      "LIVE-CHECK \(live.agent) usage \(live.transcript.lastTurn as Any) "
        + "\(live.transcript.contextUsage as Any)")
  }

  /// Where two values differ, field by field (`[3].thinkingDuration: 1.2 ≠ 1.3`); a date to
  /// the nanosecond, which its description rounds to the second.
  private static func differences(_ live: Any, _ replayed: Any, at path: String = "")
    -> [String]
  {
    if let left = live as? Date, let right = replayed as? Date {
      guard left != right else { return [] }
      return [
        "\(path): \(left.timeIntervalSinceReferenceDate) ≠ "
          + "\(right.timeIntervalSinceReferenceDate)"
      ]
    }
    let left = Mirror(reflecting: live)
    let right = Mirror(reflecting: replayed)
    let leftChildren = Array(left.children)
    let rightChildren = Array(right.children)
    // A dictionary's order is its own: its elements are compared as a set.
    func describe(_ mirror: Mirror, _ value: Any) -> String {
      guard mirror.displayStyle == .dictionary else { return String(reflecting: value) }
      return mirror.children.map { String(reflecting: $0.value) }.sorted().joined(separator: ", ")
    }
    func leaf() -> [String] {
      let (a, b) = (describe(left, live), describe(right, replayed))
      return a == b ? [] : ["\(path): \(a.prefix(400)) ≠ \(b.prefix(400))"]
    }
    if left.displayStyle == .collection {
      var found = zip(leftChildren, rightChildren).enumerated().flatMap { index, pair in
        differences(pair.0.value, pair.1.value, at: "\(path)[\(index)]")
      }
      if leftChildren.count != rightChildren.count {
        found.append("\(path).count: \(leftChildren.count) ≠ \(rightChildren.count)")
      }
      return found
    }
    guard left.displayStyle != .dictionary, !leftChildren.isEmpty,
      leftChildren.map(\.label) == rightChildren.map(\.label)
    else { return leaf() }
    return zip(leftChildren, rightChildren).flatMap { pair in
      differences(pair.0.value, pair.1.value, at: "\(path).\(pair.0.label ?? "_")")
    }
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
