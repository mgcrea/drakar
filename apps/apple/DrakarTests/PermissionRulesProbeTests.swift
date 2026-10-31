import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// The rules probe against stand-in `claude`s that answer, refuse or stall.
@MainActor
@Suite("Reading a project's permission rules with no session running")
struct PermissionRulesProbeTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-rules-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func standIn(_ body: String) throws -> URL {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// A stand-in that answers the line asking for the rules with `reply`, then reads on until
  /// its input closes.
  private func answering(_ reply: String) throws -> URL {
    try standIn(
      "while read line; do\n  case \"$line\" in *list_permission_rules*) echo '\(reply)';; esac\n"
        + "done")
  }

  /// The spec's real reply: a project with a local allow and deny.
  private let listing =
    #"{"type":"control_response","response":{"subtype":"success","request_id":"rules-probe-list","response":{"state":{"rules":[{"behavior":"allow","source":"localSettings","rule":"Bash(npm run test:*)","description":{"prefix":"Any Bash command starting with ","emphasis":"npm run test"},"editability":"persistent"},{"behavior":"deny","source":"localSettings","rule":"Read(./secrets/**)","editability":"persistent"}],"workspaceDirectories":[],"originalCwd":"/tmp/rules","managedOnly":false}}}}"#

  @Test func readsTheListing() async throws {
    let claude = try answering(listing)
    let answer = await PermissionRulesProbe.run(
      folder: folder, account: nil, executableOverride: claude)
    guard case .listed(let state) = answer else {
      Issue.record("Expected a listing, got \(answer)")
      return
    }
    #expect(state.rules.map(\.rule) == ["Bash(npm run test:*)", "Read(./secrets/**)"])
    #expect(state.rules.map(\.behavior) == [.allow, .deny])
  }

  @Test func aRefusalIsSaid() async throws {
    let claude = try answering(
      #"{"type":"control_response","response":{"subtype":"error","request_id":"rules-probe-list","error":"nope"}}"#
    )
    let answer = await PermissionRulesProbe.run(
      folder: folder, account: nil, executableOverride: claude)
    #expect(answer == .refused("nope"))
  }

  @Test func aSilentClaudeTimesOut() async throws {
    let claude = try standIn("exec sleep 30")
    let answer = await PermissionRulesProbe.run(
      folder: folder, account: nil, executableOverride: claude, timeout: .milliseconds(500))
    #expect(answer == .refused("Claude Code took too long to answer."))
  }

  @Test func anEarlyExitIsSaid() async throws {
    let claude = try standIn("read a\nexit 2")
    let answer = await PermissionRulesProbe.run(
      folder: folder, account: nil, executableOverride: claude)
    #expect(answer == .refused("Claude Code exited with status 2."))
  }

  @Test func aMissingFolderIsSaid() async {
    let gone = folder.appending(path: "gone", directoryHint: .isDirectory)
    let answer = await PermissionRulesProbe.run(
      folder: gone, account: nil, executableOverride: nil)
    #expect(answer == .refused("The folder gone no longer exists."))
  }
}
