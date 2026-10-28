import DrakarKit
import Foundation
import Testing

@Suite("Starting claude")
struct ClaudeCommandTests {

  @Test func allowsBypassOnlyWhenAsked() {
    #expect(!ClaudeCommand().arguments.contains("--allow-dangerously-skip-permissions"))
    var command = ClaudeCommand()
    command.allowsBypass = true
    #expect(command.arguments.contains("--allow-dangerously-skip-permissions"))
  }

  @Test func passesEffortWhenAsked() {
    #expect(!ClaudeCommand().arguments.contains("--effort"))
    var command = ClaudeCommand()
    command.effort = "xhigh"
    #expect(command.arguments.joined(separator: " ").contains("--effort xhigh"))
  }

  @Test func passesTheExtensionsArguments() {
    #expect(
      ClaudeCommand().arguments == [
        "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
        "--permission-prompt-tool", "stdio", "--include-partial-messages",
        "--thinking-display", "summarized",
      ])
  }

  @Test func resumesWithOneArgument() {
    let arguments = ClaudeCommand(resumeSessionID: "abc", model: "opus").arguments
    #expect(arguments.suffix(3) == ["--model", "opus", "--resume=abc"])
  }

  @Test func looksOnThePathBeforeTheKnownLocations() {
    let home = URL(filePath: "/Users/me")
    let candidates = ClaudeLocator.candidates(home: home, path: "/custom/bin:/opt/homebrew/bin")
    #expect(candidates.first?.path == "/custom/bin/claude")
    #expect(candidates[1].path == "/opt/homebrew/bin/claude")
    // Homebrew's directory was on the PATH, so its known location is not listed twice.
    #expect(candidates.filter { $0.path == "/opt/homebrew/bin/claude" }.count == 1)
    #expect(candidates.contains { $0.path == "/Users/me/.local/bin/claude" })
  }

  @Test func locatesTheFirstExecutable() {
    let found = ClaudeLocator.locate(
      home: URL(filePath: "/Users/me"), path: "/nope",
      isExecutable: { $0.path == "/opt/homebrew/bin/claude" || $0.path == "/usr/local/bin/claude" })
    #expect(found?.path == "/opt/homebrew/bin/claude")
  }

  @Test func prefersThePickedOneWhileItIsThere() {
    let home = URL(filePath: "/Users/me")
    let picked = URL(filePath: "/opt/homebrew/bin/claude")
    let everywhere = ClaudeLocator.locate(
      preferred: picked, home: home, path: "/Users/me/.local/bin", isExecutable: { _ in true })
    #expect(everywhere == picked)
    // Uninstalled since: what the shell would run.
    let gone = ClaudeLocator.locate(
      preferred: picked, home: home, path: "/Users/me/.local/bin",
      isExecutable: { $0 != picked })
    #expect(gone?.path == "/Users/me/.local/bin/claude")
  }

  @Test func listsEachInstallOnce() {
    let installed = ClaudeLocator.installed(
      home: URL(filePath: "/Users/me"), path: "/opt/homebrew/bin:/opt/homebrew/bin",
      isExecutable: { $0.path != "/Users/me/.bun/bin/claude" },
      resolve: {
        // The Homebrew link and /usr/local/bin both lead to the cask's binary.
        $0.path == "/usr/local/bin/claude"
          ? URL(filePath: "/opt/homebrew/bin/claude") : $0
      })
    #expect(
      installed.map(\.path) == [
        "/opt/homebrew/bin/claude", "/Users/me/.local/bin/claude",
        "/Users/me/.claude/local/claude", "/Users/me/.npm-global/bin/claude",
      ])
  }

  @Test func readsTheEnvironmentAfterTheShellsBanner() throws {
    let data = Data("Welcome to zsh!\n__DRAKAR_ENV__PATH=/a:/b\0HOME=/Users/me\0EMPTY=\0".utf8)
    let environment = try #require(ShellEnvironment.parse(data))
    #expect(environment["PATH"] == "/a:/b")
    #expect(environment["HOME"] == "/Users/me")
    #expect(environment["EMPTY"] == "")
    #expect(ShellEnvironment.parse(Data("no marker".utf8)) == nil)
  }
}

/// Which `ProcessTransport` a test runs its stand-in agent through.
enum Transport: String, CaseIterable, CustomTestStringConvertible, Sendable {
  case child, hosted

  var testDescription: String { rawValue }

  /// A transport for `configuration`; a hosted one comes with the host to close afterwards.
  func make(_ configuration: AgentProcess.Configuration) async throws
    -> (any ProcessTransport, TestHost?)
  {
    switch self {
    case .child:
      return (AgentProcess(configuration), nil)
    case .hosted:
      let host = try TestHost()
      let client = try host.connect()
      _ = try await client.hello(appVersion: "test")
      return (HostedProcess(client: client, configuration: configuration, meta: Data()), host)
    }
  }
}

/// A transport against stand-in agents: `cat` replays a capture or echoes what it is sent,
/// `sh` misbehaves on purpose. Real pipes, and for a hosted one a real socket.
@Suite("Supervising the process", .timeLimit(.minutes(1)))
struct AgentProcessTests {

  private func configuration(_ executable: String, _ arguments: [String])
    -> AgentProcess.Configuration
  {
    .init(
      executable: URL(filePath: executable), arguments: arguments, environment: [:],
      currentDirectory: FileManager.default.temporaryDirectory)
  }

  private func run(
    _ transport: Transport, _ executable: String, _ arguments: [String],
    sending: [ClientMessage] = []
  ) async throws -> [AgentProcess.Event] {
    let (process, host) = try await transport.make(configuration(executable, arguments))
    defer { host?.close() }
    let events = try process.start()
    for message in sending { try process.send(message) }
    process.closeInput()
    var collected: [AgentProcess.Event] = []
    for await event in events { collected.append(event) }
    return collected
  }

  private func messages(_ events: [AgentProcess.Event]) -> [StreamMessage] {
    events.flatMap { event -> [StreamMessage] in
      if case .lines(let batch, _) = event { return batch.map(StreamMessage.init) }
      return []
    }
  }

  @Test(arguments: Transport.allCases)
  func deliversEveryLineThenTheExit(_ transport: Transport) async throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "turn-with-tool", withExtension: "jsonl", subdirectory: "Fixtures"))
    let events = try await run(transport, "/bin/cat", [url.path])
    #expect(messages(events) == (try Fixture.turnWithTool.messages))
    #expect(events.last == .exited(status: 0, remainder: Data()))
  }

  @Test(arguments: Transport.allCases)
  func aLineIsTimedWhenRead(_ transport: Transport) async throws {
    let before = Date()
    let events = try await run(transport, "/bin/echo", ["{}"])
    let received = Date()
    let times = events.compactMap { event -> Date? in
      if case .lines(_, let time) = event { return time }
      return nil
    }
    let time = try #require(times.first)
    #expect(time >= before && time <= received)
  }

  @Test(arguments: Transport.allCases)
  func whatItSendsArrivesAsOneLine(_ transport: Transport) async throws {
    let events = try await run(transport, "/bin/cat", [], sending: [.prompt("hello")])
    guard case .user(let user) = messages(events).first else {
      Issue.record("got \(events)")
      return
    }
    #expect(user.content == [.text("hello")])
  }

  @Test(arguments: Transport.allCases)
  func keepsStderrAndAnUnterminatedTail(_ transport: Transport) async throws {
    let events = try await run(
      transport, "/bin/sh", ["-c", "echo not-json; echo oops >&2; printf partial; exit 3"])
    #expect(events.contains(.stderr("oops\n")))
    switch transport {
    case .child:
      #expect(
        messages(events) == [.unknown(type: "invalid-line", raw: .string("not-json"))])
      #expect(events.last == .exited(status: 3, remainder: Data("partial".utf8)))
    case .hosted:
      // The host logs the tail as a line of its own, so the exit has none to carry.
      #expect(
        messages(events) == [
          .unknown(type: "invalid-line", raw: .string("not-json")),
          .unknown(type: "invalid-line", raw: .string("partial")),
        ])
      #expect(events.last == .exited(status: 3, remainder: Data()))
    }
  }

  @Test(arguments: Transport.allCases)
  func textThatIsNotJSONKeepsNoTerminator(_ transport: Transport) async throws {
    let events = try await run(transport, "/bin/echo", ["text"])
    #expect(events.contains(.lines([.invalid("text")], at: try #require(time(of: events)))))
  }

  private func time(of events: [AgentProcess.Event]) -> Date? {
    for case .lines(_, let time) in events { return time }
    return nil
  }

  @Test(arguments: Transport.allCases)
  func endingInputEndsCat(_ transport: Transport) async throws {
    // `run` closes input and waits for the exit: a `cat` that kept reading would hang it.
    let events = try await run(transport, "/bin/cat", [])
    #expect(events.last == .exited(status: 0, remainder: Data()))
  }

  @Test(arguments: Transport.allCases)
  func terminateEndsAProcessThatWouldNot(_ transport: Transport) async throws {
    let (process, host) = try await transport.make(configuration("/bin/sleep", ["30"]))
    defer { host?.close() }
    let events = try process.start()
    process.terminate()
    var status: Int32?
    for await event in events {
      if case .exited(let code, _) = event { status = code }
    }
    #expect(try #require(status) != 0)
    #expect(!process.isRunning)
  }

  @Test(arguments: Transport.allCases)
  func refusesToSendOnceTheProcessIsGone(_ transport: Transport) async throws {
    let (process, host) = try await transport.make(configuration("/usr/bin/true", []))
    defer { host?.close() }
    for await _ in try process.start() {}
    #expect(throws: AgentProcess.Failure.notRunning) { try process.send(.prompt("late")) }
  }
}

@Suite("Claude Code versions")
struct ClaudeVersionTests {

  @Test func readsBothSpellings() throws {
    #expect(ClaudeVersion("2.1.288")?.description == "2.1.288")
    #expect(ClaudeVersion("2.1.222 (Claude Code)\n")?.description == "2.1.222")
    #expect(ClaudeVersion("") == nil)
    #expect(ClaudeVersion("claude: command not found") == nil)
    #expect(ClaudeVersion("2..1") == nil)
  }

  @Test func comparesNumbersNotText() throws {
    let v = { (text: String) in ClaudeVersion(text)! }
    #expect(v("2.1.288") < v("2.1.1000"))
    #expect(v("2.1.288") < v("2.2"))
    #expect(v("2.1") == v("2.1.0"))
  }

  @Test func saysWhichSideOfTheTestedRange() throws {
    #expect(ClaudeVersion("2.1.222")?.drift == .older)
    #expect(ClaudeVersion("2.1.284")?.drift == nil)
    #expect(ClaudeVersion("2.1.312")?.drift == nil)
    #expect(ClaudeVersion("2.1.313")?.drift == .newer)
    #expect(ClaudeVersion("3.0.0")?.drift == .newer)
  }

  @Test func asksTheBinary() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-version-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fake = folder.appending(path: "claude")
    try Data("#!/bin/sh\necho \"9.8.7 (Claude Code)\"\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    #expect(await ClaudeVersion.read(of: fake, environment: [:])?.description == "9.8.7")

    let silent = folder.appending(path: "silent")
    try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: silent)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent.path)
    #expect(
      await ClaudeVersion.read(of: silent, environment: [:], timeout: .milliseconds(200)) == nil)
  }
}
