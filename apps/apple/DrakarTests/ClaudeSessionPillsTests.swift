import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A session's mode and model")
struct ClaudeSessionPillsTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-pills-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func standIn(_ name: String, _ body: String) throws -> URL {
    let script = folder.appending(path: name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// Settings in a scratch suite, Bypass as given.
  private func scoped(allowsBypass: Bool = true, _ body: () async throws -> Void) async rethrows {
    let suite = "drakar-pills-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(allowsBypass, forKey: PreferenceKey.allowsBypass)
    try await ClaudeChoice.$testSuite.withValue(suite, operation: body)
  }

  private func read(_ file: URL, until done: (String) -> Bool) async throws -> String {
    var text = ""
    for _ in 0..<50 {
      text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      if done(text) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    return text
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<50 where !condition() { try await Task.sleep(for: .milliseconds(100)) }
  }

  @Test func picksBeforeTheStartGoOnTheCommandLine() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      ClaudeChoice.pickModel("sonnet", for: folder)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      session.setMode(.plan)
      #expect(session.shownMode == "plan")
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(args.contains("--model sonnet"))
      #expect(args.contains("--permission-mode plan"))
      #expect(args.contains("--allow-dangerously-skip-permissions"))
      #expect(ClaudeChoice.sessionPicks(for: folder).mode == "plan")
    }
  }

  @Test func defaultsAddNothing() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      session.setModel("default")
      session.setMode(.ask)
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(!args.contains("--model"))
      #expect(!args.contains("--permission-mode"))
    }
  }

  /// Turned off in Settings after it was picked: the session starts in its folder's mode.
  @Test func bypassNeedsTheSetting() async throws {
    try await scoped(allowsBypass: false) {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      #expect(!session.offersBypass)
      session.setMode(.bypass)
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(!args.contains("--permission-mode"))
      #expect(!args.contains("--allow-dangerously-skip-permissions"))
    }
  }

  @Test func aChangeWhileRunningIsSent() async throws {
    try await scoped {
      let script = try standIn("claude", #"cat >> "$0.stdin""#)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      #expect(session.launchedWithBypass)
      session.setMode(.acceptEdits)
      session.setModel("haiku")
      let sent = try await read(script.appendingPathExtension("stdin")) {
        $0.contains("set_model")
      }
      #expect(sent.contains(#""mode":"acceptEdits","subtype":"set_permission_mode""#))
      #expect(sent.contains(#""model":"haiku","subtype":"set_model""#))
      #expect(session.shownMode == "acceptEdits")
    }
  }

  /// The CLI's refusal puts the pill back and says why.
  @Test func aRefusedChangeGoesBack() async throws {
    try await scoped {
      let script = try standIn(
        "claude",
        """
        while read -r line; do
          case "$line" in *set_permission_mode*)
            id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]*)".*/\\1/')
            printf '%s\\n' "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"error\\",\\"request_id\\":\\"$id\\",\\"error\\":\\"Not launched for it\\"}}"
          esac
        done
        """)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      session.setMode(.plan)
      #expect(session.shownMode == "plan")
      try await waitUntil { session.pillNote != nil }
      #expect(session.pillNote == "Not launched for it")
      #expect(session.modePick == nil)
      #expect(session.shownMode == "default")
    }
  }

  /// The CLI leaves Plan on its own once a plan is approved: the pill follows.
  @Test func aStatusLineMovesTheMode() async throws {
    try await scoped {
      let status =
        #"{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}"#
      let script = try standIn("claude", "read line\nprintf '%s\\n' '\(status)'\ncat > /dev/null")
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      try await waitUntil { session.permissionMode != nil }
      #expect(session.shownMode == "acceptEdits")
    }
  }

  /// Another window picking for the folder does not relabel a session already running.
  @Test func aRunningSessionKeepsItsPicks() async throws {
    try await scoped {
      let script = try standIn("claude", #"cat > /dev/null"#)
      ClaudeChoice.pickModel("sonnet", for: folder)
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      ClaudeChoice.pickModel("haiku", for: folder)
      #expect(session.pickedModel == "sonnet")
    }
  }

  @Test func theStartListsTheAccountsModels() async throws {
    try await scoped {
      let reply =
        #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[],"models":[{"value":"default","displayName":"Default (recommended)"},{"value":"haiku","displayName":"Haiku 4.5"}]}}}"#
      let script = try standIn("claude", "read line\necho '\(reply)'\ncat > /dev/null")
      let catalog = ModelCatalog()
      let session = ClaudeSession(folder: folder)
      session.executableOverride = script
      session.catalog = catalog
      await session.spawn()
      defer { session.stop() }
      let account = try #require(session.account)
      try await waitUntil { catalog.models(for: account) != nil }
      #expect(catalog.models(for: account)?.map(\.value) == ["default", "haiku"])
    }
  }
}
