import DrakarKit
import Foundation
import Testing

@Suite("The live session registry")
struct SessionRegistryTests {

  private let account: ClaudeAccount
  private var sessions: URL { account.directory.appending(path: "sessions") }

  init() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "registry-\(UUID())")
    account = ClaudeAccount(directory: folder, isDefault: false)
    try FileManager.default.createDirectory(
      at: folder.appending(path: "sessions"), withIntermediateDirectories: true)
  }

  private func write(_ pid: Int32, _ json: String) throws {
    try Data(json.utf8).write(to: sessions.appending(path: "\(pid).json"))
    // The key file beside each registry entry is not JSON and must be skipped.
    try Data("secret".utf8).write(to: sessions.appending(path: "\(pid).abc.key"))
  }

  /// Captured from 2.1.288 (this Mac, 2026-10-03), pid and paths changed.
  @Test func readsWhatTheSessionSaysAboutItself() throws {
    try write(
      41,
      #"{"pid":41,"sessionId":"s1","cwd":"/work/drakar","startedAt":1791063576511,"version":"2.1.288","kind":"interactive","entrypoint":"claude-vscode","status":"waiting","waitingFor":"permission prompt","updatedAt":1791063683948}"#
    )
    let live = LiveSession.read(
      account: account, isAlive: { _ in true }, parentOf: { _ in 1 }, ownPID: 99,
      temporaryDirectories: [])
    #expect(live.count == 1)
    #expect(live.first?.cwd == "/work/drakar")
    #expect(live.first?.status == "waiting")
    #expect(live.first?.waitingFor == "permission prompt")
    #expect(live.first?.updatedAt == Date(timeIntervalSince1970: 1_791_063_683.948))
  }

  /// Drakar's own processes register too; they are read from memory, never from here.
  @Test func skipsDrakarsOwnChildrenAndTemporarySpawns() throws {
    try write(41, #"{"pid":41,"sessionId":"mine","cwd":"/work/drakar"}"#)
    try write(42, #"{"pid":42,"sessionId":"summarizer","cwd":"/private/var/folders/x/T"}"#)
    try write(43, #"{"pid":43,"sessionId":"theirs","cwd":"/work/drakar"}"#)
    let live = LiveSession.read(
      account: account, isAlive: { _ in true }, parentOf: { $0 == 41 ? 99 : 1 }, ownPID: 99,
      temporaryDirectories: ["/private/var/folders/x/T"])
    #expect(live.map(\.sessionID) == ["theirs"])
  }

  @Test func skipsAProcessThatIsGone() throws {
    try write(41, #"{"pid":41,"sessionId":"s1","cwd":"/w"}"#)
    #expect(
      LiveSession.read(
        account: account, isAlive: { _ in false }, parentOf: { _ in 1 }, ownPID: 99,
        temporaryDirectories: []
      ).isEmpty)
  }
}
