import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Antigravity behind the backend")
struct AgyBackendTests {
  private func line(_ json: String) throws -> AgentProcess.Line {
    .json(try JSONValue.parse(Data(json.utf8)))
  }

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

  @Test func launchesACPServerUnderNoClaudeAccount() {
    let launch = AgyBackend().launch(start())
    #expect(launch.configuration?.arguments == ["acp"])
    #expect(launch.configuration?.currentDirectory == URL(filePath: "/p"))
    #expect(launch.executable == URL(filePath: "/bin/cat"))
    #expect(launch.account == nil)
  }

  @Test func grokLaunchAndResumeKeepTheirAgent() throws {
    let backend = AgentKind.grok.makeBackend()
    let launch = backend.launch(start())
    #expect(launch.configuration?.arguments == ["agent", "stdio"])
    #expect(launch.configuration?.currentDirectory == URL(filePath: "/p"))
    #expect(backend.locateTarget(sessionID: "id", cwd: "/p", in: [])?.agentKind == .grok)

    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)
    _ = backend.receive(
      try line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#), from: process,
      at: .now)
    _ = try backend.send(
      .prompt(text: "hi", context: [], uuid: "p-1", attachments: []), to: process)
    _ = backend.receive(
      try line(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"grok-1"}}"#), from: process,
      at: .now)

    #expect(try backend.send(.setMode("plan"), to: process) != nil)
    #expect(try backend.send(.setMode("bypassPermissions"), to: process) != nil)
    #expect(try backend.send(.setMode("acceptEdits"), to: process) == nil)
  }

  @Test func findsAgyOnPathThenLocalBinThenHomebrew() {
    let found = AgyLaunch.locate(path: "/a:/b", home: URL(filePath: "/Users/me")) {
      $0.path == "/b/agy"
    }
    #expect(found == URL(filePath: "/b/agy"))
    let localBin = AgyLaunch.locate(path: "/a", home: URL(filePath: "/Users/me")) {
      $0.path == "/Users/me/.local/bin/agy"
    }
    #expect(localBin == URL(filePath: "/Users/me/.local/bin/agy"))
    let brewed = AgyLaunch.locate(path: "/a", home: URL(filePath: "/Users/me")) {
      $0.path == "/opt/homebrew/bin/agy"
    }
    #expect(brewed == URL(filePath: "/opt/homebrew/bin/agy"))
    let grokBin = AgyLaunch.locate(path: "/a", binary: "grok", home: URL(filePath: "/Users/me")) {
      $0.path == "/Users/me/.grok/bin/grok"
    }
    #expect(grokBin == URL(filePath: "/Users/me/.grok/bin/grok"))
    #expect(AgyLaunch.locate(path: nil, home: URL(filePath: "/Users/me")) { _ in false } == nil)
  }

  @Test func signalsReachTheSessionAndTargetIsLocated() throws {
    let backend = AgyBackend()
    _ = backend.launch(start())
    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)

    _ = backend.receive(
      try line(
        #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"Antigravity ACP Server","version":"1.5.18"}}}"#
      ),
      from: process, at: .now)
    _ = try backend.send(
      .prompt(text: "hi", context: [], uuid: "p-1", attachments: []), to: process)

    let opened = backend.receive(
      try line(
        #"""
        {"jsonrpc":"2.0","id":2,"result":{"sessionId":"agy-1","models":{"currentModelId":"gemini-4-neon-high","availableModels":[{"modelId":"gemini-4-neon-high","name":"Gemini 4 Neon (High)"}]},"modes":{"currentModeId":"default"},"configOptions":[{"id":"model","currentValue":"gemini-4-neon","options":[{"value":"gemini-4-neon","name":"Gemini 4 Neon"}]},{"id":"thought_level","currentValue":"high","options":[{"value":"high","name":"High"}]},{"id":"mode","currentValue":"default"}]}}
        """#),
      from: process, at: .now)
    #expect(
      opened.signals.contains(
        .models([
          ModelOption(
            value: "gemini-4-neon", resolvedModel: "gemini-4-neon", displayName: "Gemini 4 Neon",
            supportsAutoMode: true, effortLevels: ["high"])
        ])))
    #expect(opened.signals.contains(.modeAdopted("acceptEdits")))
    #expect(opened.events.contains { if case .sessionStarted = $0 { true } else { false } })

    let target = backend.locateTarget(sessionID: "agy-1", cwd: "/p", in: [])
    #expect(target?.agentKind == .agy)
    #expect(target?.sessionID == "agy-1")
  }

  @Test func liveModelAndModePicksReturnRequestIDs() throws {
    let backend = AgyBackend()
    _ = backend.launch(start())
    let process = try process()
    defer { process.terminate() }
    try backend.started(process, then: nil)
    _ = backend.receive(
      try line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#), from: process,
      at: .now)
    _ = try backend.send(
      .prompt(text: "hi", context: [], uuid: "p-1", attachments: []), to: process)
    _ = backend.receive(
      try line(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"agy-1"}}"#), from: process,
      at: .now)

    let modeReq = try backend.send(.setMode("plan"), to: process)
    #expect(modeReq != nil)
    let modelReq = try backend.send(.setModel("gemini-3.8-flash"), to: process)
    #expect(modelReq != nil)
    let effortReq = try backend.send(.setEffort("low"), to: process)
    #expect(effortReq != nil)
  }

  @Test func historyReturnsReplayedPromptWhenLoadCompletes() async throws {
    let server = #"""
      read -r initialize
      echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
      read -r load
      case "$load" in *session*load*) ;; *) exit 1 ;; esac
      echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"saved prompt"}}}}'
      echo '{"jsonrpc":"2.0","id":2,"result":{}}'
      """#
    let events = try await AgyHistory.events(
      sessionID: "saved", cwd: "/tmp",
      configuration: .init(
        executable: URL(filePath: "/bin/sh"), arguments: ["-c", server], environment: [:],
        currentDirectory: URL(filePath: "/tmp")))
    #expect(
      events.contains { event in
        guard case .prompt(let prompt, _) = event else { return false }
        return prompt.text == "saved prompt"
      })
  }

  @Test func antigravityAndGrokHaveDefaultModelsOfTheirOwn() {
    ClaudeChoice.$testSuite.withValue("agy-model-\(UUID())") {
      ClaudeChoice.defaults.set("claude-opus-5-5", forKey: PreferenceKey.defaultModel)
      ClaudeChoice.defaults.set("gemini-4-hydrogen", forKey: PreferenceKey.agyDefaultModel)
      ClaudeChoice.defaults.set("grok-4.7-build-fast", forKey: PreferenceKey.grokDefaultModel)
      let agy = AgentSession(folder: URL(filePath: "/p"), agent: .agy)
      let grok = AgentSession(folder: URL(filePath: "/p"), agent: .grok)
      #expect(agy.pickedModel == "gemini-4-hydrogen")
      #expect(grok.pickedModel == "grok-4.7-build-fast")
      agy.setModel("gemini-3.8-flash")
      #expect(agy.pickedModel == "gemini-3.8-flash")
      #expect(ClaudeChoice.agyDefaultModel == "gemini-4-hydrogen")
    }
  }

  @Test func featuresAndTargetRoundTrip() throws {
    #expect(AgyBackend().features == .agy)
    #expect(AgyBackend(agent: .grok).features == .grok)
    #expect(AgentFeatures.agy.cancelsQueued)
    #expect(AgentFeatures.agy.picksApplyAtOnce)
    #expect(AgentFeatures.agy.slashCommands)
    #expect(AgentFeatures.grok.slashCommands)
    #expect(!AgentFeatures.agy.acceptsPDF)
    #expect(AgentKind.agy.name == "Antigravity")

    let target = ResumeTarget(
      sessionID: "agy-1", cwd: "/p", file: "", accountDirectory: "/a", accountIsDefault: true,
      agent: .agy)
    let decoded = try JSONDecoder().decode(ResumeTarget.self, from: JSONEncoder().encode(target))
    #expect(decoded.agentKind == .agy)
  }

  @Test func grokAndAgySkillStoresStaySeparatePerFolder() {
    let folder = URL(filePath: "/tmp/drakar-grok-skills-\(UUID().uuidString)")
    let agyEntry = AgySkillStore.shared.skills(for: folder, agent: .agy)
    let grokEntry = AgySkillStore.shared.skills(for: folder, agent: .grok)
    #expect(agyEntry !== grokEntry)
    #expect(agyEntry.agent == .agy)
    #expect(grokEntry.agent == .grok)

    let backend = AgyBackend(agent: .grok)
    _ = backend.launch(
      AgentStart(
        folder: folder, resuming: nil, environment: [:],
        executableOverride: URL(filePath: "/bin/true"), model: nil, mode: nil, effort: nil,
        allowsBypass: true, name: nil))
    let update = JSONValue.object([
      "jsonrpc": .string("2.0"),
      "method": .string("session/update"),
      "params": .object([
        "sessionId": .string("g-1"),
        "update": .object([
          "sessionUpdate": .string("available_commands_update"),
          "availableCommands": .array([
            .object(["name": .string("commit-task"), "description": .string("Commit")])
          ]),
        ]),
      ]),
    ])
    _ = backend.receive(
      .json(update),
      from: AgentProcess(
        AgyLaunch.configuration(
          executable: URL(filePath: "/bin/true"), environment: [:], folder: folder, agent: .grok)),
      at: .now)
    #expect(grokEntry.skills?.map(\.name) == ["commit-task"])
    #expect(agyEntry.skills == nil)
  }
}
