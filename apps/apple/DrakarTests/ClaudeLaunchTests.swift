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
