import Darwin
import DrakarKit
import Foundation
import Testing

@Suite("The VS Code window a session runs in")
struct VSCodeWindowTests {
  private let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "drakar-ide-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func lock(_ port: Int, _ json: String, in directory: URL? = nil) throws {
    try Data(json.utf8).write(to: (directory ?? self.directory).appending(path: "\(port).lock"))
  }

  @Test func theLinkShowsTheSession() {
    #expect(
      VSCodeWindow.link(sessionID: "742ad3c4-b95d-43d1-ae31-bcb987f01923")?.absoluteString
        == "vscode://anthropic.claude-code/open?session=742ad3c4-b95d-43d1-ae31-bcb987f01923")
  }

  @Test func thePortNamesTheWindowsFolder() throws {
    try lock(
      50266, #"{"pid":1252,"workspaceFolders":["/p/drakar"],"ideName":"Visual Studio Code"}"#)
    try lock(29010, #"{"pid":1252,"workspaceFolders":["/p/apps"],"ideName":"Visual Studio Code"}"#)
    #expect(VSCodeWindow.folder(listeningOn: [4000, 50266], in: [directory]) == "/p/drakar")
  }

  /// The lock may be in any account's folder: the extension writes where its own
  /// `CLAUDE_CONFIG_DIR` points, not where the session's account is.
  @Test func everyFolderIsLookedIn() throws {
    let other = directory.appending(path: "other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try lock(50266, #"{"workspaceFolders":["/p/drakar"]}"#, in: other)
    #expect(VSCodeWindow.folder(listeningOn: [50266], in: [directory, other]) == "/p/drakar")
  }

  @Test func noLockOrNoFolderIsNothing() throws {
    try lock(50266, #"{"workspaceFolders":[]}"#)
    try lock(50267, "not json")
    #expect(VSCodeWindow.folder(listeningOn: [50266, 50267, 50268], in: [directory]) == nil)
  }

  @Test func aListeningSocketIsFound() throws {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    try #require(socket >= 0)
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        bind(socket, pointer, length) == 0 && getsockname(socket, pointer, &length) == 0
      }
    }
    try #require(bound && listen(socket, 1) == 0)
    let port = Int(UInt16(bigEndian: address.sin_port))
    #expect(ProcessAncestry.listeningPorts(of: getpid()).contains(port))
  }

  @Test func aProcessThatIsGoneListensOnNothing() {
    #expect(ProcessAncestry.listeningPorts(of: 999_999).isEmpty)
  }
}
