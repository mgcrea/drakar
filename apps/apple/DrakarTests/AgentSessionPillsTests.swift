import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A session's mode and model")
struct AgentSessionPillsTests {

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

  /// A Codex pick mid-turn says when it takes, which is no refusal.
  @Test func aCodexPickMidTurnIsNotARefusal() async throws {
    let session = AgentSession(folder: folder, agent: .codex)
    session.executableOverride = try standIn("codex", "cat > /dev/null")
    session.send("working")
    defer { session.stop() }
    #expect(session.transcript.isRunning)
    session.setMode(.acceptEdits)
    #expect(session.pillNote == AgentSession.fromNextTurn)
    #expect(!session.pillNoteIsRefusal)
  }

  @Test func picksBeforeTheStartGoOnTheCommandLine() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      ClaudeChoice.defaults.set("sonnet", forKey: PreferenceKey.defaultModel)
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      session.setMode(.plan)
      #expect(session.shownMode == "plan")
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(args.contains("--model sonnet"))
      #expect(args.contains("--permission-mode plan"))
      #expect(args.contains("--allow-dangerously-skip-permissions"))
      // The session's pick is its own: Settings keeps its default.
      #expect(ClaudeChoice.defaultMode == nil)
    }
  }

  @Test func defaultsAddNothing() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      let session = AgentSession(folder: folder)
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
      let session = AgentSession(folder: folder)
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
      let session = AgentSession(folder: folder)
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
      let session = AgentSession(folder: folder)
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

  /// Review Focus 5: two changes in flight, the first refused and the second taken. The
  /// refusal puts back its own pick only, and says why. The stand-in waits for both, and its
  /// success carries no `mode`, so the pill is not set back by the CLI's echo.
  @Test func aRefusalLeavesALaterPick() async throws {
    try await scoped {
      let script = try standIn(
        "claude",
        """
        first=""
        while read -r line; do
          case "$line" in *set_permission_mode*)
            id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]*)".*/\\1/')
            if [ -z "$first" ]; then first=$id; continue; fi
            printf '%s\\n' "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"error\\",\\"request_id\\":\\"$first\\",\\"error\\":\\"Not launched for it\\"}}"
            printf '%s\\n' "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"success\\",\\"request_id\\":\\"$id\\"}}"
          esac
        done
        """)
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      session.setMode(.bypass)
      session.setMode(.plan)
      try await waitUntil { session.pillNote != nil }
      // Long enough for the success line, which follows the refusal, to land too.
      try await Task.sleep(for: .milliseconds(300))
      #expect(session.pillNote == "Not launched for it")
      #expect(session.modePick == .plan)
      #expect(session.shownMode == "plan")
    }
  }

  /// The CLI leaves Plan on its own once a plan is approved: the pill follows.
  @Test func aStatusLineMovesTheMode() async throws {
    try await scoped {
      let status =
        #"{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}"#
      let script = try standIn("claude", "read line\nprintf '%s\\n' '\(status)'\ncat > /dev/null")
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      try await waitUntil { session.permissionMode != nil }
      #expect(session.shownMode == "acceptEdits")
    }
  }

  /// A default changed in Settings does not relabel a session already running.
  @Test func aRunningSessionKeepsItsPicks() async throws {
    try await scoped {
      let script = try standIn("claude", #"cat > /dev/null"#)
      ClaudeChoice.defaults.set("sonnet", forKey: PreferenceKey.defaultModel)
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      ClaudeChoice.defaults.set("haiku", forKey: PreferenceKey.defaultModel)
      #expect(session.pickedModel == "sonnet")
    }
  }

  @Test func theStartListsTheAccountsModels() async throws {
    try await scoped {
      let reply =
        #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[],"models":[{"value":"default","displayName":"Default (recommended)"},{"value":"haiku","displayName":"Haiku 4.5"}]}}}"#
      let script = try standIn("claude", "read line\necho '\(reply)'\ncat > /dev/null")
      let catalog = ModelCatalog()
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      session.catalog = catalog
      await session.spawn()
      defer { session.stop() }
      let account = try #require(session.account)
      try await waitUntil { catalog.models(for: account) != nil }
      #expect(catalog.models(for: account)?.map(\.value) == ["default", "haiku"])
    }
  }

  /// Plan, approved: the CLI moves to Edit on its own, and a restart carries on there.
  @Test func aModeTheCLIChoseSurvivesARestart() async throws {
    try await scoped {
      let status =
        #"{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}"#
      let script = try standIn(
        "claude",
        "printf '%s\\n' \"$*\" >> \"$0.args\"\nread line\nprintf '%s\\n' '\(status)'\ncat > /dev/null"
      )
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      session.setMode(.plan)
      await session.spawn()
      try await waitUntil { session.permissionMode == "acceptEdits" }
      session.stop()
      #expect(session.shownMode == "acceptEdits")
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) {
        $0.split(separator: "\n").count >= 2
      }
      #expect(args.split(separator: "\n").last?.contains("--permission-mode acceptEdits") == true)
    }
  }

  /// `settings.json` may start it elsewhere than the pick: the pill says what the CLI says.
  @Test func theStartSaysWhichModeItIsIn() async throws {
    try await scoped {
      let reply =
        #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[],"current_permission_mode":"acceptEdits"}}}"#
      let script = try standIn("claude", "read line\necho '\(reply)'\ncat > /dev/null")
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      try await waitUntil { session.permissionMode != nil }
      #expect(session.shownMode == "acceptEdits")
    }
  }

  /// Bypass as Settings' default mode: new sessions start in it.
  @Test func startsInBypassWhenItIsTheDefault() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      ClaudeChoice.defaults.set("bypassPermissions", forKey: PreferenceKey.defaultMode)
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      #expect(session.shownMode == "bypassPermissions")
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(args.contains("--permission-mode bypassPermissions"))
      #expect(args.contains("--allow-dangerously-skip-permissions"))
    }
  }

  @Test func anEffortPickedBeforeTheStartGoesOnTheCommandLine() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      #expect(session.shownEffort == nil)
      session.setEffort("xhigh")
      #expect(session.shownEffort == "xhigh")
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(args.contains("--effort xhigh"))
    }
  }

  @Test func noEffortPickedAddsNothing() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      let args = try await read(script.appendingPathExtension("args")) { !$0.isEmpty }
      #expect(!args.contains("--effort"))
    }
  }

  /// Sent at once as a flag setting, then read back: the pill shows what the CLI applies.
  @Test func anEffortChangeWhileRunningIsSentAndReadBack() async throws {
    try await scoped {
      let script = try standIn("claude", #"cat >> "$0.stdin""#)
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      defer { session.stop() }
      session.setEffort("low")
      #expect(session.shownEffort == "low")
      let sent = try await read(script.appendingPathExtension("stdin")) {
        $0.components(separatedBy: "get_settings").count > 1
      }
      #expect(
        sent.contains(#""settings":{"effortLevel":"low"},"subtype":"apply_flag_settings""#))
    }
  }

  /// No pick: the level the process applies, from `settings.json` or the model's own.
  @Test func showsTheEffortTheProcessApplies() async throws {
    try await scoped {
      let script = try standIn(
        "claude",
        """
        while read -r line; do
          case "$line" in *get_settings*)
            id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]*)".*/\\1/')
            printf '%s\\n' "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"success\\",\\"request_id\\":\\"$id\\",\\"response\\":{\\"applied\\":{\\"effort\\":\\"high\\"}}}}"
          esac
        done
        """)
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      await session.spawn()
      try await waitUntil { session.shownEffort != nil }
      #expect(session.shownEffort == "high")
      // Ended: what the process applied went with it.
      session.stop()
      #expect(session.shownEffort == nil)
      #expect(session.appliedModel == nil)
    }
  }

  /// Settings' effort goes on the command line; a pick wins over it.
  @Test func startsWithSettingsEffort() async throws {
    try await scoped {
      let script = try standIn("claude", #"printf '%s\n' "$*" >> "$0.args"; cat > /dev/null"#)
      ClaudeChoice.defaults.set("max", forKey: PreferenceKey.defaultEffort)
      let session = AgentSession(folder: folder)
      session.executableOverride = script
      #expect(session.shownEffort == "max")
      await session.spawn()
      let args = script.appendingPathExtension("args")
      _ = try await read(args) { !$0.isEmpty }
      session.stop()
      session.setEffort("low")
      await session.spawn()
      defer { session.stop() }
      let runs = try await read(args) { $0.split(separator: "\n").count >= 2 }
        .split(separator: "\n")
      #expect(runs.first?.contains("--effort max") == true)
      #expect(runs.last?.contains("--effort low") == true)
    }
  }
}
