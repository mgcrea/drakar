import DrakarKit
import Foundation
import Testing

@Suite("Naming a session")
struct SessionTitleTests {

  @Test func theFirstForkIsUnnumbered() {
    #expect(SessionTitle.forkName(of: "Pineapple", among: ["Pineapple"]) == "Pineapple (fork)")
  }

  @Test func laterForksCountOnFromTheHighest() {
    #expect(
      SessionTitle.forkName(of: "Pineapple", among: ["Pineapple", "Pineapple (fork)"])
        == "Pineapple (fork #2)")
    // A gap is not filled: #2 was renamed or removed, and a new fork must not reuse a
    // number that may still be listed somewhere else.
    #expect(
      SessionTitle.forkName(of: "Pineapple", among: ["Pineapple (fork)", "Pineapple (fork #3)"])
        == "Pineapple (fork #4)")
  }

  /// Numbered after its original, as a sibling, not "Pineapple (fork) (fork)".
  @Test func aForkOfAForkIsTheNextSibling() {
    #expect(
      SessionTitle.forkName(of: "Pineapple (fork #2)", among: ["Pineapple (fork #2)"])
        == "Pineapple (fork #3)")
    #expect(
      SessionTitle.forkName(of: "Pineapple (fork)", among: ["Pineapple (fork)"])
        == "Pineapple (fork #2)")
  }

  /// Another session's forks count only when they share the base exactly.
  @Test func otherTitlesDoNotCount() {
    #expect(
      SessionTitle.forkName(
        of: "Pineapple", among: ["Pineapple pie (fork #5)", "Pine (fork #4)", "(fork #9)"])
        == "Pineapple (fork)")
    #expect(
      SessionTitle.forkName(of: "Notes on (fork)ing", among: []) == "Notes on (fork)ing (fork)")
  }

  @Test func aNameIsCleanedAsTheCLICleansIt() {
    #expect(SessionTitle.clean("  Ship\tit\n") == "Shipit")
    #expect(SessionTitle.clean(" \n ") == nil)
    #expect(SessionTitle.clean(String(repeating: "a", count: 300))?.count == 200)
  }

  @Test func aNameWinsOverAnyAITitle() {
    let transcript = Transcript.history(
      lines: [
        #"{"type":"ai-title","aiTitle":"Draft"}"#,
        #"{"type":"custom-title","customTitle":"Mine"}"#,
        #"{"type":"ai-title","aiTitle":"Refined"}"#,
      ].map { Data($0.utf8) })
    #expect(transcript.title == "Mine")
    #expect(transcript.aiTitle == "Refined")
  }

  /// What a rename with no process writes is what the next read finds, the list's and the
  /// history's, and the CLI's own `custom-title.json` beside the transcript says the same.
  @Test func writingANameIsReadBack() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-title-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "abc.jsonl")
    let lines = [
      #"{"type":"custom-title","customTitle":"Old name","sessionId":"abc"}"#,
      #"{"type":"user","cwd":"/p","message":{"role":"user","content":"hi"}}"#,
      #"{"type":"ai-title","aiTitle":"Greeting","sessionId":"abc"}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

    try SessionTitle.write("New name", sessionID: "abc", transcript: file)

    let account = ClaudeAccount(directory: folder, isDefault: false)
    #expect(SessionIndex.summary(of: file, account: account)?.title == "New name")
    #expect(try Transcript.history(contentsOf: file).title == "New name")
    let sidecar = try JSONValue.parse(
      Data(contentsOf: folder.appending(path: "abc/custom-title.json")))
    #expect(sidecar["customTitle"]?.stringValue == "New name")
  }

  @Test func aNameReachesTheCommandLineAsOneArgument() {
    var command = ClaudeCommand(resumeSessionID: "abc")
    command.forksSession = true
    command.name = "-Pineapple (fork)"
    #expect(
      command.arguments.suffix(3) == ["--resume=abc", "--fork-session", "--name=-Pineapple (fork)"])
    #expect(!ClaudeCommand().arguments.contains { $0.hasPrefix("--name") })
  }

  /// The request the VS Code extension sends, which the CLI answered with success and a
  /// `custom-title` line (checked on 2.1.288).
  @Test func encodesARename() throws {
    let line = String(
      decoding: try ClientMessage.renameSession(
        requestID: "rename-1", title: "Plum", sessionID: "abc"
      )
      .line(), as: UTF8.self)
    #expect(
      line
        == #"{"request":{"session_id":"abc","source":"host","subtype":"rename_session","title":"Plum"},"request_id":"rename-1","type":"control_request"}"#
        + "\n")
  }
}
