import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Codex behind the backend")
struct CodexBackendTests {
  private func line(_ json: String) throws -> AgentProcess.Line {
    .json(try JSONValue.parse(Data(json.utf8)))
  }

  /// A `cat` stands in for the process: what the backend writes is not read here (the
  /// conversation's writes are `CodexSessionTests`'). Each test terminates its own.
  private func process() throws -> AgentProcess {
    let process = AgentProcess(
      .init(
        executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
        currentDirectory: FileManager.default.temporaryDirectory))
    _ = try process.start()
    return process
  }

  private func start(resuming: ResumeTarget? = nil) -> AgentStart {
    AgentStart(
      folder: URL(filePath: "/p"), resuming: resuming, environment: ["PATH": "/nowhere"],
      executableOverride: URL(filePath: "/bin/cat"), model: nil, mode: .acceptEdits,
      effort: nil, allowsBypass: true, name: nil)
  }

  @Test func launchesAppServerUnderNoClaudeAccount() {
    let launch = CodexBackend().launch(start())
    #expect(launch.configuration?.arguments == ["app-server"])
    #expect(launch.configuration?.currentDirectory == URL(filePath: "/p"))
    #expect(launch.executable == URL(filePath: "/bin/cat"))
    #expect(launch.account == nil)
  }

  @Test func findsCodexOnThePathThenHomebrew() {
    let found = CodexLaunch.locate(path: "/a:/b") { $0.path == "/b/codex" }
    #expect(found == URL(filePath: "/b/codex"))
    let brewed = CodexLaunch.locate(path: "/a") { $0.path == "/opt/homebrew/bin/codex" }
    #expect(brewed == URL(filePath: "/opt/homebrew/bin/codex"))
    #expect(CodexLaunch.locate(path: nil) { _ in false } == nil)
  }

  @Test func signalsReachTheSessionAndTheThreadIsLocated() throws {
    let backend = CodexBackend()
    _ = backend.launch(start())
    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)
    _ = backend.receive(
      try line(#"{"id":1,"result":{"codexHome":"/home/.codex"}}"#), from: process, at: .now)
    let models = backend.receive(
      try line(
        #"{"id":3,"result":{"data":[{"id":"m","model":"m","displayName":"M","supportedReasoningEfforts":[]}]}}"#
      ),
      from: process, at: .now)
    #expect(
      models.signals == [.models([ModelOption(value: "m", resolvedModel: "m", displayName: "M")])])
    _ = try backend.send(
      .prompt(text: "hi", context: [], uuid: "p-1", attachments: []), to: process)
    let thread = backend.receive(
      try line(
        #"{"id":4,"result":{"thread":{"id":"t-1","cwd":"/p","cliVersion":"0.160.1","path":"/home/.codex/sessions/r.jsonl"},"model":"gpt-6-astra"}}"#
      ), from: process, at: .now)
    #expect(thread.signals == [.modeAdopted("acceptEdits")])
    #expect(thread.events.contains { if case .sessionStarted = $0 { true } else { false } })
    let target = backend.locateTarget(sessionID: "t-1", cwd: "/p", in: [])
    #expect(target?.agentKind == .codex)
    #expect(target?.sessionID == "t-1")
    #expect(target?.file == "/home/.codex/sessions/r.jsonl")
    #expect(target?.accountDirectory == "/home/.codex")
  }

  /// A queued prompt that moves says so: the session tells the window a turn ended once its
  /// queue empties.
  @Test func aQueueChangeIsSignalled() throws {
    let backend = CodexBackend()
    _ = backend.launch(start())
    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)
    _ = backend.receive(try line(#"{"id":1,"result":{}}"#), from: process, at: .now)
    _ = try backend.send(
      .prompt(text: "one", context: [], uuid: "p-1", attachments: []), to: process)
    _ = backend.receive(
      try line(#"{"id":4,"result":{"thread":{"id":"t-1","cwd":"/p"},"model":"m"}}"#),
      from: process, at: .now)
    let started = backend.receive(
      try line(#"{"id":5,"result":{"turn":{"id":"turn-1"}}}"#), from: process, at: .now)
    #expect(!started.signals.contains(.queueChanged))
    _ = try backend.send(
      .prompt(text: "two", context: [], uuid: "p-2", attachments: []), to: process)
    let refused = backend.receive(
      try line(#"{"id":6,"error":{"code":-32600,"message":"expected turn mismatch"}}"#),
      from: process, at: .now)
    #expect(refused.events == [.queue(id: "p-2", .dropped(agent: "Codex"))])
    #expect(refused.signals == [.queueChanged])
  }

  @Test func notSignedInIsUnusable() throws {
    let backend = CodexBackend()
    _ = backend.launch(start())
    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)
    _ = backend.receive(try line(#"{"id":1,"result":{}}"#), from: process, at: .now)
    let output = backend.receive(
      try line(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#), from: process,
      at: .now)
    #expect(output.signals == [.unusable(CodexSession.notSignedIn)])
  }

  @Test func picksAndCancelsAnswerWithNoRequest() throws {
    let backend = CodexBackend()
    _ = backend.launch(start())
    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)
    #expect(try backend.send(.setMode("default"), to: process) == nil)
    #expect(try backend.send(.setEffort("high"), to: process) == nil)
    #expect(try backend.send(.cancelQueued(uuid: "u"), to: process) == nil)
  }

  @Test func featuresSayWhatACodexSessionLacks() {
    #expect(CodexBackend().features == .codex)
    #expect(ClaudeBackend().features == .claude)
    #expect(!AgentFeatures.codex.cancelsQueued && AgentFeatures.claude.cancelsQueued)
    #expect(AgentKind.codex.name == "Codex")
  }

  /// Review Focus 5, the stored half: windows stored before this slice decode as Claude.
  @Test func aTargetStoredWithoutAnAgentIsClaudes() throws {
    let old =
      #"{"sessionID":"s","cwd":"/p","file":"/f.jsonl","accountDirectory":"/a","accountIsDefault":true}"#
    let target = try JSONDecoder().decode(ResumeTarget.self, from: Data(old.utf8))
    #expect(target.agentKind == .claude)
    var codex = target
    codex.agent = .codex
    let again = try JSONDecoder().decode(ResumeTarget.self, from: JSONEncoder().encode(codex))
    #expect(again.agentKind == .codex)
  }
}
