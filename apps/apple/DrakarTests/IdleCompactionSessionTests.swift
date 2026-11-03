import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// An idle session compacting before its prompt cache expires, against a stand-in `claude`
/// whose every turn caches 250k tokens for an hour and that says auto-compact is on. The
/// timer itself is not waited for: `compactIfIdle` is what it calls when it goes off.
@MainActor
@Suite("Compacting an idle session", .serialized)
struct IdleCompactionSessionTests {
  private let folder: URL
  private let script: URL
  private let suite = "drakar-idle-compaction-\(UUID().uuidString)"
  private var stdin: URL { script.appendingPathExtension("stdin") }

  private static let usage =
    #"{"input_tokens":3,"cache_creation_input_tokens":250000,"cache_read_input_tokens":0,"output_tokens":9,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":250000}}"#

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-idle-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    script = folder.appending(path: "claude")
    // A prompt reading `/ask` asks to run a tool, and its turn ends once that is answered.
    let fake = """
      #!/bin/sh
      n=0
      finish() {
        echo '{"type":"assistant","message":{"id":"m'$n'","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"ok"}],"usage":\(Self.usage)},"parent_tool_use_id":null,"session_id":"s-idle"}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s-idle"}'
      }
      while read -r line; do
        printf '%s\\n' "$line" >> "$0.stdin"
        case "$line" in
          *'"type":"user"'*)
            n=$((n+1))
            [ $n -eq 1 ] && echo '{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s-idle","model":"m","permissionMode":"default"}'
            case "$line" in
              *'/ask'*) echo '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}}' ;;
              *) finish ;;
            esac
            ;;
          *'"type":"control_response"'*)
            finish
            ;;
          *get_context_usage*)
            id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
            echo '{"type":"control_response","response":{"subtype":"success","request_id":"'$id'","response":{"totalTokens":250000,"maxTokens":1000000,"categories":[],"isAutoCompactEnabled":true,"autoCompactThreshold":967000}}}'
            ;;
        esac
      done

      """
    try Data(fake.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func prompts() -> [String] {
    let text = (try? String(contentsOf: stdin, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line in
      guard line.contains(#""type":"user""#),
        let json = try? JSONValue.parse(Data(line.utf8)),
        let content = json["message"]?["content"]
      else { return nil }
      if let text = content.stringValue { return text }
      return content.arrayValue?.compactMap { $0["text"]?.stringValue }.joined()
    }
  }

  /// One turn ended, its usage and the CLI's context reply in.
  private func idleSession(first: String? = nil, compacts: Bool = true) async throws
    -> AgentSession
  {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(compacts, forKey: PreferenceKey.compactsIdle)
    defaults.set(first ?? "", forKey: PreferenceKey.compactionFirst)
    let session = AgentSession(folder: folder)
    session.executableOverride = script
    session.send("hi")
    try await waitFor { !session.status.isRunning && session.reportedContext != nil }
    #expect(session.reportedContext?.autoCompactThreshold == 967_000)
    return session
  }

  private func due(_ session: AgentSession) throws -> Date {
    try #require(IdleCompaction.due(session.transcript.promptCache))
  }

  private func fire(_ session: AgentSession, at date: Date, floor: Int = 200_000) async {
    await ClaudeChoice.$testSuite.withValue(suite) {
      session.compactIfIdle(at: date, floor: floor)
    }
  }

  @Test func compactsWhenDue() async throws {
    let session = try await idleSession()
    defer { session.stop() }
    await fire(session, at: try due(session))
    try await waitFor { prompts().count == 2 }
    #expect(prompts() == ["hi", "/compact"])
    #expect(
      session.transcript.entries.contains {
        if case .notice(let text) = $0.kind {
          text.hasSuffix("Compacting before the prompt cache expires.")
        } else {
          false
        }
      })
  }

  @Test func runsTheCommandFirstThenCompacts() async throws {
    let session = try await idleSession(first: "/distill")
    defer { session.stop() }
    await fire(session, at: try due(session))
    try await waitFor { prompts().count == 3 }
    #expect(prompts() == ["hi", "/distill", "/compact"])
  }

  @Test func theManualCompactRunsTheCommandFirstToo() async throws {
    let session = try await idleSession(first: "/distill")
    defer { session.stop() }
    #expect(session.canCompact)
    ClaudeChoice.$testSuite.withValue(suite) { session.compact() }
    try await waitFor { prompts().count == 3 }
    #expect(prompts() == ["hi", "/distill", "/compact"])
  }

  @Test func notWhenTurnedOffOrBelowTheFloor() async throws {
    let off = try await idleSession(compacts: false)
    defer { off.stop() }
    await fire(off, at: try due(off))
    let small = try await idleSession()
    defer { small.stop() }
    await fire(small, at: try due(small), floor: 400_000)
    try await Task.sleep(for: .milliseconds(300))
    #expect(prompts() == ["hi", "hi"])
  }

  /// The person came back to answer: what comes next is theirs to say, and a note says why
  /// nothing was compacted.
  @Test func aFirstCommandThatAskedDoesNotCompact() async throws {
    let session = try await idleSession(first: "/ask")
    defer { session.stop() }
    await fire(session, at: try due(session))
    try await waitFor { session.status.pendingPermissions.count == 1 }
    let pending = try #require(session.status.pendingPermissions.first)
    session.answer(pending, .allow(updatedInput: pending.request.input))
    try await waitFor { !session.status.isRunning }
    try await Task.sleep(for: .milliseconds(300))
    #expect(prompts() == ["hi", "/ask"])
    #expect(
      session.transcript.entries.contains {
        $0.kind == .notice("Not compacted: /ask stopped to ask you something.")
      })
  }

  /// What the person sends comes first, and the compaction does not go on after it.
  @Test func thePersonsMessageEndsTheRun() async throws {
    let session = try await idleSession(first: "/distill")
    defer { session.stop() }
    await fire(session, at: try due(session))
    session.send("actually, one more thing")
    try await waitFor { prompts().count == 3 }
    try await waitFor { !session.status.isRunning }
    try await Task.sleep(for: .milliseconds(300))
    #expect(prompts() == ["hi", "/distill", "actually, one more thing"])
  }
}
