import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// The probe against stand-in `claude`s: scripts that answer, stall or fail.
@MainActor
@Suite("Asking a project's claude what it would load")
struct CapabilityProbeTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func standIn(_ body: String) throws -> URL {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  private let initialize =
    #"{"type":"control_response","response":{"subtype":"success","request_id":"probe-init","response":{"commands":[{"name":"check","description":"Fix it","argumentHint":""},{"name":"compact","description":"","argumentHint":"","builtin":true}]}}}"#
  private let status =
    #"{"type":"control_response","response":{"subtype":"success","request_id":"probe-mcp","response":{"mcpServers":[{"name":"armada","status":"connected","config":{"headers":{"Authorization":"Bearer x"}}}]}}}"#

  /// Both replies, then the input closes: the stand-in's `cat` ends and it runs to its end,
  /// which is how the real CLI takes its registry entry down.
  @Test func readsBothRepliesThenLetsTheProcessGo() async throws {
    let claude = try standIn(
      "read a\nread b\necho '\(initialize)'\necho '\(status)'\ncat > /dev/null\ntouch \"$0.ended\"")
    let outcome = await CapabilityProbe.run(folder: folder, executableOverride: claude)
    #expect(outcome.capabilities.skills?.map(\.name) == ["check"])
    #expect(outcome.capabilities.mcpServers?.map(\.name) == ["armada"])
    #expect(outcome.skillsProblem == nil)
    #expect(outcome.serversProblem == nil)
    #expect(exists(claude.appendingPathExtension("ended")))
  }

  private func pending(_ id: String) -> String {
    #"{"type":"control_response","response":{"subtype":"success","request_id":""# + id
      + #"","response":{"mcpServers":[{"name":"armada","status":"pending"}]}}}"#
  }

  /// A server still connecting at the first `mcp_status`: asked again, its later status is
  /// the one shown.
  @Test func asksAgainWhileAServerIsConnecting() async throws {
    let connected = status.replacingOccurrences(of: "probe-mcp", with: "probe-mcp-2")
    let claude = try standIn(
      "read a\nread b\necho '\(initialize)'\necho '\(pending("probe-mcp"))'\nread c\n"
        + "case \"$c\" in *probe-mcp-2*) echo '\(connected)';; esac\ncat > /dev/null")
    let outcome = await CapabilityProbe.run(
      folder: folder, executableOverride: claude, grace: .milliseconds(200))
    #expect(outcome.capabilities.mcpServers?.map(\.status) == [.connected])
    #expect(outcome.serversProblem == nil)
  }

  /// One that never connects: the probe still ends, the server shown as connecting.
  @Test func endsWhileAServerStaysPending() async throws {
    let claude = try standIn(
      "read a\nread b\necho '\(initialize)'\necho '\(pending("probe-mcp"))'\n"
        + "while read c; do echo '\(pending("probe-mcp-2"))'; done")
    let started = ContinuousClock.now
    let outcome = await CapabilityProbe.run(
      folder: folder, executableOverride: claude, grace: .milliseconds(200),
      connectingLimit: .milliseconds(1500))
    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(outcome.capabilities.skills?.map(\.name) == ["check"])
    #expect(outcome.capabilities.mcpServers?.map(\.status) == [.pending])
  }

  /// An older CLI that never answers `mcp_status`: the skills are kept, the servers pane
  /// says why.
  @Test func keepsTheSkillsWhenTheStatusNeverComes() async throws {
    let claude = try standIn("read a\necho '\(initialize)'\nexec sleep 30")
    let outcome = await CapabilityProbe.run(
      folder: folder, executableOverride: claude, timeout: .seconds(1), grace: .milliseconds(200))
    #expect(outcome.capabilities.skills?.map(\.name) == ["check"])
    #expect(outcome.skillsProblem == nil)
    #expect(
      outcome.serversProblem == "Couldn't read MCP status. Claude Code took too long to answer.")
  }

  @Test func saysWhyWhenTheProcessFails() async throws {
    let claude = try standIn("read a\necho 'not signed in' >&2\nexit 1")
    let outcome = await CapabilityProbe.run(folder: folder, executableOverride: claude)
    #expect(outcome.capabilities == ProjectCapabilities())
    #expect(outcome.skillsProblem == "Couldn't read skills. Claude Code exited with status 1.")
    #expect(
      outcome.serversProblem == "Couldn't read MCP status. Claude Code exited with status 1.")
    #expect(outcome.diagnostics.contains("not signed in"))
  }

  @Test func saysWhenTheFolderIsGone() async {
    let gone = folder.appending(path: "gone", directoryHint: .isDirectory)
    let outcome = await CapabilityProbe.run(folder: gone)
    #expect(outcome.skillsProblem == "The folder gone no longer exists.")
    #expect(outcome.serversProblem == "The folder gone no longer exists.")
  }

  /// A window closed mid-probe: input closed first, so the CLI can exit on its own.
  @Test func aCancelledProbeLetsTheProcessGo() async throws {
    let claude = try standIn(
      "touch \"$0.started\"\ncat > /dev/null\ntouch \"$0.closed\"\nexec sleep 30")
    let started = claude.appendingPathExtension("started")
    let closed = claude.appendingPathExtension("closed")
    let probe = Task {
      await CapabilityProbe.run(
        folder: folder, executableOverride: claude, grace: .milliseconds(200))
    }
    // Cancelled once the process runs, however long the shell environment took to load.
    for _ in 0..<200 where !exists(started) {
      try await Task.sleep(for: .milliseconds(25))
    }
    try #require(exists(started))
    probe.cancel()
    _ = await probe.value
    for _ in 0..<40 where !exists(closed) {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(exists(closed))
  }

  /// Cancelled before it starts: the task body cannot run before the test's next await (both
  /// are on the main actor), so it always begins cancelled, and no `claude` is launched.
  @Test func aProbeCancelledBeforeItStartsLaunchesNothing() async throws {
    let claude = try standIn("touch \"$0.started\"\ncat > /dev/null")
    let probe = Task {
      await CapabilityProbe.run(
        folder: folder, executableOverride: claude, grace: .milliseconds(200))
    }
    probe.cancel()
    _ = await probe.value
    try await Task.sleep(for: .milliseconds(500))
    #expect(!exists(claude.appendingPathExtension("started")))
  }
}
