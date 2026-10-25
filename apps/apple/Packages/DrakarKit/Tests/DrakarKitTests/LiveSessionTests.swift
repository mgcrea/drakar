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

  /// One started through a wrapper that does not `exec` is a grandchild, and still Drakar's.
  @Test func skipsDrakarsGrandchildren() throws {
    try write(41, #"{"pid":41,"sessionId":"mine","cwd":"/work/drakar"}"#)
    let parents: [Int32: Int32] = [41: 50, 50: 99, 99: 1]
    let live = LiveSession.read(
      account: account, isAlive: { _ in true }, parentOf: { parents[$0] }, ownPID: 99,
      temporaryDirectories: [])
    #expect(live.isEmpty)
  }

  /// Under the session host, what this app's own rows run is its own, whichever app
  /// started the host; another Drakar's there, and the same session open in a terminal, are
  /// still listed.
  @Test func skipsOnlyWhatThisAppRunsInTheSessionHost() throws {
    try write(41, #"{"pid":41,"sessionId":"mine","cwd":"/work/drakar"}"#)
    try write(42, #"{"pid":42,"sessionId":"anotherDrakars","cwd":"/work/drakar"}"#)
    try write(43, #"{"pid":43,"sessionId":"mine","cwd":"/work/drakar"}"#)
    try write(44, #"{"pid":44,"sessionId":"theirs","cwd":"/work/drakar"}"#)
    let parents: [Int32: Int32] = [41: 70, 42: 70, 70: 1, 43: 90, 44: 90, 90: 1]
    let live = LiveSession.read(
      account: account, isAlive: { _ in true }, parentOf: { parents[$0] }, ownPID: 99,
      hosts: [70], hostedHere: ["mine"], temporaryDirectories: [])
    #expect(live.map(\.sessionID) == ["anotherDrakars", "mine", "theirs"])
    #expect(live.map(\.pid) == [42, 43, 44])
  }

  /// A move signals the process the registry still lists for that session, between turns.
  @Test func endsOnlyTheProcessStillHoldingTheSession() throws {
    try write(41, #"{"pid":41,"sessionId":"s1","status":"idle"}"#)
    var signalled: [Int32] = []
    let ending = LiveSession(pid: 41, sessionID: "s1")
    #expect(
      LiveSession.end(
        ending, account: account, isAlive: { _ in true },
        signal: {
          signalled.append($0)
          return true
        }))
    #expect(signalled == [41])
  }

  @Test func neverEndsAReusedPidABusySessionOrAGoneOne() throws {
    try write(41, #"{"pid":41,"sessionId":"other","status":"idle"}"#)
    try write(42, #"{"pid":42,"sessionId":"s2","status":"busy"}"#)
    var signalled: [Int32] = []
    let signal: (Int32) -> Bool = {
      signalled.append($0)
      return true
    }
    let alive: (Int32) -> Bool = { _ in true }
    #expect(
      !LiveSession.end(
        LiveSession(pid: 41, sessionID: "s1"), account: account, isAlive: alive, signal: signal))
    #expect(
      !LiveSession.end(
        LiveSession(pid: 42, sessionID: "s2"), account: account, isAlive: alive, signal: signal))
    #expect(
      !LiveSession.end(
        LiveSession(pid: 43, sessionID: "s3"), account: account, isAlive: alive, signal: signal))
    #expect(signalled.isEmpty)
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
