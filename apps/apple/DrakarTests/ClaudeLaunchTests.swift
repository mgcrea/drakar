import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// What a `claude` in a folder runs: the probe and a new session must agree on it.
@MainActor
@Suite("Starting claude for a folder")
struct ClaudeLaunchTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// The folder's pick wins over Settings, and reaches the environment.
  @Test func runsUnderTheFoldersPick() throws {
    let picked = folder.appending(path: ".claude-picked", directoryHint: .isDirectory)
    let settings = folder.appending(path: ".claude-settings", directoryHint: .isDirectory)
    for directory in [picked, settings] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(settings.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
    defer { defaults.removePersistentDomain(forName: suite) }

    let launch = ClaudeChoice.$testSuite.withValue(suite) {
      ClaudeChoice.pick(ClaudeChoice.account(at: picked.path(percentEncoded: false)), for: folder)
      return ClaudeLaunch.make(
        folder: folder, resuming: nil, environment: ["PATH": "/usr/bin"],
        executableOverride: URL(filePath: "/bin/echo"))
    }
    #expect(launch.account?.name == "picked")
    #expect(launch.environment["CLAUDE_CONFIG_DIR"]?.hasSuffix(".claude-picked") == true)
    #expect(launch.environment["PATH"] == "/usr/bin")
    #expect(launch.executable == URL(filePath: "/bin/echo"))
  }

  /// The probe runs under the account its lists are kept for, whatever the folder's pick.
  @Test func anExplicitAccountWinsOverTheFoldersPick() throws {
    let picked = folder.appending(path: ".claude-picked", directoryHint: .isDirectory)
    let probed = folder.appending(path: ".claude-probed", directoryHint: .isDirectory)
    for directory in [picked, probed] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let launch = ClaudeChoice.$testSuite.withValue(suite) {
      ClaudeChoice.pick(ClaudeChoice.account(at: picked.path(percentEncoded: false)), for: folder)
      return ClaudeLaunch.make(
        folder: folder, resuming: nil,
        account: ClaudeChoice.account(at: probed.path(percentEncoded: false)),
        environment: ["CLAUDE_CONFIG_DIR": "/elsewhere"],
        executableOverride: URL(filePath: "/bin/echo"))
    }
    #expect(launch.account?.name == "probed")
    #expect(launch.environment["CLAUDE_CONFIG_DIR"]?.hasSuffix(".claude-probed") == true)
  }

  /// A resume runs where it was written, whatever the folder's pick.
  @Test func aResumeRunsUnderItsOwnAccount() throws {
    let writer = folder.appending(path: ".claude-writer", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: writer, withIntermediateDirectories: true)
    let target = ResumeTarget(
      sessionID: "s", cwd: folder.path(percentEncoded: false),
      file: writer.appending(path: "s.jsonl").path(percentEncoded: false),
      accountDirectory: writer.path(percentEncoded: false), accountIsDefault: false)
    let launch = ClaudeLaunch.make(
      folder: folder, resuming: target, environment: [:],
      executableOverride: URL(filePath: "/bin/echo"))
    #expect(launch.account?.name == "writer")
    #expect(launch.environment["CLAUDE_CONFIG_DIR"]?.hasSuffix(".claude-writer") == true)
  }

  /// Every `claude` keeps file checkpoints, so that a prompt's files can be rewound.
  @Test func checkpointsAreOn() {
    let launch = ClaudeLaunch.make(
      folder: folder, resuming: nil, environment: ["PATH": "/usr/bin"],
      executableOverride: URL(filePath: "/bin/echo"))
    #expect(launch.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "true")
  }

  /// The person's own switch, whatever its value, wins over Drakar's.
  @Test func aDisabledCheckpointWins() {
    let launch = ClaudeLaunch.make(
      folder: folder, resuming: nil,
      environment: ["PATH": "/usr/bin", "CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING": "1"],
      executableOverride: URL(filePath: "/bin/echo"))
    #expect(launch.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == nil)
    #expect(launch.environment["CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING"] == "1")
  }

  /// A switch the person set on themselves is theirs: kept as they wrote it. Beside the
  /// disable switch, both stay as they are and the disable switch still wins.
  @Test func anExplicitCheckpointSwitchIsKept() {
    let own = ClaudeLaunch.make(
      folder: folder, resuming: nil,
      environment: ["PATH": "/usr/bin", "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "1"],
      executableOverride: URL(filePath: "/bin/echo"))
    #expect(own.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "1")
    let off = ClaudeLaunch.make(
      folder: folder, resuming: nil,
      environment: ["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "false"],
      executableOverride: URL(filePath: "/bin/echo"))
    #expect(off.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "false")
    let both = ClaudeLaunch.make(
      folder: folder, resuming: nil,
      environment: [
        "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "1",
        "CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING": "1",
      ],
      executableOverride: URL(filePath: "/bin/echo"))
    #expect(both.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "1")
    #expect(both.environment["CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING"] == "1")
  }

  /// A runner's facts, its environment and its `claude` as its relay states them.
  private func runnerFacts(
    environment: [String: String], claude: [String] = ["/runner/bin/claude"]
  ) -> RunnerFacts {
    RunnerFacts(
      drakar: "9.9", build: "999", hostMajors: [HostWire.major], home: "/Users/r", user: "r",
      hostname: "studio", environment: environment, environmentFrom: .gui,
      claude: claude.map { ClaudeCandidate(path: $0, version: nil) },
      accounts: ["/Users/r/.claude", "/Users/r/.claude-work"])
  }

  /// A runner's `claude` runs on the runner's environment and binary alone: nothing of this
  /// Mac's, its own HOME and TMPDIR least of all, nor the account picked here in Settings.
  @Test func runnerSpawnCarriesNothingOfTheMac() throws {
    let mac = ProcessInfo.processInfo.environment
    let macTMPDIR = try #require(mac["TMPDIR"])
    #expect(mac["HOME"] != "/Users/r")
    // An account picked here in Settings, which a session of this Mac's would start under.
    let mine = folder.appending(path: ".claude-mine", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(mine.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
    defer { defaults.removePersistentDomain(forName: suite) }

    let facts = runnerFacts(environment: ["PATH": "/runner/bin", "HOME": "/Users/r"])
    let launch = ClaudeChoice.$testSuite.withValue(suite) {
      ClaudeLaunch.make(onRunner: facts, folder: folder, account: nil, executable: nil)
    }
    #expect(launch.executable == URL(filePath: "/runner/bin/claude"))
    #expect(launch.environment["HOME"] == "/Users/r")
    #expect(launch.environment["PATH"] == "/runner/bin")
    #expect(launch.environment["CLAUDE_CONFIG_DIR"] == nil)
    #expect(launch.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "true")
    #expect(!launch.environment.values.contains(macTMPDIR))
    // The runner's own default account, not this Mac's.
    #expect(launch.account?.key == "/Users/r/.claude")
    #expect(launch.account?.isDefault == true)

    // What the session's backend makes of it, and what a replay of its meta makes, on any
    // Mac: the same, with nothing read here.
    let start = AgentStart(
      folder: folder, environment: launch.environment, executableOverride: launch.executable,
      allowsBypass: false, account: launch.account, runner: UUID().uuidString)
    let configuration = try #require(
      ClaudeChoice.$testSuite.withValue(suite) { ClaudeBackend().launch(start) }.configuration)
    #expect(configuration.executable == URL(filePath: "/runner/bin/claude"))
    #expect(configuration.environment == launch.environment)
    #expect(configuration.currentDirectory == folder)
    #expect(!configuration.environment.values.contains(macTMPDIR))

    // A `claude` picked for the runner wins over the first one found there.
    let picked = ClaudeLaunch.make(
      onRunner: facts, folder: folder, account: nil, executable: "/opt/homebrew/bin/claude")
    #expect(picked.executable == URL(filePath: "/opt/homebrew/bin/claude"))
    // None found there is none: not looked for on this Mac.
    let none = ClaudeLaunch.make(
      onRunner: runnerFacts(environment: ["PATH": "/usr/bin"], claude: []), folder: folder,
      account: nil, executable: nil)
    #expect(none.executable == nil)
  }

  /// An account of the runner's is named to its `claude` by its directory there.
  @Test func aRunnerAccountNamesItsDirectory() {
    let work = ClaudeAccount(
      directory: URL(filePath: "/Users/r/.claude-work", directoryHint: .isDirectory),
      isDefault: false)
    let launch = ClaudeLaunch.make(
      onRunner: runnerFacts(environment: ["PATH": "/runner/bin", "HOME": "/Users/r"]),
      folder: folder, account: work, executable: nil)
    #expect(launch.environment["CLAUDE_CONFIG_DIR"] == "/Users/r/.claude-work")
    #expect(launch.account == work)
    // The runner shell's own directory is its account when none is picked.
    let shell = ClaudeLaunch.make(
      onRunner: runnerFacts(
        environment: ["PATH": "/runner/bin", "CLAUDE_CONFIG_DIR": "/Users/r/.claude-work"]),
      folder: folder, account: nil, executable: nil)
    #expect(shell.environment["CLAUDE_CONFIG_DIR"] == "/Users/r/.claude-work")
    #expect(shell.account?.key == "/Users/r/.claude-work")
    #expect(shell.account?.isDefault == false)
  }

  /// The capability probe is never prompted: it keeps no checkpoints, which would leave an
  /// empty `file-history/<id>/` folder for each probe. A session started the same way does.
  @Test func theProbeKeepsNoCheckpoints() {
    let probe = CapabilityProbe.launch(
      folder: folder, account: nil, environment: ["PATH": "/usr/bin"],
      executableOverride: URL(filePath: "/bin/echo"))
    #expect(probe.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == nil)
    // The person's own switch still reaches it.
    let own = CapabilityProbe.launch(
      folder: folder, account: nil,
      environment: ["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "1"],
      executableOverride: URL(filePath: "/bin/echo"))
    #expect(own.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "1")
    let session = ClaudeBackend().launch(
      AgentStart(
        folder: folder, resuming: nil, environment: ["PATH": "/usr/bin"],
        executableOverride: URL(filePath: "/bin/echo"), allowsBypass: false))
    #expect(
      session.configuration?.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "true")
  }
}
