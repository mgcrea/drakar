import DrakarKit
import Foundation
import Testing

@Suite("A Codex session as a state machine")
struct CodexSessionTests {
  private func json(_ text: String) -> JSONValue {
    (try? JSONValue.parse(Data(text.utf8))) ?? .null
  }
  private func methods(_ step: CodexSession.Step) -> [String] {
    step.writes.compactMap { $0["method"]?.stringValue }
  }
  private func write(_ method: String, in step: CodexSession.Step) throws -> JSONValue {
    try #require(step.writes.first { $0["method"]?.stringValue == method })
  }
  /// Answers our request `write` with `result`.
  private func answer(_ session: inout CodexSession, _ write: JSONValue, _ result: String)
    -> CodexSession.Step
  {
    let id = write["id"]?.intValue ?? -1
    return session.receive(json(#"{"id":\#(id),"result":\#(result)}"#), at: nil)
  }
  private func fail(_ session: inout CodexSession, _ write: JSONValue, _ message: String)
    -> CodexSession.Step
  {
    let id = write["id"]?.intValue ?? -1
    return session.receive(
      json(#"{"id":\#(id),"error":{"code":-32600,"message":"\#(message)"}}"#), at: nil)
  }
  private let thread =
    #"{"thread":{"id":"t-1","cwd":"/p","model":"gpt-6-astra","cliVersion":"0.160.1","path":"/home/.codex/sessions/r.jsonl"},"model":"gpt-6-astra"}"#
  private func input(_ text: String) -> JSONValue { .array([CodexInput.text(text)]) }

  /// A session past `initialize`.
  private func initialized(resuming: String? = nil, mode: PermissionMode = .ask)
    -> (CodexSession, CodexSession.Step)
  {
    var session = CodexSession(
      cwd: "/p", resuming: resuming, mode: mode, model: nil, effort: nil, version: "1.0")
    let start = session.start()
    let step = answer(&session, start.writes[0], #"{"codexHome":"/home/.codex"}"#)
    return (session, step)
  }

  /// A session whose thread runs, with a turn `turn-1` running from prompt `p-1`.
  private func running() throws -> CodexSession {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(&session, try write("thread/start", in: opening), thread)
    _ = answer(&session, try write("turn/start", in: started), #"{"turn":{"id":"turn-1"}}"#)
    return session
  }

  @Test func startsWithInitializeAloneThenTheRest() throws {
    var session = CodexSession(
      cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0")
    let start = session.start()
    #expect(methods(start) == ["initialize"])
    #expect(
      start.writes[0]["params"]?["capabilities"]?["optOutNotificationMethods"]
        == .array([.string("mcpServer/startupStatus/updated")]))
    let (_, step) = initialized()
    #expect(methods(step) == ["initialized", "account/read", "model/list"])
  }

  @Test func aFirstPromptOpensTheThreadThenStartsATurn() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let start = try write("thread/start", in: opening)
    #expect(start["params"]?["cwd"] == .string("/p"))
    #expect(start["params"]?["approvalPolicy"] == .string("untrusted"))
    #expect(start["params"]?["sandbox"] == .string("workspace-write"))
    #expect(start["params"]?["model"] == nil)
    let started = answer(&session, start, thread)
    #expect(
      started.events.first
        == .sessionStarted(
          SessionInfo(sessionID: "t-1", cwd: "/p", model: "gpt-6-astra", agentVersion: "0.160.1")))
    #expect(
      started.signals
        == [
          .thread(id: "t-1", path: "/home/.codex/sessions/r.jsonl", codexHome: "/home/.codex"),
          .modeAdopted("default"),
        ])
    let turn = try write("turn/start", in: started)
    #expect(turn["params"]?["threadId"] == .string("t-1"))
    #expect(turn["params"]?["clientUserMessageId"] == .string("p-1"))
    #expect(turn["params"]?["input"] == input("one"))
    #expect(turn["params"]?["sandboxPolicy"]?["type"] == .string("workspaceWrite"))
    #expect(turn["params"]?["effort"] == nil)
  }

  @Test func aPromptBeforeInitializeWaitsForIt() throws {
    var session = CodexSession(
      cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0")
    let start = session.start()
    #expect(session.send(.prompt(input: input("one"), uuid: "p-1")).writes.isEmpty)
    let step = answer(&session, start.writes[0], "{}")
    #expect(methods(step) == ["initialized", "account/read", "model/list", "thread/start"])
  }

  @Test func aResumePassesItsSettingsAgain() throws {
    var (session, _) = initialized(resuming: "t-1", mode: .acceptEdits)
    _ = session.send(.setModel("gpt-6.1-sol"))
    let resume = try write("thread/resume", in: session.send(.prompt(input: input("x"), uuid: "p")))
    #expect(resume["params"]?["threadId"] == .string("t-1"))
    #expect(resume["params"]?["excludeTurns"] == .bool(true))
    #expect(resume["params"]?["approvalPolicy"] == .string("on-request"))
    #expect(resume["params"]?["model"] == .string("gpt-6.1-sol"))
  }

  @Test func aPromptMidTurnIsSteeredAndLeavesTheQueueWhenEchoed() throws {
    var session = try running()
    let steer = try write("turn/steer", in: session.send(.prompt(input: input("two"), uuid: "p-2")))
    #expect(steer["params"]?["expectedTurnId"] == .string("turn-1"))
    #expect(steer["params"]?["clientUserMessageId"] == .string("p-2"))
    let echo = session.receive(
      json(
        #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"u2","clientId":"p-2","content":[]},"threadId":"t-1","turnId":"turn-1"}}"#
      ), at: nil)
    #expect(echo.events == [.queue(id: "p-2", .started)])
    let end = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"completed"}}}"#
      ),
      at: nil)
    #expect(!end.events.contains(.queue(id: "p-2", .dropped(agent: "Codex"))))
  }

  /// Review Focus 4.
  @Test func aSteerTooLateStartsATurnOfItsOwn() throws {
    var session = try running()
    let steer = try write("turn/steer", in: session.send(.prompt(input: input("two"), uuid: "p-2")))
    let retried = fail(&session, steer, "no active turn to steer")
    let turn = try write("turn/start", in: retried)
    #expect(turn["params"]?["clientUserMessageId"] == .string("p-2"))
    #expect(turn["params"]?["input"] == input("two"))
  }

  @Test func aSteerAnInterruptCutShortIsDropped() throws {
    var session = try running()
    _ = session.send(.prompt(input: input("two"), uuid: "p-2"))
    let end = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"interrupted"}}}"#
      ),
      at: nil)
    #expect(end.events.last == .queue(id: "p-2", .dropped(agent: "Codex")))
  }

  /// Review Focus 1.
  @Test func aSecondPromptWhileTheThreadOpensJoinsTheFirstTurn() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    #expect(session.send(.prompt(input: input("two"), uuid: "p-2")).writes.isEmpty)
    let started = answer(&session, try write("thread/start", in: opening), thread)
    #expect(methods(started) == ["turn/start"])
    let running = answer(
      &session, try write("turn/start", in: started), #"{"turn":{"id":"turn-1"}}"#)
    let steer = try write("turn/steer", in: running)
    #expect(steer["params"]?["clientUserMessageId"] == .string("p-2"))
    #expect(steer["params"]?["expectedTurnId"] == .string("turn-1"))
  }

  /// Review Focus 2.
  @Test func stopBeforeTheTurnHasAnIdInterruptsWhenItDoes() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(&session, try write("thread/start", in: opening), thread)
    #expect(session.send(.interrupt).writes.isEmpty)
    let running = session.receive(
      json(
        #"{"method":"turn/started","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"inProgress"}}}"#
      ),
      at: nil)
    let interrupt = try write("turn/interrupt", in: running)
    #expect(interrupt["params"]?["turnId"] == .string("turn-1"))
    _ = started
  }

  /// Stop means stop: a prompt waiting for the turn's id is dropped, not steered in.
  @Test func stopBeforeTheTurnHasAnIdDropsThePromptsWaitingForIt() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(&session, try write("thread/start", in: opening), thread)
    _ = try write("turn/start", in: started)
    #expect(session.send(.prompt(input: input("two"), uuid: "p-2")).writes.isEmpty)
    #expect(session.send(.interrupt).writes.isEmpty)
    let running = session.receive(
      json(
        #"{"method":"turn/started","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"inProgress"}}}"#
      ),
      at: nil)
    #expect(methods(running) == ["turn/interrupt"])
    #expect(running.events.contains(.queue(id: "p-2", .dropped(agent: "Codex"))))
  }

  /// The same while the thread is still opening: only the first prompt's turn starts.
  @Test func stopWhileTheThreadOpensDropsTheLaterPrompts() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    _ = session.send(.prompt(input: input("two"), uuid: "p-2"))
    #expect(session.send(.interrupt).writes.isEmpty)
    let started = answer(&session, try write("thread/start", in: opening), thread)
    let running = answer(
      &session, try write("turn/start", in: started), #"{"turn":{"id":"turn-1"}}"#)
    #expect(methods(running) == ["turn/interrupt"])
    #expect(running.events == [.queue(id: "p-2", .dropped(agent: "Codex"))])
  }

  @Test func stopCancelsAWaitingApprovalThenInterrupts() throws {
    var session = try running()
    let asked = session.receive(
      json(
        #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"t-1","turnId":"turn-1","itemId":"exec-1","command":"/bin/zsh -lc 'touch x'","commandActions":[]}}"#
      ),
      at: nil)
    #expect(asked.events.count == 1)
    let stop = session.send(.interrupt)
    #expect(
      stop.writes.first
        == CodexRPC.answer(.number(0), result: .object(["decision": .string("cancel")])))
    #expect(try write("turn/interrupt", in: stop)["params"]?["turnId"] == .string("turn-1"))
  }

  @Test func answersMapOntoCodexDecisions() throws {
    var session = try running()
    for (id, decision, expected) in [
      (0, PermissionDecision.allow(updatedInput: .null), "accept"),
      (
        1, .allow(updatedInput: .null, updatedPermissions: [CodexPolicy.acceptForSession]),
        "acceptForSession"
      ),
      (2, .deny(message: "no"), "decline"),
    ] {
      _ = session.receive(
        json(
          #"{"method":"item/fileChange/requestApproval","id":\#(id),"params":{"threadId":"t-1","turnId":"turn-1","itemId":"p"}}"#
        ),
        at: nil)
      let step = session.send(.answer(requestID: String(id), decision: decision))
      #expect(
        step.writes == [
          CodexRPC.answer(.number(id), result: .object(["decision": .string(expected)]))
        ])
    }
  }

  /// Review Focus 3.
  @Test func anAnswerToARequestNoLongerWaitingWritesNothing() throws {
    var session = try running()
    _ = session.receive(
      json(
        #"{"method":"item/fileChange/requestApproval","id":0,"params":{"threadId":"t-1","turnId":"turn-1","itemId":"p"}}"#
      ),
      at: nil)
    _ = session.receive(
      json(#"{"method":"serverRequest/resolved","params":{"threadId":"t-1","requestId":0}}"#),
      at: nil)
    #expect(
      session.send(.answer(requestID: "0", decision: .allow(updatedInput: .null))).writes.isEmpty)
    #expect(
      session.send(.answer(requestID: "9", decision: .allow(updatedInput: .null))).writes.isEmpty)
  }

  @Test func anUnknownRequestIsRefusedAndNoted() throws {
    var session = try running()
    let step = session.receive(
      json(#"{"method":"item/tool/requestUserInput","id":4,"params":{"threadId":"t-1"}}"#), at: nil)
    #expect(step.writes.first?["id"] == .number(4))
    #expect(step.writes.first?["error"]?["code"] == .number(-32601))
    guard case .note(let note)? = step.events.first else {
      Issue.record("\(step.events)")
      return
    }
    #expect(note.text.contains("item/tool/requestUserInput"))
  }

  @Test func notSignedInMakesTheSessionUnusable() throws {
    var session = CodexSession(
      cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0")
    let start = session.start()
    let step = answer(&session, start.writes[0], "{}")
    let account = try write("account/read", in: step)
    #expect(
      answer(&session, account, #"{"account":null,"requiresOpenaiAuth":true}"#).signals
        == [.unusable(CodexSession.notSignedIn)])
    var signedIn = CodexSession(
      cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0")
    let opened = signedIn.start()
    let again = answer(&signedIn, opened.writes[0], "{}")
    #expect(
      answer(
        &signedIn, try write("account/read", in: again),
        #"{"account":{"type":"chatgpt"},"requiresOpenaiAuth":true}"#
      )
      .signals.isEmpty)
  }

  @Test func theModelListComesAsASignal() throws {
    var (session, step) = initialized()
    let models = answer(
      &session, try write("model/list", in: step),
      #"{"data":[{"id":"m","model":"m","displayName":"M","supportedReasoningEfforts":[]}]}"#)
    #expect(
      models.signals == [.models([ModelOption(value: "m", resolvedModel: "m", displayName: "M")])])
  }

  @Test func picksRideOnTheNextTurn() throws {
    var session = try running()
    #expect(session.send(.setMode(.acceptEdits)).writes.isEmpty)
    #expect(session.send(.setModel("gpt-6.1-sol")).writes.isEmpty)
    #expect(session.send(.setEffort("high")).writes.isEmpty)
    _ = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"completed"}}}"#
      ),
      at: nil)
    let turn = try write("turn/start", in: session.send(.prompt(input: input("x"), uuid: "p-3")))
    #expect(turn["params"]?["approvalPolicy"] == .string("on-request"))
    #expect(turn["params"]?["model"] == .string("gpt-6.1-sol"))
    #expect(turn["params"]?["effort"] == .string("high"))
  }

  private let commandApproval =
    #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"t-1","turnId":"turn-1","itemId":"exec-1","command":"/bin/zsh -lc 'touch x'","commandActions":[]}}"#
  private let fileApproval =
    #"{"method":"item/fileChange/requestApproval","id":1,"params":{"threadId":"t-1","turnId":"turn-1","itemId":"p"}}"#
  private func accepted(_ id: Int) -> JSONValue {
    CodexRPC.answer(.number(id), result: .object(["decision": .string("accept")]))
  }

  /// The running turn keeps the policy it started with, so what the new mode lets through
  /// unasked Drakar accepts itself.
  @Test func aTurnSwitchedToBypassIsAnsweredWithoutAsking() throws {
    var session = try running()
    _ = session.send(.setMode(.bypass))
    let command = session.receive(json(commandApproval), at: nil)
    #expect(command.writes == [accepted(0)])
    #expect(command.events.isEmpty)
    let file = session.receive(json(fileApproval), at: nil)
    #expect(file.writes == [accepted(1)])
    #expect(file.events.isEmpty)
  }

  @Test func switchingToBypassAcceptsWhatWaits() throws {
    var session = try running()
    _ = session.receive(json(commandApproval), at: nil)
    let step = session.send(.setMode(.bypass))
    #expect(step.writes == [accepted(0)])
    #expect(step.events == [.permissionWithdrawn(requestID: "0")])
    #expect(
      session.send(.answer(requestID: "0", decision: .allow(updatedInput: .null))).writes.isEmpty)
  }

  @Test func aTurnSwitchedToEditAutomaticallyStillAsksForCommands() throws {
    var session = try running()
    _ = session.receive(json(commandApproval), at: nil)
    let switched = session.send(.setMode(.acceptEdits))
    #expect(switched.writes.isEmpty)
    let file = session.receive(json(fileApproval), at: nil)
    #expect(file.writes == [accepted(1)])
    let command = session.receive(
      json(commandApproval.replacingOccurrences(of: #""id":0"#, with: #""id":2"#)), at: nil)
    #expect(command.writes.isEmpty)
    #expect(command.events.count == 1)
  }

  @Test func aThreadAnotherProcessHoldsMakesTheSessionUnusable() throws {
    var (session, _) = initialized(resuming: "t-1")
    let resume = try write("thread/resume", in: session.send(.prompt(input: input("x"), uuid: "p")))
    #expect(
      fail(&session, resume, "thread t-1 already has an active writer").signals
        == [.unusable(CodexSession.heldElsewhere)])
  }

  /// A thread answer with no id opened nothing: the prompts end as a failed open does, and
  /// the next prompt opens the thread again.
  @Test func aThreadAnswerWithoutAnIdFailsTheOpen() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    _ = session.send(.prompt(input: input("two"), uuid: "p-2"))
    let answered = answer(&session, try write("thread/start", in: opening), #"{"thread":{}}"#)
    #expect(answered.writes.isEmpty)
    #expect(
      answered.events
        == [
          .turnEnded(TurnSummary(outcome: .failed, failureText: CodexSession.noThread)),
          .queue(id: "p-2", .dropped(agent: "Codex")),
        ])
    #expect(methods(session.send(.prompt(input: input("x"), uuid: "p-3"))) == ["thread/start"])
  }

  @Test func aTurnThatCannotStartEndsFailed() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(&session, try write("thread/start", in: opening), thread)
    let failed = fail(&session, try write("turn/start", in: started), "Model not found")
    #expect(
      failed.events == [.turnEnded(TurnSummary(outcome: .failed, failureText: "Model not found"))])
    // The session takes the next prompt as a new turn.
    #expect(methods(session.send(.prompt(input: input("x"), uuid: "p-2"))) == ["turn/start"])
  }

  @Test func renameNamesTheThread() throws {
    var session = try running()
    let rename = try write("thread/name/set", in: session.send(.rename("Pineapple")))
    #expect(
      rename["params"] == .object(["threadId": .string("t-1"), "name": .string("Pineapple")]))
  }

  /// A name given while the thread opens goes once it runs; the old name it answers with
  /// is not shown over it.
  @Test func aRenameBeforeTheThreadIsReadyIsSentOnceReady() throws {
    var (session, _) = initialized(resuming: "t-1")
    let resume = try write("thread/resume", in: session.send(.prompt(input: input("x"), uuid: "p")))
    #expect(session.send(.rename("Pineapple")).writes.isEmpty)
    let resumed = answer(
      &session, resume, #"{"thread":{"id":"t-1","cwd":"/p","name":"Mango"},"model":"m"}"#)
    let rename = try write("thread/name/set", in: resumed)
    #expect(
      rename["params"] == .object(["threadId": .string("t-1"), "name": .string("Pineapple")]))
    #expect(!resumed.events.contains(.title(.custom("Mango"))))
    #expect(methods(resumed).filter { $0 == "thread/name/set" }.count == 1)
  }

  /// A name the session started with goes once the thread runs.
  @Test func aNameGivenAtStartIsSentOnceTheThreadRuns() throws {
    var session = CodexSession(
      cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0",
      name: "Pineapple")
    let start = session.start()
    _ = answer(&session, start.writes[0], "{}")
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(&session, try write("thread/start", in: opening), thread)
    #expect(
      try write("thread/name/set", in: started)["params"]?["name"] == .string("Pineapple"))
  }

  @Test func aResumedThreadsNameIsItsTitle() throws {
    var (session, _) = initialized(resuming: "t-1")
    let resume = try write("thread/resume", in: session.send(.prompt(input: input("x"), uuid: "p")))
    let resumed = answer(
      &session, resume, #"{"thread":{"id":"t-1","cwd":"/p","name":"Pineapple"},"model":"m"}"#)
    #expect(resumed.events.contains(.title(.custom("Pineapple"))))
    #expect(!methods(resumed).contains("thread/name/set"))
  }

  @Test func aThreadWithNoNameHasNoTitle() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(
      &session, try write("thread/start", in: opening),
      #"{"thread":{"id":"t-1","cwd":"/p","name":null},"model":"m"}"#)
    #expect(!started.events.contains { if case .title = $0 { true } else { false } })
  }

  @Test func aNameUpdateIsTheTitle() throws {
    var session = try running()
    let updated = session.receive(
      json(
        #"{"method":"thread/name/updated","params":{"threadId":"t-1","threadName":"Pineapple"}}"#),
      at: nil)
    #expect(updated.events == [.title(.custom("Pineapple"))])
  }

  @Test func linesStillReachTheTranslator() throws {
    var session = try running()
    let step = session.receive(
      json(
        #"{"method":"item/agentMessage/delta","params":{"threadId":"t-1","turnId":"turn-1","itemId":"m","delta":"hi"}}"#
      ),
      at: nil)
    #expect(step.events == [.itemDelta(id: "m", .text("hi"))])
  }

  @Test func aSteerTooLateAfterTheTurnCompletedIsNotDropped() throws {
    var session = try running()
    let steer = try write("turn/steer", in: session.send(.prompt(input: input("two"), uuid: "p-2")))
    let end = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"completed"}}}"#
      ),
      at: nil)
    #expect(!end.events.contains(.queue(id: "p-2", .dropped(agent: "Codex"))))
    let retried = fail(&session, steer, "no active turn to steer")
    #expect(!retried.events.contains(.queue(id: "p-2", .dropped(agent: "Codex"))))
    #expect(
      try write("turn/start", in: retried)["params"]?["clientUserMessageId"] == .string("p-2"))
  }

  @Test func aDroppedSteersLateFailureWritesNothing() throws {
    var session = try running()
    let steer = try write("turn/steer", in: session.send(.prompt(input: input("two"), uuid: "p-2")))
    _ = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"interrupted"}}}"#
      ),
      at: nil)
    let late = fail(&session, steer, "no active turn to steer")
    #expect(late.writes.isEmpty)
    #expect(late.events.isEmpty)
  }

  @Test func stopWhileTheThreadOpensInterruptsOnceTheTurnHasAnId() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    #expect(session.send(.interrupt).writes.isEmpty)
    let started = answer(&session, try write("thread/start", in: opening), thread)
    let running = answer(
      &session, try write("turn/start", in: started), #"{"turn":{"id":"turn-1"}}"#)
    #expect(try write("turn/interrupt", in: running)["params"]?["turnId"] == .string("turn-1"))
  }
}
