import DrakarKit
import Foundation
import Testing

@Suite("A subagent's own transcript")
struct SubagentTranscriptTests {

  private func joined(_ lines: [Data]) -> Data {
    Data(lines.map { $0 + Data("\n".utf8) }.joined())
  }

  /// A temporary projects folder, removed after `body`.
  private func inProjects(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-subagents-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder)
  }

  /// Writes an empty file at `path` under `folder`, its folders made.
  @discardableResult
  private func plant(_ path: String, in folder: URL) throws -> URL {
    let file = folder.appending(path: path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: file)
    return file
  }

  /// The captured subagent file, every line a sidechain: its prompt, its Bash call with the
  /// rejection the stop gave it, and the interruption that ends it.
  @Test func foldsTheWholeConversation() throws {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "subagent-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    try joined(try Fixture.subagentFile.lines).write(to: file)
    var follower = TranscriptFollower(file: file, includesSidechains: true)
    var transcript = Transcript()
    try follower.catchUp(&transcript)
    let kinds = transcript.entries.map(\.kind)
    #expect(kinds.count == 3)
    guard kinds.count == 3 else { return }
    #expect(
      kinds[0]
        == .prompt(
          "Run exactly this command with the Bash tool in the foreground (run_in_background: false): python3 -c 'import time; time.sleep(90)' and then reply done."
        ))
    guard case .tool(let call) = kinds[1] else {
      Issue.record("entry 1 is \(kinds[1])")
      return
    }
    #expect(call.id == "toolu_01Ak2ftyoHCTnMr2dWQvwd3F")
    #expect(call.name == "Bash")
    #expect(call.summary == "python3 -c 'import time; time.sleep(90)'")
    #expect(call.result?.isError == true)
    #expect(
      call.result?.content.hasPrefix("The user doesn't want to proceed with this tool use.")
        == true)
    #expect(kinds[2] == .notice("Request interrupted by user for tool use"))
  }

  /// The flag survives a rewrite: the file read again from the start keeps its sidechains.
  @Test func keepsSidechainsAfterARewrite() throws {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "subagent-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    try joined(try Fixture.subagentFile.lines).write(to: file)
    var follower = TranscriptFollower(file: file, includesSidechains: true)
    var transcript = Transcript()
    try follower.catchUp(&transcript)
    let line = #"{"isSidechain":true,"type":"user","message":{"role":"user","content":"again"}}"#
    try Data((line + "\n").utf8).write(to: file)
    try follower.catchUp(&transcript)
    #expect(transcript.entries.map(\.kind) == [.prompt("again")])
  }

  /// A session's own history still leaves its subagents' lines out.
  @Test func historyStillDropsSidechains() throws {
    let transcript = Transcript.history(lines: try Fixture.subagentFile.lines)
    #expect(transcript.entries.isEmpty)
  }

  @Test func findsItsOwnAgent() throws {
    try inProjects { projects in
      let transcript = try plant("a.jsonl", in: projects)
      let agent = try plant("a/subagents/agent-x.jsonl", in: projects)
      #expect(
        SubagentTranscript.file(agentID: "x", transcriptFile: transcript)?.standardizedFileURL
          == agent.standardizedFileURL)
    }
  }

  /// A fork's agents are written under the fork's own session folder, beside the transcript.
  @Test func findsAForksAgentBesideIt() throws {
    try inProjects { projects in
      let transcript = try plant("a.jsonl", in: projects)
      let agent = try plant("b/subagents/agent-x.jsonl", in: projects)
      #expect(
        SubagentTranscript.file(agentID: "x", transcriptFile: transcript)?.standardizedFileURL
          == agent.standardizedFileURL)
    }
  }

  /// No path is built from an ID that is not a plain name, whatever is planted to match it.
  @Test func refusesAnIDThatIsNotAName() throws {
    try inProjects { projects in
      let transcript = try plant("a.jsonl", in: projects)
      try plant("b/subagents/agent-x.jsonl", in: projects)
      try plant("a/subagents/agent-../b/subagents/agent-x.jsonl", in: projects)
      try plant("a/subagents/agent-.jsonl", in: projects)
      let long = String(repeating: "a", count: 129)
      try plant("a/subagents/agent-\(long).jsonl", in: projects)
      for id in ["../b/subagents/agent-x", "", long] {
        #expect(SubagentTranscript.file(agentID: id, transcriptFile: transcript) == nil)
      }
    }
  }

  /// The session's own folder alone: a fork's file beside it is not looked for.
  @Test func ownFileLooksOnlyInItsOwnFolder() throws {
    try inProjects { projects in
      let transcript = try plant("a.jsonl", in: projects)
      try plant("b/subagents/agent-x.jsonl", in: projects)
      #expect(SubagentTranscript.ownFile(agentID: "x", transcriptFile: transcript) == nil)
      let agent = try plant("a/subagents/agent-x.jsonl", in: projects)
      #expect(
        SubagentTranscript.ownFile(agentID: "x", transcriptFile: transcript)?.standardizedFileURL
          == agent.standardizedFileURL)
      try plant("a/subagents/agent-../b/subagents/agent-x.jsonl", in: projects)
      #expect(
        SubagentTranscript.ownFile(
          agentID: "../b/subagents/agent-x", transcriptFile: transcript) == nil)
    }
  }

  /// Writes a 2.1.312 meta file for `toolUseID` at `path` under `folder`.
  private func meta(_ path: String, toolUseID: String, in folder: URL) throws {
    let file = try plant(path, in: folder)
    let json =
      #"{"agentType":"general-purpose","description":"Sleep","toolUseId":"\#(toolUseID)","spawnDepth":1,"requestShape":"background","requestNonInteractive":true,"model":"sonnet","finished":true}"#
    try Data(json.utf8).write(to: file)
  }

  /// A running subagent of a session read from its file: its agent ID by its call's id.
  @Test func findsTheAgentOfACall() throws {
    try inProjects { projects in
      let transcript = try plant("a.jsonl", in: projects)
      try meta("a/subagents/agent-w.meta.json", toolUseID: "toolu_other", in: projects)
      try meta("a/subagents/agent-x.meta.json", toolUseID: "toolu_1", in: projects)
      #expect(
        SubagentTranscript.agentID(forToolUseID: "toolu_1", transcriptFile: transcript) == "x")
    }
  }

  /// The session's own folder only: a fork's finished calls carry their agent ID.
  @Test func noCallMatchIsNil() throws {
    try inProjects { projects in
      let transcript = try plant("a.jsonl", in: projects)
      try meta("a/subagents/agent-w.meta.json", toolUseID: "toolu_other", in: projects)
      try meta("b/subagents/agent-x.meta.json", toolUseID: "toolu_1", in: projects)
      #expect(
        SubagentTranscript.agentID(forToolUseID: "toolu_1", transcriptFile: transcript) == nil)
      #expect(
        SubagentTranscript.agentID(
          forToolUseID: "toolu_1",
          transcriptFile: projects.appending(
            path: "none.jsonl")) == nil)
    }
  }

  @Test func skipsAMalformedMetaFile() throws {
    try inProjects { projects in
      let transcript = try plant("a.jsonl", in: projects)
      let broken = try plant("a/subagents/agent-v.meta.json", in: projects)
      try Data(#"{"toolUseId":"toolu_1""#.utf8).write(to: broken)
      try meta("a/subagents/agent-x.meta.json", toolUseID: "toolu_1", in: projects)
      #expect(
        SubagentTranscript.agentID(forToolUseID: "toolu_1", transcriptFile: transcript) == "x")
    }
  }

  /// A meta file whose name holds no plain agent ID gives none, even for the right call.
  @Test func refusesAMetaFileNotNamedByAnID() throws {
    try inProjects { projects in
      let transcript = try plant("a.jsonl", in: projects)
      try meta("a/subagents/agent-x.y.meta.json", toolUseID: "toolu_1", in: projects)
      try meta("a/subagents/agent-.meta.json", toolUseID: "toolu_1", in: projects)
      #expect(
        SubagentTranscript.agentID(forToolUseID: "toolu_1", transcriptFile: transcript) == nil)
    }
  }

  @Test func nothingIsNil() throws {
    try inProjects { projects in
      let transcript = try plant("a.jsonl", in: projects)
      try FileManager.default.createDirectory(
        at: projects.appending(path: "a/subagents"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: projects.appending(path: "b"), withIntermediateDirectories: true)
      #expect(SubagentTranscript.file(agentID: "x", transcriptFile: transcript) == nil)
    }
  }
}
