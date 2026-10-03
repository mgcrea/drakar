import DrakarKit
import Foundation
import Testing

@Suite("Being claude's editor")
struct IDEProtocolTests {

  private var requests: [IDEMessage] {
    get throws { try Fixture.ideRequests.lines.compactMap(IDEMessage.init) }
  }

  /// What a real interactive claude 2.1.288 sent, in order, while editing one file.
  @Test func readsTheCapturedSession() throws {
    let messages = try requests
    #expect(messages.count == 8)
    guard messages.count == 8 else { return }
    #expect(
      messages[0] == .request(id: .number(0), call: .initialize(protocolVersion: "2025-11-25")))
    #expect(messages[1] == .notification(method: "notifications/initialized", params: .object([:])))
    #expect(
      messages[2] == .notification(method: "ide_connected", params: .object(["pid": .number(4242)]))
    )
    #expect(messages[3] == .request(id: .number(1), call: .listTools))
    #expect(messages[4] == .request(id: .number(2), call: .tool(.closeAllDiffTabs)))
    guard case .request(let id, .tool(.openDiff(let diff))) = messages[5] else {
      Issue.record("message 5 is \(messages[5])")
      return
    }
    #expect(id == .number(3))
    #expect(diff.oldFilePath == "/Users/me/project/notes.md")
    #expect(diff.newContents == "alpha\nBETA\ngamma\n")
    #expect(diff.tabName.contains("notes.md"))
    #expect(messages[6] == .request(id: .number(4), call: .tool(.closeTab(diff.tabName))))
  }

  @Test func answersInTheExtensionsShapes() throws {
    let accepted = IDEReply.result(id: .number(3), IDEReply.diffAccepted(contents: "new\n"))
    #expect(
      accepted["result"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } == [
        "FILE_SAVED", "new\n",
      ])
    let rejected = IDEReply.diffRejected(tabName: "tab")
    #expect(
      rejected["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } == [
        "DIFF_REJECTED", "tab",
      ])
    #expect(
      IDEReply.initialize(protocolVersion: "2025-11-25")["protocolVersion"] == .string("2025-11-25")
    )
  }

  /// Only the tools Drakar honours are offered: the model sees each one as mcp__ide__*.
  @Test func listsTheToolsItCanHonour() {
    let names = IDEReply.tools["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    #expect(names.contains("openDiff"))
    #expect(names.contains("close_tab"))
    #expect(names.contains("openFile"))
    #expect(!names.contains("executeCode"))
  }

  @Test func describesTheWorkspace() throws {
    let reply = IDEReply.workspaceFolders(["/Users/me/project"])
    let text = try #require(reply["content"]?.arrayValue?.first?["text"]?.stringValue)
    let json = try JSONValue.parse(Data(text.utf8))
    #expect(json["success"] == .bool(true))
    #expect(json["folders"]?.arrayValue?.first?["path"] == .string("/Users/me/project"))
    #expect(json["folders"]?.arrayValue?.first?["uri"] == .string("file:///Users/me/project/"))
  }

  @Test func ignoresResponsesAndNoise() {
    #expect(IDEMessage(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == nil)
    #expect(IDEMessage(Data("not json".utf8)) == nil)
  }

  @Test func diffsAProposalAgainstTheFileOnDisk() {
    let diff = OpenDiff(
      oldFilePath: "/p/a", newFilePath: "/p/a", newContents: "a\nB\nc\n", tabName: "t")
    let change = diff.change(existing: "a\nb\nc\n")
    #expect(change.addedCount == 1)
    #expect(change.removedCount == 1)
    #expect(!change.isNewFile)
    #expect(diff.change(existing: nil).isNewFile)
  }
}

@Suite("The lock file")
struct IDELockFileTests {

  @Test func writesWhatTheCLIReads() {
    let lock = IDELockFile(
      port: 54500, pid: 42, workspaceFolders: ["/p"], ideName: "Drakar", authToken: "t")
    #expect(
      lock.json
        == .object([
          "pid": .number(42), "workspaceFolders": .array([.string("/p")]),
          "ideName": .string("Drakar"), "transport": .string("ws"),
          "runningInWindows": .bool(false), "authToken": .string("t"),
        ]))
    #expect(lock.file(in: URL(filePath: "/x/ide")).path == "/x/ide/54500.lock")
    let account = ClaudeAccount(
      directory: URL(filePath: "/Users/me/.claude-work"), isDefault: false)
    #expect(
      IDELockFile.directory(for: account).path(percentEncoded: false).hasSuffix(".claude-work/ide/")
    )
  }

  /// Only its own locks, and only the dead ones: VS Code's are none of its business.
  @Test func findsOnlyItsOwnDeadLocks() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-ide-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let locks = [
      ("1.lock", #"{"pid":101,"ideName":"Drakar"}"#),
      ("2.lock", #"{"pid":202,"ideName":"Drakar"}"#),
      ("3.lock", #"{"pid":303,"ideName":"Visual Studio Code"}"#),
    ]
    for (name, body) in locks {
      try body.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
    }
    let stale = IDELockFile.stale(in: folder, ideName: "Drakar", isAlive: { $0 == 101 })
    #expect(stale.map(\.lastPathComponent) == ["2.lock"])
  }
}
