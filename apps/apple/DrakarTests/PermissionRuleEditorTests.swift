import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// `claude edit-permission-rules` through stand-ins: scripts that save, refuse or stall.
/// Never the real `claude`: it would write the person's settings files.
@MainActor
@Suite("Saving a permission rule through claude")
struct PermissionRuleEditorTests {

  private let folder: URL
  /// The base environment each edit runs from, in place of the login shell's.
  private let environment = ["PATH": "/usr/bin:/bin"]

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-rule-editor-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func standIn(_ body: String) throws -> URL {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private let add = PermissionRuleEdit.add(
    rules: ["Bash(npm run test:*)"], behavior: .allow, file: .localSettings)

  @Test func sendsTheEditAndReadsTheOutcome() async throws {
    let claude = try standIn(
      "{ pwd -P; echo \"$@\"; cat; } > \"$0.seen\"\necho 'saving'\n"
        + #"echo '{"ok":true,"warnings":[],"stored":["A"]}'"#)
    let outcome = await PermissionRuleEditor.apply(
      add, folder: folder, account: nil, executableOverride: claude, environment: environment)
    #expect(outcome == .saved(warnings: [], stored: ["A"]))
    let seen = try String(
      contentsOf: claude.appendingPathExtension("seen"), encoding: .utf8)
    let lines = seen.split(separator: "\n").map(String.init)
    let resolved = try #require(realpath(folder.path(percentEncoded: false), nil))
    defer { free(resolved) }
    #expect(lines.first == String(cString: resolved))
    #expect(lines.dropFirst().first == "edit-permission-rules --json")
    let sent = try JSONValue.parse(Data(lines.dropFirst(2).joined(separator: "\n").utf8))
    #expect(sent == add.json)
  }

  /// Drakar runs inside a Claude Code session in development, and `claude` refuses to edit
  /// rules from one.
  @Test func dropsTheChildSessionVariable() async throws {
    let claude = try standIn(
      "if [ -n \"$CLAUDE_CODE_CHILD_SESSION\" ]; then echo inside >&2; exit 1; fi\ncat > /dev/null\n"
        + #"echo '{"ok":true,"warnings":[],"stored":["A"]}'"#)
    var inside = environment
    inside["CLAUDE_CODE_CHILD_SESSION"] = "1"
    let outcome = await PermissionRuleEditor.apply(
      add, folder: folder, account: nil, executableOverride: claude, environment: inside)
    #expect(outcome == .saved(warnings: [], stored: ["A"]))
  }

  @Test func aRefusalCarriesStderr() async throws {
    let claude = try standIn("cat > /dev/null\necho 'Empty parentheses — …' >&2\nexit 1")
    let outcome = await PermissionRuleEditor.apply(
      add, folder: folder, account: nil, executableOverride: claude, environment: environment)
    #expect(outcome == .refused("Empty parentheses — …"))
  }

  @Test func aMissingClaudeIsARefusal() async {
    let outcome = await PermissionRuleEditor.apply(
      add, folder: folder, account: nil,
      executableOverride: folder.appending(path: "no-claude-here"), environment: environment)
    #expect(outcome == .refused(ClaudeLaunch.notFound))
  }

  @Test func aStalledEditTimesOut() async throws {
    let claude = try standIn("exec sleep 5")
    let outcome = await PermissionRuleEditor.apply(
      add, folder: folder, account: nil, executableOverride: claude, timeout: .milliseconds(300),
      environment: environment)
    // `sleep` left to its end would exit 0 and read as saved.
    #expect(outcome == .refused("Claude Code took too long to save the rule."))
  }
}
