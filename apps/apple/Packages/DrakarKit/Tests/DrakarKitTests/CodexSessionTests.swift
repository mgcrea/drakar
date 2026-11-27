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
    #expect(
      methods(step) == ["initialized", "account/read", "model/list", "account/rateLimits/read"])
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
    #expect(
      methods(step)
        == ["initialized", "account/read", "model/list", "account/rateLimits/read", "thread/start"])
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

  /// The old turn's completion, late behind a steer that started the next: once that one
  /// runs, it ends nothing, so the new turn keeps what it waits on. While the next turn is
  /// still starting, the old one's end still shows.
  @Test func aLateCompletionOfTheOldTurnEndsOnlyItself() throws {
    let late = json(
      #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"completed"}}}"#
    )
    func ends(_ step: CodexSession.Step) -> Bool {
      step.events.contains { if case .turnEnded = $0 { true } else { false } }
    }
    for startedFirst in [true, false] {
      var session = try running()
      let steer = try write(
        "turn/steer", in: session.send(.prompt(input: input("two"), uuid: "p-2")))
      let start = try write("turn/start", in: fail(&session, steer, "no active turn to steer"))
      if startedFirst { _ = answer(&session, start, #"{"turn":{"id":"turn-2"}}"#) }
      #expect(ends(session.receive(late, at: nil)) == !startedFirst, "started: \(startedFirst)")
    }
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

  /// Esc, as in the extension: the turn stops, and what was queued behind it runs next.
  @Test func escSendsAnInterruptedTurnsSteersAgainAsTheNextTurn() throws {
    var session = try running()
    let steer = try write("turn/steer", in: session.send(.prompt(input: input("two"), uuid: "p-2")))
    #expect(methods(session.send(.interruptKeepingQueued)) == ["turn/interrupt"])
    let end = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"interrupted"}}}"#
      ),
      at: nil)
    #expect(!end.events.contains(.queue(id: "p-2", .dropped(agent: "Codex"))))
    let turn = try write("turn/start", in: end)
    #expect(turn["params"]?["clientUserMessageId"] == .string("p-2"))
    #expect(turn["params"]?["input"] == input("two"))
    // The steer's own late refusal does not start it a second time.
    #expect(fail(&session, steer, "no active turn to steer").writes.isEmpty)
  }

  /// Codex 0.162 takes a steer into the turn at once (captured 2026-10-12): Esc then leaves it
  /// in the thread unanswered, and an empty turn has the model answer it.
  @Test func escAfterCodexTookASteerStartsAnEmptyTurn() throws {
    var session = try running()
    _ = session.send(.prompt(input: input("two"), uuid: "p-2"))
    _ = session.receive(
      json(
        #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"u2","clientId":"p-2","content":[]},"threadId":"t-1","turnId":"turn-1"}}"#
      ),
      at: nil)
    _ = session.send(.interruptKeepingQueued)
    let end = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"interrupted"}}}"#
      ),
      at: nil)
    let turn = try write("turn/start", in: end)
    #expect(turn["params"]?["input"] == .array([]))
  }

  /// Answered already (the model worked after taking it): nothing to start.
  @Test func escAfterTheModelWorkedOnATakenSteerStartsNothing() throws {
    var session = try running()
    _ = session.send(.prompt(input: input("two"), uuid: "p-2"))
    for line in [
      #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"u2","clientId":"p-2","content":[]},"threadId":"t-1","turnId":"turn-1"}}"#,
      #"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"m2","text":""},"threadId":"t-1","turnId":"turn-1"}}"#,
    ] { _ = session.receive(json(line), at: nil) }
    _ = session.send(.interruptKeepingQueued)
    let end = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"interrupted"}}}"#
      ),
      at: nil)
    #expect(methods(end).isEmpty)
  }

  /// Stop leaves a taken steer where it is: the next prompt's turn reads it.
  @Test func stopAfterCodexTookASteerStartsNothing() throws {
    var session = try running()
    _ = session.send(.prompt(input: input("two"), uuid: "p-2"))
    _ = session.receive(
      json(
        #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"u2","clientId":"p-2","content":[]},"threadId":"t-1","turnId":"turn-1"}}"#
      ),
      at: nil)
    _ = session.send(.interrupt)
    let end = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"interrupted"}}}"#
      ),
      at: nil)
    #expect(methods(end).isEmpty)
  }

  /// Several queued: the first starts the turn, the rest are steered into it.
  @Test func escBeforeTheTurnHasAnIdHoldsWhatWaitedForTheNextTurn() throws {
    var (session, _) = initialized()
    let opening = session.send(.prompt(input: input("one"), uuid: "p-1"))
    let started = answer(&session, try write("thread/start", in: opening), thread)
    _ = try write("turn/start", in: started)
    _ = session.send(.prompt(input: input("two"), uuid: "p-2"))
    _ = session.send(.prompt(input: input("three"), uuid: "p-3"))
    #expect(session.send(.interruptKeepingQueued).writes.isEmpty)
    let running = session.receive(
      json(
        #"{"method":"turn/started","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"inProgress"}}}"#
      ),
      at: nil)
    #expect(methods(running) == ["turn/interrupt"])
    #expect(!running.events.contains { if case .queue = $0 { true } else { false } })
    let end = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"interrupted"}}}"#
      ),
      at: nil)
    #expect(
      try write("turn/start", in: end)["params"]?["clientUserMessageId"] == .string("p-2"))
    let next = answer(
      &session, try write("turn/start", in: end), #"{"turn":{"id":"turn-2"}}"#)
    #expect(
      try write("turn/steer", in: next)["params"]?["clientUserMessageId"] == .string("p-3"))
  }

  /// Stop after Esc still means stop.
  @Test func stopAfterEscDropsTheQueueAfterAll() throws {
    var session = try running()
    _ = session.send(.prompt(input: input("two"), uuid: "p-2"))
    _ = session.send(.interruptKeepingQueued)
    _ = session.send(.interrupt)
    let end = session.receive(
      json(
        #"{"method":"turn/completed","params":{"threadId":"t-1","turn":{"id":"turn-1","status":"interrupted"}}}"#
      ),
      at: nil)
    #expect(end.events.last == .queue(id: "p-2", .dropped(agent: "Codex")))
    #expect(methods(end).isEmpty)
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
      json(#"{"method":"item/tool/call","id":4,"params":{"threadId":"t-1"}}"#), at: nil)
    #expect(step.writes.first?["id"] == .number(4))
    #expect(step.writes.first?["error"]?["code"] == .number(-32601))
    guard case .note(let note)? = step.events.first else {
      Issue.record("\(step.events)")
      return
    }
    #expect(note.text.contains("item/tool/call"))
  }

  @Test func requestUserInputAsksQuestionsEvenInBypassAndMapsAnswersByID() throws {
    var session = try running()
    _ = session.send(.setMode(.bypass))

    let req = json(
      #"""
      {
        "method": "item/tool/requestUserInput",
        "id": 7,
        "params": {
          "threadId": "t-1",
          "turnId": "turn-1",
          "itemId": "call_q1",
          "questions": [
            {
              "id": "language",
              "header": "Language",
              "question": "Which language?",
              "isOther": true,
              "isSecret": false,
              "options": [
                {"label": "Python (Recommended)", "description": "Use Python."},
                {"label": "Shell", "description": "Use sh."}
              ]
            },
            {
              "id": "token",
              "header": "Token",
              "question": "API token?",
              "isOther": true,
              "isSecret": true,
              "options": null
            }
          ]
        }
      }
      """#)
    let asked = session.receive(req, at: nil)
    #expect(asked.writes.isEmpty)
    guard case .permissionRequested(let pending)? = asked.events.first else {
      Issue.record("Expected permissionRequested")
      return
    }
    #expect(pending.requestID == "7")
    #expect(pending.request.isChoice)
    let questions = UserQuestion.list(pending.request.input)
    #expect(questions.map(\.questionID) == ["language", "token"])
    #expect(questions[1].isSecret)
    #expect(questions[1].options.isEmpty)

    let answered = session.send(
      .answer(
        requestID: "7",
        decision: .allow(
          updatedInput: UserQuestion.answering(
            pending.request.input,
            with: ["Which language?": "Python (Recommended)", "API token?": "secret-123"]))))
    #expect(
      answered.writes == [
        CodexRPC.answer(
          .number(7),
          result: .object([
            "answers": .object([
              "language": .object(["answers": .array([.string("Python (Recommended)")])]),
              "token": .object(["answers": .array([.string("secret-123")])]),
            ])
          ]))
      ])
  }

  @Test func interruptingAnswersPendingUserInputWithEmptyAnswers() throws {
    var session = try running()
    _ = session.receive(
      json(
        #"{"method":"item/tool/requestUserInput","id":8,"params":{"threadId":"t-1","turnId":"turn-1","questions":[{"id":"q","header":"Q","question":"Go?","isOther":false,"isSecret":false,"options":[{"label":"Yes","description":""}]}]}}"#
      ),
      at: nil)
    let stopped = session.send(.interrupt)
    #expect(
      stopped.writes.contains(
        CodexRPC.answer(.number(8), result: .object(["answers": .object([:])]))))
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

  /// Codex says its skills changed, without listing them: the session says so too.
  @Test func aSkillsChangeIsASignal() throws {
    var session = try running()
    let step = session.receive(json(#"{"method":"skills/changed"}"#), at: nil)
    #expect(step.signals == [.skillsChanged])
    #expect(step.writes.isEmpty)
    #expect(step.events.isEmpty)
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

  @Test func rateLimitUpdateNotificationEmitsSignal() throws {
    var session = try running()
    let now = Date(timeIntervalSince1970: 1_791_300_000)
    let step = session.receive(
      json(
        #"""
        {"method":"account/rateLimits/updated","params":{"rateLimits":{
          "limitId":"codex","planType":"plus",
          "primary":{"usedPercent":15,"windowDurationMins":300,"resetsAt":1791317294},
          "secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1791792475}}}}
        """#),
      at: now)
    guard case .rateLimit(let codex)? = step.signals.first else {
      Issue.record("expected rateLimit signal, got \(step.signals)")
      return
    }
    #expect(codex.plan == "Plus")
    #expect(codex.usage.fiveHour?.percent == 15)
    #expect(codex.usage.sevenDay?.percent == 40)
    #expect(codex.usage.readAt == now)
    #expect(codex.usage.source == .live)
  }

  @Test func initializeReadsRateLimitsAndUsageLimitFailureRefreshesThem() throws {
    var session = CodexSession(
      cwd: "/p", resuming: nil, mode: .ask, model: nil, effort: nil, version: "1.0")
    let start = session.start()
    let initStep = answer(&session, start.writes[0], #"{"codexHome":"/home/.codex"}"#)
    let readCall = try write("account/rateLimits/read", in: initStep)
    let readStep = answer(
      &session, readCall,
      #"""
      {"ordinaryUsageAllowed":false,"rateLimits":{
        "limitId":"codex","planType":"plus","rateLimitReachedType":"rate_limit_reached",
        "primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1795798786},
        "secondary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":1796385586}}}
      """#)
    guard case .rateLimit(let initial)? = readStep.signals.first else {
      Issue.record("expected rateLimit signal, got \(readStep.signals)")
      return
    }
    #expect(initial.usage.fiveHour?.percent == 100)
    #expect(initial.usage.fiveHour?.isRejected == true)
    #expect(initial.usage.sevenDay?.isRejected == false)

    // When a turn fails with usageLimitExceeded, CodexSession refreshes rate limits.
    var runningSession = try running()
    let failed = runningSession.receive(
      json(
        #"""
        {"method":"turn/completed","params":{"threadId":"t-1","turn":{
          "id":"turn-1","status":"failed",
          "error":{"message":"You’ve hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}}}}
        """#),
      at: nil)
    #expect(methods(failed) == ["account/rateLimits/read"])
  }
}
