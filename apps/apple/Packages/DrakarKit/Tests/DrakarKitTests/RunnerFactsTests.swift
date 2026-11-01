import Foundation
import Testing

@testable import DrakarKit

@Suite struct RunnerFactsTests {
  private let facts = RunnerFacts(
    relay: RunnerFacts.relayVersion, drakar: "1.4.0", build: "212", hostMajors: [1],
    home: "/Users/runner", user: "runner", hostname: "studio.local",
    environment: ["PATH": "/usr/bin:/bin", "MULTI": "a\nb"], environmentFrom: .gui,
    claude: [
      ClaudeCandidate(path: "/Users/runner/.local/bin/claude", version: "2.1.0"),
      ClaudeCandidate(path: "/opt/homebrew/bin/claude", version: nil),
    ],
    accounts: ["/Users/runner/.claude", "/Users/runner/.claude-work"])

  @Test func factsSurviveTheirLine() throws {
    let line = try facts.line()
    #expect(line.last == UInt8(ascii: "\n"))
    #expect(line.filter { $0 == UInt8(ascii: "\n") }.count == 1)
    #expect(try RunnerFacts.parse(line) == facts)
  }

  @Test func aLineOfAnotherShapeIsRefused() {
    #expect(throws: (any Error).self) { try RunnerFacts.parse(Data("{}\n".utf8)) }
  }

  @Test func withoutSSHDropsTheSessionsVariables() {
    let environment = [
      "SSH_CONNECTION": "10.0.0.2 52000 10.0.0.3 22", "SSH_CLIENT": "10.0.0.2 52000 22",
      "SSH_TTY": "/dev/ttys004", "SSH_AUTH_SOCK": "/tmp/ssh-x/agent.1",
      "PATH": "/usr/bin:/bin", "HOME": "/Users/runner",
    ]
    #expect(
      RunnerEnvironment.withoutSSH(environment) == [
        "PATH": "/usr/bin:/bin", "HOME": "/Users/runner",
      ])
  }

  @Test func theEnvironmentFileIsOwnersOnly() throws {
    let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
      "runner-env-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: appSupport) }
    let url = RunnerEnvironment.file(in: appSupport)
    #expect(url.lastPathComponent == RunnerEnvironment.fileName)
    #expect(RunnerEnvironment.read(from: url) == nil)

    let environment = ["PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/private/tmp/launchd/Listeners"]
    try RunnerEnvironment.write(environment, to: url)
    var info = stat()
    #expect(stat(url.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(RunnerEnvironment.read(from: url) == environment)

    // A rewrite replaces the file whole and keeps it owner's only.
    try RunnerEnvironment.write(["PATH": "/bin"], to: url)
    #expect(stat(url.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(RunnerEnvironment.read(from: url) == ["PATH": "/bin"])
  }
}
